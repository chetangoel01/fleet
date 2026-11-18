// fleetd: answers "how is this Mac doing" as JSON on 127.0.0.1.
// It reads nothing until asked, apart from one timer that counts processor and network use for
// the last three hours' graphs. See README.md.

import Foundation
import IOKit
import IOKit.pwr_mgt
import Network
import SystemConfiguration

// MARK: Settings

var port: UInt16 = 4790
var dockerSocketOverride: String?
var once = false
/// The release this helper came from, which Xcode writes into the binary from project.yml.
let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"

var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--port": port = UInt16(arguments.next() ?? "") ?? port
    case "--docker-socket": dockerSocketOverride = arguments.next()
    case "--once": once = true
    default:
        FileHandle.standardError.write(Data("fleetd: unknown argument \(argument)\n".utf8))
        exit(2)
    }
}

// Started by launchd there is nowhere for a complaint to go, so it goes to a log of the helper's own.
let underLaunchd = getppid() == 1
if underLaunchd { freopen(NSHomeDirectory() + "/Library/Logs/fleetd.log", "a", stderr) }

// MARK: Helpers

struct Failure: Error { let message: String }

final class Box<T> { var value: T?; init() {} }

/// One queue owns all state, so nothing here needs a lock.
let work = DispatchQueue(label: "fleetd.work")
let counters = NSLock()
var spawned = 0
var requests = 0

/// A reading that could not be taken. Never reported as zero or "down".
func unknown(_ message: String) -> [String: Any] { ["state": "unknown", "error": message] }

func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

func oneDecimal(_ value: Double) -> NSDecimalNumber { NSDecimalNumber(string: String(format: "%.1f", value)) }

func sysctlValue<T>(_ name: String, _ initial: T) -> T? {
    var value = initial
    var size = MemoryLayout<T>.size
    let read = withUnsafeMutablePointer(to: &value) { sysctlbyname(name, $0, &size, nil, 0) == 0 }
    return read ? value : nil
}

/// Runs `body` on another thread and gives up after `seconds`.
func within<T>(_ seconds: Double, _ body: @escaping () -> T) -> T? {
    let box = Box<T>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async { box.value = body(); done.signal() }
    return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
}

/// Runs a tool and returns what it printed. The tool is stopped at the deadline.
func run(_ tool: String, _ toolArguments: [String], environment: [String: String] = [:],
         includeErrors: Bool = false, timeout: Double) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = toolArguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
    let output = Pipe()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = output
    process.standardError = includeErrors ? output : FileHandle.nullDevice
    try process.run()
    counters.lock(); spawned += 1; counters.unlock()

    // The reader owns the pipe: it reads until the tool lets go of its end, then closes ours.
    // Closing it from this thread while that read was still going crashed the helper on 2026-11-18,
    // the first time a tool ran past its deadline.
    let reading = output.fileHandleForReading
    let box = Box<Data>()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        box.value = (try? reading.readToEnd()) ?? Data()
        try? reading.close()
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        let pid = process.processIdentifier   // a tool that ignores the polite request is killed
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(pid, SIGKILL) } }
        throw Failure(message: "\(URL(fileURLWithPath: tool).lastPathComponent) timed out after \(Int(timeout)) s")
    }
    return String(decoding: box.value ?? Data(), as: UTF8.self)
}

// MARK: Readings taken in-process

let host = mach_host_self()

/// Memory in use, as Activity Monitor's "Memory Used": what is installed less the free pages and
/// the files the system keeps cached. Within 0.1 GB of Activity Monitor on a 48 GB Mac (2026-11-18).
func memoryUsedPct() -> Int? {
    var counts = vm_statistics64()
    var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let read = withUnsafeMutablePointer(to: &counts) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(host, HOST_VM_INFO64, $0, &size) }
    }
    guard read == KERN_SUCCESS, let installed = sysctlValue("hw.memsize", UInt64(0)), installed > 0,
          let page = sysctlValue("hw.pagesize", Int64(0)) else { return nil }
    // The free count includes the speculative pages, which are also among the cached files.
    let spare = Double(counts.free_count) - Double(counts.speculative_count) + Double(counts.external_page_count)
    return Int(((1 - spare * Double(page) / Double(installed)) * 100).rounded())
}

func memory() -> [String: Any] {
    guard let used = memoryUsedPct(), let level = sysctlValue("kern.memorystatus_level", Int32(0)),
          let swap = sysctlValue("vm.swapusage", xsw_usage()) else { return unknown("sysctl failed") }
    // free_pct is the kernel's own measure of how close the Mac is to running short, which is what
    // a warning should follow; it is not the rest of used_pct.
    return ["state": "ok", "used_pct": used, "free_pct": Int(level),
            "swap_used_mb": Int(swap.xsu_used / 1_048_576), "swap_total_mb": Int(swap.xsu_total / 1_048_576)]
}

/// Open files across the whole Mac against the kernel's limit, and how many vnodes (the
/// kernel's entries for files in use) are still free. Every open file pins a vnode, and
/// the vnode limit is the lower one: on 2026-11-18 m1-server ran out of vnodes with open
/// files at half their limit, and every program on it failed with "too many open files in system".
func openFiles() -> [String: Any] {
    guard let open = sysctlValue("kern.num_files", Int32(0)),
          let limit = sysctlValue("kern.maxfiles", Int32(0)),
          let freeVnodes = sysctlValue("kern.free_vnodes", Int32(0)),
          let vnodeLimit = sysctlValue("kern.maxvnodes", Int32(0)) else { return unknown("sysctl failed") }
    return ["state": "ok", "open": Int(open), "limit": Int(limit),
            "vnodes_free": Int(freeVnodes), "vnodes_limit": Int(vnodeLimit)]
}

func uptimeSeconds() -> Any {
    guard let boot = sysctlValue("kern.boottime", timeval()) else { return NSNull() }
    return Int(Date().timeIntervalSince1970) - boot.tv_sec
}

func power() -> [String: Any] {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return ["state": "none"] }
    defer { IOObjectRelease(service) }
    var unmanaged: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return unknown("battery registry unreadable") }
    var result: [String: Any] = ["state": "ok"]
    if properties["BatteryInstalled"] as? Bool == true {
        result["battery_pct"] = properties["CurrentCapacity"] as? Int ?? NSNull()
        result["charging"] = properties["IsCharging"] as? Bool ?? false
    }
    result["on_adapter"] = properties["ExternalConnected"] as? Bool ?? false
    if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
        // Adapter input in milliwatts: on a charging laptop this includes charging.
        if let input = telemetry["SystemPowerIn"] as? Int { result["watts_in"] = oneDecimal(Double(input) / 1000) }
        if let load = telemetry["SystemLoad"] as? Int { result["watts_load"] = oneDecimal(Double(load) / 1000) }
    }
    return result
}

func disks() -> [String: Any] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey,
                                  .volumeIsInternalKey, .volumeIsLocalKey]
    let found: [[String: Any]]? = within(3) {
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                           options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { url -> [String: Any]? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal == true,
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            return ["name": values.volumeName ?? url.lastPathComponent, "path": url.path,
                    "free_gb": oneDecimal(Double(values.volumeAvailableCapacity ?? 0) / 1e9),
                    "total_gb": oneDecimal(Double(total) / 1e9),
                    "internal": values.volumeIsInternal ?? false]
        }
    }
    guard let found else { return unknown("volume list timed out after 3 s") }
    return ["state": "ok", "items": found]
}

// MARK: Containers, read from Docker's own socket

func dockerSocketPath() -> String? {
    if let dockerSocketOverride { return dockerSocketOverride }
    for path in [NSHomeDirectory() + "/.docker/run/docker.sock", "/var/run/docker.sock"] {
        var info = stat()
        if stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK { return path }
    }
    return nil
}

func waitFor(_ descriptor: Int32, _ events: Int32, until deadline: Date) -> Bool {
    var entry = pollfd(fd: descriptor, events: Int16(events), revents: 0)
    return poll(&entry, 1, Int32(max(0, deadline.timeIntervalSinceNow * 1000))) > 0
}

/// One HTTP request over a Unix socket: a GET, or a POST when there is a JSON body. Every
/// step shares one deadline, because a hung Docker engine accepts the connection and then never answers.
func unixRequest(socketPath: String, path: String, body: Data? = nil, timeout: Double) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw Failure(message: "socket: \(String(cString: strerror(errno)))") }
    defer { close(descriptor) }
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(socketPath.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw Failure(message: "socket path too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected != 0 {
        guard errno == EINPROGRESS else { throw Failure(message: "connect: \(String(cString: strerror(errno)))") }
        guard waitFor(descriptor, POLLOUT, until: deadline) else { throw Failure(message: "no answer within \(Int(timeout)) s") }
    }

    var request = Array("\(body == nil ? "GET" : "POST") \(path) HTTP/1.0\r\nHost: docker\r\n".utf8)
    if let body { request += Array("Content-Type: application/json\r\nContent-Length: \(body.count)\r\n".utf8) }
    request += Array("\r\n".utf8) + Array(body ?? Data())
    guard send(descriptor, request, request.count, 0) == request.count else {
        throw Failure(message: "send: \(String(cString: strerror(errno)))")
    }

    var reply = Data()
    var buffer = [UInt8](repeating: 0, count: 65_536)
    while true {
        guard waitFor(descriptor, POLLIN, until: deadline) else { throw Failure(message: "no answer within \(Int(timeout)) s") }
        let count = recv(descriptor, &buffer, buffer.count, 0)
        if count == 0 { break }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            throw Failure(message: "recv: \(String(cString: strerror(errno)))")
        }
        reply.append(buffer, count: count)
    }

    guard let split = reply.range(of: Data("\r\n\r\n".utf8)) else { throw Failure(message: "reply was not HTTP") }
    let head = String(decoding: reply[..<split.lowerBound], as: UTF8.self)
    let statusParts = head.prefix { $0 != "\r" }.split(separator: " ")
    guard statusParts.count > 1, statusParts[1] == "200" || statusParts[1] == "201" else {
        throw Failure(message: "engine answered HTTP \(statusParts.count > 1 ? String(statusParts[1]) : "?")")
    }
    let body = Data(reply[split.upperBound...])
    return head.lowercased().contains("transfer-encoding: chunked") ? try dechunk(body) : body
}

func dechunk(_ data: Data) throws -> Data {
    var result = Data()
    var rest = data[...]
    while let lineEnd = rest.range(of: Data("\r\n".utf8)) {
        let sizeText = String(decoding: rest[..<lineEnd.lowerBound], as: UTF8.self).prefix { $0 != ";" }
        guard let size = Int(sizeText, radix: 16) else { throw Failure(message: "bad chunk size") }
        if size == 0 { return result }
        let start = lineEnd.upperBound
        guard rest.endIndex - start >= size else { throw Failure(message: "reply cut short") }
        result.append(rest[start..<(start + size)])
        rest = rest[min(start + size + 2, rest.endIndex)...]
    }
    return result
}

func containers() -> [String: Any] {
    guard let socketPath = dockerSocketPath() else { return ["state": "none"] }
    do {
        let body = try unixRequest(socketPath: socketPath, path: "/containers/json?all=1", timeout: 3)
        guard let list = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
            throw Failure(message: "engine reply was not a container list")
        }
        let items = list.map { container -> [String: Any] in
            let name = ((container["Names"] as? [String])?.first ?? "?").drop { $0 == "/" }
            let ports = Set(((container["Ports"] as? [[String: Any]]) ?? []).compactMap { $0["PublicPort"] as? Int }).sorted()
            return ["name": String(name), "state": container["State"] as? String ?? "?",
                    "status": container["Status"] as? String ?? "", "ports": ports]
        }
        return ["state": "ok", "items": items.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

/// Downloads in progress. qBittorrent's web interface answers without a password only
/// from inside its own container, so the question is put there, through Docker. This one
/// fixed command is the only thing the helper ever runs in a container.
func downloads(_ containers: [String: Any]) -> [String: Any] {
    let running = (containers["items"] as? [[String: Any]])?.contains {
        $0["name"] as? String == "qbittorrent" && $0["state"] as? String == "running"
    }
    guard running == true, let socketPath = dockerSocketPath() else { return ["state": "none"] }
    do {
        // wget gets its own limit, so a hung qBittorrent cannot leave one running per status.
        let command = ["wget", "-T", "2", "-qO-", "http://127.0.0.1:8080/api/v2/torrents/info?filter=downloading"]
        let create = try JSONSerialization.data(withJSONObject: ["AttachStdout": true, "Tty": true, "Cmd": command])
        let created = try unixRequest(socketPath: socketPath, path: "/containers/qbittorrent/exec", body: create, timeout: 2)
        guard let id = (try JSONSerialization.jsonObject(with: created) as? [String: Any])?["Id"] as? String else {
            throw Failure(message: "engine did not start the question")
        }
        let start = try JSONSerialization.data(withJSONObject: ["Detach": false, "Tty": true])
        let output = try unixRequest(socketPath: socketPath, path: "/exec/\(id)/start", body: start, timeout: 2)
        guard let list = try? JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
            throw Failure(message: "qBittorrent did not answer with a list")
        }
        let items = list.map { torrent -> [String: Any] in
            var item: [String: Any] = [
                "name": torrent["name"] as? String ?? "?",
                "pct": Int(((torrent["progress"] as? Double ?? 0) * 100).rounded(.down)),
                "bytes_per_s": torrent["dlspeed"] as? Int ?? 0,
            ]
            // qBittorrent reports 100 days when it cannot estimate.
            if let eta = torrent["eta"] as? Int, eta < 8_640_000 { item["eta_s"] = eta }
            return item
        }
        return ["state": "ok", "items": items.sorted { ($0["pct"] as? Int ?? 0) > ($1["pct"] as? Int ?? 0) }]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

// MARK: Scheduled assistant jobs, read from the apps' own files

/// Jobs the Claude and Codex apps run on a schedule on this Mac, switched on ones only.
/// Both apps' files are undocumented, so anything unreadable is skipped, not reported.
/// Prompts, folders and session ids stay out of the status.
func schedules() -> [String: Any] {
    let files = FileManager.default
    var items: [[String: Any]] = []

    // Claude keeps one scheduled-tasks.json per account and organisation.
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let sessions = NSHomeDirectory() + "/Library/Application Support/Claude/claude-code-sessions"
    for account in (try? files.contentsOfDirectory(atPath: sessions)) ?? [] {
        for organisation in (try? files.contentsOfDirectory(atPath: "\(sessions)/\(account)")) ?? [] {
            guard let data = files.contents(atPath: "\(sessions)/\(account)/\(organisation)/scheduled-tasks.json"),
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = document["scheduledTasks"] as? [[String: Any]] else { continue }
            for task in tasks where task["enabled"] as? Bool == true {
                guard let name = task["displayName"] as? String ?? task["id"] as? String else { continue }
                var item: [String: Any] = ["app": "Claude", "name": name]
                if let cron = task["cronExpression"] as? String { item["schedule"] = cron }
                if let once = task["fireAt"] as? Double { item["next_run"] = iso(Date(timeIntervalSince1970: once / 1000)) }
                if let last = (task["lastRunAt"] as? String).flatMap(fractional.date) { item["last_run"] = iso(last) }
                items.append(item)
            }
        }
    }

    // Codex keeps one automation.toml per automation.
    let automations = NSHomeDirectory() + "/.codex/automations"
    for id in (try? files.contentsOfDirectory(atPath: automations)) ?? [] {
        guard let text = try? String(contentsOfFile: "\(automations)/\(id)/automation.toml", encoding: .utf8) else { continue }
        func value(_ key: String) -> String? {
            text.split(separator: "\n").first { $0.hasPrefix("\(key) = ") }
                .map { $0.dropFirst(key.count + 3).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        guard value("status") == "ACTIVE" else { continue }
        var item: [String: Any] = ["app": "Codex", "name": value("name") ?? id]
        if let rule = value("rrule") { item["schedule"] = rule }
        items.append(item)
    }
    return ["state": "ok", "items": items.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
}

// MARK: Readings that need a system tool

func jobs() -> [String: Any] {
    do {
        let text = try run("/bin/launchctl", ["list"], timeout: 3)
        var count = 0
        var failed: [[String: Any]] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: "\t")
            guard fields.count == 3, !fields[2].hasPrefix("com.apple."), !fields[2].hasPrefix("application.") else { continue }
            count += 1
            // The helper's own job is left out: it leaves with 1 after every upgrade so that launchd starts the new copy.
            if let status = Int(fields[1]), status != 0, fields[2] != "com.chetangoel.fleetd" {
                failed.append(["label": String(fields[2]), "last_exit": status, "running": fields[0] != "-"])
            }
        }
        return ["state": "ok", "count": count, "failed": failed]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

// MARK: Keeping this Mac awake

/// The one thing the helper does when told to. The choice is kept in a file, because the helper
/// restarts with every upgrade and the Mac should stay awake through that.
let awakeFile = NSHomeDirectory() + "/Library/Application Support/Fleet/awake-until"
/// When to stop keeping this Mac awake, as unix time. 0 is "until told to stop"; nil is "not keeping it awake".
var awakeUntil = (try? String(contentsOfFile: awakeFile, encoding: .utf8)).flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
var awakeAssertion = IOPMAssertionID(0)

func keepAwake(until: Double?) {
    awakeUntil = until
    if let until {
        try? FileManager.default.createDirectory(atPath: (awakeFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? String(until).write(toFile: awakeFile, atomically: true, encoding: .utf8)
    } else {
        try? FileManager.default.removeItem(atPath: awakeFile)
    }
    holdOrRelease()
    lastSnapshot = nil  // the next status shows the change
}

/// Makes what macOS is told match the choice, and ends a timed one. Run at start and on the sampler's 20 s tick.
func holdOrRelease() {
    if let until = awakeUntil, until != 0, until <= Date().timeIntervalSince1970 { return keepAwake(until: nil) }
    if awakeUntil != nil, awakeAssertion == 0 {
        // The same request `caffeinate -i` makes: no sleep while idle. The display may still sleep.
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Kept awake from Fleet" as CFString, &awakeAssertion)
    } else if awakeUntil == nil, awakeAssertion != 0 {
        IOPMAssertionRelease(awakeAssertion)
        awakeAssertion = 0
    }
}

/// Carries out "POST /awake/on", "POST /awake/on?minutes=120" or "POST /awake/off", and says whether
/// the request was one of them. It must carry an X-Fleet header and no Origin. A web page cannot add
/// the header without first asking the helper's leave, which is never given, and a browser puts
/// Origin on every request a page sends this way.
func awakeCommand(_ lines: [String]) -> Bool {
    let headers = lines.dropFirst().map { $0.lowercased() }
    let request = (lines.first ?? "").split(separator: " ")
    guard request.count == 3, request[0] == "POST", headers.contains(where: { $0.hasPrefix("x-fleet:") }),
          !headers.contains(where: { $0.hasPrefix("origin:") }) else { return false }
    let target = String(request[1]), timed = "/awake/on?minutes="
    if target == "/awake/off" {
        keepAwake(until: nil)
    } else if target == "/awake/on" {
        keepAwake(until: 0)
    } else if target.hasPrefix(timed), let minutes = Double(target.dropFirst(timed.count)), (1...10080).contains(minutes) {
        keepAwake(until: Date().timeIntervalSince1970 + minutes * 60)
    } else {
        return false
    }
    return true
}

/// What is stopping this Mac from sleeping when idle, whether Fleet is one of those things, and
/// how long the Mac's own setting lets it sit idle before sleeping (0 is never).
func awake() -> [String: Any] {
    var unmanaged: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
          let byProcess = unmanaged?.takeRetainedValue() as NSDictionary? else { return unknown("sleep assertions unreadable") }
    let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion"]
    var holders: [[String: String]] = []
    for (_, value) in byProcess {
        for assertion in (value as? [[String: Any]]) ?? [] {
            guard let type = assertion["AssertType"] as? String, blocking.contains(type),
                  (assertion["AssertLevel"] as? Int ?? 255) != 0 else { continue }
            holders.append(["process": assertion["Process Name"] as? String ?? "?",
                            "reason": String((assertion["AssertName"] as? String ?? "").prefix(80))])
        }
    }
    holders.sort { ($0["process"] ?? "", $0["reason"] ?? "") < ($1["process"] ?? "", $1["reason"] ?? "") }
    var fleet: [String: Any] = ["on": awakeUntil != nil]
    if let until = awakeUntil, until != 0 { fleet["until"] = iso(Date(timeIntervalSince1970: until)) }
    var result: [String: Any] = ["state": "ok", "held_by": Array(holders.prefix(8)), "fleet": fleet]
    if let settings = SCDynamicStoreCopyValue(nil, "State:/IOKit/PowerManagement/CurrentSettings" as CFString) as? [String: Any],
       let minutes = settings["System Sleep Timer"] as? Int { result["sleep_after_min"] = minutes }
    return result
}

/// CPU temperature and fan speeds, from Cooler's read-only probe where Cooler is installed.
func thermal() -> [String: Any] {
    let folder = "/Library/Application Support/Cooler"
    guard FileManager.default.isExecutableFile(atPath: folder + "/cooler") else { return ["state": "none"] }
    // While Cooler's fan curve is running it rewrites this file every few seconds, so reading it is free.
    if let data = FileManager.default.contents(atPath: folder + "/status.json"),
       let written = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let time = (written["time"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) }),
       Date().timeIntervalSince(time) < 60, let cpu = written["cpu"] as? Double {
        let targets = (written["targets"] as? [NSNumber] ?? []).map { $0.intValue }
        return ["state": "ok", "cpu_c": oneDecimal(cpu), "fans_rpm": targets, "source": "cooler status file"]
    }
    do {
        let text = try run(folder + "/cooler", ["probe"], timeout: 3)
        guard let sample = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let values = sample["values"] as? [String: Any], let hardware = sample["hardware"] as? [String: Any],
              let hottest = ((hardware["cpu"] as? [String]) ?? []).compactMap({ values[$0] as? Double }).max() else {
            throw Failure(message: "unexpected probe output")
        }
        let fans = (0..<(hardware["fans"] as? Int ?? 0)).compactMap { values["F\($0)Ac"] as? Double }.map { Int($0) }
        return ["state": "ok", "cpu_c": oneDecimal(hottest), "fans_rpm": fans, "source": "cooler probe"]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

func busiest() -> [String: Any] {
    do {
        let text = try run("/bin/ps", ["-Aco", "pcpu=,rss=,comm="], timeout: 3)
        var topCPU = (name: "", value: -1.0)
        var topMemory = (name: "", value: -1.0)
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let cpu = Double(fields[0]), let rss = Double(fields[1]) else { continue }
            if cpu > topCPU.value { topCPU = (String(fields[2]), cpu) }
            if rss > topMemory.value { topMemory = (String(fields[2]), rss) }
        }
        return ["state": "ok",
                "cpu": ["name": topCPU.name, "pct": oneDecimal(topCPU.value)],
                "memory": ["name": topMemory.name, "mb": Int(topMemory.value / 1024)]]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

func timeMachine() -> [String: Any] {
    // Time Machine's own preferences list every completed backup. They are read through the preferences
    // system: a launchd job has no Full Disk Access, so it can neither run `tmutil latestbackup` nor open
    // the preferences file itself.
    let domain = "com.apple.TimeMachine" as CFString
    func setting(_ key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)
    }
    CFPreferencesSynchronize(domain, kCFPreferencesAnyUser, kCFPreferencesCurrentHost)   // drop this process's cached copy
    let destinations = setting("Destinations") as? [[String: Any]] ?? []
    guard !destinations.isEmpty else { return ["state": "none"] }
    var result: [String: Any] = ["state": "ok", "automatic": setting("AutoBackup") as? Bool ?? false,
                                 "destinations": destinations.compactMap { $0["LastKnownVolumeName"] as? String }]
    if let latest = destinations.compactMap({ ($0["SnapshotDates"] as? [Date])?.max() }).max() { result["latest"] = iso(latest) }
    return result
}

func brewOutdated() -> [String: Any] {
    let brew = "/opt/homebrew/bin/brew"
    guard FileManager.default.isExecutableFile(atPath: brew) else { return ["state": "none"] }
    do {
        // Uses brew's last fetched data: this never contacts the network.
        let text = try run(brew, ["outdated", "--quiet"],
                           environment: ["HOMEBREW_NO_AUTO_UPDATE": "1", "PATH": "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
                           timeout: 60)
        let names = text.split(separator: "\n").map(String.init)
        return ["state": "ok", "outdated": names.count, "names": names]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

/// A slow reading. A request never waits for it: it gets the last value, and a
/// refresh starts in the background when that value is older than `maxAge`, or when
/// `changed` reports something newer than the last read began. In that second case the
/// old value is known to be wrong, so requests get "pending" until the new one is in.
final class Slow {
    let maxAge: Double
    let read: () -> [String: Any]
    let changed: () -> Date?
    var value: [String: Any] = ["state": "pending"]
    var checked: Date?
    var began = Date.distantPast
    var busy = false

    init(maxAge: Double, changed: @escaping () -> Date? = { nil }, read: @escaping () -> [String: Any]) {
        self.maxAge = maxAge; self.changed = changed; self.read = read
    }

    func current() -> [String: Any] {
        let stale = changed().map { $0 > began } ?? false
        if !busy, stale || (checked.map { Date().timeIntervalSince($0) > maxAge } ?? true) {
            busy = true
            began = Date()
            if stale { value = ["state": "pending"]; checked = nil }
            DispatchQueue.global(qos: .utility).async {
                let fresh = self.read()
                work.async { self.value = fresh; self.checked = Date(); self.busy = false }
            }
        }
        var result = value
        if let checked { result["checked"] = iso(checked) }
        return result
    }
}

/// When Homebrew last changed what is installed or what it knows to be newest: an upgrade
/// relinks under `opt` and rewrites a cask's folder, and `brew update` rewrites its fetched data.
func brewChanged() -> Date? {
    let files = FileManager.default
    let casks = "/opt/homebrew/Caskroom"
    let watched = ["/opt/homebrew/opt", NSHomeDirectory() + "/Library/Caches/Homebrew/api"]
        + ((try? files.contentsOfDirectory(atPath: casks)) ?? []).map { casks + "/" + $0 }
    return watched.compactMap { (try? files.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
}

let slowBrew = Slow(maxAge: 6 * 60 * 60, changed: brewChanged, read: brewOutdated)

// MARK: Load and network

/// Counts the system only ever adds to. A reading is the difference between two of these.
struct Counts {
    var at = Date()
    var cores: [(busy: UInt32, total: UInt32)] = []     // ticks, per core
    var received: UInt32 = 0, sent: UInt32 = 0          // bytes, across the en interfaces
    var addresses: [String: String] = [:]               // interface: its IPv4 address
}

func counts() -> Counts {
    var found = Counts()
    var coreCount: natural_t = 0
    var info: processor_info_array_t?
    var infoCount: mach_msg_type_number_t = 0
    if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS, let info {
        let states = Int(CPU_STATE_MAX)
        found.cores = (0..<Int(coreCount)).map { core in
            let ticks = (0..<states).map { UInt32(bitPattern: info[core * states + $0]) }
            let total = ticks.reduce(0, &+)
            return (total &- ticks[Int(CPU_STATE_IDLE)], total)
        }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
    }
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0 else { return found }
    var entry = first
    while let current = entry {
        entry = current.pointee.ifa_next
        let name = String(cString: current.pointee.ifa_name)
        guard let address = current.pointee.ifa_addr, current.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
        if address.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en"), let data = current.pointee.ifa_data {
            let bytes = data.assumingMemoryBound(to: if_data.self).pointee
            found.received &+= bytes.ifi_ibytes
            found.sent &+= bytes.ifi_obytes
        } else if address.pointee.sa_family == UInt8(AF_INET) {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.addresses[name] = String(cString: host)
            }
        }
    }
    freeifaddrs(first)
    return found
}

// MARK: History

/// The last three hours, a point a minute, for the window's graphs. This is the helper's one timer:
/// it reads the counters every 20 seconds, adds up what changed, and closes a point once a minute.
/// The history is kept in memory, so a restarted helper starts with none.
var history: [[Int]] = []       // unix time, CPU %, memory free %, bytes a second down, bytes a second up
var ticks: [Counts] = []        // the last two counts, older first
var minute = (since: Date(), busy: UInt64(0), total: UInt64(0), received: UInt64(0), sent: UInt64(0))
let sampler = DispatchSource.makeTimerSource(queue: work)

func sample() {
    let now = counts()
    defer { ticks = Array((ticks + [now]).suffix(2)) }
    // A count more than 45 s old means the Mac slept, and nothing is known about the time between.
    guard let before = ticks.last, now.at.timeIntervalSince(before.at) < 45, before.cores.count == now.cores.count else {
        minute = (now.at, 0, 0, 0, 0)
        return
    }
    for (new, old) in zip(now.cores, before.cores) {
        minute.busy += UInt64(new.busy &- old.busy)
        minute.total += UInt64(new.total &- old.total)
    }
    minute.received += UInt64(now.received &- before.received)
    minute.sent += UInt64(now.sent &- before.sent)
    let seconds = now.at.timeIntervalSince(minute.since)
    guard seconds >= 55 else { return }
    history.append([Int(now.at.timeIntervalSince1970),
                    minute.total == 0 ? 0 : Int((Double(minute.busy) / Double(minute.total) * 100).rounded()),
                    memoryUsedPct() ?? 0,
                    Int(Double(minute.received) / seconds), Int(Double(minute.sent) / seconds)])
    history.removeFirst(max(0, history.count - 180))
    minute = (now.at, 0, 0, 0, 0)
}

/// How busy each core was and how much went over the network, measured since the timer's count from
/// 8 to 32 seconds ago (the two it keeps are 20 to 22 seconds apart, so one always is). Just after a start or a sleep there is none, and a tenth of a second is taken
/// now instead (a status waits for it, so it is kept short). The counters are 32-bit and wrap, which
/// the subtraction allows for; 32 seconds is short enough that a gigabit link cannot wrap them twice.
func loadAndNetwork() -> (cpu: [String: Any], network: [String: Any]) {
    var now = counts()
    var earlier = ticks.first { (8...32).contains(now.at.timeIntervalSince($0.at)) && $0.cores.count == now.cores.count }
    if earlier == nil {
        earlier = now
        usleep(100_000)
        now = counts()
    }
    let before = earlier!
    let seconds = max(now.at.timeIntervalSince(before.at), 0.001)
    let cores = zip(now.cores, before.cores).map { new, old -> Int in
        let total = new.total &- old.total
        return total == 0 ? 0 : Int((Double(new.busy &- old.busy) / Double(total) * 100).rounded())
    }
    let over = (seconds * 10).rounded() / 10
    let cpu: [String: Any] = cores.isEmpty ? unknown("processor counters unreadable")
        : ["state": "ok", "usage_pct": cores.reduce(0, +) / cores.count, "cores_pct": cores, "over_s": over]

    var network: [String: Any] = ["state": "ok", "over_s": over,
                                  "down_bps": Int(Double(now.received &- before.received) / seconds),
                                  "up_bps": Int(Double(now.sent &- before.sent) / seconds)]
    // The interface the default route uses, under the name System Settings gives it ("Wi-Fi", "Ethernet").
    let global = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
    if let primary = global?["PrimaryInterface"] as? String {
        network["interface"] = primary
        network["address"] = now.addresses[primary]
        let known = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        if let match = known.first(where: { SCNetworkInterfaceGetBSDName($0) as String? == primary }) {
            network["kind"] = SCNetworkInterfaceGetLocalizedDisplayName(match) as String?
        }
    }
    // Tailscale's own address: 100.64.0.0/10 on a tunnel interface.
    network["tailscale"] = now.addresses.first { name, address in
        let parts = address.split(separator: ".").compactMap { Int($0) }
        return name.hasPrefix("utun") && parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }?.value
    return (cpu, network)
}

/// The other devices on the tailnet that are online, and whether this Mac reaches each directly or
/// through one of Tailscale's relays. A peer nothing has been sent to lately has no path to report.
func tailnet() -> [String: Any] {
    let tool = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    guard FileManager.default.isExecutableFile(atPath: tool) else { return ["state": "absent"] }
    do {
        // Started without a terminal, the app's binary takes itself for the app unless told otherwise.
        let text = try run(tool, ["status", "--json"], environment: ["TAILSCALE_BE_CLI": "1"], timeout: 3)
        guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return unknown("status unreadable") }
        let peers = ((parsed["Peer"] as? [String: [String: Any]]) ?? [:]).values.compactMap { peer -> [String: Any]? in
            guard peer["Online"] as? Bool == true, let name = peer["HostName"] as? String, name != "localhost" else { return nil }
            let direct = !((peer["CurAddr"] as? String) ?? "").isEmpty
            return ["name": name, "direct": direct, "active": direct || peer["Active"] as? Bool == true, "relay": peer["Relay"] as? String ?? ""]
        }
        return ["state": "ok", "running": parsed["BackendState"] as? String == "Running", "peers": peers.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }]
    } catch let failure as Failure {
        return unknown(failure.message)
    } catch {
        return unknown(error.localizedDescription)
    }
}

// MARK: Status

/// CPU seconds used so far by this process (RUSAGE_SELF) or by the tools it started (RUSAGE_CHILDREN).
func cpuSeconds(_ who: Int32) -> NSDecimalNumber {
    var usage = rusage()
    getrusage(who, &usage)
    let micro = Double(usage.ru_utime.tv_usec) + Double(usage.ru_stime.tv_usec)
    return NSDecimalNumber(string: String(format: "%.3f", Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + micro / 1_000_000))
}

/// What this Mac is, for choosing its picture: the model code, the case colour where the Mac
/// records one (a number macOS's own device pictures are keyed by), and the macOS version.
func hardware() -> [String: Any] {
    var result: [String: Any] = [:]
    var size = 0
    if sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 {
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 { result["model"] = String(cString: buffer) }
    }
    let chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
    if chosen != 0 {
        // 16 bytes; the colour is the last four, little-endian.
        if let colour = IORegistryEntryCreateCFProperty(chosen, "housing-color" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data,
           colour.count == 16 {
            result["color"] = colour.suffix(4).reversed().reduce(0) { $0 << 8 | Int($1) }
        }
        IOObjectRelease(chosen)
    }
    let version = ProcessInfo.processInfo.operatingSystemVersion
    result["os"] = version.patchVersion == 0 ? "\(version.majorVersion).\(version.minorVersion)"
                                             : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    return result
}

func hostName() -> String {
    var buffer = [CChar](repeating: 0, count: 256)
    gethostname(&buffer, buffer.count)
    return String(String(cString: buffer).prefix { $0 != "." })
}

func status() -> [String: Any] {
    let start = Date()
    var slow: [String: Int] = [:]   // readings that took 100 ms or more, so a slow status names its cause
    func timed(_ name: String, _ read: () -> [String: Any]) -> [String: Any] {
        let began = Date()
        let value = read()
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        if ms >= 100 { slow[name] = ms }
        return value
    }
    let containerList = timed("containers", containers)
    let measured = loadAndNetwork()
    var result: [String: Any] = [
        "host": hostName(), "build": version, "time": iso(start), "uptime_s": uptimeSeconds(), "hardware": hardware(),
        "memory": memory(), "files": openFiles(), "power": timed("power", power), "disks": timed("disks", disks),
        "containers": containerList, "downloads": timed("downloads") { downloads(containerList) },
        "jobs": timed("jobs", jobs), "busiest": timed("busiest", busiest),
        "awake": timed("awake", awake), "thermal": timed("thermal", thermal),
        "time_machine": timeMachine(), "brew": slowBrew.current(), "schedules": timed("schedules", schedules),
        "cpu": measured.cpu, "network": measured.network, "tailnet": timed("tailnet", tailnet),
        "history": ["every_s": 60, "points": history],
    ]
    result["slow_ms"] = slow
    // Counted after the readings above, so the tools this status started are included.
    counters.lock(); let spawnedSoFar = spawned; counters.unlock()
    result["helper"] = ["requests": requests, "tools_run": spawnedSoFar,
                        "cpu_s": cpuSeconds(RUSAGE_SELF), "tools_cpu_s": cpuSeconds(RUSAGE_CHILDREN),
                        "open_files": (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd"))?.count ?? -1]
    result["took_ms"] = Int(Date().timeIntervalSince(start) * 1000)
    return result
}

var lastSnapshot: (at: Date, body: Data)?

/// Requests closer than 5 s apart share one snapshot.
func snapshot() -> Data {
    if let lastSnapshot, Date().timeIntervalSince(lastSnapshot.at) < 5 { return lastSnapshot.body }
    let body = (try? JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys])) ?? Data("{}".utf8)
    lastSnapshot = (Date(), body)
    return body
}

// MARK: Server

func handle(_ connection: NWConnection) {
    connection.start(queue: work)
    work.asyncAfter(deadline: .now() + 20) { connection.cancel() }  // no connection outlives 20 s
    connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
        let lines = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n")
        // Only a request addressed to this Mac is answered: the loopback address, or this
        // Mac's own name, which is how another Mac reaches it through Tailscale's forward
        // (on another port, since Tailscale holds its own). A web page that points some
        // other name at this helper gets nothing.
        let name = hostName().lowercased()
        let addressedHere = lines.contains { line in
            let line = line.lowercased()
            guard line.hasPrefix("host: ") else { return false }
            let host = line.dropFirst(6).prefix { $0 != ":" }
            return ["127.0.0.1", "localhost", name].contains(String(host))
                || (host.hasPrefix("\(name).") && host.hasSuffix(".ts.net"))
        }
        var code = "404 Not Found"
        var body = Data("{}".utf8)
        if addressedHere, lines.first?.hasPrefix("GET /status ") == true {
            requests += 1
            code = "200 OK"
            body = snapshot()
        } else if addressedHere, awakeCommand(lines) {
            code = "200 OK"
        }
        let head = "HTTP/1.1 \(code)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

if once {
    slowBrew.value = brewOutdated()
    slowBrew.checked = Date()
    let body = try JSONSerialization.data(withJSONObject: status(), options: [.sortedKeys, .prettyPrinted])
    FileHandle.standardOutput.write(body + Data("\n".utf8))
    exit(0)
}

// Homebrew sends an interrupt when the cask is removed. Leaving with 0 tells launchd not to
// start the helper again.
signal(SIGINT) { _ in _exit(0) }

// An upgrade puts a new copy of the helper where this one was started from, and this one then
// leaves so that launchd starts the new copy. It leaves only once macOS will run that copy:
// Homebrew marks the new app as approved a moment after installing it, and a copy started
// sooner is held for an "Open" prompt that nobody answers on a Mac with no one at its screen.
let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
func fileNumber(_ path: String) -> UInt64? {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
}
let startedAs = fileNumber(executable)

func leaveIfReplaced() {
    guard underLaunchd, let now = fileNumber(executable), now != startedAs else { return }
    // The download flag starts with a hexadecimal number, and 0x40 in it is the approval.
    // A copy with no flag at all starts as well.
    var flag = [CChar](repeating: 0, count: 256)
    if getxattr(executable, "com.apple.quarantine", &flag, 255, 0, 0) > 0,
       (Int(String(cString: flag).prefix { $0 != ";" }, radix: 16) ?? 0) & 0x40 == 0 { return }
    exit(1)  // launchd starts the helper again only after a failure
}

sampler.schedule(deadline: .now(), repeating: 20, leeway: .seconds(2))
sampler.setEventHandler { sample(); holdOrRelease(); leaveIfReplaced() }
sampler.resume()

let parameters = NWParameters.tcp
parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
parameters.allowLocalEndpointReuse = true
let listener = try NWListener(using: parameters)
listener.newConnectionHandler = handle
listener.stateUpdateHandler = { state in
    if case .failed(let error) = state {
        FileHandle.standardError.write(Data("fleetd: cannot listen on 127.0.0.1:\(port): \(error)\n".utf8))
        exit(1)
    }
}
listener.start(queue: work)
dispatchMain()

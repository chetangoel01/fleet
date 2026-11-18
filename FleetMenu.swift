// Fleet's menu bar item: one icon, and a menu that shows how each Mac is doing. The window
// (FleetWindow.swift) shows the same answers with more room.
//
// It keeps no timers. A status is fetched from each Mac's helper (fleetd) when the app
// starts, each time the menu opens, and when the window opens or comes to the front, so
// with both closed it does nothing. The menu opens at once on the last readings and fills
// in as the answers land.
//
//   Fleet.app/Contents/MacOS/Fleet                  run in the menu bar
//   Fleet.app/Contents/MacOS/Fleet --dump           print the menu as text, and its width, and exit
//   Fleet.app/Contents/MacOS/Fleet --open           run, and open the menu once at launch
//   Fleet.app/Contents/MacOS/Fleet --window PAGE    run, open the window on PAGE and print its window number
//   Fleet.app/Contents/MacOS/Fleet --status FILE    with any of the above: show one saved status in place of the three Macs

import AppKit
import Observation
import ServiceManagement
import SystemConfiguration

// MARK: - What the helper sends

struct Status: Decodable {
    var host: String
    var uptimeS: Double?
    var disks: Disks
    var memory: Memory
    var files: Files
    var power: Power
    var containers: Containers
    var jobs: Jobs
    var busiest: Busiest
    var awake: Awake
    var thermal: Thermal
    var timeMachine: TimeMachine
    var brew: Brew
    var downloads: Downloads?       // these three are newer than the rest; a helper without them still decodes
    var schedules: Schedules?
    var hardware: Hardware?
    var cpu: CPU?
    var network: Network?
    var tailnet: Tailnet?
    var history: History?
    var time: Date?                 // the helper's clock when it answered

    /// Drives short of space. Time Machine's are left out: a backup drive fills up by design.
    var lowDisks: [Disk] { (disks.items ?? []).filter { $0.low && timeMachine.destinations?.contains($0.name) != true } }

    struct Disks: Decodable { var state: String; var error: String?; var items: [Disk]? }
    struct Disk: Decodable {
        var name: String; var freeGb: Double; var totalGb: Double
        var low: Bool { freeGb < 25 || freeGb < totalGb * 0.1 }       // worth a warning
    }
    struct Memory: Decodable { var state: String; var error: String?; var freePct: Double?; var swapUsedMb: Double? }
    struct Files: Decodable {
        var state: String; var error: String?
        var open: Double?; var limit: Double?; var vnodesFree: Double?; var vnodesLimit: Double?
    }
    struct Power: Decodable {
        var state: String; var error: String?
        var batteryPct: Double?; var charging: Bool?; var onAdapter: Bool?; var wattsIn: Double?; var wattsLoad: Double?
    }
    struct Containers: Decodable { var state: String; var error: String?; var items: [Container]? }
    struct Container: Decodable { var name: String; var state: String; var status: String; var ports: [Int]? }
    struct Jobs: Decodable { var state: String; var error: String?; var failed: [Job]? }
    struct Job: Decodable { var label: String; var lastExit: Int; var running: Bool }
    struct Busiest: Decodable {
        var state: String; var error: String?; var cpu: CPU?; var memory: Mem?
        struct CPU: Decodable { var name: String; var pct: Double }
        struct Mem: Decodable { var name: String; var mb: Double }
    }
    struct Awake: Decodable {
        var state: String; var error: String?; var heldBy: [Holder]?
        var fleet: Kept?            // nil from a helper that cannot be told to keep its Mac awake
        var sleepAfterMin: Int?     // the Mac's own idle-sleep setting; 0 is never
    }
    struct Kept: Decodable { var on: Bool; var until: Date? }
    struct Holder: Decodable { var process: String }
    struct Thermal: Decodable { var state: String; var error: String?; var cpuC: Double?; var fansRpm: [Double]? }
    struct TimeMachine: Decodable { var state: String; var error: String?; var latest: Date?; var automatic: Bool?; var destinations: [String]? }
    struct Brew: Decodable { var state: String; var error: String?; var outdated: Int?; var names: [String]? }
    struct Downloads: Decodable { var state: String; var error: String?; var items: [Download]? }
    struct Download: Decodable { var name: String; var pct: Int; var bytesPerS: Double; var etaS: Double? }
    struct Schedules: Decodable { var state: String; var error: String?; var items: [Schedule]? }
    struct Schedule: Decodable { var app: String; var name: String; var schedule: String?; var lastRun: Date?; var nextRun: Date? }
    struct Hardware: Decodable { var model: String?; var color: Int?; var os: String? }
    struct CPU: Decodable { var state: String; var error: String?; var usagePct: Int?; var coresPct: [Int]? }
    struct Network: Decodable {
        var state: String; var error: String?
        var downBps: Double?; var upBps: Double?; var interface: String?; var kind: String?; var address: String?; var tailscale: String?
    }
    /// A point a minute: unix time, CPU %, memory free %, bytes a second down, bytes a second up.
    struct History: Decodable { var points: [[Double]]? }
    struct Tailnet: Decodable { var state: String; var error: String?; var running: Bool?; var peers: [Peer]? }
    struct Peer: Decodable { var name: String; var direct: Bool; var active: Bool; var relay: String }
}

struct Machine {
    var name: String
    var url: URL
    var ssh: String?        // the ssh name actions use to reach it; nil for the Mac this runs on
    var lan: String?        // an ssh name that reaches it over its own network, for when its Tailscale is off
    var sleeps = false      // a Mac that is often asleep or away: being offline is normal, so it raises no warning
    var server = false      // always on and plugged in: running on battery is worth a warning
}

/// The Macs shown, in menu order. The one this runs on is asked over loopback; the others by
/// name over the tailnet, where Tailscale forwards port 4791 to their helper
/// (`tailscale serve --bg --tcp 4791 tcp://127.0.0.1:4790` on each; 4790 itself is the helper's).
let machines: [Machine] = {
    // "--status FILE" shows one saved status in place of the three Macs, as a server, for states that are rare live.
    if let flag = CommandLine.arguments.firstIndex(of: "--status"), let file = CommandLine.arguments.dropFirst(flag + 1).first {
        return [Machine(name: "saved status", url: URL(fileURLWithPath: file), server: true)]
    }
    let here = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
    return ["m1-server", "mini", "m5-macbook"].map { name in
        name == here
            ? Machine(name: name, url: URL(string: "http://127.0.0.1:4790/status")!, server: name == "m1-server")
            : Machine(name: name, url: URL(string: "http://\(name):4791/status")!, ssh: name, lan: name == "m1-server" ? "m1-server-lan" : nil,
                      sleeps: name != "m1-server", server: name == "m1-server")
    }
}()

// MARK: - Actions

/// What clicking a row does. Only keeping a Mac awake changes one by itself: a prompt waits in
/// Claude for Return, and a command runs in a Terminal window where it can be watched and stopped.
enum Action {
    case awake(Machine, minutes: Int?)      // nil lets it sleep again; 0 keeps it awake until told otherwise
    case open(URL)
    case claude(prompt: String)
    case terminal(command: String)
    case window
    case login
    case quit

    /// The icon drawn before a row that does this.
    var symbol: String {
        switch self {
        case .awake(_, let minutes): minutes == nil ? "moon.zzz" : "cup.and.saucer"
        case .open: "arrow.up.forward.square"
        case .claude: "bubble.left"
        case .terminal: "terminal"
        case .window: "macwindow"
        case .login: SMAppService.mainApp.status == .enabled ? "checkmark.circle" : "circle"
        case .quit: "power"
        }
    }
}

func place(_ machine: Machine) -> String {
    guard let ssh = machine.ssh else { return "this Mac (\(machine.name))" }
    return "\(machine.name), working over ssh from this Mac (ssh \(ssh))"
}

func cleanUpPrompt(_ machine: Machine) -> String {
    """
    Free up disk space on \(place(machine)).

    Step 1, read-only: report free space per drive and the 15 largest reclaimable items with sizes (caches, Xcode DerivedData and old simulators, Docker images and build cache, brew cache, Downloads, Trash).

    Step 2: wait for me to pick. Delete nothing before I answer.

    Never touch backups, Time Machine history, the Immich library or media folders. Afterwards report the space freed per drive.
    """
}

func memoryPrompt(_ machine: Machine) -> String {
    """
    Check memory on \(place(machine)).

    Report memory pressure, swap used and the 10 processes using the most memory, grouped by app. Say which are safe to quit or restart and what each would free.

    Quit nothing until I pick. Leave containers, Syncthing, Caddy and Tailscale running.
    """
}

func stoppedPrompt(_ container: String, _ machine: Machine) -> String {
    """
    The \(container) container on \(place(machine)) is not running.

    Read its state and its last 100 log lines, and tell me the cause. If this has happened before, say what the earlier cause was.

    Don't restart or change anything until I say so.
    """
}

let syncPrompt = """
    Make the assistant setup the same on m5-macbook, mini and m1-server.

    First run ~/tools/instruction-check/check.sh and chezmoi status here, then compare rules files, Claude and Codex settings, hooks, plugins, MCP servers and skills on the other two over ssh. Show me every difference as a table before changing anything.

    m5-macbook's version wins; merge lists such as allow rules. Skip machine-specific items: device IDs, simulator approvals, window state, scheduled tasks, and the xcode-remote server and hook on the mini.

    Don't change security settings, sign-ins or keys. List those for me to apply with sync-security-settings.py.
    """

/// An interactive login shell, so brew is on the path and a shell wrapper around it applies.
/// The first line says which Mac is being upgraded: the Terminal window is always on this one.
/// A command for a Terminal window, run on `machine` through a login shell so Homebrew's and
/// Docker's tools are found. The window always opens on this Mac, so its first line says where the command runs.
func onMac(_ machine: Machine, _ command: String) -> String {
    let shell = "zsh -lic '\(command)'"
    guard let ssh = machine.ssh else { return "print 'On this Mac (\(machine.name))'\n\(shell)" }
    return "print 'On \(machine.name), over ssh from this Mac'\nssh -t \(ssh) \"\(shell)\""
}

enum Fetched {
    case waiting                // asked, or about to be, and not heard from since launch
    case status(Status)
    case failed(String)
}

func fetch(_ machine: Machine) async -> Fetched {
    var request = URLRequest(url: machine.url)
    request.timeoutInterval = 6
    do {
        let (data, _) = try await URLSession.shared.data(for: request)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return .status(try decoder.decode(Status.self, from: data))
    } catch let error as DecodingError {
        return .failed("unexpected answer: \(error)")
    } catch {
        return .failed(error.localizedDescription)
    }
}

// MARK: - Turning statuses into rows

/// How a dot or a value is coloured. `off` is a Mac that has not answered.
enum Level: String { case ok, warn, bad, off }

/// One line of a menu. A row with `children` opens a submenu.
struct Row {
    var title: String
    var value: String = ""
    var level: Level?            // colours the value: warn or bad
    var dot: Level?              // a status dot before the title
    var note: String?            // tooltip: why a reading could not be taken, or more about the row
    var symbol: String?          // an icon of the row's own, in place of its action's
    var extras: [Row] = []       // further actions on the same thing, offered on a right-click in the window
    var isHeader = false
    var isSeparator = false
    var action: Action?
    var children: [Row] = []
    var dim = false              // from a Mac asked again and not yet heard from: the reading may be old

    static let separator = Row(title: "", isSeparator: true)
    static func header(_ title: String) -> Row { Row(title: title, isHeader: true) }
}

func gigabytes(_ gb: Double) -> String {
    gb >= 1000 ? String(format: "%.1f TB", gb / 1000) : String(format: "%.0f GB", gb)
}

func rate(_ bytesPerSecond: Double) -> String {
    bytesPerSecond >= 1_000_000 ? String(format: "%.1f MB/s", bytesPerSecond / 1_000_000) : String(format: "%.0f KB/s", bytesPerSecond / 1000)
}

func megabytes(_ mb: Double) -> String {
    mb >= 1000 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

/// A length of time in its largest unit: "6 days", "12 min".
func span(_ seconds: Double) -> String {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.maximumUnitCount = 1
    return formatter.string(from: seconds) ?? ""
}

/// "daily 07:15" or "daily 9, 14, 19" for a schedule that runs every day at set times, from Claude's
/// cron line or Codex's rule. Anything else is shown as the app wrote it.
func readable(_ schedule: String) -> String {
    var hours = "", minute = ""
    let cron = schedule.split(separator: " ")
    if cron.count == 5, cron[2...].allSatisfy({ $0 == "*" }) {
        (minute, hours) = (String(cron[0]), String(cron[1]))
    } else if schedule.hasPrefix("FREQ=DAILY;") {
        for part in schedule.split(separator: ";") {
            if part.hasPrefix("BYHOUR=") { hours = String(part.dropFirst(7)) }
            if part.hasPrefix("BYMINUTE=") { minute = String(part.dropFirst(9)) }
        }
    }
    let each = hours.split(separator: ",").map { Int($0) }
    guard let minute = Int(minute), !each.isEmpty, !each.contains(nil) else { return schedule }
    // Several times on the hour read better as "daily 6, 8, 10".
    if each.count > 1, minute == 0 { return "daily " + each.compactMap { $0.map(String.init) }.joined(separator: ", ") }
    return "daily " + each.compactMap { $0.map { String(format: "%02d:%02d", $0, minute) } }.joined(separator: ", ")
}

/// One download: "43% · 12 min". The speed of all downloads together is on the Downloads row.
func progress(_ download: Status.Download) -> String {
    guard let seconds = download.etaS, download.bytesPerS > 0 else { return "\(download.pct)%" }
    return "\(download.pct)% · \(span(seconds))"
}

func unread(_ title: String, _ error: String?) -> Row {
    Row(title: title, value: "not read", note: error)
}

/// Something that needs attention: a row at the top of the menu and a count beside the icon.
struct Problem { var subject: String; var detail: String; var level: Level }

func problems(_ status: Status, on machine: Machine, now: Date) -> [Problem] {
    var found: [Problem] = []
    for container in status.containers.items ?? [] where container.state != "running" {
        found.append(Problem(subject: container.name, detail: container.state, level: .bad))
    }
    if status.containers.state == "unknown" {
        found.append(Problem(subject: machine.name, detail: "Docker not answering", level: .bad))
    }
    if let free = status.files.vnodesFree, let limit = status.files.vnodesLimit, free < limit * 0.15 {
        found.append(Problem(subject: machine.name, detail: "\(Int((free / limit * 100).rounded()))% of vnodes free", level: .bad))
    }
    if let open = status.files.open, let limit = status.files.limit, open > limit * 0.8 {
        found.append(Problem(subject: machine.name, detail: "open files at \(Int(open / limit * 100))%", level: .warn))
    }
    for disk in status.lowDisks {
        found.append(Problem(subject: machine.name, detail: "\(disk.name) \(gigabytes(disk.freeGb)) free", level: .warn))
    }
    if machine.server, status.power.onAdapter == false {
        found.append(Problem(subject: machine.name, detail: "on battery" + (status.power.batteryPct.map { ", \(Int($0))%" } ?? ""), level: .warn))
    }
    // Only where Time Machine runs by itself. Two days is one missed daily backup and a margin.
    if status.timeMachine.automatic == true, let latest = status.timeMachine.latest, now.timeIntervalSince(latest) > 2 * 86400 {
        found.append(Problem(subject: machine.name, detail: "last backup \(RelativeDateTimeFormatter().localizedString(for: latest, relativeTo: now))", level: .warn))
    }
    return found
}

/// A Mac's own dot follows its own problems; a stopped container shows under Services.
func ownLevel(_ found: [Problem], on machine: Machine) -> Level {
    let own = found.filter { $0.subject == machine.name }
    return own.contains { $0.level == .bad } ? .bad : own.isEmpty ? .ok : .warn
}

func summary(_ status: Status) -> String {
    var parts: [String] = []
    if let battery = status.power.batteryPct { parts.append("\(Int(battery))%") }
    if let watts = status.power.onAdapter == false ? status.power.wattsLoad : status.power.wattsIn {
        parts.append("\(Int(watts.rounded())) W")
    }
    return parts.joined(separator: " · ")
}

/// One Mac's readings in the groups the window lays out. The menu's flyout shows them as one list.
struct Details {
    var now: [Row] = []         // what to look at first: battery, power, CPU, memory
    var more: [Row] = []        // background: swap, the busiest process, what keeps it awake, uptime
    var storage: [Row] = []     // drives and the last backup
    var actions: [Row] = []     // what can be done to this Mac
    var flyout: [Row] { now + more + [.separator] + storage + [.separator] + actions }
}

func details(_ status: Status, on machine: Machine, now: Date) -> Details {
    var groups = Details()

    let power = status.power
    if power.state == "unknown" { groups.now.append(unread("Power", power.error)) }
    if let battery = power.batteryPct {
        let how = power.charging == true ? ", charging" : power.onAdapter == true ? ", plugged in" : ""
        groups.now.append(Row(title: "Battery", value: "\(Int(battery))%\(how)"))
    }
    if let watts = power.onAdapter == false ? power.wattsLoad : power.wattsIn {
        groups.now.append(Row(title: "Power", value: String(format: "%.1f W", watts)))
    }

    // A hot CPU and nearly full memory are coloured where they stand; they pass by themselves and raise no warning.
    let thermal = status.thermal
    let fastest = thermal.fansRpm?.max() ?? 0
    let hot = (thermal.cpuC ?? 0) >= 90
    let load = status.cpu?.usagePct.map { "\($0)%" }, heat = thermal.cpuC.map { "\(Int($0.rounded()))°" }
    // The colour is about the temperature, so a hot CPU leads with it: the window sets the first figure large.
    let cpu = ((hot ? [heat, load] : [load, heat]) + [fastest > 0 ? "fans \(Int(fastest)) rpm" : nil]).compactMap { $0 }
    if !cpu.isEmpty {
        groups.now.append(Row(title: "CPU", value: cpu.joined(separator: " · "), level: hot ? .warn : nil))
    } else if thermal.state == "unknown" {
        groups.now.append(unread("CPU", thermal.error))
    }

    let memory = status.memory
    if let free = memory.freePct {
        groups.now.append(Row(title: "Memory", value: "\(Int(free))% free", level: free < 10 ? .warn : nil))
        if let swap = memory.swapUsedMb, swap >= 100 { groups.more.append(Row(title: "Swap", value: megabytes(swap))) }
    } else if memory.state == "unknown" {
        groups.now.append(unread("Memory", memory.error))
    }

    if let network = status.network, let down = network.downBps, let up = network.upBps {
        groups.more.append(Row(title: "Network", value: "↓ \(rate(down)) · ↑ \(rate(up))",
                               note: [network.kind, network.address].compactMap { $0 }.joined(separator: ", ")))
    }
    if let top = status.busiest.cpu {
        groups.more.append(Row(title: "Busiest", value: "\(top.name), \(Int(top.pct.rounded()))% CPU"))
    } else if status.busiest.state == "unknown" {
        groups.more.append(unread("Busiest", status.busiest.error))
    }

    // Fleet's own hold comes first, under its name and with its end; the helper's process is not listed again.
    let kept = status.awake.fleet
    var holders: [String] = kept?.on == true ? ["Fleet" + (kept?.until.map { " until " + $0.formatted(date: .omitted, time: .shortened) } ?? "")] : []
    for holder in status.awake.heldBy ?? [] where !["powerd", "runningboardd", "fleetd"].contains(holder.process) && !holders.contains(holder.process) {
        holders.append(holder.process)
    }
    if !holders.isEmpty {
        groups.more.append(Row(title: "Kept awake by", value: holders.joined(separator: ", "), note: holders.joined(separator: ", ")))
    } else if let minutes = status.awake.sleepAfterMin {
        groups.more.append(Row(title: "Sleeps when idle", value: minutes == 0 ? "never" : "after \(minutes) min"))
    }
    if let up = status.uptimeS { groups.more.append(Row(title: "Up", value: span(up))) }

    if status.disks.state == "unknown" { groups.storage.append(unread("Drives", status.disks.error)) }
    for disk in status.disks.items ?? [] {
        groups.storage.append(Row(title: disk.name, value: "\(gigabytes(disk.freeGb)) free"))
    }
    let backup = status.timeMachine
    if let latest = backup.latest {
        groups.storage.append(Row(title: "Last backup", value: RelativeDateTimeFormatter().localizedString(for: latest, relativeTo: now)))
    } else if backup.state == "unknown" {
        groups.storage.append(unread("Last backup", backup.error))
    }

    if let ssh = machine.ssh {
        groups.actions.append(Row(title: "Share Screen", symbol: "rectangle.on.rectangle", action: .open(URL(string: "vnc://\(ssh)")!)))
        groups.actions.append(Row(title: "Open Terminal", action: .terminal(command: "ssh \(ssh)")))
    }
    if let kept {
        groups.actions += kept.on
            ? [Row(title: "Stop Keeping Awake", action: .awake(machine, minutes: nil))]
            : [Row(title: "Keep Awake", action: .awake(machine, minutes: 0)),
               Row(title: "Keep Awake for 2 Hours", action: .awake(machine, minutes: 120))]
    }
    for stopped in status.containers.items ?? [] where stopped.state != "running" {
        groups.actions.append(Row(title: "Start \(stopped.name)", symbol: "play", action: .terminal(command: onMac(machine, "docker start \(stopped.name)"))))
    }
    if backup.automatic == true {
        groups.actions.append(Row(title: "Back Up Now", symbol: "clock.arrow.circlepath", action: .terminal(command: onMac(machine, "tmutil startbackup && print started"))))
    }
    groups.actions.append(Row(title: "Clean Up Disk…", action: .claude(prompt: cleanUpPrompt(machine))))
    groups.actions.append(Row(title: "Free Up Memory…", action: .claude(prompt: memoryPrompt(machine))))
    if let outdated = status.brew.outdated, outdated > 0 {
        groups.actions.append(Row(title: "Upgrade \(outdated) Brew Package\(outdated == 1 ? "" : "s")",
                                  note: status.brew.names?.joined(separator: ", "),
                                  action: .terminal(command: onMac(machine, "brew update && brew upgrade"))))
    }
    return groups
}

let tailscaleUp = "TAILSCALE_BE_CLI=1 /Applications/Tailscale.app/Contents/MacOS/Tailscale up && print connected"

/// What can still be done to another Mac that did not answer. `online` is what this Mac's
/// Tailscale says about it, nil when that is not known.
func reach(_ machine: Machine, online: Bool?) -> [Row] {
    guard let ssh = machine.ssh else { return [] }
    if online == false {
        // With its Tailscale off, only a route over its own network reaches it.
        guard let lan = machine.lan else { return [] }
        return [Row(title: "Reconnect Tailscale", symbol: "network",
                    action: .terminal(command: "print 'On \(machine.name), over its own network (ssh \(lan))'\nssh -t \(lan) '\(tailscaleUp)'"))]
    }
    var rows = [Row(title: "Share Screen", symbol: "rectangle.on.rectangle", action: .open(URL(string: "vnc://\(ssh)")!)),
                Row(title: "Open Terminal", action: .terminal(command: "ssh \(ssh)"))]
    if online == true {
        // The dollar sign is escaped so the user number is worked out on that Mac.
        rows.append(Row(title: "Restart Helper", symbol: "arrow.clockwise",
                        action: .terminal(command: onMac(machine, "launchctl kickstart -k gui/\\$(id -u)/com.chetangoel.fleetd && print restarted"))))
    }
    return rows
}

func dimmed(_ rows: [Row]) -> [Row] {
    rows.map { row in
        var row = row
        row.dim = true
        row.children = dimmed(row.children)
        return row
    }
}

/// The whole menu, and what the menu bar icon carries beside it.
struct Contents {
    var rows: [Row]
    var alerts: [Row]           // what needs attention; how many is shown beside the icon
}

/// One Mac's containers. A running one with a port opens in the browser.
func containerRows(_ items: [Status.Container], on machine: Machine) -> [Row] {
    items.map { item in
        let up = item.state == "running"
        // Only for another Mac: here it would be a raw localhost address. 6881 is the torrent
        // port, which no browser can open.
        let address = up ? machine.ssh.flatMap { host in item.ports?.first { $0 != 6881 }.map { "\(host):\($0)" } } : nil
        return Row(title: item.name, value: address ?? (up ? "" : item.state), level: up ? nil : .bad, dot: up ? .ok : .bad,
                   note: item.status,
                   extras: [Row(title: up ? "Restart" : "Start", action: .terminal(command: onMac(machine, "docker \(up ? "restart" : "start") \(item.name)"))),
                            Row(title: "Show Logs", action: .terminal(command: onMac(machine, "docker logs --tail 200 -f \(item.name)")))],
                   action: address.flatMap { URL(string: "http://\($0)") }.map { .open($0) })
    }
}

/// One Mac's scheduled jobs under a heading per app, then its background jobs that exited badly.
func jobRows(_ status: Status, on machine: Machine, now: Date) -> (rows: [Row], jobs: Int, failures: Int) {
    var rows: [Row] = [], jobs = 0
    // Claude's jobs show when they last ran; Codex records no last run, so its jobs show their schedule.
    for app in ["Claude", "Codex"] {
        let ofApp = (status.schedules?.items ?? []).filter { $0.app == app }
        if ofApp.isEmpty { continue }
        jobs += ofApp.count
        rows.append(.header("\(app) on \(machine.name)"))
        rows += ofApp.map { job in
            let plan = job.schedule.map(readable) ?? job.nextRun.map { "once, \($0.formatted(date: .abbreviated, time: .shortened))" }
            let ran = job.lastRun.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now) }
            return Row(title: job.name, value: ran ?? plan ?? "", note: ran == nil ? nil : plan)
        }
    }
    // A background job that exited badly once and is running again is not a failure worth a row.
    let failed = (status.jobs.failed ?? []).filter { !$0.running }
    if !failed.isEmpty {
        rows.append(.header("Background jobs on \(machine.name)"))
        rows += failed.map { Row(title: $0.label, value: "exit \($0.lastExit)", level: .warn) }
    }
    return (rows, jobs, failed.count)
}

/// `pending` names the Macs asked again and not yet heard from. Their rows are dimmed.
func menuRows(_ fetched: [(Machine, Fetched)], pending: Set<String> = [], now: Date) -> Contents {
    var alerts: [Row] = [], macs: [Row] = [], services: [Row] = [], downloads: [Row] = [], scheduled: [Row] = []
    var containers = 0, running = 0, active = 0, speed = 0.0, jobs = 0, failures = 0
    var stopped: [Row] = []
    var qbittorrent: URL?
    let dockerHosts = fetched.filter { if case .status(let status) = $0.1 { status.containers.items?.isEmpty == false } else { false } }.count

    // What this Mac's own Tailscale reports: whether it is connected, and which devices are online.
    let tailscale = fetched.lazy.compactMap { machine, result -> Status.Tailnet? in
        if machine.ssh == nil, case .status(let status) = result { status.tailnet } else { nil }
    }.first

    for (machine, result) in fetched {
        func mine(_ rows: [Row]) -> [Row] { pending.contains(machine.name) ? dimmed(rows) : rows }
        guard case .status(let status) = result else {
            if case .failed(let reason) = result {
                // Online on the tailnet and silent means the Mac is up and its helper is not.
                let online = machine.ssh == nil || tailscale?.running != true
                    ? nil : tailscale?.peers?.contains { $0.name.lowercased() == machine.name.lowercased() }
                let what = online == true ? "helper not answering" : online == false ? "offline" : "not answering"
                let expected = machine.sleeps && online != true
                if !expected {
                    alerts += mine([Row(title: machine.name, value: what, level: .bad, dot: .bad, note: reason)])
                }
                macs += mine([Row(title: machine.name, value: what, dot: expected ? .off : .bad, note: reason, children: reach(machine, online: online))])
            } else {
                macs.append(Row(title: machine.name, dot: .off))
            }
            continue
        }

        let found = problems(status, on: machine, now: now)
        alerts += mine(found.map { Row(title: $0.subject, value: $0.detail, level: $0.level, dot: $0.level) })
        if machine.ssh == nil, status.tailnet?.running == false {
            alerts += mine([Row(title: "Connect Tailscale", value: "off on this Mac", level: .bad, dot: .bad,
                                action: .terminal(command: onMac(machine, tailscaleUp)))])
        }
        macs += mine([Row(title: machine.name, value: summary(status), dot: ownLevel(found, on: machine), children: details(status, on: machine, now: now).flyout)])

        if let items = status.containers.items, !items.isEmpty {
            let rows = (dockerHosts > 1 ? [.header(machine.name)] : []) + containerRows(items, on: machine)
            stopped += mine(items.filter { $0.state != "running" }.map {
                Row(title: "Find Out Why \($0.name) Stopped…", action: .claude(prompt: stoppedPrompt($0.name, machine)))
            })
            services += mine(rows)
            containers += items.count
            running += items.filter { $0.state == "running" }.count
        } else if status.containers.state == "unknown" {
            services += mine([unread("Containers on \(machine.name)", status.containers.error)])
        }

        if let items = status.downloads?.items, !items.isEmpty {
            downloads += mine(items.map { Row(title: $0.name, value: progress($0)) })
            active += items.count
            speed += items.reduce(0) { $0 + $1.bytesPerS }
            qbittorrent = machine.ssh.flatMap { URL(string: "http://\($0):8080") }
        } else if status.downloads?.state == "unknown" {
            downloads += mine([unread("Downloads", status.downloads?.error)])
        }

        let ofThisMac = jobRows(status, on: machine, now: now)
        scheduled += mine(ofThisMac.rows)
        jobs += ofThisMac.jobs
        failures += ofThisMac.failures
    }

    var rows = alerts
    if !alerts.isEmpty { rows.append(.separator) }
    rows.append(.header("Machines"))
    rows += macs
    rows.append(.separator)
    if !services.isEmpty {
        let all = running == containers
        rows.append(Row(title: "Services", value: all ? "\(running) up" : "\(running) of \(containers) up", level: all ? nil : .bad,
                        children: services + (stopped.isEmpty ? [] : [.separator] + stopped), dim: services.contains { $0.dim }))
    }
    if !downloads.isEmpty {
        let value = active == 0 ? "not read" : "\(active) active" + (speed > 0 ? String(format: " · %.1f MB/s", speed / 1_000_000) : "")
        let open = qbittorrent.map { [Row.separator, Row(title: "Open qBittorrent", action: .open($0))] } ?? []
        rows.append(Row(title: "Downloads", value: value, children: downloads + open, dim: downloads.contains { $0.dim }))
    }
    if !scheduled.isEmpty {
        rows.append(Row(title: "Scheduled jobs", value: failures > 0 ? "\(jobs) · \(failures) failed" : "\(jobs)", level: failures > 0 ? .warn : nil,
                        children: scheduled, dim: scheduled.contains { $0.dim }))
    }
    rows += [.separator, Row(title: "Sync Assistant Setup…", action: .claude(prompt: syncPrompt)),
             Row(title: "Open Fleet Window", action: .window), Row(title: "Open at Login", action: .login),
             Row(title: "Quit Fleet", action: .quit)]
    return Contents(rows: rows, alerts: alerts)
}

func dump(_ rows: [Row], indent: String = "") -> String {
    rows.map { row in
        if row.isSeparator { return "\(indent)----" }
        if row.isHeader { return "\(indent)[\(row.title)]" }
        let does = switch row.action {
        case .awake(let machine, let minutes):
            "  →  " + (minutes.map { $0 == 0 ? "keeps \(machine.name) awake until told to stop" : "keeps \(machine.name) awake for \($0) minutes" }
                       ?? "lets \(machine.name) sleep again")
        case .open(let url): "  →  opens \(url.absoluteString)"
        case .claude(let prompt): "  →  Claude prompt (\(prompt.count) characters)"
        case .terminal(let command): "  →  Terminal: \(command)"
        case .window: "  →  opens the window"
        case .login: "  →  turns opening at login on or off"
        case .quit: "  →  quits"
        case nil: ""
        }
        // What is drawn before the title: a status dot, or the icon of the action.
        let mark = row.dot.map { "(\($0.rawValue)) " } ?? (row.symbol ?? row.action?.symbol).map { "{\($0)} " } ?? ""
        let value = row.value.isEmpty ? "" : "  —  \(row.value)" + (row.level.map { " (\($0.rawValue))" } ?? "") + (row.dim ? " (dim)" : "")
        let line = "\(indent)\(mark)\(row.title)\(value)\(does)"
        return row.children.isEmpty ? line : line + "\n" + dump(row.children, indent: indent + "    ")
    }.joined(separator: "\n")
}

// MARK: - Drawing rows

/// Every menu's text is this wide, in points, so no menu grows with its longest name.
/// A title or value that does not fit is cut with "…" and shown whole in the tooltip.
let textWidth: CGFloat = 236
let imageRoom: CGFloat = 22      // what a dot or icon takes from the text beside it

func symbolImage(_ name: String) -> NSImage {
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { fatalError("no system symbol named \(name)") }
    return image
}

/// A dot or an icon set in a row's own text. A menu item's `image` would make AppKit keep an image
/// column for every row of that menu, the ones without one too. An icon goes in as the symbol
/// itself, which is what lets it take the text's colour: white on a highlighted row, light in Dark Mode.
func inText(_ image: NSImage, font: NSFont) -> NSAttributedString {
    let image = image.withSymbolConfiguration(.init(pointSize: font.pointSize, weight: .regular, scale: .small)) ?? image
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = NSRect(x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(), width: image.size.width, height: image.size.height)
    return NSAttributedString(attachment: attachment)
}

func dotImage(_ level: Level) -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
        let color: NSColor = switch level {
        case .ok: .systemGreen
        case .warn: .systemOrange
        case .bad: .systemRed
        case .off: .tertiaryLabelColor
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4, y: 4, width: 8, height: 8)).fill()
        return true
    }
}

func fitted(_ text: String, to width: CGFloat, font: NSFont) -> String {
    func measured(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
    if measured(text) <= width { return text }
    var cut = text
    while !cut.isEmpty, measured(cut + "…") > width { cut.removeLast() }
    return cut.trimmingCharacters(in: .whitespaces) + "…"
}

/// Brings `menu` in line with `rows`. A row keeps the menu item it had, found by its title, so a
/// flyout the user has open stays open and stays that row's when a late answer changes the
/// numbers or adds and removes rows around it.
func sync(_ menu: NSMenu, with rows: [Row], target: AnyObject?, action: Selector?) {
    for (index, row) in rows.enumerated() {
        func isThisRow(_ item: NSMenuItem) -> Bool {
            if row.isSeparator { return item.isSeparatorItem }
            if row.isHeader { return item.isSectionHeader && item.title == row.title }
            return !item.isSeparatorItem && !item.isSectionHeader && item.title == row.title && item.hasSubmenu == !row.children.isEmpty
        }
        // Items between here and this row's own item belong to rows that are gone. Separators all
        // look alike, so one only counts as this row's when it is already in this place.
        let rest = menu.items[min(index, menu.items.count)...]
        if let found = row.isSeparator ? rest.prefix(1).firstIndex(where: isThisRow) : rest.firstIndex(where: isThisRow) {
            for _ in index..<found { menu.removeItem(at: index) }
        } else {
            menu.insertItem(row.isSeparator ? .separator() : row.isHeader ? .sectionHeader(title: row.title) : NSMenuItem(), at: index)
        }
        if row.isSeparator || row.isHeader { continue }
        let item = menu.items[index]

        let font = NSFont.menuFont(ofSize: 0)
        // A row with a dot or an icon starts with it; one without starts at the menu's edge. Values end in one column either way.
        let image = row.dot.map(dotImage) ?? (row.symbol ?? row.action?.symbol).map(symbolImage)
        let room = textWidth - (image == nil ? 0 : imageRoom)
        // A value gets half the row, or all that a short title leaves.
        let titleWidth = (row.title as NSString).size(withAttributes: [.font: font]).width
        let value = fitted(row.value, to: max(room * 0.5, room - titleWidth - 14), font: font)
        let valueWidth = value.isEmpty ? 0 : (value as NSString).size(withAttributes: [.font: font]).width + 14
        let title = fitted(row.title, to: room - valueWidth, font: font)
        let style = NSMutableParagraphStyle()
        // Icons differ in width, so each is centred in the same 16 points and the title starts after them.
        style.tabStops = (image == nil ? [] : [NSTextTab(textAlignment: .center, location: 8), NSTextTab(textAlignment: .left, location: imageRoom)])
            + [NSTextTab(textAlignment: .right, location: textWidth)]
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: style]
        let text = NSMutableAttributedString()
        if let image {
            text.append(NSAttributedString(string: "\t"))
            text.append(inText(image, font: font))
            text.append(NSAttributedString(string: "\t"))
            text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        }
        text.append(NSAttributedString(string: title, attributes: attributes))
        if !value.isEmpty {
            let color: NSColor = row.dim ? .tertiaryLabelColor : row.level == .bad ? .systemRed : row.level == .warn ? .systemOrange : .secondaryLabelColor
            text.append(NSAttributedString(string: "\t" + value, attributes: [.font: font, .paragraphStyle: style, .foregroundColor: color]))
        }
        item.title = row.title
        item.attributedTitle = text
        let whole = [title == row.title ? nil : row.title, value == row.value ? nil : row.value, row.note].compactMap { $0 }
        item.toolTip = whole.isEmpty ? nil : whole.joined(separator: "\n")
        item.representedObject = row.action
        item.target = row.action == nil ? nil : target
        item.action = row.action == nil ? nil : action
        if row.children.isEmpty {
            item.submenu = nil
        } else {
            let submenu = item.submenu ?? NSMenu()
            submenu.autoenablesItems = false
            sync(submenu, with: row.children, target: target, action: action)
            if item.submenu == nil { item.submenu = submenu }
        }
    }
    while menu.items.count > rows.count { menu.removeItem(at: menu.items.count - 1) }
}

/// The width of the widest menu under `menu`, itself included, without opening any of them.
func widest(_ menu: NSMenu) -> CGFloat {
    menu.items.compactMap(\.submenu).map(widest).reduce(menu.size.width, max)
}

// MARK: - Answers and actions, shared by the menu and the window

/// Each Mac's latest answer.
@Observable
final class Fleet {
    private(set) var answers = [Fetched](repeating: .waiting, count: machines.count)
    private(set) var pending: Set<Int> = []              // asked and not yet heard from
    private(set) var answeredAt: Date?                   // when the latest answer landed
    @ObservationIgnored private var askedAt = Date.distantPast
    @ObservationIgnored private var asked = [Int](repeating: 0, count: machines.count)      // how many times each has been asked
    @ObservationIgnored var changed: () -> Void = {}     // the menu redraws itself here; the window observes

    var contents: Contents {
        menuRows(Array(zip(machines, answers)), pending: Set(pending.map { machines[$0].name }), now: Date())
    }

    /// Asks every Mac at once. Until a Mac answers, its last readings stay, dimmed. Each answer
    /// is shown as it lands, so a Mac that is asleep holds up only its own rows.
    /// `unlessWithin` skips asking when the last ask was that recent: the helper would send the
    /// same five-second snapshot again.
    func refresh(unlessWithin seconds: Double = 0) {
        guard Date().timeIntervalSince(askedAt) >= seconds else { return }
        askedAt = Date()
        for index in machines.indices {
            asked[index] += 1
            let ask = asked[index]
            pending.insert(index)
            Task {
                let answer = await fetch(machines[index])
                guard asked[index] == ask else { return }      // asked again since: that answer is the one to show
                answers[index] = answer
                pending.remove(index)
                answeredAt = Date()
                changed()
            }
        }
        changed()
    }
}

let fleet = Fleet()

func carryOut(_ action: Action) {
    switch action {
    case .awake(let machine, let minutes):
        // The one command a helper takes. It answers 200 once the Mac is held or let go, and the next status shows it.
        let path = minutes.map { $0 == 0 ? "awake/on" : "awake/on?minutes=\($0)" } ?? "awake/off"
        guard let url = URL(string: path, relativeTo: machine.url) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("1", forHTTPHeaderField: "X-Fleet")
        request.timeoutInterval = 6
        Task {
            let answer = try? await URLSession.shared.data(for: request)
            if (answer?.1 as? HTTPURLResponse)?.statusCode == 200 { fleet.refresh() } else { NSSound.beep() }
        }
    case .quit:
        NSApp.terminate(nil)
    case .window:
        openWindow()
    case .login:
        // macOS keeps the login item; the row's circle shows what it holds the next time the menu opens.
        let item = SMAppService.mainApp
        do { if item.status == .enabled { try item.unregister() } else { try item.register() } } catch { NSSound.beep() }
    case .open(let url):
        NSWorkspace.shared.open(url)
    case .claude(let prompt):
        // The Claude app's link opens a new Code session with the prompt typed in and not sent.
        var link = URLComponents(string: "claude://code/new")!
        link.queryItems = [URLQueryItem(name: "q", value: prompt)]
        if let url = link.url { NSWorkspace.shared.open(url) }
    case .terminal(let command):
        // Opening a .command file runs it in a Terminal window, without asking for permission to control Terminal.
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("com.chetangoel.fleet")
        let script = folder.appendingPathComponent("run.command")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "#!/bin/zsh\n\(command)\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            NSWorkspace.shared.open(script)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - The menu bar item

@main
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let menu = NSMenu()

    static func main() {
        if let flag = CommandLine.arguments.firstIndex(of: "--dump") {
            // "--dump status.json" shows the menu a saved status would give, for rows that are rare live.
            let saved = CommandLine.arguments.dropFirst(flag + 1).first.map { Machine(name: "saved status", url: URL(fileURLWithPath: $0), server: true) }
            Task {
                let fetched = if let saved { [(saved, await fetch(saved))] } else { await fetchAll() }
                let contents = menuRows(fetched, now: Date())
                let menu = NSMenu()
                let began = Date()
                sync(menu, with: contents.rows, target: nil, action: nil)       // also proves every icon exists
                let drawn = Int(Date().timeIntervalSince(began) * 1000)
                let beside = contents.alerts.isEmpty ? "nothing" : "\(contents.alerts.count), needs attention"
                print(dump(contents.rows) + "\n\nbeside the icon: \(beside)\nwidest menu: \(Int(widest(menu))) pt\nmenus drawn in \(drawn) ms")
                exit(0)
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = App()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// Every Mac's answer, asked at once. For `--dump`; the menu and the window use `fleet`.
    static func fetchAll() async -> [(Machine, Fetched)] {
        await withTaskGroup(of: (Int, Fetched).self) { group in
            for (index, machine) in machines.enumerated() {
                group.addTask { (index, await fetch(machine)) }
            }
            var results = [Fetched?](repeating: nil, count: machines.count)
            for await (index, fetched) in group { results[index] = fetched }
            return zip(machines, results).map { ($0, $1 ?? .failed("no answer")) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = symbolImage("server.rack")
        item.button?.setAccessibilityLabel("Fleet")
        // The menu belongs to the item, so a click opens it at once on the last readings.
        // Nothing waits for the network; `menuWillOpen` asks again and answers fill in as they land.
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // An app with no Dock icon has no menu bar of its own, and so no Command-W unless something carries it.
        let windowKeys = NSMenu()
        windowKeys.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let holder = NSMenuItem()
        holder.submenu = windowKeys
        NSApp.mainMenu = NSMenu()
        NSApp.mainMenu?.addItem(holder)
        fleet.changed = { [weak self] in self?.show() }
        fleet.refresh()
        let arguments = CommandLine.arguments
        // "--open" opens the menu once at launch, and "--window PAGE" the window, for checking them on screen.
        if arguments.contains("--open") { item.button?.perform(#selector(NSButton.performClick(_:)), with: nil, afterDelay: 0.1) }
        if let flag = arguments.firstIndex(of: "--window") {
            // "--height N" after the page makes the window that tall, to capture a page whole.
            let height = arguments.firstIndex(of: "--height").flatMap { arguments.dropFirst($0 + 1).first }.flatMap { Double($0) }
            openWindow(arguments.dropFirst(flag + 1).first.flatMap(Page.init(named:)) ?? .overview, printNumber: true, checkHeight: height.map { CGFloat($0) })
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        fleet.refresh()
    }

    /// Opening the app while it is running (from Finder, Spotlight or `open`) shows its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openWindow()
        return false
    }

    private func show() {
        let contents = fleet.contents
        sync(menu, with: contents.rows, target: self, action: #selector(run(_:)))
        // Beside the icon: how many things needed attention the last time the helpers were asked.
        guard let button = item.button else { return }
        let beside = contents.alerts.isEmpty ? "" : "\(contents.alerts.count)"
        button.attributedTitle = NSAttributedString(string: beside, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium), .foregroundColor: NSColor.systemOrange,
        ])
        button.imagePosition = beside.isEmpty ? .imageOnly : .imageLeading
    }

    @objc private func run(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? Action { carryOut(action) }
    }
}

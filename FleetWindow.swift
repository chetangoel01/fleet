// Fleet's window: the answers the menu shows, with room for every reading and a page per Mac.
//
// It keeps no timers either. The helpers are asked when the window opens, when it comes to
// the front and on Refresh, and the title bar says when the answers on screen landed.

import Charts
import SwiftUI
import UniformTypeIdentifiers

enum Page: Hashable {
    case overview, machine(String), services, downloads, scheduled

    /// The names `--window` takes: overview, services, downloads, scheduled, or a Mac's name.
    init?(named name: String) {
        switch name {
        case "overview": self = .overview
        case "services": self = .services
        case "downloads": self = .downloads
        case "scheduled": self = .scheduled
        default:
            guard machines.contains(where: { $0.name == name }) else { return nil }
            self = .machine(name)
        }
    }
}

@Observable
final class Shown {
    var page: Page? = .overview
    var curves: String?     // the Mac whose fan curve editor is open
}

let shown = Shown()
private var window: NSWindow?

/// Brings the window forward, making it the first time. `printNumber` is for `--window`:
/// `screencapture -l <number>` then captures the window alone.
/// `checkHeight` is for capturing a whole page: a window that tall, whose size is not remembered.
func openWindow(_ page: Page? = nil, printNumber: Bool = false, checkHeight: CGFloat? = nil) {
    if let page { shown.page = page }
    if window == nil {
        let controller = NSHostingController(rootView: FleetWindow())
        controller.sceneBridgingOptions = [.toolbars, .title]
        let made = NSWindow(contentViewController: controller)
        made.title = "Fleet"
        made.setContentSize(NSSize(width: 940, height: checkHeight ?? 640))
        made.isReleasedWhenClosed = false      // it is kept and shown again after a close
        made.center()
        if checkHeight == nil { made.setFrameAutosaveName("Fleet") }
        window = made
    }
    NSApp.activate()
    window?.makeKeyAndOrderFront(nil)
    fleet.refresh(unlessWithin: 5)
    if printNumber {
        print(window?.windowNumber ?? 0)
        fflush(stdout)
    }
}

// MARK: - One Mac, as the window shows it

struct Mac: Identifiable {
    var machine: Machine
    var fetched: Fetched
    var pending: Bool       // asked again and not yet heard from: what is shown may be old

    var id: String { machine.name }
    var status: Status? { if case .status(let status) = fetched { status } else { nil } }
    var failure: String? { if case .failed(let reason) = fetched { reason } else { nil } }
    var level: Level {
        if let status { return ownLevel(problems(status, on: machine, now: Date()), on: machine) }
        return failure != nil && !machine.sleeps ? .bad : .off
    }
}

extension Fleet {
    var macs: [Mac] {
        machines.indices.map { Mac(machine: machines[$0], fetched: answers[$0], pending: pending.contains($0)) }
    }
}

/// The device type macOS has for a model and case colour, which carries its picture and name.
/// A colour macOS does not know falls back to the model alone.
func deviceType(_ hardware: Status.Hardware?) -> UTType? {
    let codes = UTTagClass(rawValue: "com.apple.device-model-code")
    func known(_ code: String) -> UTType? {
        UTType(tag: code, tagClass: codes, conformingTo: nil).flatMap { $0.isDynamic ? nil : $0 }
    }
    guard let model = hardware?.model else { return nil }
    return hardware?.color.flatMap { known("\(model)@ECOLOR=\($0)") } ?? known(model)
}

func picture(_ hardware: Status.Hardware?) -> NSImage {
    NSWorkspace.shared.icon(for: deviceType(hardware) ?? UTType("com.apple.mac") ?? .data)
}

extension Level {
    var color: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .bad: .red
        case .off: Color(nsColor: .tertiaryLabelColor)
        }
    }
}

// MARK: - The window

struct FleetWindow: View {
    @Environment(\.controlActiveState) private var active
    @State var spins = 0

    var body: some View {
        @Bindable var shown = shown
        let contents = fleet.contents
        let statuses = fleet.macs.compactMap(\.status)
        NavigationSplitView {
            List(selection: $shown.page) {
                Label("Overview", systemImage: "square.grid.2x2").tag(Page.overview)
                Section("Machines") {
                    ForEach(fleet.macs) { mac in
                        Label { Text(mac.machine.name) } icon: { Dot(level: mac.level) }.tag(Page.machine(mac.id))
                    }
                }
                // A badge only for what is out of the ordinary: stopped containers, running downloads, failed jobs.
                Section("All Macs") {
                    Label("Services", systemImage: "shippingbox").tag(Page.services)
                        .badge(statuses.reduce(0) { $0 + ($1.containers.items ?? []).filter { $0.state != "running" }.count })
                    Label("Downloads", systemImage: "arrow.down.circle").tag(Page.downloads)
                        .badge(statuses.reduce(0) { $0 + ($1.downloads?.items?.count ?? 0) })
                    Label("Scheduled jobs", systemImage: "clock").tag(Page.scheduled)
                        .badge(statuses.reduce(0) { $0 + ($1.jobs.failed ?? []).filter { !$0.running }.count })
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            ScrollView {
                // A new identity per page: numbers and bars animate when an answer lands, never when the page changes.
                page(contents).id(shown.page).padding(20).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .navigationTitle("Fleet")
            // A clock time, not "2 minutes ago": nothing here runs to keep a relative time true.
            .navigationSubtitle(fleet.answeredAt.map { "As of \($0.formatted(date: .omitted, time: .shortened))" } ?? "")
            .toolbar {
                Button {
                    spins += 1
                    fleet.refresh()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").symbolEffect(.rotate, options: .nonRepeating, value: spins)
                }
                .keyboardShortcut("r")
            }
        }
        .onChange(of: active) {
            if active == .key { fleet.refresh(unlessWithin: 5) }
        }
    }

    @ViewBuilder
    private func page(_ contents: Contents) -> some View {
        switch shown.page ?? .overview {
        case .overview:
            Overview(contents: contents)
        case .machine(let name):
            if let mac = fleet.macs.first(where: { $0.id == name }) { MacPage(mac: mac) }
        case .services:
            listed("Services", in: contents, none: "No containers", symbol: "shippingbox")
        case .downloads:
            listed("Downloads", in: contents, none: "No downloads", symbol: "arrow.down.circle")
        case .scheduled:
            listed("Scheduled jobs", in: contents, none: "No scheduled jobs", symbol: "clock")
        }
    }

    /// A page that lists what one of the menu's flyouts lists, found by the row's title.
    @ViewBuilder
    private func listed(_ title: String, in contents: Contents, none: String, symbol: String) -> some View {
        if let row = contents.rows.first(where: { $0.title == title }) {
            Box(title: title, value: row.value, level: row.level) { Rows(rows: row.children).tile() }
        } else {
            ContentUnavailableView(none, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 400)
        }
    }
}

struct Overview: View {
    var contents: Contents
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let alerts = contents.alerts
        VStack(alignment: .leading, spacing: 24) {
            if !alerts.isEmpty {
                Box(title: "Needs attention", symbol: "exclamationmark.triangle") { Rows(rows: alerts).tile() }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(fleet.macs) { mac in
                    Button { shown.page = .machine(mac.id) } label: { Card(mac: mac) }.buttonStyle(Pressable(corner: 12))
                }
            }
            // What runs across the Macs, from the same rows as the menu: every container, and downloads while there are any.
            if let services = contents.rows.first(where: { $0.title == "Services" }) {
                Box(title: "Services", symbol: "shippingbox", value: services.value, level: services.level) {
                    Rows(rows: services.children, sideBySide: true).tile()
                }
            }
            if let downloads = contents.rows.first(where: { $0.title == "Downloads" }) {
                Box(title: "Downloads", symbol: "arrow.down.circle", value: downloads.value) { Rows(rows: downloads.children).tile() }
            }
        }
        // The cards slide down for a warning that arrives, and back up when it clears, in place of a jump.
        .animation(.snappy(duration: 0.25), value: alerts.count)
    }
}

/// What tells one Mac's state at a glance: its picture, power, CPU, memory and the drive closest to full.
struct Card: View {
    var mac: Mac

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(nsImage: picture(mac.status?.hardware)).resizable().frame(width: 128, height: 128).padding(.vertical, -10).frame(maxWidth: .infinity)
            HStack(spacing: 6) {
                Dot(level: mac.level)
                Text(mac.machine.name).font(.headline)
                Spacer()
                Text(mac.status.map(summary) ?? (mac.failure == nil ? "" : "not answering")).foregroundStyle(.secondary)
            }
            if let status = mac.status {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(details(status, on: mac.machine, now: Date()).now.filter { ["CPU", "Memory"].contains($0.title) }, id: \.title) {
                        Figure(row: $0, compact: true).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                // The fullest drive that is not a backup drive, which is full by design.
                let drives = (status.disks.items ?? []).filter { status.timeMachine.destinations?.contains($0.name) != true }
                if let tightest = drives.min(by: { $0.freeGb / max($0.totalGb, 1) < $1.freeGb / max($1.totalGb, 1) }) {
                    Drive(disk: tightest, low: status.lowDisks.contains { $0.name == tightest.name }, compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 236, alignment: .top)
        .dimmed(while: mac.pending)
        .tile()
        .contentShape(Rectangle())
        .help(mac.failure ?? "")
    }
}

struct MacPage: View {
    var mac: Mac

    var body: some View {
        if let status = mac.status {
            let now = Date()
            let groups = details(status, on: mac.machine, now: now)
            let found = problems(status, on: mac.machine, now: now)
            let disks = status.disks.items ?? []
            let containers = status.containers.items ?? []
            let stopped = containers.filter { $0.state != "running" }.count
            let jobs = jobRows(status, on: mac.machine, now: now)
            // Each lesser reading goes beside what it qualifies: swap with memory, uptime with the Mac, the last backup with its drive.
            let swap = groups.more.first { $0.title == "Swap" }
            let up = groups.more.first { $0.title == "Up" }
            let backup = groups.storage.first { $0.title == "Last backup" }
            let backupDrive = disks.first { status.timeMachine.destinations?.contains($0.name) == true }?.name
            let otherStorage = groups.storage.filter { row in !disks.contains { $0.name == row.title } && !(row.title == "Last backup" && backupDrive != nil) }
            let traffic = groups.more.first { $0.title == "Network" }
            let facts = groups.more.filter { !["Swap", "Up", "Network"].contains($0.title) } + files(status.files)
            let reach = network(status)
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center, spacing: 18) {
                    Image(nsImage: picture(status.hardware)).resizable().frame(width: 120, height: 120).padding(.vertical, -12)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Dot(level: mac.level)
                            Text(mac.machine.name).font(.title2.weight(.semibold))
                        }
                        Text(about(status.hardware, up: up?.value)).foregroundStyle(.secondary)
                        // What is done to a Mac most, as icons.
                        if !groups.quick.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(groups.quick, id: \.title) { Act(row: $0, compact: true) }
                            }
                            .padding(.top, 6)
                        }
                    }
                }
                // The rest of what can be done to this Mac, wrapping to as many lines as the window needs.
                Flow(spacing: 8) {
                    ForEach(groups.actions + [groups.fan].compactMap { $0 }, id: \.title) { Act(row: $0) }
                }
                .padding(.top, -8)
                if !found.isEmpty {
                    Box(title: "Needs attention", symbol: "exclamationmark.triangle") {
                        Rows(rows: found.map { problem in
                            let own = problem.subject == mac.machine.name
                            return Row(title: own ? problem.detail.prefix(1).uppercased() + problem.detail.dropFirst() : problem.subject,
                                       value: own ? "" : problem.detail, level: problem.level, dot: problem.level)
                        })
                        .tile()
                    }
                }
                // A Mac with a battery shows its power on the battery's tile; one without has a tile for power alone.
                let watts = groups.now.first { $0.title == "Power" }
                let onBattery = groups.now.contains { $0.title == "Battery" }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 360), spacing: 12)], alignment: .leading, spacing: 12) {
                    ForEach(groups.now.filter { !(onBattery && $0.title == "Power") } + (traffic.map { [$0] } ?? []), id: \.title) { row in
                        Tile(row: row, share: share(row.title, of: status), cores: row.title == "CPU" ? status.cpu?.coresPct : nil,
                             extra: row.title == "Memory" ? swap.map { "\($0.value) swap" } ?? "" : row.title == "Battery" ? watts?.value ?? "" : "")
                    }
                }
                if let points = status.history?.points.map({ $0.filter { $0.count == 5 } }), points.count > 1, let until = status.time {
                    Box(title: "Last 3 hours", symbol: "chart.xyaxis.line") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 12)], spacing: 12) {
                            // Before 0.2.1 a point held memory free where it now holds memory in use; such a helper
                            // sends no used_pct, and its Mac goes without the memory graph.
                            ForEach(Array(["CPU", "Memory", "Download", "Upload"].enumerated()).filter { $0.offset != 1 || status.memory.usedPct != nil }, id: \.offset) { index, title in
                                Trend(title: title, points: points.map { (Date(timeIntervalSince1970: $0[0]), $0[index + 1]) }, until: until,
                                      top: index < 2 ? 100 : nil, label: index < 2 ? { "\(Int($0))%" } : rate)
                            }
                        }
                    }
                }
                if !groups.storage.isEmpty {
                    Box(title: "Storage", symbol: "internaldrive") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 360), spacing: 12)], alignment: .leading, spacing: 12) {
                            ForEach(disks, id: \.name) { disk in
                                // With a backup drive among them, every drive keeps a line for the note, so tiles in a row stay level.
                                Drive(disk: disk, low: status.lowDisks.contains { $0.name == disk.name }, note: backupDrive.map { $0 == disk.name ? "Last backup \(backup?.value ?? "")" : "" }).tile()
                            }
                        }
                        if !otherStorage.isEmpty { Rows(rows: otherStorage).tile() }
                    }
                }
                if !containers.isEmpty {
                    Box(title: "Containers", symbol: "shippingbox", value: stopped == 0 ? "\(containers.count) running" : "\(stopped) of \(containers.count) stopped", level: stopped == 0 ? nil : .bad) {
                        Rows(rows: containerRows(containers, on: mac.machine), sideBySide: true).tile()
                    }
                }
                if !jobs.rows.isEmpty {
                    Box(title: "Scheduled jobs", symbol: "clock", value: jobs.failures > 0 ? "\(jobs.failures) failed" : "", level: .warn) { Rows(rows: jobs.rows).tile() }
                }
                if !reach.isEmpty {
                    Box(title: "Network", symbol: "network") { Facts(rows: reach).tile() }
                }
                if !facts.isEmpty {
                    Box(title: "Details", symbol: "info.circle") { Facts(rows: facts).tile() }
                }
            }
            .dimmed(while: mac.pending)
            .sheet(isPresented: Binding(get: { shown.curves == mac.id }, set: { if !$0 { shown.curves = nil } })) {
                if let cooling = status.cooling { CurveEditor(machine: mac.machine, cooling: cooling, thermal: status.thermal) }
            }
        } else {
            ContentUnavailableView {
                Label(mac.machine.name, systemImage: "desktopcomputer")
            } description: {
                Text(mac.failure == nil ? "" : "Not answering")
            } actions: {
                if mac.failure != nil, let wake = wakeRow(mac.machine, among: Array(zip(machines, fleet.answers))) { Act(row: wake) }
            }
            .frame(maxWidth: .infinity, minHeight: 400)
            .help(mac.failure ?? "")
        }
    }

    /// "MacBook Pro (Mac17,13) · macOS 27.2 · up 7 days · This Mac", with whatever of it is known.
    private func about(_ hardware: Status.Hardware?, up: String?) -> String {
        let model = hardware?.model.map { code in deviceType(hardware)?.localizedDescription.map { "\($0) (\(code))" } ?? code }
        return [model, hardware?.os.map { "macOS \($0)" }, up.map { "up \($0)" }, mac.machine.ssh == nil ? "This Mac" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// A reading that is a share of something gets a ring: charge left in the battery, memory in use.
    /// Power and temperature have no ceiling to be a share of.
    private func share(_ title: String, of status: Status) -> Double? {
        switch title {
        case "Battery": status.power.batteryPct.map { $0 / 100 }
        case "Memory": status.memory.usedPct.map { $0 / 100 }
        default: nil
        }
    }

    /// How this Mac is connected, its addresses, and how the Mac running Fleet reaches it over the tailnet.
    private func network(_ status: Status) -> [Row] {
        var rows: [Row] = []
        if let network = status.network {
            if let kind = network.kind ?? network.interface {
                rows.append(Row(title: "Connection", value: kind + (network.kind != nil && network.interface != nil ? " (\(network.interface!))" : "")))
            }
            if let address = network.address { rows.append(Row(title: "Address", value: address)) }
            if let address = network.tailscale { rows.append(Row(title: "Tailscale address", value: address)) }
        }
        // Each helper reports the paths from its own Mac, so the path to this one is in this Mac's answer.
        let here = fleet.macs.first { $0.machine.ssh == nil }?.status?.tailnet?.peers ?? []
        if let peer = here.first(where: { $0.name == mac.machine.name }) {
            rows.append(Row(title: "Path from this Mac", value: peer.direct ? "Direct" : peer.active ? "Through Tailscale's \(peer.relay) relay" : "Idle"))
        }
        if mac.machine.ssh == nil, let peers = status.tailnet?.peers, !peers.isEmpty {
            rows.append(Row(title: "Tailnet devices online", value: peers.map { $0.name + ($0.direct ? "" : $0.active ? " (relayed)" : " (idle)") }.joined(separator: ", ")))
        }
        return rows
    }

    private func files(_ files: Status.Files) -> [Row] {
        var rows: [Row] = []
        if let open = files.open, let limit = files.limit {
            rows.append(Row(title: "Open files", value: "\(Int(open).formatted()) of \(Int(limit).formatted())"))
        }
        if let free = files.vnodesFree, let limit = files.vnodesLimit, limit > 0 {
            rows.append(Row(title: "Vnodes free", value: "\(Int((free / limit * 100).rounded()))%"))
        }
        return rows
    }
}

// MARK: - Pieces

struct Dot: View {
    var level: Level
    var body: some View { Circle().fill(level.color).frame(width: 8, height: 8) }
}

extension Level? {
    /// Orange or red for a warning. Everything else is drawn in grey, so colour in the window always means something.
    var fill: Color { self == .warn || self == .bad ? self!.color : .primary.opacity(0.45) }
}

extension View {
    /// Half strength while a Mac has been asked again and has not answered. The fade waits a moment,
    /// so an answer that comes straight back dims nothing; the return to full strength is immediate.
    func dimmed(while pending: Bool) -> some View {
        opacity(pending ? 0.5 : 1).animation(pending ? .easeOut(duration: 0.2).delay(0.5) : nil, value: pending)
    }

    /// The filled, rounded ground a reading or a list sits on.
    func tile() -> some View {
        padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// For things that do something when clicked: a tint under the pointer, and a slight give while held
/// (the tint alone under Reduce Motion). The tint lies over the content, since a card's own fill would
/// cover one drawn behind it. `outset` lets it reach past the content's own edges.
struct Pressable: ButtonStyle {
    var corner: CGFloat = 6
    var outset: CGFloat = 0

    func makeBody(configuration: Configuration) -> some View { Pressed(configuration: configuration, corner: corner, outset: outset) }

    private struct Pressed: View {
        let configuration: Configuration
        var corner: CGFloat
        var outset: CGFloat
        @State var hovered = false
        @Environment(\.accessibilityReduceMotion) var reduceMotion

        var body: some View {
            configuration.label
                .overlay(RoundedRectangle(cornerRadius: corner).fill(.primary.opacity(configuration.isPressed ? 0.09 : hovered ? 0.05 : 0)).padding(-outset).allowsHitTesting(false))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A titled section, with an optional value beside the title.
struct Box<Content: View>: View {
    var title: String
    var symbol: String?
    var value = ""
    var level: Level?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                if let symbol { Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18) }
                Text(title).font(.headline)
                Spacer()
                Text(value).foregroundStyle(level?.color ?? .secondary)
            }
            content
        }
    }
}

/// "23% · 56° · fans 2687 rpm" as the figure to draw large and the rest of it. The menu's wording
/// stays the one wording; the window only sets its first part larger.
func figure(_ value: String) -> (large: String, rest: String) {
    guard let match = value.firstMatch(of: /^(↓ )?[\d.]+ ?([KM]B\/s|[%°W])/) else { return ("", value) }
    return (String(match.0), value[match.range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ,·")))
}

/// One reading with its figure set large: an icon and the name, the figure, then what qualifies it.
struct Figure: View {
    var row: Row
    var compact = false         // on a card: smaller, and only the first of what qualifies it
    var extra = ""
    static let symbols = ["Battery": "battery.75percent", "Power": "bolt", "CPU": "cpu", "Memory": "memorychip", "Network": "arrow.up.arrow.down"]

    var body: some View {
        let parts = figure(row.value)
        let rest = compact ? String(parts.rest.split(separator: " · ").first ?? "") : [parts.rest, extra].filter { !$0.isEmpty }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let symbol = Figure.symbols[row.title] { Image(systemName: symbol).imageScale(.small).frame(width: 16) }
                Text(row.title)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            // A changed number rolls to its new value; an old one greys only if its Mac is slow to answer.
            Text(parts.large.isEmpty ? "–" : parts.large)
                .font(.system(size: compact ? 20 : 28, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)     // "↓ 12.4 MB/s" is wider than a tile at four across
                .foregroundStyle(row.dim ? Color(nsColor: .tertiaryLabelColor) : row.level == .warn || row.level == .bad ? row.level!.color : .primary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.25), value: parts.large)
            Text(rest.isEmpty ? " " : rest).font(compact ? .caption : .callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(row.note ?? "")
    }
}

/// A reading on its own ground, with a drawing beside the figure where there is something to draw:
/// a ring for a share of something, a bar per core for load.
/// A button for something that can be done to a Mac. `compact` draws the icon alone, named by its
/// tooltip. A choice among several is a menu, labelled with the choice in force when there is one
/// (the fan profile).
struct Act: View {
    var row: Row
    var compact = false

    @ViewBuilder private var label: some View {
        let label = Label(row.value.isEmpty ? row.title : row.value, systemImage: row.symbol ?? row.action?.symbol ?? "")
        if compact { label.labelStyle(.iconOnly) } else { label }
    }

    var body: some View {
        Group {
            if !row.children.isEmpty {
                Menu {
                    ForEach(row.children, id: \.title) { choice in
                        if choice.isSeparator {
                            Divider()
                        } else {
                            Button { choice.action.map(carryOut) } label: { Label(choice.title, systemImage: choice.symbol ?? choice.action?.symbol ?? "") }
                        }
                    }
                } label: {
                    label
                }
                .fixedSize()
            } else if case .awake(_, nil)? = row.action {
                // Lit while Fleet keeps the Mac awake; a click lets it sleep again.
                Toggle(isOn: Binding(get: { true }, set: { _ in row.action.map(carryOut) })) { label }.toggleStyle(.button)
            } else {
                Button { row.action.map(carryOut) } label: { label }
            }
        }
        // A tooltip names what the button does not: an icon alone, or a menu showing only its choice.
        .help(row.note ?? (compact || !row.value.isEmpty ? row.title : ""))
    }
}

struct Tile: View {
    var row: Row
    var share: Double?
    var cores: [Int]?
    var extra = ""

    var body: some View {
        Figure(row: row, extra: extra)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Beside the figure and clear of the line under it, which may run the tile's whole width.
            .overlay(alignment: .topTrailing) {
                Group {
                    if let share { Ring(share: share, level: row.level) } else if let cores { Cores(busy: cores) }
                }
                .padding(.top, 18)
            }
            .tile()
    }
}

/// How busy each core was, one bar a core.
struct Cores: View {
    var busy: [Int]

    var body: some View {
        // Thinner bars for more cores, so 18 take the room 10 do.
        let gap: CGFloat = busy.count > 12 ? 1 : 2
        let width = max(2, min(4, (58 - gap * CGFloat(busy.count - 1)) / CGFloat(max(busy.count, 1))))
        HStack(alignment: .bottom, spacing: gap) {
            ForEach(Array(busy.enumerated()), id: \.offset) { _, percent in
                Capsule().fill(.primary.opacity(0.1)).frame(width: width, height: 32)
                    .overlay(alignment: .bottom) {
                        Capsule().fill(.primary.opacity(0.45)).frame(width: width, height: max(2, 32 * Double(min(percent, 100)) / 100))
                    }
            }
        }
        .animation(.snappy(duration: 0.3), value: busy)
        .help("Load on each of \(busy.count) cores")
    }
}

struct Ring: View {
    var share: Double
    var level: Level?

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: 5)
            Circle().trim(from: 0, to: min(max(share, 0), 1))
                .stroke(level.fill, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy(duration: 0.3), value: share)
        }
        .frame(width: 32, height: 32)
        .padding(.trailing, 3)
    }
}

/// One reading over the last three hours, a point a minute. The line breaks where the helper has no
/// points: the Mac slept, or the helper started after the graph does.
struct Trend: View {
    var title: String
    var points: [(at: Date, value: Double)]
    var until: Date                     // the helper's clock, where the graph ends
    var top: Double?                    // the top of the scale, for a reading that has one
    var label: (Double) -> String
    @State private var pointed: Date?

    /// Each point with the number of the unbroken line it belongs to: a point more than two and a half
    /// minutes after the one before starts a new line.
    private var runs: [(at: Date, value: Double, run: Int)] {
        var run = 0
        return points.enumerated().map { index, point in
            if index > 0, point.at.timeIntervalSince(points[index - 1].at) > 150 { run += 1 }
            return (point.at, point.value, run)
        }
    }

    var body: some View {
        let shown = pointed.flatMap { at in points.min { abs($0.at.timeIntervalSince(at)) < abs($1.at.timeIntervalSince(at)) } }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                if let shown { Text("\(shown.at.formatted(date: .omitted, time: .shortened)) · \(label(shown.value))").monospacedDigit() }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach(runs, id: \.at) { point in
                    AreaMark(x: .value("Time", point.at), y: .value(title, point.value), series: .value("Line", point.run), stacking: .unstacked)
                        .foregroundStyle(Color.primary.opacity(0.08))
                    LineMark(x: .value("Time", point.at), y: .value(title, point.value), series: .value("Line", point.run))
                        .foregroundStyle(Color.primary.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if let shown {
                    RuleMark(x: .value("Time", shown.at)).foregroundStyle(Color.primary.opacity(0.25)).lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Time", shown.at), y: .value(title, shown.value)).symbolSize(36).foregroundStyle(Color.primary)
                }
            }
            .chartXScale(domain: until.addingTimeInterval(-3 * 3600)...until)
            .chartYScale(domain: 0...(top ?? max(points.map(\.value).max() ?? 0, 1000)))
            .chartXAxis { AxisMarks(values: .stride(by: .hour)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour()) } }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { mark in
                    AxisGridLine()
                    AxisValueLabel { if let value = mark.as(Double.self) { Text(label(value)) } }
                }
            }
            .chartOverlay { chart in
                GeometryReader { space in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            if case .active(let place) = phase, let plot = chart.plotFrame {
                                pointed = chart.value(atX: place.x - space[plot].origin.x, as: Date.self)
                            } else {
                                pointed = nil
                            }
                        }
                }
            }
            .frame(height: 96)
        }
        .tile()
    }
}

struct Bar: View {
    var share: Double
    var level: Level?

    var body: some View {
        Capsule().fill(.primary.opacity(0.1)).frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { space in
                    Capsule().fill(level.fill).frame(width: space.size.width * min(max(share, 0), 1))
                }
            }
            .animation(.snappy(duration: 0.3), value: share)
    }
}

/// One drive: how much is free, and a bar of how full it is, orange under the limit that puts a drive among the warnings.
struct Drive: View {
    var disk: Status.Disk
    var low: Bool
    var compact = false         // on a card: one line and the bar
    var note: String?           // a line under the bar; "" keeps the line and leaves it empty

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if compact {
                HStack {
                    Text(disk.name).lineLimit(1)
                    Spacer(minLength: 12)
                    Text("\(gigabytes(disk.freeGb)) free").foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                HStack(spacing: 5) {
                    Image(systemName: note?.isEmpty == false ? "clock.arrow.circlepath" : disk.name == "Macintosh HD" ? "internaldrive" : "externaldrive")
                        .imageScale(.small).frame(width: 16)
                    Text(disk.name).lineLimit(1)
                }
                .font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(gigabytes(disk.freeGb)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                    Text("free of \(gigabytes(disk.totalGb))").foregroundStyle(.secondary)
                }
            }
            Bar(share: disk.totalGb > 0 ? 1 - disk.freeGb / disk.totalGb : 0, level: low ? .warn : nil)
            if let note { Text(note.isEmpty ? " " : note).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Names with their values beside them, the values free to wrap: for readings too long for a row.
struct Facts: View {
    var rows: [Row]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 20, verticalSpacing: 8) {
            ForEach(rows, id: \.title) { row in
                GridRow {
                    Text(row.title).foregroundStyle(.secondary)
                    Text(row.value).textSelection(.enabled)
                }
            }
        }
    }
}

/// The menu's rows drawn in the window: a dot or an action's icon, the title, the value at the
/// right. A row with an action is a button. A long name is cut to one line and shown whole in the
/// tooltip. `sideBySide` sets many short rows in as many columns as fit.
struct Rows: View {
    var rows: [Row]
    var sideBySide = false

    var body: some View {
        if sideBySide {
            // What has a state stands side by side; what can be done about it goes underneath, across the whole width.
            let rest = rows.filter { $0.dot == nil && !$0.isSeparator }
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .leading)], alignment: .leading, spacing: 0) {
                    each(rows.filter { $0.dot != nil })
                }
                if !rest.isEmpty {
                    Divider().padding(.vertical, 6)
                    each(rest)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) { each(rows) }
        }
    }

    private func each(_ rows: [Row]) -> some View {
        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
            if row.isSeparator {
                Divider().padding(.vertical, 6)
            } else if row.isHeader {
                Text(row.title).font(.subheadline).foregroundStyle(.secondary).padding(.top, 10).padding(.bottom, 2)
            } else {
                RowLine(row: row, sideBySide: sideBySide)
            }
        }
    }
}

/// One row. What else can be done to it (restart a container, show its logs) is in the "…" menu at
/// its end, and on right-click; clicking the row itself opens it, where it opens something.
struct RowLine: View {
    var row: Row
    var sideBySide: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let action = row.action {
                Button { carryOut(action) } label: { line }.buttonStyle(Pressable(outset: 6))
            } else {
                line
            }
            if !row.extras.isEmpty {
                Menu { extras } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .opacity(0.45)        // a menu's label takes no colour of its own
                    .accessibilityLabel("Actions for \(row.title)")
            }
        }
        .contextMenu { extras }
    }

    @ViewBuilder private var extras: some View {
        if let action = row.action, case .open = action { Button("Open in Browser") { carryOut(action) } }
        ForEach(row.extras, id: \.title) { extra in
            Button(extra.title) { extra.action.map(carryOut) }
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            if let dot = row.dot {
                Dot(level: dot)
            } else if let action = row.action {
                Image(systemName: row.symbol ?? action.symbol).foregroundStyle(.secondary)
            }
            Text(row.title).lineLimit(1)
            Spacer(minLength: 4)
            // Side by side there is no room for an address beside every name: the tooltip has it, and a row
            // with no menu of its own gets an arrow to say that it opens something.
            if sideBySide, row.action != nil, row.level == nil {
                if row.extras.isEmpty { Image(systemName: "arrow.up.forward").imageScale(.small).foregroundStyle(.tertiary) }
            } else if !row.value.isEmpty {
                Text(row.value).lineLimit(1)
                    .foregroundStyle(row.dim ? Color(nsColor: .tertiaryLabelColor) : row.level == .bad || row.level == .warn ? row.level!.color : .secondary)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.25), value: row.value)
                    .animation(row.dim ? .easeOut(duration: 0.2).delay(0.5) : nil, value: row.dim)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .help([row.title, row.value, row.note ?? ""].reduce(into: [String]()) { if !$1.isEmpty, !$0.contains($1) { $0.append($1) } }.joined(separator: "\n"))
    }
}

/// Lays its views out in a line and starts a new line when the next one does not fit.
struct Flow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let last = place(subviews, in: width).last
        return CGSize(width: proposal.width ?? (last.map { $0.maxX } ?? 0), height: last?.maxY ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, in: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, in width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = [], x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

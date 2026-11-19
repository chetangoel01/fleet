// Fleet's fan curve editor: a sheet over a Mac's page that shapes the curve Cooler's controller
// follows there. It starts from the curve in the Mac's last answer and applies through the same
// root script as the profiles, over ssh for another Mac.

import Charts
import SwiftUI

struct CurvePoint: Equatable {
    var temperature: Double
    var fraction: Double        // fan demand, 0 to 1 of the range above the baseline
}

/// The controller draws straight lines between points and holds the end values beyond the first and last.
func demand(at temperature: Double, on points: [CurvePoint]) -> Double {
    guard let first = points.first, let last = points.last else { return 0 }
    if temperature <= first.temperature { return first.fraction }
    for (a, b) in zip(points, points.dropFirst()) where temperature <= b.temperature {
        return a.fraction + (b.fraction - a.fraction) * (temperature - a.temperature) / (b.temperature - a.temperature)
    }
    return last.fraction
}

/// One curve, with points to drag. A double-click adds a point.
struct CurveChart: View {
    @Binding var points: [CurvePoint]
    @Binding var selection: Int?
    var palm: Bool
    var now: Double?            // the temperature this curve follows, as of the Mac's last answer
    var insert: (Double) -> Void
    @State private var dragging: Int?
    @State private var frozen: ClosedRange<Double>?     // the axis holds still during a drag

    private var domain: ClosedRange<Double> {
        if let frozen { return frozen }
        let low = min(palm ? 25 : 35, (points.first?.temperature ?? 40) - 5)
        let high = max(palm ? 45 : 90, (points.last?.temperature ?? 85) + 5)
        return (low / 5).rounded(.down) * 5...(high / 5).rounded(.up) * 5
    }

    /// Keeps temperatures increasing, demand never decreasing, and the last point at full speed:
    /// the rules Cooler's controller checks a curve against.
    private func move(_ index: Int, to temperature: Double, fraction: Double) {
        guard points.indices.contains(index) else { return }
        let coolest = index == 0 ? 10 : points[index - 1].temperature + 1
        let hottest = index == points.count - 1 ? 90 : points[index + 1].temperature - 1
        points[index].temperature = min(hottest, max(coolest, temperature.rounded()))
        if index < points.count - 1 {
            let least = index == 0 ? 0 : points[index - 1].fraction
            points[index].fraction = min(points[index + 1].fraction, max(least, (fraction * 100).rounded() / 100))
        }
    }

    private func nearest(to location: CGPoint, proxy: ChartProxy, plot: CGRect) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for index in points.indices {
            guard let x = proxy.position(forX: points[index].temperature),
                  let y = proxy.position(forY: points[index].fraction * 100) else { continue }
            let distance = hypot(plot.minX + x - location.x, plot.minY + y - location.y)
            if distance < 18, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }

    var body: some View {
        let range = domain
        let line = [CurvePoint(temperature: range.lowerBound, fraction: points.first?.fraction ?? 0)] + points
            + [CurvePoint(temperature: range.upperBound, fraction: points.last?.fraction ?? 1)]
        Chart {
            ForEach(Array(line.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Temperature", point.temperature), y: .value("Speed", point.fraction * 100))
                    .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.24), Color.accentColor.opacity(0.03)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Temperature", point.temperature), y: .value("Speed", point.fraction * 100))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }
            if let now, range.contains(now) {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, spacing: 2) {
                        Text("\(Int(now.rounded()))°").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                PointMark(x: .value("Now", now), y: .value("Speed", demand(at: now, on: points) * 100))
                    .symbolSize(30).foregroundStyle(Color.secondary)
            }
            ForEach(points.indices, id: \.self) { index in
                PointMark(x: .value("Temperature", points[index].temperature), y: .value("Speed", points[index].fraction * 100))
                    .symbol {
                        Circle()
                            .fill(selection == index ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                            .frame(width: selection == index ? 14 : 11, height: selection == index ? 14 : 11)
                    }
            }
        }
        .chartXScale(domain: range)
        .chartYScale(domain: -4...104)
        .chartXAxis {
            AxisMarks(values: .stride(by: palm ? 5 : 10)) { value in
                AxisGridLine()
                AxisValueLabel { if let degrees = value.as(Double.self) { Text("\(Int(degrees))°") } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel { if let speed = value.as(Double.self) { Text(speed == 0 ? "Min" : speed == 100 ? "Full" : "50%") } }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { event in
                            guard let anchor = proxy.plotFrame else { return }
                            let plot = geometry[anchor]
                            if dragging == nil {
                                frozen = range
                                dragging = nearest(to: event.startLocation, proxy: proxy, plot: plot)
                                if let dragging { selection = dragging }
                            }
                            guard let index = dragging,
                                  let temperature: Double = proxy.value(atX: event.location.x - plot.minX),
                                  let speed: Double = proxy.value(atY: event.location.y - plot.minY) else { return }
                            if event.translation != .zero { move(index, to: temperature, fraction: speed / 100) }
                        }
                        .onEnded { _ in dragging = nil; frozen = nil })
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { event in
                        guard let anchor = proxy.plotFrame,
                              let temperature: Double = proxy.value(atX: event.location.x - geometry[anchor].minX) else { return }
                        insert(temperature)
                    })
            }
        }
        .accessibilityLabel(palm ? "Palm rest curve" : "CPU and GPU curve")
        .accessibilityValue("\(points.count) points")
    }
}

struct CurveEditor: View {
    var machine: Machine
    var cooling: Status.Cooling
    var thermal: Status.Thermal
    @State private var baseline: Double
    @State private var chip: [CurvePoint]
    @State private var palm: [CurvePoint]
    @State private var onPalm = false
    @State private var selection: Int? = 0
    @State private var applying = false
    @Environment(\.dismiss) private var dismiss

    init(machine: Machine, cooling: Status.Cooling, thermal: Status.Thermal) {
        self.machine = machine
        self.cooling = cooling
        self.thermal = thermal
        // Max Cooling is flat out at every temperature, with nothing to shape: editing then starts from a curve that has one.
        let flatOut = cooling.installed?.chip.allSatisfy { $0.count == 2 && $0[1] == 1 } ?? true
        let start = (flatOut ? nil : cooling.installed) ?? cooling.saved ?? fanProfiles[2]
        _baseline = State(initialValue: Double(start.baseline))
        _chip = State(initialValue: Self.points(start.chip))
        _palm = State(initialValue: Self.points(start.palm))
    }

    private static func points(_ curve: [[Double]]) -> [CurvePoint] {
        curve.filter { $0.count == 2 }.map { CurvePoint(temperature: $0[0], fraction: $0[1]) }
    }

    private var draft: FanProfile {
        FanProfile(name: "Custom", baseline: Int(baseline), chip: chip.map { [$0.temperature, $0.fraction] }, palm: palm.map { [$0.temperature, $0.fraction] })
    }

    /// Whether the Mac's fans already follow the curve as drawn. With macOS running them they do not, whatever was last set.
    private var inForce: Bool {
        guard cooling.running == true, let installed = cooling.installed else { return false }
        return installed.baseline == draft.baseline && installed.chip == draft.chip && installed.palm == draft.palm
    }

    private var now: Double? {
        onPalm ? thermal.palmC : [thermal.cpuC, thermal.gpuC].compactMap { $0 }.max()
    }

    private func use(_ profile: FanProfile) {
        commitFields()
        baseline = Double(profile.baseline)
        chip = Self.points(profile.chip)
        palm = Self.points(profile.palm)
        selection = 0
    }

    /// A value still being typed is taken before anything reads the curve.
    private func commitFields() { NSApp.keyWindow?.makeFirstResponder(nil) }

    var body: some View {
        // Everything below keeps the curve it was made for, so switching curves can't redirect an edit.
        let curve = onPalm ? $palm : $chip
        let count = curve.wrappedValue.count
        let removable = (selection.map { $0 < count - 1 } ?? false) && count > 2
        VStack(spacing: 14) {
            HStack {
                Text("Fan Curve").font(.headline)
                Spacer()
                // A Mac without palm rest sensors has one curve to shape.
                if cooling.palm == true {
                    Picker("Curve", selection: $onPalm) {
                        Text("CPU & GPU").tag(false)
                        Text("Palm rest").tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            CurveChart(points: curve, selection: $selection, palm: onPalm, now: now) { insert($0, in: curve) }
                .frame(height: 230)
            HStack(spacing: 14) {
                ControlGroup {
                    Button { add(to: curve) } label: { Image(systemName: "plus") }
                        .help("Add point").disabled(count >= 20)
                    Button { remove(from: curve) } label: { Image(systemName: "minus") }
                        .help("Remove point").disabled(!removable)
                }
                .fixedSize()
                if let index = selection, index < count { pointFields(index, in: curve) }
                Spacer(minLength: 12)
                Text("Minimum").foregroundStyle(.secondary)
                TextField("Minimum RPM", value: slowest, format: .number.precision(.fractionLength(0)))
                    .textFieldStyle(.roundedBorder).frame(width: 58).multilineTextAlignment(.trailing)
                    .accessibilityLabel("Minimum RPM")
                Text("RPM").foregroundStyle(.secondary)
                Stepper("Minimum RPM", value: slowest, in: 1200...2500, step: 100).labelsHidden()
            }
            HStack {
                Menu("Start From") {
                    if let installed = cooling.installed { Button("Current Curve") { use(installed) } }
                    if let saved = cooling.saved { Button("Custom") { use(saved) } }
                    Divider()
                    ForEach(fanProfiles.prefix(3), id: \.name) { profile in
                        Button(profile.name) { use(profile) }
                    }
                }
                .fixedSize()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply") {
                    commitFields()
                    applying = true
                    // Taken on the next turn, once a typed value has landed in the curve.
                    DispatchQueue.main.async {
                        runQuietly("Fan Curve", customCommand(machine, draft)) { worked in
                            applying = false
                            if worked { dismiss() }
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inForce)
            }
        }
        .padding(20)
        .frame(width: 640)
        .disabled(applying)
        .onChange(of: onPalm) { selection = 0 }
    }

    /// The speed the fans idle at, within what Cooler accepts.
    private var slowest: Binding<Double> {
        Binding(get: { baseline }, set: { baseline = min(2500, max(1200, $0.rounded())) })
    }

    /// Adds a point in the widest gap and selects it.
    private func add(to curve: Binding<[CurvePoint]>) {
        commitFields()
        let points = curve.wrappedValue
        guard points.count < 20, let widest = (0..<(points.count - 1)).max(by: {
            points[$0 + 1].temperature - points[$0].temperature < points[$1 + 1].temperature - points[$1].temperature
        }) else { return }
        curve.wrappedValue.insert(CurvePoint(temperature: ((points[widest].temperature + points[widest + 1].temperature) / 2).rounded(),
                                             fraction: (points[widest].fraction + points[widest + 1].fraction) / 2), at: widest + 1)
        selection = widest + 1
    }

    /// A double-click on the graph: a new point on the curve at that temperature.
    private func insert(_ temperature: Double, in curve: Binding<[CurvePoint]>) {
        let points = curve.wrappedValue, degrees = temperature.rounded()
        guard points.count < 20, degrees >= 10, let index = points.firstIndex(where: { $0.temperature > degrees }),
              index == 0 || points[index - 1].temperature < degrees else { return }
        commitFields()
        curve.wrappedValue.insert(CurvePoint(temperature: degrees, fraction: (demand(at: degrees, on: points) * 100).rounded() / 100), at: index)
        selection = index
    }

    private func remove(from curve: Binding<[CurvePoint]>) {
        commitFields()
        guard let index = selection, index < curve.wrappedValue.count - 1, curve.wrappedValue.count > 2 else { return }
        curve.wrappedValue.remove(at: index)
        selection = max(0, index - 1)
    }

    /// The selected point's exact values, and the speed each fan runs at there. Typed values are held between the neighbours, like dragging.
    private func pointFields(_ index: Int, in curve: Binding<[CurvePoint]>) -> some View {
        let points = curve.wrappedValue
        let temperature = Binding<Double>(
            get: { index < curve.wrappedValue.count ? curve.wrappedValue[index].temperature : 0 },
            set: { value in
                let points = curve.wrappedValue
                guard index < points.count else { return }
                let coolest = index == 0 ? 10 : points[index - 1].temperature + 1
                let hottest = index == points.count - 1 ? 90 : points[index + 1].temperature - 1
                curve.wrappedValue[index].temperature = min(hottest, max(coolest, value.rounded()))
            })
        let speed = Binding<Double>(
            get: { index < curve.wrappedValue.count ? curve.wrappedValue[index].fraction * 100 : 0 },
            set: { value in
                let points = curve.wrappedValue
                guard index < points.count - 1 else { return }
                let least = index == 0 ? 0 : points[index - 1].fraction
                curve.wrappedValue[index].fraction = min(points[index + 1].fraction, max(least, value.rounded() / 100))
            })
        let fraction = index < points.count ? points[index].fraction : 0
        let rpm = (cooling.fanLimits ?? []).filter { $0.count == 2 }.map { limit in
            let floor = max(baseline, limit[0])
            return Int((floor + (limit[1] - floor) * fraction).rounded()).formatted()
        }.joined(separator: " / ")
        return HStack(spacing: 5) {
            TextField("Temperature", value: temperature, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 44).multilineTextAlignment(.trailing)
                .accessibilityLabel("Selected point temperature")
            Text("°C").foregroundStyle(.secondary)
            TextField("Speed", value: speed, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder).frame(width: 40).multilineTextAlignment(.trailing)
                .disabled(index >= points.count - 1).accessibilityLabel("Selected point speed")
            Text("%").foregroundStyle(.secondary)
            if !rpm.isEmpty { Text("\(rpm) RPM").foregroundStyle(.secondary).monospacedDigit().padding(.leading, 6) }
        }
        .fixedSize()
    }
}

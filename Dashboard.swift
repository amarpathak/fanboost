// Dashboard: the panel shown when you click FanBoost in the menu bar.
import SwiftUI
import Charts

struct Dashboard: View {
    @ObservedObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("CPU temperature · last 10 min, 10s averages")
                    tempChart
                    sectionTitle("Fan speed")
                    fanChart
                }
                .frame(width: 350)
                VStack(alignment: .leading, spacing: 14) {
                    processes.frame(height: 150, alignment: .top)
                    heatLog.frame(height: 160, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                battery.frame(width: 350, height: 100, alignment: .topLeading)
                controls
            }
            footer
        }
        .padding(16)
        .frame(width: 640)
    }

    // MARK: - Header

    var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayTemp.map { String(format: "%.0f°C", $0) } ?? "--")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundColor(tempColor(m.displayTemp))
                    .monospacedDigit()
                Text(stateText).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(Array(m.status.rpms.enumerated()), id: \.offset) { i, rpm in
                fanGauge(index: i, rpm: rpm)
            }
        }
    }

    var stateText: String {
        if let e = m.lastError { return "⚠️ \(e)" }
        if m.boosting { return "🌪 Boosting: CPU held above \(Int(m.hot))°C" }
        switch m.mode {
        case .smart: return "Smart · macOS controls fans until \(Int(m.hot))°C"
        case .auto: return "Auto · macOS controls the fans"
        case .medium: return "Fixed 50% · max when hot"
        case .high: return "Fixed 75% · max when hot"
        case .max: return "Fans at max"
        }
    }

    func fanGauge(index i: Int, rpm: Int) -> some View {
        let lo = Double(m.status.fanMin[safe: i] ?? 0)
        let hi = Double(m.status.fanMax[safe: i] ?? 6000)
        let fraction = hi > lo ? min(max((Double(rpm) - lo) / (hi - lo), 0), 1) : 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Fan \(i + 1)").font(.caption).foregroundStyle(.secondary)
            Text("\(rpm) rpm").font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
            ProgressView(value: fraction).frame(width: 90).tint(fraction > 0.8 ? .red : .blue)
        }
    }

    // MARK: - Charts

    var visibleBoosts: [Boost] {
        m.boosts.filter { ($0.end ?? Date()) > timeWindow.lowerBound }
    }

    var tempChart: some View {
        let start = timeWindow.lowerBound
        return Chart {
            ForEach(visibleBoosts) { b in
                RectangleMark(xStart: .value("Start", max(b.date, start)), xEnd: .value("End", b.end ?? Date()))
                    .foregroundStyle(.red.opacity(0.08))
            }
            RuleMark(y: .value("Boost", m.hot))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.red.opacity(0.6))
                .annotation(position: .top, alignment: .leading) {
                    Text("boost \(Int(m.hot))°").font(.caption2).foregroundStyle(.red.opacity(0.8))
                }
            RuleMark(y: .value("Release", m.cool))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(.blue.opacity(0.5))
                .annotation(position: .bottom, alignment: .leading) {
                    Text("release \(Int(m.cool))°").font(.caption2).foregroundStyle(.blue.opacity(0.8))
                }
            ForEach(m.history) { s in
                LineMark(x: .value("Time", s.date), y: .value("°C", s.temp))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartYScale(domain: 30...105)
        .chartYAxis { AxisMarks(position: .leading, values: [40, 60, 80, 100]) }
        .chartXScale(domain: timeWindow)
        .chartXAxis { timeAxis }
        .frame(height: 165)
    }

    var fanChart: some View {
        let top = Double(m.status.fanMax.max() ?? 6000)
        return Chart(m.history) { s in
            AreaMark(x: .value("Time", s.date), y: .value("rpm", s.rpm))
                .foregroundStyle(.blue.opacity(0.25))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", s.date), y: .value("rpm", s.rpm))
                .foregroundStyle(.blue)
                .interpolationMethod(.monotone)
        }
        .chartYScale(domain: 0...max(top, 1000))
        .chartYAxis { AxisMarks(position: .leading, values: [0, 2000, 4000]) }
        .padding(.top, 4)
        .chartXScale(domain: timeWindow)
        .chartXAxis { timeAxis }
        .frame(height: 95)
    }

    // Both charts always span the full history window so their time axes line up.
    var timeWindow: ClosedRange<Date> {
        let now = m.history.last?.date ?? Date()
        return now.addingTimeInterval(-Double(m.historySeconds))...now
    }

    var timeAxis: some AxisContent {
        // .aligned keeps the first and last labels inside the chart instead of clipping them.
        AxisMarks(preset: .aligned, values: .stride(by: .minute, count: 2)) { _ in
            AxisGridLine()
            AxisValueLabel(format: .dateTime.hour().minute())
        }
    }

    // MARK: - Processes and heat log

    var processes: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Using CPU · last ~10s")
            if m.procs.isEmpty {
                Text("Measuring…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(m.procs.prefix(5)) { p in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(p.name).lineLimit(1).truncationMode(.middle)
                        if p.name == "kernel_task" {
                            Text("macOS slowing the CPU to cool it").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Capsule().fill(p.cpu > 100 ? Color.red : Color.orange)
                        .frame(width: CGFloat(min(p.cpu, 400) / 400 * 50), height: 4)
                    Text("\(Int(p.cpu))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
            }
        }
    }

    var heatLog: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Heat boosts")
            Text("🔥 \(m.heatSummary)").font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(m.boosts.suffix(4).reversed()) { b in
                HStack(spacing: 6) {
                    Text(b.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                        .foregroundStyle(.secondary)
                    Text(b.culprit).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(duration(b)).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
        }
    }

    func duration(_ b: Boost) -> String {
        if b.end == b.date { return "–" }   // app was killed mid-boost; length unknown
        let secs = Int((b.end ?? Date()).timeIntervalSince(b.date))
        let text = secs < 60 ? "\(secs)s" : "\(secs / 60)m"
        return b.end == nil ? "\(text)…" : text
    }

    // MARK: - Battery and controls

    var battery: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Battery")
            if let pct = m.status.battery {
                HStack(spacing: 8) {
                    Text("\(pct)%").font(.system(.title3, design: .rounded).weight(.medium)).monospacedDigit()
                    Text(m.batteryState).foregroundStyle(.secondary)
                }
                if let h = m.batteryHealth {
                    let temp = h.temp.map { String(format: " · %.0f°C", $0) } ?? ""
                    Text("Health \(h.health)% · \(h.cycles) cycles\(temp)").font(.callout)
                    if h.health < 80 {
                        Text("Below 80% of its original capacity. A battery replacement would restore runtime.")
                            .font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("No battery").foregroundStyle(.secondary)
            }
        }
    }

    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle("Fans")
                Picker("Fans", selection: Binding(get: { m.mode }, set: { m.setMode($0) })) {
                    ForEach(Mode.allCases) { Text($0.short).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if m.chargeLimitSupported {
                VStack(alignment: .leading, spacing: 4) {
                    sectionTitle("Charge limit")
                    Picker("Charge limit", selection: Binding(get: { m.chargeLimit }, set: { m.setChargeLimit($0) })) {
                        Text("Off").tag(0)
                        Text("80%").tag(80)
                        Text("90%").tag(90)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
        }
    }

    var footer: some View {
        HStack {
            Text("FanBoost \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .foregroundStyle(.secondary)
            Link("GitHub", destination: URL(string: "https://github.com/amarpathak/fanboost")!)
            Spacer()
            Button("Quit FanBoost") { NSApp.terminate(nil) }
        }
        .font(.caption)
    }

    // MARK: - Helpers

    func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
    }

    func tempColor(_ t: Double?) -> Color {
        guard let t = t else { return .secondary }
        if t >= 85 { return .red }
        if t >= m.hot { return .orange }
        return .green
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

// Monitor: reads sensors in-process, runs the fan/charge logic, and keeps history for
// the dashboard. fanctl (via sudo) is only used for writes, which are rare.
import Foundation
import IOKit

let fanctl = "/usr/local/bin/fanctl"

struct Status {
    var temp: Double?
    var rpms: [Int] = []
    var fanMax: [Int] = []
    var fanMin: [Int] = []
    var manual = false
    var battery: Int?
    var onAC = false
    var charging = false
    var bclm: Int?              // Intel: hardware charge limit currently set
    var softwareLimit = false   // Apple Silicon: limit by pausing charging
}

enum Mode: String, CaseIterable, Identifiable {
    case smart, auto, medium, high, max
    var id: String { rawValue }
    var short: String {
        switch self {
        case .smart: return "Smart"
        case .auto: return "Auto"
        case .medium: return "50%"
        case .high: return "75%"
        case .max: return "Max"
        }
    }
}

// One automatic boost and the process that was using the most CPU at the time.
struct Boost: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let culprit: String
    let cpu: Double
    var end: Date?
}

struct Sample: Identifiable {
    var id: Date { date }
    let date: Date
    let temp: Double
    let rpm: Int
}

struct ProcUsage: Identifiable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let cpu: Double             // percent of one core, so 400 = four cores busy
}

struct BatteryHealth {
    let health: Int             // max capacity as % of design capacity
    let cycles: Int
    let temp: Double?
}

@discardableResult
func exec(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

final class Monitor: ObservableObject {
    // Published state is refreshed every `publishEvery` ticks (or right away on events),
    // so the UI stays readable and cheap. The control loop reads sensors every tick.
    @Published var status = Status()
    @Published var displayTemp: Double?     // average of the last few readings
    @Published var history: [Sample] = []
    @Published var procs: [ProcUsage] = []
    @Published var boosts: [Boost]
    @Published var mode: Mode
    @Published var chargeLimit: Int     // percent; 0 means off
    @Published var boosting = false     // a smart/safety boost is holding the fans at max
    @Published var lastError: String?
    @Published var batteryHealth: BatteryHealth?

    // Smart, Medium and High go to max once the CPU has stayed at/above `hot` for
    // `holdSeconds`, and drop back below `cool`, so a fixed speed can never cool
    // less than the Mac needs. The hold ignores brief spikes like an app launching.
    let hot = 65.0, cool = 58.0, holdSeconds = 3.0
    let historySeconds = 600
    let historyBucket = 10          // seconds averaged into each chart point
    let publishEvery = 3            // seconds between UI updates
    let tempSmoothing = 5           // readings averaged for the displayed temperature
    var dashboardOpen = false { didSet { if dashboardOpen { publish() } } }
    // Boost log entries older than this are deleted, so the saved log stays small.
    let boostRetention: TimeInterval = 2 * 86400
    // Software charge limiting resumes this many points below the limit.
    let chargeHysteresis = 5

    private let defaults = UserDefaults.standard
    private var hotSince: Date?
    private var chargingPaused = false
    private var tickCount = 0
    private var lastCPUTimes: [Int32: Double] = [:]
    private var lastProcSample: Date?
    private var cpuAverage: [Int32: (name: String, cpu: Double)] = [:]
    private var raw = Status()
    private var recentTemps: [Double] = []
    private var bucketTemps: [Double] = []
    private var bucketRPMs: [Int] = []

    init() {
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .smart
        chargeLimit = defaults.integer(forKey: "chargeLimit")
        boosts = defaults.data(forKey: "boosts")
            .flatMap { try? JSONDecoder().decode([Boost].self, from: $0) } ?? []
        // A boost still open at launch means the app was killed mid-boost; its real end
        // is unknown, so mark it ended where it started (shown as "–").
        for i in boosts.indices where boosts[i].end == nil { boosts[i].end = boosts[i].date }
        pruneBoosts()
    }

    func start() {
        _ = sensors_open()
        raw = readStatus(includeBattery: true)
        apply(mode)
        if raw.softwareLimit { write(["charging", "on"]) }
        tick()
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.2   // lets macOS coalesce wake-ups
    }

    func stop() {
        endBoost()
        write(["auto"])
        // Never leave an Apple Silicon Mac unable to charge after quitting.
        if chargingPaused { write(["charging", "on"]) }
    }

    func setMode(_ m: Mode) {
        mode = m
        defaults.set(m.rawValue, forKey: "mode")
        apply(m)
        publish()
    }

    func setChargeLimit(_ pct: Int) {
        chargeLimit = pct
        defaults.set(pct, forKey: "chargeLimit")
        applyChargeLimit(raw)
        publish()
    }

    var chargeLimitSupported: Bool { status.bclm != nil || status.softwareLimit }

    var batteryState: String {
        guard let pct = status.battery else { return "" }
        if status.charging { return "charging" }
        if !status.onAC { return "on battery" }
        if chargeLimit > 0 && pct >= chargeLimit - chargeHysteresis { return "held by \(chargeLimit)% limit" }
        return "on power, not charging"
    }

    var heatSummary: String {
        let today = boosts.filter { Calendar.current.isDateInToday($0.date) }
        guard !today.isEmpty else { return "No heat boosts today" }
        let counts = Dictionary(grouping: today, by: \.culprit).mapValues(\.count)
        let top = counts.max { $0.value < $1.value }!.key
        return "Boosted \(today.count)× today · mostly \(top)"
    }

    // MARK: - Polling

    private func tick() {
        tickCount += 1
        // Battery and charge-limit state change slowly; read them every 10 seconds.
        let s = readStatus(includeBattery: tickCount % 10 == 1)
        raw = s

        if let t = s.temp {
            recentTemps = (recentTemps + [t]).suffix(tempSmoothing)
            bucketTemps.append(t)
            bucketRPMs.append(s.rpms.max() ?? 0)
        }
        if bucketTemps.count >= historyBucket {
            let cutoff = Date().addingTimeInterval(-Double(historySeconds))
            let avgTemp = bucketTemps.reduce(0, +) / Double(bucketTemps.count)
            let avgRPM = bucketRPMs.reduce(0, +) / bucketRPMs.count
            history = history.filter { $0.date > cutoff } + [Sample(date: Date(), temp: avgTemp, rpm: avgRPM)]
            bucketTemps = []
            bucketRPMs = []
        }

        var event = false
        if mode == .smart || mode == .medium || mode == .high {
            // Unknown temperature is treated as hot: fail toward more cooling.
            let t = s.temp ?? .infinity
            hotSince = t >= hot ? (hotSince ?? Date()) : nil
            if !boosting, let since = hotSince, Date().timeIntervalSince(since) >= holdSeconds {
                apply(.max)
                boosting = true
                sampleProcesses()   // second snapshot: CPU use over the hold window
                recordBoost()
                event = true
            } else if boosting && t < cool {
                apply(mode)
                event = true
            } else if boosting && !s.manual {
                // Something else (sleep/wake, another tool) gave the fans back to macOS.
                write(["max"])
            }
        }
        applyChargeLimit(s)

        // Per-process CPU costs a `ps` run, so it's only measured while the dashboard is
        // open, plus one snapshot when the CPU first crosses `hot`. The boost (above)
        // takes a second snapshot, and the difference names the culprit.
        if dashboardOpen {
            if tickCount % publishEvery == 0 { sampleProcesses() }
        } else if hotSince != nil {
            if lastProcSample == nil { sampleProcesses() }
        } else if lastProcSample != nil {
            lastProcSample = nil
            lastCPUTimes = [:]
            cpuAverage = [:]
        }

        if event || tickCount % publishEvery == 0 { publish() }
    }

    // Copies the latest readings into published state for the menu bar and dashboard.
    private func publish() {
        status = raw
        displayTemp = recentTemps.isEmpty ? raw.temp : recentTemps.reduce(0, +) / Double(recentTemps.count)
        procs = Array(cpuByName().filter { $0.cpu >= 2 }.prefix(5))
        if tickCount % 30 == 1 || batteryHealth == nil { batteryHealth = readBatteryHealth() }
    }

    private func readStatus(includeBattery: Bool) -> Status {
        var s = Status()
        let t = sensors_cpu_temp()
        if t > 0 { s.temp = t }
        for i in 0..<sensors_fan_count() {
            var actual = 0.0, lo = 0.0, hi = 0.0
            var manual: Int32 = 0
            guard sensors_fan(Int32(i), &actual, &lo, &hi, &manual) == 0 else { continue }
            s.rpms.append(Int(actual))
            s.fanMin.append(Int(lo))
            s.fanMax.append(Int(hi))
            if manual != 0 { s.manual = true }
        }
        if includeBattery {
            var pct: Int32 = 0, ac: Int32 = 0, charging: Int32 = 0
            if sensors_battery(&pct, &ac, &charging) == 0 {
                s.battery = Int(pct)
                s.onAC = ac != 0
                s.charging = charging != 0
            }
            let limit = sensors_charge_limit()
            if limit >= 0 { s.bclm = Int(limit) } else { s.softwareLimit = sensors_can_pause_charging() != 0 }
        } else {
            s.battery = raw.battery
            s.onAC = raw.onAC
            s.charging = raw.charging
            s.bclm = raw.bclm
            s.softwareLimit = raw.softwareLimit
        }
        return s
    }

    private func write(_ args: [String]) {
        let (code, text) = exec("/usr/bin/sudo", ["-n", fanctl] + args)
        lastError = code == 0 ? nil : (text.contains("password") ? "Not installed: run the installer" : text)
    }

    private func apply(_ m: Mode) {
        endBoost()
        boosting = false
        switch m {
        case .auto, .smart: write(["auto"])
        case .medium: write(["set", "50"])
        case .high: write(["set", "75"])
        case .max: write(["max"])
        }
    }

    // MARK: - Heat log

    private func recordBoost() {
        // kernel_task is macOS's cooling throttle: the symptom, not the cause.
        let skip: Set<String> = ["kernel_task", "FanBoost", "fanctl", "sudo"]
        guard let top = cpuByName().first(where: { !skip.contains($0.name) }) else { return }
        boosts.append(Boost(date: Date(), culprit: top.name, cpu: top.cpu))
        pruneBoosts()
    }

    private func pruneBoosts() {
        let cutoff = Date().addingTimeInterval(-boostRetention)
        boosts.removeAll { $0.date < cutoff }
        saveBoosts()
    }

    // CPU summed per process name (Chrome runs many helpers with the same name), busiest first.
    private func cpuByName() -> [ProcUsage] {
        var total: [String: (pid: Int32, cpu: Double)] = [:]
        for (pid, p) in cpuAverage {
            let prev = total[p.name]
            total[p.name] = (prev?.pid ?? pid, (prev?.cpu ?? 0) + p.cpu)
        }
        return total.map { ProcUsage(pid: $0.value.pid, name: $0.key, cpu: $0.value.cpu) }
            .sorted { $0.cpu > $1.cpu }
    }

    private func endBoost() {
        guard boosting, let i = boosts.indices.last, boosts[i].end == nil else { return }
        boosts[i].end = Date()
        saveBoosts()
    }

    private func saveBoosts() {
        if let data = try? JSONEncoder().encode(boosts) { defaults.set(data, forKey: "boosts") }
    }

    // CPU usage per process over the last interval, from the change in cumulative CPU
    // time. `ps -o pcpu` is a decaying average that lags spikes, so it isn't used.
    private func sampleProcesses() {
        let now = Date()
        var times: [Int32: Double] = [:]
        var names: [Int32: String] = [:]
        for line in exec("/bin/ps", ["-Ao", "pid=,time=,comm="]).1.split(separator: "\n") {
            var rest = Substring(line).drop { $0 == " " }
            guard let sp1 = rest.firstIndex(of: " "), let pid = Int32(rest[..<sp1]) else { continue }
            rest = rest[sp1...].drop { $0 == " " }
            guard let sp2 = rest.firstIndex(of: " "), let t = parseCPUTime(rest[..<sp2]) else { continue }
            times[pid] = t
            names[pid] = (String(rest[sp2...].drop { $0 == " " }) as NSString).lastPathComponent
        }
        if let last = lastProcSample {
            let dt = now.timeIntervalSince(last)
            // Exponential moving average (~10s) so the list doesn't jump around.
            let weight = min(dt / 10, 1)
            var next: [Int32: (name: String, cpu: Double)] = [:]
            for (pid, t) in times {
                // A pid missing from the last snapshot started since then: count from zero.
                guard let name = names[pid], name != "ps" else { continue }
                let prev = lastCPUTimes[pid] ?? 0
                let cpu = max(t - prev, 0) / dt * 100
                let avg = (cpuAverage[pid]?.cpu ?? cpu) * (1 - weight) + cpu * weight
                if avg >= 0.5 { next[pid] = (name, avg) }
            }
            cpuAverage = next
        }
        lastCPUTimes = times
        lastProcSample = now
    }

    // ps CPU time looks like "12:34.56", "1:02:03.04" or "2-01:02:03.04".
    private func parseCPUTime(_ s: Substring) -> Double? {
        var days = 0.0
        var clock = s
        if let dash = s.firstIndex(of: "-") {
            days = Double(s[..<dash]) ?? 0
            clock = s[s.index(after: dash)...]
        }
        var total = 0.0
        for part in clock.split(separator: ":") {
            guard let v = Double(part) else { return nil }
            total = total * 60 + v
        }
        return days * 86400 + total
    }

    // MARK: - Battery

    private func readBatteryHealth() -> BatteryHealth? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        guard let maxCap = int("AppleRawMaxCapacity"), let design = int("DesignCapacity"), design > 0 else { return nil }
        return BatteryHealth(health: maxCap * 100 / design,
                             cycles: int("CycleCount") ?? 0,
                             temp: int("Temperature").map { Double($0) / 100 })
    }

    private func applyChargeLimit(_ s: Status) {
        if let current = s.bclm {
            let target = chargeLimit == 0 ? 100 : chargeLimit
            if current != target { write(["limit", "\(target)"]) }
        } else if s.softwareLimit, let pct = s.battery {
            if chargeLimit > 0 && pct >= chargeLimit && !chargingPaused {
                write(["charging", "off"]); chargingPaused = true
            } else if chargingPaused && (chargeLimit == 0 || pct <= chargeLimit - chargeHysteresis) {
                write(["charging", "on"]); chargingPaused = false
            }
        }
    }
}

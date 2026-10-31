// FanBoost: menu bar fan control. Reads via `fanctl status`, writes via `sudo -n fanctl`.
import AppKit

let fanctl = "/usr/local/bin/fanctl"

struct Status {
    var temp: Double?
    var rpms: [Int] = []
    var manual = false
    var battery: Int?
    var onAC = false
    var charging = false
    var bclm: Int?              // Intel: hardware charge limit currently set
    var softwareLimit = false   // Apple Silicon: limit by pausing charging
}

enum Mode: String {
    case auto, medium, high, max, smart
}

// One automatic boost and the process that was using the most CPU at the time.
struct Boost: Codable {
    let date: Date
    let culprit: String
    let cpu: Double
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard
    lazy var mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .smart
    // True while a safety/smart boost is holding the fans at max.
    var boosting = false
    var lastError: String?

    // Smart, Medium and High go to max once the CPU has stayed at/above `hot` for
    // `holdSeconds`, and drop back below `cool`, so a fixed speed can never cool
    // less than the Mac needs. The hold ignores brief spikes like an app launching.
    let hot = 65.0, cool = 58.0, holdSeconds = 3.0
    var hotSince: Date?

    lazy var boosts: [Boost] = (defaults.data(forKey: "boosts"))
        .flatMap { try? JSONDecoder().decode([Boost].self, from: $0) } ?? []

    // Charge limit in percent; 0 means off. Software limiting resumes charging
    // `chargeHysteresis` points below the limit so it doesn't toggle constantly.
    lazy var chargeLimit = defaults.integer(forKey: "chargeLimit")
    let chargeHysteresis = 5
    var chargingPaused = false

    func applicationDidFinishLaunching(_ n: Notification) {
        apply(mode)
        if readStatus().softwareLimit { write(["charging", "on"]) }
        tick()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ n: Notification) {
        write(["auto"])
        // Never leave an Apple Silicon Mac unable to charge after quitting.
        if chargingPaused { write(["charging", "on"]) }
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

    func readStatus() -> Status {
        var s = Status()
        for line in exec(fanctl, ["status"]).1.split(separator: "\n") {
            let f = line.split(separator: " ")
            switch f.first {
            case "temp" where f.count > 1:
                s.temp = Double(f[1])
            case "fan" where f.count > 5:
                s.rpms.append(Int(f[2]) ?? 0)
                if f[5] == "manual" { s.manual = true }
            case "battery" where f.count > 3:
                s.battery = Int(f[1])
                s.onAC = f[2] == "ac"
                s.charging = f[3] == "charging"
            case "chargelimit" where f.count > 1:
                if f[1] == "bclm", f.count > 2 { s.bclm = Int(f[2]) }
                if f[1] == "software" { s.softwareLimit = true }
            default:
                break
            }
        }
        return s
    }

    func write(_ args: [String]) {
        let (code, text) = exec("/usr/bin/sudo", ["-n", fanctl] + args)
        lastError = code == 0 ? nil : (text.contains("password") ? "Not installed: run install.sh" : text)
    }

    func apply(_ m: Mode) {
        boosting = false
        switch m {
        case .auto: write(["auto"])
        case .medium: write(["set", "50"])
        case .high: write(["set", "75"])
        case .max: write(["max"])
        case .smart: write(["auto"])
        }
    }

    // The process using the most CPU, ignoring kernel_task (it's the symptom, not the cause).
    func topProcess() -> (String, Double)? {
        let skip: Set<String> = ["kernel_task", "FanBoost", "fanctl", "ps", "sudo"]
        for line in exec("/bin/ps", ["-Aro", "pcpu=,comm="]).1.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let cpu = Double(trimmed[..<space]) else { continue }
            let name = (String(trimmed[space...]).trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
            if !skip.contains(name) { return (name, cpu) }
        }
        return nil
    }

    func recordBoost() {
        guard let (name, cpu) = topProcess() else { return }
        let weekAgo = Date().addingTimeInterval(-7 * 86400)
        boosts = boosts.filter { $0.date > weekAgo } + [Boost(date: Date(), culprit: name, cpu: cpu)]
        if let data = try? JSONEncoder().encode(boosts) { defaults.set(data, forKey: "boosts") }
    }

    func applyChargeLimit(_ s: Status) {
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

    func tick() {
        let s = readStatus()
        if mode == .smart || mode == .medium || mode == .high {
            // Unknown temperature is treated as hot: fail toward more cooling.
            let t = s.temp ?? .infinity
            hotSince = t >= hot ? (hotSince ?? Date()) : nil
            if !boosting, let since = hotSince, Date().timeIntervalSince(since) >= holdSeconds {
                apply(.max); boosting = true
                recordBoost()
            } else if boosting && t < cool {
                apply(mode)
            } else if boosting && !s.manual {
                // Something else (sleep/wake, another tool) gave the fans back to macOS.
                write(["max"])
            }
        }
        applyChargeLimit(s)
        let temp = s.temp.map { String(format: "%.0f°", $0) } ?? "--"
        let rpm = s.rpms.max().map { "\($0)" } ?? "--"
        let icon = (s.manual || boosting) ? "🌪" : "🌀"
        item.button?.title = "\(icon) \(temp) \(rpm)"
        item.menu = buildMenu(s)
    }

    func heatSummary() -> String {
        let today = boosts.filter { Calendar.current.isDateInToday($0.date) }
        guard !today.isEmpty else { return "🔥 No heat boosts today" }
        let counts = Dictionary(grouping: today, by: \.culprit).mapValues(\.count)
        let top = counts.max { $0.value < $1.value }!.key
        return "🔥 Boosted \(today.count)× today · mostly \(top)"
    }

    func buildMenu(_ s: Status) -> NSMenu {
        let menu = NSMenu()
        let info = s.rpms.enumerated().map { "Fan \($0.offset + 1): \($0.element) rpm" }.joined(separator: "   ")
        menu.addItem(withTitle: "CPU \(s.temp.map { String(format: "%.1f°C", $0) } ?? "?")   \(info)", action: nil, keyEquivalent: "")
        if let pct = s.battery {
            let state = s.charging ? "charging"
                : !s.onAC ? "on battery"
                : chargeLimit > 0 && pct >= chargeLimit - chargeHysteresis ? "held by \(chargeLimit)% limit"
                : "on power, not charging"
            menu.addItem(withTitle: "🔋 \(pct)% · \(state)", action: nil, keyEquivalent: "")
        }
        if let e = lastError { menu.addItem(withTitle: "⚠️ \(e)", action: nil, keyEquivalent: "") }

        menu.addItem(.separator())
        menu.addItem(withTitle: heatSummary(), action: nil, keyEquivalent: "")
        if !boosts.isEmpty {
            let recent = NSMenu()
            let time = DateFormatter()
            time.dateFormat = "EEE HH:mm"
            for b in boosts.suffix(15).reversed() {
                recent.addItem(withTitle: "\(time.string(from: b.date))   \(b.culprit)  \(Int(b.cpu))%", action: nil, keyEquivalent: "")
            }
            let recentItem = NSMenuItem(title: "Recent boosts", action: nil, keyEquivalent: "")
            recentItem.submenu = recent
            menu.addItem(recentItem)
        }

        menu.addItem(.separator())
        let options: [(Mode, String)] = [
            (.smart, "Smart — max fans after \(Int(holdSeconds))s at \(Int(hot))°C, release at \(Int(cool))°C"),
            (.auto, "Auto (macOS default)"),
            (.medium, "Medium (50%, max when hot)"),
            (.high, "High (75%, max when hot)"),
            (.max, "Max"),
        ]
        for (m, title) in options {
            let mi = NSMenuItem(title: title, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = m == mode ? .on : .off
            menu.addItem(mi)
        }

        menu.addItem(.separator())
        if s.bclm != nil || s.softwareLimit {
            let limits = NSMenu()
            for pct in [0, 80, 90] {
                let mi = NSMenuItem(title: pct == 0 ? "Off" : "\(pct)%", action: #selector(pickLimit(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = pct
                mi.state = pct == chargeLimit ? .on : .off
                limits.addItem(mi)
            }
            let li = NSMenuItem(title: "Charge limit: \(chargeLimit == 0 ? "Off" : "\(chargeLimit)%")", action: nil, keyEquivalent: "")
            li.submenu = limits
            menu.addItem(li)
        } else {
            menu.addItem(withTitle: "Charge limit: not supported on this Mac", action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit (fans back to auto)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        mode = m
        defaults.set(m.rawValue, forKey: "mode")
        apply(m)
        tick()
    }

    @objc func pickLimit(_ sender: NSMenuItem) {
        chargeLimit = sender.tag
        defaults.set(chargeLimit, forKey: "chargeLimit")
        tick()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

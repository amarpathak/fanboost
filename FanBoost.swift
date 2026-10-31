// FanBoost: menu bar fan control. Reads via `fanctl status`, writes via `sudo -n fanctl`.
import AppKit

let fanctl = "/usr/local/bin/fanctl"

struct Status {
    var temp: Double?
    var rpms: [Int] = []
    var manual = false
}

enum Mode: String {
    case auto, medium, high, max, smart
}

final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .smart
    // True while a safety/smart boost is holding the fans at max.
    var boosting = false
    var lastError: String?

    // Smart, Medium and High go to max at/above `hot` and drop back below `cool`,
    // so a fixed speed can never cool less than the Mac needs.
    let hot = 65.0, cool = 58.0

    func applicationDidFinishLaunching(_ n: Notification) {
        apply(mode)
        tick()
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tick() }
    }

    func applicationWillTerminate(_ n: Notification) {
        run(sudo: true, ["auto"])
    }

    @discardableResult
    func run(sudo: Bool, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sudo ? "/usr/bin/sudo" : fanctl)
        p.arguments = sudo ? ["-n", fanctl] + args : args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (p.terminationStatus, text)
    }

    func readStatus() -> Status {
        var s = Status()
        for line in run(sudo: false, ["status"]).1.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.first == "temp", f.count > 1 { s.temp = Double(f[1]) }
            if f.first == "fan", f.count > 5 {
                s.rpms.append(Int(f[2]) ?? 0)
                if f[5] == "manual" { s.manual = true }
            }
        }
        return s
    }

    func write(_ args: [String]) {
        let (code, text) = run(sudo: true, args)
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

    func tick() {
        let s = readStatus()
        if mode == .smart || mode == .medium || mode == .high {
            // Unknown temperature is treated as hot: fail toward more cooling.
            let t = s.temp ?? .infinity
            if !boosting && t >= hot { apply(.max); boosting = true }
            else if boosting && t < cool { apply(mode) }
        }
        let temp = s.temp.map { String(format: "%.0f°", $0) } ?? "--"
        let rpm = s.rpms.max().map { "\($0)" } ?? "--"
        let icon = (s.manual || boosting) ? "🌪" : "🌀"
        item.button?.title = "\(icon) \(temp) \(rpm)"
        item.menu = buildMenu(s)
    }

    func buildMenu(_ s: Status) -> NSMenu {
        let menu = NSMenu()
        let info = s.rpms.enumerated().map { "Fan \($0.offset + 1): \($0.element) rpm" }.joined(separator: "   ")
        menu.addItem(withTitle: "CPU \(s.temp.map { String(format: "%.1f°C", $0) } ?? "?")   \(info)", action: nil, keyEquivalent: "")
        if let e = lastError { menu.addItem(withTitle: "⚠️ \(e)", action: nil, keyEquivalent: "") }
        menu.addItem(.separator())
        let options: [(Mode, String)] = [
            (.smart, "Smart — max fans at \(Int(hot))°C, release at \(Int(cool))°C"),
            (.auto, "Auto (macOS default)"),
            (.medium, "Medium (50%, max when hot)"),
            (.high, "High (75%, max when hot)"),
            (.max, "Max"),
        ]
        for (m, title) in options {
            let mi = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = m == mode ? .on : .off
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit (fans back to auto)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    @objc func pick(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        apply(m)
        tick()
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

// FanBoost: menu bar fan control. Left-click opens the dashboard, right-click the quick menu.
import AppKit
import Combine
import SwiftUI

final class App: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let monitor = Monitor()
    // Fixed width with monospaced digits, so the menu bar (and the dashboard anchored
    // to it) doesn't shift as the numbers change.
    let item = NSStatusBar.system.statusItem(withLength: 92)
    let popover = NSPopover()
    var updates: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        let host = NSHostingController(rootView: Dashboard(m: monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self

        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // objectWillChange fires before the change lands, so read the new values next turn.
        updates = monitor.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateTitle() }
        }
        monitor.start()

        // `kill`/`pkill` sends SIGTERM, which skips applicationWillTerminate. Quit
        // properly instead, so the fans are always handed back to macOS.
        signal(SIGTERM, SIG_IGN)
        sigterm.setEventHandler { NSApp.terminate(nil) }
        sigterm.resume()
    }

    let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    func applicationWillTerminate(_ n: Notification) {
        monitor.stop()
    }

    func popoverWillShow(_ n: Notification) { monitor.dashboardOpen = true }
    func popoverDidClose(_ n: Notification) { monitor.dashboardOpen = false }

    func updateTitle() {
        let s = monitor.status
        let temp = monitor.displayTemp.map { String(format: "%.0f°", $0) } ?? "--"
        // Rounded so the menu bar doesn't flicker with every small fan change.
        let rpm = s.rpms.max().map { "\(($0 + 50) / 100 * 100)" } ?? "--"
        let icon = (s.manual || monitor.boosting) ? "🌪" : "🌀"
        item.button?.title = "\(icon) \(temp) \(rpm)"
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            item.menu = buildMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(withTitle: "🔥 \(monitor.heatSummary)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let titles: [Mode: String] = [
            .smart: "Smart — max fans after \(Int(monitor.holdSeconds))s at \(Int(monitor.hot))°C",
            .auto: "Auto (macOS default)",
            .medium: "Medium (50%, max when hot)",
            .high: "High (75%, max when hot)",
            .max: "Max",
        ]
        for m in Mode.allCases {
            let mi = NSMenuItem(title: titles[m]!, action: #selector(pickMode(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = m.rawValue
            mi.state = m == monitor.mode ? .on : .off
            menu.addItem(mi)
        }
        if monitor.chargeLimitSupported {
            menu.addItem(.separator())
            for pct in [0, 80, 90] {
                let mi = NSMenuItem(title: pct == 0 ? "Charge limit off" : "Charge limit \(pct)%", action: #selector(pickLimit(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = pct
                mi.state = pct == monitor.chargeLimit ? .on : .off
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit (fans back to auto)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc func openDashboard() {
        DispatchQueue.main.async { [self] in
            guard let button = item.button else { return }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc func pickMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) else { return }
        monitor.setMode(m)
    }

    @objc func pickLimit(_ sender: NSMenuItem) {
        monitor.setChargeLimit(sender.tag)
    }
}

@main
enum Main {
    static let delegate = App()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

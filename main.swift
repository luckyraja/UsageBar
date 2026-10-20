import AppKit
import ServiceManagement

// Menu bar readout of subscription usage left:  C  5H 77%  W 58%   │   G  5H 93%  W 81%
// (Claude 5h·week, ChatGPT 5h·week, as % left.)
// Claude: snapshot written by the Claude Code status line (~/.claude/statusline-command.sh).
// ChatGPT: `openclaw status --usage --json`, which reads the Codex login Mini uses.

struct Window {
    let usedPercent: Double
    let resetsAt: Date?

    // Once the reset time passes the window is fresh, even if our data is older.
    var leftPercent: Int {
        if let resetsAt, resetsAt < Date() { return 100 }
        return max(0, min(100, Int((100 - usedPercent).rounded())))
    }
}

struct Usage {
    var fiveHour: Window?
    var week: Window?
    var updated: Date?
    var error: String?
}

let supportDir = NSHomeDirectory() + "/Library/Application Support/UsageBar"

enum Claude {
    static func read() -> Usage {
        guard let data = FileManager.default.contents(atPath: supportDir + "/claude.json"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return Usage(error: "No data yet. Send a message in Claude Code.")
        }
        func window(_ key: String) -> Window? {
            guard let w = json[key] as? [String: Any], let used = w["used_percentage"] as? Double else { return nil }
            return Window(usedPercent: used, resetsAt: (w["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) })
        }
        return Usage(fiveHour: window("five_hour"), week: window("seven_day"),
                     updated: (json["updated"] as? Double).map { Date(timeIntervalSince1970: $0) })
    }
}

enum ChatGPT {
    static let openclaw = NSHomeDirectory() + "/.local/bin/openclaw"

    static func fetch() -> Usage {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openclaw)
        p.arguments = ["status", "--usage", "--json"]
        // openclaw is a node script; use the same PATH as the OpenClaw gateway.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/opt/node@24/bin:\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Usage(error: "openclaw not found") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let provider = find(json, where: { $0["provider"] as? String == "openai" && $0["windows"] != nil }),
              let windows = provider["windows"] as? [[String: Any]] else {
            return Usage(error: "Couldn't read usage from openclaw")
        }
        func window(_ label: String) -> Window? {
            guard let w = windows.first(where: { ($0["label"] as? String)?.lowercased() == label }),
                  let used = (w["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            return Window(usedPercent: used, resetsAt: (w["resetAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
        return Usage(fiveHour: window("5h"), week: window("week"), updated: Date())
    }

    // The provider entry sits somewhere inside a larger status document.
    static func find(_ node: Any, where match: ([String: Any]) -> Bool) -> [String: Any]? {
        if let dict = node as? [String: Any] {
            if match(dict) { return dict }
            for v in dict.values { if let hit = find(v, where: match) { return hit } }
        } else if let array = node as? [Any] {
            for v in array { if let hit = find(v, where: match) { return hit } }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var claude = Usage()
    private var chatgpt = Usage(error: "Loading…")
    private var fetching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? SMAppService.mainApp.register()  // start at login
        menu.delegate = self
        item.menu = menu
        claude = Claude.read()
        render()
        fetchChatGPT()
        // Claude's snapshot is a local file, so re-read it often; ChatGPT costs a ~20s openclaw run.
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.claude = Claude.read()
            self?.render()
        }
        Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetchChatGPT() }
    }

    private func fetchChatGPT() {
        guard !fetching else { return }
        fetching = true
        DispatchQueue.global().async {
            let usage = ChatGPT.fetch()
            DispatchQueue.main.async {
                self.fetching = false
                // Keep the last good numbers if one fetch fails.
                if usage.error == nil || self.chatgpt.fiveHour == nil { self.chatgpt = usage }
                self.render()
            }
        }
    }

    // MARK: - Title

    private func render() {
        let title = NSMutableAttributedString()
        func add(_ s: String, _ color: NSColor = .labelColor, bold: Bool = false) {
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: bold ? .semibold : .regular)
            title.append(NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]))
        }
        func pair(_ label: String, _ u: Usage) {
            add(label, bold: true)
            add("  5H ")
            add(number(u.fiveHour), color(u.fiveHour), bold: true)
            add("  W ")
            add(number(u.week), color(u.week), bold: true)
        }
        pair("C", claude)
        add("   │   ")
        pair("G", chatgpt)
        item.button?.attributedTitle = title
    }

    private func number(_ w: Window?) -> String { w.map { "\($0.leftPercent)%" } ?? "–" }

    private func color(_ w: Window?) -> NSColor {
        guard let left = w?.leftPercent else { return .secondaryLabelColor }
        return left <= 10 ? .systemRed : left <= 25 ? .systemOrange : .labelColor
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        section("Claude", claude, source: "from Claude Code")
        menu.addItem(.separator())
        section("ChatGPT", chatgpt, source: fetching ? "refreshing…" : "via OpenClaw")
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func section(_ name: String, _ u: Usage, source: String) {
        menu.addItem(disabled(name, bold: true))
        if let error = u.error, u.fiveHour == nil {
            menu.addItem(disabled(error))
            return
        }
        menu.addItem(disabled(line("5-hour", u.fiveHour)))
        menu.addItem(disabled(line("Week", u.week)))
        if let updated = u.updated {
            let ago = RelativeDateTimeFormatter().localizedString(for: updated, relativeTo: Date())
            menu.addItem(disabled("Updated \(ago), \(source)"))
        }
    }

    private func line(_ label: String, _ w: Window?) -> String {
        guard let w else { return "\(label): no data" }
        var s = "\(label): \(w.leftPercent)% left"
        if let resetsAt = w.resetsAt {
            s += resetsAt < Date() ? " · reset since last update" : " · resets \(format(resetsAt))"
        }
        return s
    }

    private func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(date) ? "h:mm a" : "EEE h:mm a"
        return f.string(from: date)
    }

    private func disabled(_ title: String, bold: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if bold {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        }
        return item
    }

    @objc private func refreshNow() {
        claude = Claude.read()
        render()
        fetchChatGPT()
    }
}

extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

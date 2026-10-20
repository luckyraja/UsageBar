import AppKit
import ServiceManagement
import UserNotifications

// Menu bar readout of subscription usage left:  C  5H 77%  W 58%   │   G  5H 93%  W 81%
// (Claude 5h·week, ChatGPT 5h·week, as % left.)
// Claude: snapshot written by the Claude Code status line (~/.claude/statusline-command.sh).
// ChatGPT: `openclaw models status`, which reads the Codex login Mini uses.

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

    // `openclaw models status` costs about 2.5x less CPU than `status --usage --json`,
    // but its text could change in an update, so the JSON is the fallback.
    static func fetch() -> Usage {
        if let usage = fromText(run(["models", "status"])) { return usage }
        return fromJSON(run(["status", "--usage", "--json"]))
    }

    static func run(_ args: [String]) -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: openclaw)
        p.arguments = args
        // openclaw is a node script; use the same PATH as the OpenClaw gateway.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/opt/node@24/bin:\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    // "- openai usage: 5h 93% left ⏱1h 45m · Week 99% left ⏱6d 15h"
    static func fromText(_ data: Data) -> Usage? {
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("openai usage:") }) else { return nil }
        let regex = try! NSRegularExpression(pattern: #"(5h|Week)\s+(\d+)% left\D*?((?:\d+[dhm]\s*)+)"#)
        var windows: [String: Window] = [:]
        let s = String(line)
        for m in regex.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            let label = String(s[Range(m.range(at: 1), in: s)!])
            let left = Double(s[Range(m.range(at: 2), in: s)!]) ?? 0
            windows[label] = Window(usedPercent: 100 - left,
                                    resetsAt: Date().addingTimeInterval(seconds(String(s[Range(m.range(at: 3), in: s)!]))))
        }
        guard let five = windows["5h"], let week = windows["Week"] else { return nil }
        return Usage(fiveHour: five, week: week, updated: Date())
    }

    // "6d 15h" -> seconds
    static func seconds(_ duration: String) -> TimeInterval {
        duration.split(separator: " ").reduce(0) { total, part in
            guard let n = Double(part.dropLast()) else { return total }
            switch part.last {
            case "d": return total + n * 86400
            case "h": return total + n * 3600
            case "m": return total + n * 60
            default: return total
            }
        }
    }

    static func fromJSON(_ data: Data) -> Usage {
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

    // Same shape as the Claude snapshot, so other tools (Mini) can read usage without running openclaw.
    static func save(_ u: Usage) {
        func window(_ w: Window?) -> Any {
            guard let w else { return NSNull() }
            return ["used_percentage": w.usedPercent, "resets_at": w.resetsAt.map { Int($0.timeIntervalSince1970) } as Any]
        }
        let json: [String: Any] = ["five_hour": window(u.fiveHour), "seven_day": window(u.week),
                                   "updated": Int((u.updated ?? Date()).timeIntervalSince1970)]
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        try? FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: supportDir + "/chatgpt.json"), options: .atomic)
    }
}

// Notifies once per window per reset period when usage left drops to 10% or below.
enum LowUsageAlert {
    static let threshold = 10
    static let key = "notifiedWindows"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func check(_ name: String, _ u: Usage) {
        check(name, "5-hour", u.fiveHour)
        check(name, "weekly", u.week)
    }

    static func check(_ name: String, _ label: String, _ w: Window?) {
        guard let w, let resetsAt = w.resetsAt, resetsAt > Date(), w.leftPercent <= threshold else { return }
        // Round the reset time so a slightly different estimate doesn't count as a new window.
        let id = "\(name)|\(label)|\(Int(resetsAt.timeIntervalSince1970 / 3600))"
        var sent = UserDefaults.standard.stringArray(forKey: key) ?? []
        guard !sent.contains(id) else { return }
        sent = Array((sent + [id]).suffix(20))
        UserDefaults.standard.set(sent, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "\(name) \(label) limit: \(w.leftPercent)% left"
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(resetsAt) ? "h:mm a" : "EEE h:mm a"
        content.body = "Resets \(f.string(from: resetsAt))."
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
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
        LowUsageAlert.requestPermission()
        menu.delegate = self
        item.menu = menu
        claude = Claude.read()
        render()
        fetchChatGPT()
        // Claude's snapshot is a local file, so re-read it often; ChatGPT costs a ~10s openclaw run.
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
                if usage.error == nil { ChatGPT.save(usage) }
                self.render()
            }
        }
    }

    // MARK: - Title

    private func render() {
        LowUsageAlert.check("Claude", claude)
        LowUsageAlert.check("ChatGPT", chatgpt)
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

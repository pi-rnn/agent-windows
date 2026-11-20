// UsageBar — menu bar view of Claude / Copilot / Codex quota and running agent tasks.
// Build: ./build.sh   CLI: UsageBar --print | --selftest
import AppKit
import Foundation

// MARK: - Model

struct Meter {
    let label: String
    let percentLeft: Double?   // nil = unlimited
    let resetsAt: Date?
    var dateOnly = false       // reset is a calendar day (Copilot), not a timestamp
}

struct ServiceStatus {
    let name: String
    var plan: String? = nil
    var meters: [Meter] = []
    var running: Int? = nil
    var runningExact = false
    var error: String? = nil
    var minLeft: Double? { meters.compactMap { $0.percentLeft }.min() }
}

// MARK: - Helpers

let home = FileManager.default.homeDirectoryForCurrentUser

func runCommand(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, "") }
    var data = Data()
    let done = DispatchGroup()
    done.enter()
    DispatchQueue.global().async { data = pipe.fileHandleForReading.readDataToEndOfFile(); done.leave() }
    if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (-1, "") }
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

enum HTTPResult { case json(Any), status(Int), failure(String) }

func httpGet(_ url: String, headers: [String: String]) -> HTTPResult {
    var req = URLRequest(url: URL(string: url)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
    for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
    let sem = DispatchSemaphore(value: 0)
    var result = HTTPResult.failure("Request timed out")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err = err { result = .failure(err.localizedDescription); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { result = .status(code); return }
        if let d = data, let obj = try? JSONSerialization.jsonObject(with: d) { result = .json(obj) }
        else { result = .failure("Unexpected response format") }
    }.resume()
    _ = sem.wait(timeout: .now() + 15)
    return result
}

func parseDate(_ v: Any?) -> Date? {
    if let n = v as? NSNumber {
        let d = n.doubleValue
        return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
    }
    guard var s = v as? String, !s.isEmpty else { return nil }
    // Drop fractional seconds (APIs send 0–6 digits; ISO8601DateFormatter is picky).
    s = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter()
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withFullDate]
    return f.date(from: s)
}

func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

/// Subscription tier as shown in brackets: "team" → TEAM, "individual_pro" → PRO, "pro_plus" → PRO+.
func planLabel(_ raw: Any?) -> String? {
    guard var p = (raw as? String)?.lowercased(), !p.isEmpty else { return nil }
    if p == "individual" { p = "pro" } else if p.hasPrefix("individual_") { p.removeFirst("individual_".count) }
    return p.replacingOccurrences(of: "_plus", with: "+").replacingOccurrences(of: "_", with: " ").uppercased()
}

func jsonObject(_ line: Substring) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

/// Last `maxBytes` of a file split into lines (first partial line dropped).
func tailLines(_ url: URL, maxBytes: UInt64 = 512_000) -> [Substring] {
    guard let h = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { try? h.close() }
    let size = (try? h.seekToEnd()) ?? 0
    let start = size > maxBytes ? size - maxBytes : 0
    try? h.seek(toOffset: start)
    var lines = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self).split(separator: "\n")
    if start > 0, !lines.isEmpty { lines.removeFirst() }
    return lines
}

func listFiles(_ dir: URL, exts: Set<String>, recursive: Bool = false) -> [(url: URL, mtime: Date)] {
    let fm = FileManager.default
    let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    var urls: [URL] = []
    if recursive {
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: keys) { for case let u as URL in e { urls.append(u) } }
    } else {
        urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []
    }
    return urls.filter { exts.contains($0.pathExtension) }.compactMap { u -> (url: URL, mtime: Date)? in
        guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
              let m = v.contentModificationDate else { return nil }
        return (u, m)
    }.sorted { $0.mtime > $1.mtime }
}

func subdirs(_ dir: URL) -> [URL] {
    ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.hasDirectoryPath }
}

// MARK: - Claude

func claudeMeters(_ o: [String: Any]) -> [Meter] {
    func label(_ key: String) -> String {
        let known = ["five_hour": "5-hour", "seven_day": "Weekly", "seven_day_opus": "Weekly · Opus",
                     "seven_day_sonnet": "Weekly · Sonnet"]
        if let l = known[key] { return l }
        return key.replacingOccurrences(of: "five_hour", with: "5-hour").replacingOccurrences(of: "seven_day", with: "weekly")
            .replacingOccurrences(of: "_", with: " ").capitalized
    }
    let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
    let keys = order.filter { o[$0] != nil } + o.keys.filter { !order.contains($0) }.sorted()
    return keys.compactMap { key in
        guard let w = o[key] as? [String: Any], let used = num(w["utilization"]),
              (w["is_enabled"] as? Bool) != false else { return nil }
        return Meter(label: label(key), percentLeft: max(0, min(100, 100 - used)), resetsAt: parseDate(w["resets_at"]))
    }
}

/// Is a Claude Code session mid-turn? Looks at the last main-thread user/assistant entry.
func claudeBusy(_ lines: [Substring], age: TimeInterval) -> Bool {
    for line in lines.reversed() {
        guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
              let o = jsonObject(line), let type = o["type"] as? String, type == "user" || type == "assistant",
              (o["isSidechain"] as? Bool) != true, (o["isMeta"] as? Bool) != true else { continue }
        let msg = o["message"] as? [String: Any] ?? [:]
        if type == "assistant" {
            switch msg["stop_reason"] as? String {
            case "tool_use"?: return age < 30 * 60          // tool running / awaiting permission
            case nil: return age < 120                       // still streaming
            default: return false                            // end_turn, max_tokens, refusal…
            }
        }
        let blocks = msg["content"] as? [[String: Any]] ?? []
        let text = (msg["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined()
        if text.hasPrefix("[Request interrupted") { return false }
        return age < 10 * 60                                 // prompt or tool result awaiting the model
    }
    return false
}

func claudeRunning(now: Date) -> Int {
    var n = 0
    for dir in subdirs(home.appendingPathComponent(".claude/projects")) {
        for f in listFiles(dir, exts: ["jsonl"]) {
            let age = now.timeIntervalSince(f.mtime)
            if age > 30 * 60 { break }
            if claudeBusy(tailLines(f.url), age: age) { n += 1 }
        }
    }
    return n
}

var claudeCache: (time: Date, meters: [Meter], error: String?)?

func claudeStatus(now: Date) -> ServiceStatus {
    var s = ServiceStatus(name: "Claude")
    s.running = claudeRunning(now: now)
    let r = runCommand("/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    guard r.status == 0,
          let creds = (try? JSONSerialization.jsonObject(with: Data(r.out.utf8))) as? [String: Any],
          let oauth = creds["claudeAiOauth"] as? [String: Any],
          let token = oauth["accessToken"] as? String else {
        s.error = "No Claude Code login in Keychain — sign in to Claude Code"
        return s
    }
    s.plan = planLabel(oauth["subscriptionType"])
    // The usage endpoint rate-limits hard: call it at most every 3 min (5 min after an error).
    if let c = claudeCache, now.timeIntervalSince(c.time) < (c.error == nil ? 180 : 300) {
        s.meters = c.meters; s.error = c.error
        return s
    }
    defer { claudeCache = (now, s.meters, s.error) }
    switch httpGet("https://api.anthropic.com/api/oauth/usage",
                   headers: ["Authorization": "Bearer \(token)", "anthropic-beta": "oauth-2025-04-20",
                             "Accept": "application/json", "User-Agent": "UsageBar"]) {
    case .json(let o):
        s.meters = claudeMeters(o as? [String: Any] ?? [:])
        if s.meters.isEmpty { s.error = "Usage API returned no limits" }
    case .status(401): s.error = "Login expired — use Claude Code once to refresh it"
    case .status(429): s.error = "Usage API rate-limited — will retry"
    case .status(let c): s.error = "Usage API returned HTTP \(c)"
    case .failure(let m): s.error = m
    }
    return s
}

// MARK: - Copilot

func copilotParse(_ o: [String: Any], into s: inout ServiceStatus) {
    s.plan = planLabel(o["copilot_plan"])
    let rawReset = o["quota_reset_date_utc"] ?? o["quota_reset_date"] ?? o["limited_user_reset_date"]
    let reset = parseDate(rawReset)
    let dateOnly = !((rawReset as? String)?.contains("T") ?? false)
    func meter(_ label: String, _ pct: Double?) -> Meter {
        Meter(label: label, percentLeft: pct.map { max(0, min(100, $0)) }, resetsAt: reset, dateOnly: dateOnly)
    }
    if let snaps = o["quota_snapshots"] as? [String: Any] {
        for (key, label) in [("premium_interactions", "Premium requests"), ("chat", "Chat"), ("completions", "Completions")] {
            guard let q = snaps[key] as? [String: Any] else { continue }
            if (q["unlimited"] as? Bool) == true {
                if key == "premium_interactions" { s.meters.append(meter(label, nil)) }
                continue
            }
            if let p = num(q["percent_remaining"]) { s.meters.append(meter(label, p)) }
            else if let r = num(q["remaining"]), let e = num(q["entitlement"]), e > 0 { s.meters.append(meter(label, r / e * 100)) }
        }
    } else if let left = o["limited_user_quotas"] as? [String: Any], let total = o["monthly_quotas"] as? [String: Any] {
        for (key, label) in [("chat", "Chat"), ("completions", "Completions")] {
            if let r = num(left[key]), let t = num(total[key]), t > 0 { s.meters.append(meter(label, r / t * 100)) }
        }
    }
}

func copilotRunning(now: Date) -> Int {
    let base = home.appendingPathComponent("Library/Application Support/Code/User")
    var dirs = subdirs(base.appendingPathComponent("workspaceStorage")).map { $0.appendingPathComponent("chatSessions") }
    dirs.append(base.appendingPathComponent("globalStorage/emptyWindowChatSessions"))
    return dirs.reduce(0) { n, d in
        n + listFiles(d, exts: ["json", "jsonl"]).filter { now.timeIntervalSince($0.mtime) < 90 }.count
    }
}

func copilotStatus(now: Date) -> ServiceStatus {
    var s = ServiceStatus(name: "GitHub Copilot")
    s.running = copilotRunning(now: now)
    guard let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        s.error = "GitHub CLI not found — run: brew install gh"
        return s
    }
    let r = runCommand(gh, ["auth", "token"])
    let token = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard r.status == 0, !token.isEmpty else {
        s.error = "Not signed in — run `gh auth login` in Terminal"
        return s
    }
    switch httpGet("https://api.github.com/copilot_internal/user",
                   headers: ["Authorization": "token \(token)", "Accept": "application/json", "User-Agent": "UsageBar"]) {
    case .json(let o):
        copilotParse(o as? [String: Any] ?? [:], into: &s)
        if s.meters.isEmpty { s.error = "No quota info for this account" }
    case .status(401): s.error = "GitHub token rejected — run `gh auth login` again"
    case .status(403), .status(404): s.error = "No Copilot access for this GitHub account"
    case .status(let c): s.error = "GitHub API returned HTTP \(c)"
    case .failure(let m): s.error = m
    }
    return s
}

// MARK: - Codex

func codexMeters(_ rl: [String: Any], eventTime: Date?, now: Date) -> [Meter] {
    ["primary", "secondary"].compactMap { key in
        guard let w = rl[key] as? [String: Any], let used = num(w["used_percent"]) else { return nil }
        var reset = parseDate(w["resets_at"])
        if reset == nil, let secs = num(w["resets_in_seconds"]), let t = eventTime { reset = t.addingTimeInterval(secs) }
        let label: String
        switch num(w["window_minutes"]).map(Int.init) {
        case 300?: label = "5-hour"
        case 10080?: label = "Weekly"
        case let m?: label = m % 1440 == 0 ? "\(m / 1440)-day" : "\(m / 60)-hour"
        case nil: label = key.capitalized
        }
        if let r = reset, r < now { return Meter(label: label, percentLeft: 100, resetsAt: nil) } // window already reset
        return Meter(label: label, percentLeft: max(0, 100 - used), resetsAt: reset)
    }
}

/// Last task_started vs task_complete/turn_aborted in a Codex rollout. nil = no task events in the tail.
func codexBusy(_ lines: [Substring]) -> Bool? {
    for line in lines.reversed() {
        guard line.contains("task_started") || line.contains("task_complete") || line.contains("turn_aborted"),
              let o = jsonObject(line), (o["type"] as? String) == "event_msg",
              let t = (o["payload"] as? [String: Any])?["type"] as? String else { continue }
        if t == "task_started" { return true }
        if t == "task_complete" || t == "turn_aborted" { return false }
    }
    return nil
}

func codexStatus(now: Date) -> ServiceStatus {
    var s = ServiceStatus(name: "Codex")
    s.runningExact = true
    let files = listFiles(home.appendingPathComponent(".codex/sessions"), exts: ["jsonl"], recursive: true)
    var fallback: [Meter] = []
    outer: for f in files.prefix(30) {
        for line in tailLines(f.url).reversed() where line.contains("\"rate_limits\"") {
            guard let o = jsonObject(line), let p = o["payload"] as? [String: Any],
                  let rl = p["rate_limits"] as? [String: Any] else { continue }
            let meters = codexMeters(rl, eventTime: parseDate(o["timestamp"]), now: now)
            if meters.isEmpty { continue }
            if let id = rl["limit_id"] as? String, id != "codex" { if fallback.isEmpty { fallback = meters }; continue }
            s.meters = meters
            s.plan = planLabel(rl["plan_type"])
            break outer
        }
    }
    if s.meters.isEmpty { s.meters = fallback }
    if s.meters.isEmpty { s.error = files.isEmpty ? "No Codex sessions in ~/.codex/sessions" : "No limit info yet — run one Codex task" }
    s.running = files.prefix(while: { now.timeIntervalSince($0.mtime) < 15 * 60 }).filter { f in
        codexBusy(tailLines(f.url)) ?? (now.timeIntervalSince(f.mtime) < 120)
    }.count
    return s
}

// MARK: - Fetch

func fetchAll() -> [ServiceStatus] {
    let now = Date()
    let providers: [(Date) -> ServiceStatus] = [claudeStatus, copilotStatus, codexStatus]
    var out = [ServiceStatus?](repeating: nil, count: providers.count)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: providers.count) { i in
        let s = providers[i](now)
        lock.lock(); out[i] = s; lock.unlock()
    }
    return out.compactMap { $0 }
}

// MARK: - Formatting

func pctText(_ p: Double?) -> String { p.map { "\(Int($0.rounded()))%" } ?? "∞" }

func resetText(_ m: Meter, now: Date) -> String {
    guard let r = m.resetsAt else { return m.percentLeft == nil ? "unlimited" : (m.percentLeft == 100 ? "already reset" : "") }
    return countdown(r.timeIntervalSince(now))
}

/// 2d 4h 13min · 3h 5min · 42min (leading zero units dropped).
func countdown(_ interval: TimeInterval) -> String {
    let total = Int(max(0, interval) / 60)
    let d = total / 1440, h = (total % 1440) / 60, m = total % 60
    if d > 0 { return "\(d)d \(h)h \(m)min" }
    if h > 0 { return "\(h)h \(m)min" }
    return total > 0 ? "\(m)min" : "<1min"
}

func runningText(_ s: ServiceStatus) -> String {
    guard let n = s.running else { return "" }
    return "\(n) running"
}

func describe(_ s: ServiceStatus, now: Date = Date()) -> String {
    var out = "\(s.name)\(s.plan.map { " (\($0))" } ?? "") — \(runningText(s))"
    if let e = s.error { out += "\n  ⚠︎ \(e)" }
    for m in s.meters { out += "\n  \(m.label): \(pctText(m.percentLeft)) left, resets in \(resetText(m, now: now))" }
    return out
}

/// Continuous gradient by % left: 100 green → 55 yellow → 25 orange → 0 red (unlimited = green).
func levelColor(_ p: Double?) -> NSColor {
    guard let p = p else { return .systemGreen }
    let stops: [(Double, NSColor)] = [(0, .systemRed), (25, .systemOrange), (55, .systemYellow), (100, .systemGreen)]
    let x = max(0, min(100, p))
    for (lo, hi) in zip(stops, stops.dropFirst()) where x <= hi.0 {
        let t = CGFloat((x - lo.0) / (hi.0 - lo.0))
        guard let a = lo.1.usingColorSpace(.sRGB), let b = hi.1.usingColorSpace(.sRGB) else { return hi.1 }
        return NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t, alpha: 1)
    }
    return .systemGreen
}

// MARK: - App

/// Rounded progress bar; drawn as a shape so its width never depends on font glyphs.
final class BarView: NSView {
    var fraction: CGFloat = 0
    var color: NSColor = .systemGreen
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds, radius = r.height / 2
        NSColor.tertiaryLabelColor.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        guard fraction > 0 else { return }
        let w = max(r.height, r.width * min(1, fraction))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height), xRadius: radius, yRadius: radius).fill()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let width: CGFloat = 440
    let resetColumn: CGFloat = 296   // 20pt gap after the right edge of "100%"
    var statuses: [ServiceStatus] = []
    var lastRefresh: Date?
    var refreshing = false
    var timer: Timer?

    func applicationDidFinishLaunching(_ n: Notification) {
        if let b = item.button {
            let img = NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: "AI usage")
                ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "AI usage")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.title = " …"
        }
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        rebuildMenu()
        // Event-driven (no polling): macOS notifies us when any app launches or quits.
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            nc.addObserver(self, selector: #selector(appsChanged(_:)), name: name, object: nil)
        }
        updateVisibility(ignoringPID: nil)
    }

    let vscodeID = "com.microsoft.VSCode"

    @objc func appsChanged(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == vscodeID else { return }
        let quitting = n.name == NSWorkspace.didTerminateApplicationNotification
        updateVisibility(ignoringPID: quitting ? app.processIdentifier : nil)
    }

    /// Show the icon and poll only while VS Code runs; otherwise hide it and stop all work.
    func updateVisibility(ignoringPID pid: pid_t?) {
        let on = NSRunningApplication.runningApplications(withBundleIdentifier: vscodeID)
            .contains { !$0.isTerminated && $0.processIdentifier != pid }
        item.isVisible = on
        if on && timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        } else if !on {
            timer?.invalidate()
            timer = nil
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if Date().timeIntervalSince(lastRefresh ?? .distantPast) > 15 { refresh() } else { rebuildMenu() }
    }

    @objc func refreshNow() { refresh() }
    @objc func openVSCode() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        rebuildMenu()
        DispatchQueue.global(qos: .utility).async {
            var result = fetchAll()
            DispatchQueue.main.async {
                // A failed fetch (e.g. HTTP 429) keeps the last good numbers instead of blanking the row.
                for i in result.indices where result[i].meters.isEmpty && result[i].error != nil {
                    if let old = self.statuses.first(where: { $0.name == result[i].name }), !old.meters.isEmpty {
                        result[i].meters = old.meters
                        result[i].plan = result[i].plan ?? old.plan
                        result[i].error = "Showing last data — " + result[i].error!
                    }
                }
                self.statuses = result
                self.lastRefresh = Date()
                self.refreshing = false
                self.publishUsage()
                self.updateButton()
                self.rebuildMenu()
            }
        }
    }

    /// The meters, for Reply Clock: it plays a sound when one drops under 50%, under 20%, to 10% and to 0%.
    func publishUsage() {
        let meters = statuses.flatMap { s in
            s.meters.compactMap { m in m.percentLeft.map { ["name": "\(s.name) \(m.label)", "left": $0] as [String: Any] } }
        }
        let dir = home.appendingPathComponent("Library/Application Support/ReplyClock")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: ["meters": meters, "written": Date().timeIntervalSince1970],
                                    options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("usage.json"), options: .atomic)
    }

    func updateButton() {
        guard let b = item.button else { return }
        guard let low = statuses.compactMap({ $0.minLeft }).min() else { b.title = " –"; return }
        let title = " " + pctText(low)
        if low < 20 {
            b.attributedTitle = NSAttributedString(string: title, attributes: [
                .foregroundColor: levelColor(low), .font: NSFont.menuBarFont(ofSize: 0)])
        } else {
            b.title = title
        }
    }

    // Menu rows are plain views so text keeps its colors and rows don't highlight.
    func row(_ text: NSAttributedString, top: CGFloat = 2) -> NSMenuItem {
        let tf = NSTextField(labelWithAttributedString: text)
        tf.sizeToFit()
        tf.frame = NSRect(x: 14, y: 2, width: width - 28, height: tf.frame.height)
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: tf.frame.height + 2 + top))
        v.addSubview(tf)
        let mi = NSMenuItem()
        mi.view = v
        return mi
    }

    func para(_ tabs: [NSTextTab]) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.tabStops = tabs
        p.lineBreakMode = .byTruncatingTail
        return p
    }

    /// `resetHeading` adds a "Reset" column label above the countdowns (first service only).
    /// Fixed columns like meterRow: name | "● N running" (right edge = % column) | "Reset" (= countdown column).
    /// `resetHeading` shows the "Reset" label (first service only).
    func headerRow(_ s: ServiceStatus, resetHeading: Bool = false) -> NSMenuItem {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 25))
        // Same y for all fields; the 1pt shorter 12pt fields put their baselines level with the 13pt name.
        func field(_ text: NSAttributedString, x: CGFloat, w: CGFloat, h: CGFloat = 16, align: NSTextAlignment = .left) {
            let tf = NSTextField(labelWithAttributedString: text)
            tf.alignment = align
            tf.lineBreakMode = .byTruncatingTail
            tf.frame = NSRect(x: x, y: 3, width: w, height: h)
            v.addSubview(tf)
        }
        let title = s.name + (s.plan.map { " (\($0))" } ?? "")
        field(NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13),
              .foregroundColor: NSColor.labelColor]), x: 14, w: 180, h: 17)

        let busy = (s.running ?? 0) > 0
        let run = NSMutableAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: busy ? NSColor.systemGreen : NSColor.tertiaryLabelColor, .baselineOffset: 1.5])
        run.append(NSAttributedString(string: runningText(s), attributes: [.font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: busy ? NSColor.labelColor : NSColor.secondaryLabelColor]))
        field(run, x: 196, w: 80, align: .right)   // right edge at 276, same as the % column

        if resetHeading {
            field(NSAttributedString(string: "Reset", attributes: [.font: NSFont.systemFont(ofSize: 12),
                  .foregroundColor: NSColor.labelColor]), x: resetColumn, w: width - resetColumn - 14)
        }
        let mi = NSMenuItem()
        mi.view = v
        return mi
    }

    // Fixed columns: label | bar | % (right-aligned) | countdown. Positions in points.
    func meterRow(_ m: Meter, now: Date) -> NSMenuItem {
        let h: CGFloat = 20
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        func text(_ s: String, x: CGFloat, w: CGFloat, align: NSTextAlignment = .left,
                  font: NSFont = .systemFont(ofSize: 12)) {
            let tf = NSTextField(labelWithString: s)
            tf.font = font
            tf.textColor = .labelColor
            tf.alignment = align
            tf.lineBreakMode = .byTruncatingTail
            tf.frame = NSRect(x: x, y: 2, width: w, height: 16)
            v.addSubview(tf)
        }
        text(m.label, x: 14, w: 110)
        let bar = BarView(frame: NSRect(x: 130, y: (h - 8) / 2, width: 100, height: 8))
        bar.fraction = CGFloat((m.percentLeft ?? 100) / 100)
        bar.color = levelColor(m.percentLeft)
        v.addSubview(bar)
        text(pctText(m.percentLeft), x: 236, w: 40, align: .right, font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
        text(resetText(m, now: now), x: resetColumn, w: width - resetColumn - 14)
        let mi = NSMenuItem()
        mi.view = v
        return mi
    }

    func noteRow(_ text: String, color: NSColor) -> NSMenuItem {
        row(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: color]))
    }

    func rebuildMenu() {
        menu.removeAllItems()
        let now = Date()
        if statuses.isEmpty { menu.addItem(noteRow("Loading…", color: .secondaryLabelColor)) }
        for (i, s) in statuses.enumerated() {
            if i > 0 { menu.addItem(.separator()) }
            menu.addItem(headerRow(s, resetHeading: i == 0))
            for m in s.meters { menu.addItem(meterRow(m, now: now)) }
            if let e = s.error { menu.addItem(noteRow("⚠︎ " + e, color: .systemOrange)) }
        }
        menu.addItem(.separator())
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        let updated = refreshing ? "Refreshing…" : lastRefresh.map { "Updated \(f.string(from: $0))" } ?? ""
        menu.addItem(noteRow(updated, color: .tertiaryLabelColor))
        for (title, sel, key) in [("Refresh Now", #selector(refreshNow), "r"), ("Open VS Code", #selector(openVSCode), "o")] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.target = self
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        addReplyClockSection()
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit UsageBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // MARK: Reply Clock settings (the overlay app has no menu bar icon of its own)

    let clockID = "local.replyclock"
    var clockDefaults: UserDefaults { UserDefaults(suiteName: clockID) ?? .standard }

    func clockValue(_ key: String, _ fallback: Double) -> Double {
        (clockDefaults.object(forKey: key) as? NSNumber)?.doubleValue ?? fallback
    }

    func addReplyClockSection() {
        menu.addItem(noteRow("Reply Clock", color: .secondaryLabelColor))
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: clockID).isEmpty
        if !running {
            let start = NSMenuItem(title: "Start Reply Clock", action: #selector(startReplyClock), keyEquivalent: "")
            start.target = self
            menu.addItem(start)
            return
        }
        if clockDefaults.object(forKey: "statusAccessibility") as? Bool == false {
            let allow = NSMenuItem(title: "Allow Accessibility access…", action: #selector(openAccessibility), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        menu.addItem(clockChoices("Reply window", key: "minutes", current: clockValue("minutes", 30),
                                  options: [(10, "10 min"), (15, "15 min"), (30, "30 min"), (45, "45 min"), (60, "60 min")]))
        menu.addItem(clockChoices("Clock opacity", key: "opacity", current: clockValue("opacity", 0.5),
                                  options: [(0.2, "20%"), (0.3, "30%"), (0.5, "50%"), (0.75, "75%")]))
        menu.addItem(clockChoices("Clock size", key: "heightShare", current: clockValue("heightShare", 0.15),
                                  options: [(0.10, "10% of the window"), (0.15, "15% of the window"), (0.20, "20% of the window")]))
        menu.addItem(clockChoices("Clock position", key: "atTop", current: clockValue("atTop", 0),
                                  options: [(0, "Center of the window"), (1, "Top of the window")]))
        menu.addItem(clockChoices("Sounds", key: "soundVolume", current: clockValue("soundVolume", 1),
                                  options: [(0, "Off"), (0.25, "25% volume"), (0.5, "50% volume"), (1, "100% volume")]))
        let quit = NSMenuItem(title: "Quit Reply Clock", action: #selector(quitReplyClock), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
    }

    func clockChoices(_ title: String, key: String, current: Double, options: [(Double, String)]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false
        for (value, label) in options {
            let choice = NSMenuItem(title: label, action: #selector(chooseClockSetting(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = [key: value]
            choice.state = abs(current - value) < 0.001 ? .on : .off
            sub.addItem(choice)
        }
        parent.submenu = sub
        return parent
    }

    @objc func chooseClockSetting(_ sender: NSMenuItem) {
        guard let pick = sender.representedObject as? [String: Double], let (key, value) = pick.first else { return }
        clockDefaults.set(value, forKey: key)   // Reply Clock reads its settings every second
        rebuildMenu()
    }

    @objc func startReplyClock() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: clockID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    @objc func quitReplyClock() {
        NSRunningApplication.runningApplications(withBundleIdentifier: clockID).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.rebuildMenu() }
    }

    @objc func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

// MARK: - Self-test

func selfTest() -> Bool {
    var ok = true
    func check(_ cond: Bool, _ name: String) { print((cond ? "PASS " : "FAIL ") + name); ok = ok && cond }
    let now = Date()
    func obj(_ s: String) -> [String: Any] { jsonObject(Substring(s)) ?? [:] }

    let c = claudeMeters(obj(#"{"five_hour":{"utilization":22.0,"resets_at":"2026-11-19T16:00:00.512345+00:00"},"seven_day":{"utilization":48,"resets_at":"2026-11-24T08:00:00Z"},"seven_day_opus":null,"extra_usage":{"is_enabled":false,"utilization":null}}"#))
    check(c.count == 2 && c[0].label == "5-hour" && c[0].percentLeft == 78 && c[1].percentLeft == 52, "claude meters")
    check(c[0].resetsAt == parseDate("2026-11-19T16:00:00Z"), "claude microsecond date")

    var p = ServiceStatus(name: "t")
    copilotParse(obj(#"{"copilot_plan":"individual","quota_reset_date":"2026-12-01","quota_snapshots":{"chat":{"unlimited":true},"completions":{"unlimited":true},"premium_interactions":{"entitlement":300,"remaining":183,"percent_remaining":61.0,"unlimited":false}}}"#), into: &p)
    check(p.meters.count == 1 && p.meters[0].percentLeft == 61 && p.meters[0].dateOnly && p.plan == "PRO", "copilot paid")
    let plans: [String?] = ["individual_pro", "pro_plus", "team", nil].map { planLabel($0) }
    check(plans == ["PRO", "PRO+", "TEAM", nil], "plan labels")
    let times: [Double] = [188_010, 11_100, 2_520, -5]   // 2d 4h 13min 30s, 3h 5min, 42min, past
    check(times.map { countdown($0) } == ["2d 4h 13min", "3h 5min", "42min", "<1min"], "countdown format")
    var fr = ServiceStatus(name: "t")
    copilotParse(obj(#"{"copilot_plan":"free","limited_user_reset_date":"2026-12-01","limited_user_quotas":{"chat":40,"completions":1800},"monthly_quotas":{"chat":50,"completions":2000}}"#), into: &fr)
    check(fr.meters.map { $0.percentLeft } == [80, 90], "copilot free")

    let future = Int(now.timeIntervalSince1970) + 3600, past = Int(now.timeIntervalSince1970) - 60
    let x = codexMeters(obj(#"{"limit_id":"codex","primary":{"used_percent":2.0,"window_minutes":300,"resets_at":\#(future)},"secondary":{"used_percent":10,"window_minutes":10080,"resets_at":\#(past)}}"#), eventTime: nil, now: now)
    check(x.count == 2 && x[0].percentLeft == 98 && x[0].label == "5-hour" && x[1].percentLeft == 100 && x[1].resetsAt == nil, "codex meters")

    let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#, done = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    check(codexBusy([Substring(done), Substring(started)]) == true && codexBusy([Substring(started), Substring(done)]) == false
          && codexBusy([]) == nil, "codex running detection")

    let u = #"{"type":"user","message":{"role":"user","content":"hi"}}"#
    let tool = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}"#
    let end = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[]}}"#
    let intr = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
    check(claudeBusy([Substring(u)], age: 5) && claudeBusy([Substring(u), Substring(tool)], age: 5)
          && !claudeBusy([Substring(u), Substring(end)], age: 5) && !claudeBusy([Substring(tool), Substring(intr)], age: 5)
          && !claudeBusy([Substring(u)], age: 3600), "claude running detection")

    let live = codexStatus(now: now)
    print("live Codex (local logs only):\n" + describe(live, now: now))
    return ok
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selfTest() ? 0 : 1) }
if args.contains("--print") { fetchAll().forEach { print(describe($0)) }; exit(0) }

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

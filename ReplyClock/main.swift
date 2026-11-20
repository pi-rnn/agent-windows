// Reply Clock: a reply clock drawn over every VS Code agent window.
//
//   ReplyClock                         the overlay (a menu bar app with no Dock icon)
//   ReplyClock --hook <service> <evt>  run by Claude Code, Codex and Copilot hooks; records the window's state
//   ReplyClock --preview <dir>         renders every state to PNG files, for checking the look
//   ReplyClock --selftest              checks the state logic
//
// A window is named by the launcher marker in its title, "Agent 3 [launcher-0123abcdef]".
// The AI Service Switcher extension writes hosts/<extension host pid>.json holding that marker,
// and a hook finds its window by walking up its parent processes to that extension host
// (Claude Code and Codex run under it). Copilot runs in one host shared by every window, so its
// sessions are tied to the VS Code window in front when their first prompt arrives
// (sessions/<service>-<session>.json), using window-index.json, which the overlay keeps.
// Each window's state lives in windows/<marker>.json; the overlay reads it every second, and
// reads the service's own session log for a turn that ended without a hook.
// hooks.log holds one line per hook run and per sound (names only, never chat text), for
// finding out why a window shows or sounds the wrong thing.
//
//   before the first prompt  nothing (the switcher clears a window's state when it starts)
//   agent working      slate, dotted ring
//   agent finished     countdown: green > yellow > orange > red, then OVERDUE
//   agent asks you     violet "?" in a triangle (a question dialog; an answer that merely
//                      ends on a question counts down like any other)
//   permission needed  cyan "!" in an octagon
//
// The window frame carries the state's color at full strength; the clock is drawn at
// half opacity by default so the chat stays readable underneath it.
//
// Sounds mark the same moments, every 7 minutes an agent works, and the credit levels that
// UsageBar publishes in usage.json (see "Sounds"). Each is a macOS system sound unless sounds/
// holds an .mp3 of its name; install_sounds.sh copies such files there.

import AppKit
import ApplicationServices
import Darwin

// MARK: - Files

let supportHome: URL = {
    if let custom = ProcessInfo.processInfo.environment["REPLY_CLOCK_HOME"] { return URL(fileURLWithPath: custom) }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ReplyClock")
}()

func hostsDir(_ home: URL) -> URL { home.appendingPathComponent("hosts") }
func windowsDir(_ home: URL) -> URL { home.appendingPathComponent("windows") }
func sessionsDir(_ home: URL) -> URL { home.appendingPathComponent("sessions") }
/// The agent windows by window number, kept by the overlay for the hooks.
func windowIndexURL(_ home: URL) -> URL { home.appendingPathComponent("window-index.json") }
func hookLogURL(_ home: URL) -> URL { home.appendingPathComponent("hooks.log") }
func soundsDir(_ home: URL) -> URL { home.appendingPathComponent("sounds") }
/// The credit meters of every service, kept by UsageBar for the sounds.
func usageURL(_ home: URL) -> URL { home.appendingPathComponent("usage.json") }

func readJSON(_ url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func writeJSON(_ object: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
}

/// The end of a file, at most `maxBytes`; its first line may be cut.
func tail(of url: URL, maxBytes: UInt64) -> String? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let size = try? handle.seekToEnd() else { return nil }
    try? handle.seek(toOffset: size > maxBytes ? size - maxBytes : 0)
    guard let data = try? handle.readToEnd() else { return nil }
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Window names

let markerPattern = try! NSRegularExpression(pattern: #"^(.*?\[(?:launcher-)?[0-9a-f]{10}\])"#)

/// The launcher marker that starts an agent window's title, or nil for any other window.
func marker(inTitle title: String) -> String? {
    let range = NSRange(title.startIndex..., in: title)
    guard let match = markerPattern.firstMatch(in: title, range: range),
          let found = Range(match.range(at: 1), in: title) else { return nil }
    return String(title[found])
}

func fileKey(_ marker: String) -> String {
    String(marker.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
}

// MARK: - State

enum Kind: String { case idle, working, finished, question, permission }

struct Watch: Equatable {
    var kind: Kind
    /// When this state began, seconds since 1970.
    var since: Double
    var service: String? = nil
    /// `permission` only: the tool waiting for approval.
    var tool: String? = nil
    /// `question` only: "dialog" (a question tool) or "answer" (the answer ended on a question).
    var via: String? = nil
    /// A question the agent posted without stopping to wait for it (Codex's
    /// request_user_input_async): the turn it was asked in, "" where the service names no
    /// turns. It stays open, through the end of that turn, until the next prompt.
    var asked: String? = nil
    /// The service's session, where its hooks name one.
    var session: String? = nil
    /// The service's own log of that session, where its hooks name one.
    var transcript: String? = nil
    /// `finished` only, and set by the overlay, never by a hook: the error that ended the turn
    /// (see TurnEnd).
    var failure: String? = nil

    init(kind: Kind, since: Double, service: String? = nil, tool: String? = nil, via: String? = nil,
         asked: String? = nil, session: String? = nil) {
        self.kind = kind; self.since = since; self.service = service; self.tool = tool; self.via = via
        self.asked = asked; self.session = session
    }

    init?(json: [String: Any]) {
        guard let kind = (json["kind"] as? String).flatMap(Kind.init(rawValue:)),
              let since = (json["since"] as? NSNumber)?.doubleValue else { return nil }
        self.init(kind: kind, since: since, service: json["service"] as? String,
                  tool: json["tool"] as? String, via: json["via"] as? String,
                  asked: json["asked"] as? String, session: json["session"] as? String)
        transcript = json["transcript"] as? String
    }

    var json: [String: Any] {
        var out: [String: Any] = ["kind": kind.rawValue, "since": since]
        if let service { out["service"] = service }
        if let tool { out["tool"] = tool }
        if let via { out["via"] = via }
        if let asked { out["asked"] = asked }
        if let session { out["session"] = session }
        if let transcript { out["transcript"] = transcript }
        return out
    }
}

func readWatch(_ marker: String, home: URL = supportHome) -> Watch? {
    readJSON(windowsDir(home).appendingPathComponent(fileKey(marker) + ".json")).flatMap(Watch.init(json:))
}

func writeWatch(_ watch: Watch, marker: String, home: URL = supportHome) throws {
    var object = watch.json
    object["marker"] = marker
    try writeJSON(object, to: windowsDir(home).appendingPathComponent(fileKey(marker) + ".json"))
}

// MARK: - Which window a hook runs for

func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let parent = info.kp_eproc.e_ppid
    return parent > 0 ? parent : nil
}

func processName(_ pid: pid_t) -> String {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
    return URL(fileURLWithPath: String(cString: buffer)).lastPathComponent
}

/// `start` and the processes above it, nearest first.
func processChain(from start: pid_t) -> [pid_t] {
    var chain = [start]
    var pid = start
    for _ in 0..<16 {
        guard pid > 1, let parent = parentPID(of: pid), parent != pid else { break }
        chain.append(parent)
        pid = parent
    }
    return chain
}

func registeredMarker(_ pid: pid_t, home: URL) -> String? {
    readJSON(hostsDir(home).appendingPathComponent("\(pid).json"))?["marker"] as? String
}

/// Walks up from `start` to the first process the AI Service Switcher registered: the
/// extension host of the agent window this chat runs in.
func hostMarker(from start: pid_t, home: URL = supportHome) -> String? {
    for pid in processChain(from: start) {
        if let found = registeredMarker(pid, home: home) { return found }
    }
    return nil
}

/// Where a hook runs.
enum Origin: Equatable {
    /// Under the extension host of an agent window.
    case window(String)
    /// Under the extension host of a window that is no agent window, or has not registered.
    case otherWindow
    /// Under VS Code but under no window's extension host: the host Copilot shares between windows.
    case sharedHost
    /// Somewhere else: a terminal, another app.
    case elsewhere
}

/// `chain` is a process and the ones above it, nearest first.
func origin(chain: [pid_t], marker: (pid_t) -> String?, name: (pid_t) -> String,
            vscode: () -> Set<pid_t>) -> Origin {
    for pid in chain {
        if let found = marker(pid) { return .window(found) }
    }
    if chain.contains(where: { name($0).contains("Helper (Plugin)") }) { return .otherWindow }
    let pids = vscode()
    return chain.contains(where: pids.contains) ? .sharedHost : .elsewhere
}

func origin(of start: pid_t, home: URL = supportHome, vscode: () -> Set<pid_t>) -> Origin {
    origin(chain: processChain(from: start), marker: { registeredMarker($0, home: home) },
           name: processName, vscode: vscode)
}

func vscodePIDs() -> Set<pid_t> {
    Set(vscodeBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        .map(\.processIdentifier))
}

/// The VS Code window in front of VS Code's others: the one the person last typed in.
func frontVSCodeWindow(_ pids: Set<pid_t>) -> CGWindowID? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    for window in list {   // front to back
        guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
              let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid),
              let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
              let bounds = window[kCGWindowBounds as String] as? [String: Any],
              ((bounds["Width"] as? NSNumber)?.doubleValue ?? 0) >= 200,
              ((bounds["Height"] as? NSNumber)?.doubleValue ?? 0) >= 150 else { continue }
        return id
    }
    return nil
}

func sessionID(_ payload: [String: Any]) -> String? {
    let raw = (payload["sessionId"] ?? payload["session_id"]) as? String
    return raw?.isEmpty == false ? raw : nil
}

func sessionURL(service: String, session: String, home: URL) -> URL {
    sessionsDir(home).appendingPathComponent(fileKey(service) + "-" + fileKey(session) + ".json")
}

/// Whether Copilot's own record says a session runs in the host VS Code shares between its windows.
func isAgentHostSession(_ payload: [String: Any]) -> Bool {
    guard let session = sessionID(payload) else { return false }
    let record = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state/\(fileKey(session))/workspace.yaml")
    return (try? String(contentsOf: record, encoding: .utf8))?.contains("vscode-agent-host") ?? false
}

/// The agent windows by window number, as the overlay last wrote them.
func readWindowIndex(home: URL) -> [String: String] {
    readJSON(windowIndexURL(home))?["windows"] as? [String: String] ?? [:]
}

/// The agent window of a session that runs in the shared host. A session is tied to the VS Code
/// window in front when its first prompt arrives, the one the person typed it in, and stays
/// there; a session that starts or resumes, or whose window is gone, is tied again.
func sessionMarker(service: String, event: String, payload: [String: Any], home: URL = supportHome,
                   front: () -> CGWindowID?) -> (marker: String?, note: String) {
    guard let session = sessionID(payload) else { return (nil, "no-session-id") }
    let url = sessionURL(service: service, session: session, home: home)
    let known = readJSON(url)?["marker"] as? String
    let name = event.lowercased()
    let isStart = name == "sessionstart"
    guard isStart || name == "userpromptsubmitted" || name == "userpromptsubmit" else {
        return (known, known == nil ? "session-not-tied-yet" : "session")
    }
    let index = readWindowIndex(home: home)
    if let known, !isStart, index.values.contains(known) { return (known, "session") }
    guard !index.isEmpty else { return (known, "no-window-index") }
    guard let window = front() else { return (known, "no-front-window") }
    guard let found = index[String(window)] else {
        // It started in a window that is no agent window: it has left the one it had.
        if isStart, known != nil { try? FileManager.default.removeItem(at: url) }
        return (isStart ? nil : known, "front-window-\(window)-is-no-agent-window")
    }
    try? writeJSON(["marker": found, "service": service, "session": session, "window": Int(window),
                    "tied": Date().timeIntervalSince1970], to: url)
    return (found, "front-window")
}

// MARK: - What a hook event means

/// Whether a final answer ends by asking the person something.
func endsWithQuestion(_ answer: String) -> Bool {
    let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
    let breaks = try! NSRegularExpression(pattern: #"\n\s*\n"#)
    let all = NSRange(text.startIndex..., in: text)
    var last = text
    if let final = breaks.matches(in: text, range: all).last, let cut = Range(final.range, in: text) {
        last = String(text[cut.upperBound...])
    }
    if last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { return false }
    let question = try! NSRegularExpression(pattern: #"\?[*_)"'\]]*(\s|$)"#)
    return question.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil
}

/// The tools through which an agent asks the person a question and waits for the answer:
/// Claude Code's, Codex's, Copilot's.
let questionTools: Set<String> = ["askuserquestion", "request_user_input", "ask_user", "askuser",
                                  "ask_questions", "askquestions", "vscode_askquestions"]

/// The tools a hook event is about, in lower case; Copilot names several at once in `toolCalls`.
func toolNames(_ payload: [String: Any]) -> [String] {
    var names: [String] = []
    for key in ["tool_name", "toolName"] {
        if let name = payload[key] as? String { names.append(name) }
    }
    for key in ["toolCalls", "tool_calls"] {
        for call in payload[key] as? [[String: Any]] ?? [] {
            if let name = (call["name"] ?? call["toolName"] ?? call["tool_name"]) as? String { names.append(name) }
        }
    }
    return names.map { $0.lowercased() }
}

func asksAndWaits(_ names: [String]) -> Bool { names.contains(where: questionTools.contains) }

/// A question posted without waiting for it (Codex's request_user_input_async): the turn goes
/// on, and may end, with the question still open.
func asksWithoutWaiting(_ names: [String]) -> Bool {
    names.contains { $0.hasSuffix("_async") && questionTools.contains(String($0.dropLast(6))) }
}

/// Whether the turn a Codex transcript ends with leaves a question open: one it posted without
/// waiting for the answer, with nothing from the person after it. (An answer given while the
/// turn still runs arrives inside that turn, as a user message.) nil where the transcript
/// does not say.
func askedWithoutWaiting(inTranscript path: String) -> Bool? {
    guard let text = tail(of: URL(fileURLWithPath: path), maxBytes: 1 << 20) else { return nil }
    var asked = false
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"task_started\"") || line.contains("\"user_message\"")
                || line.contains("request_user_input") else { continue }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let payload = object["payload"] as? [String: Any], let type = payload["type"] as? String else { continue }
        // Going back from the end: only what came after the person last spoke counts.
        if object["type"] as? String == "event_msg", type == "task_started" || type == "user_message" { return asked }
        if object["type"] as? String == "response_item", type == "function_call" || type == "custom_tool_call",
           let name = payload["name"] as? String, asksWithoutWaiting([name.lowercased()]) {
            asked = true
        }
    }
    // The turn began before this part of the transcript: a question found in it is this turn's.
    return asked ? true : nil
}

/// The state after a hook event, or nil to keep the current one. Event names are matched
/// without case, so Claude Code's and Codex's `Stop` and Copilot's `agentStop` both work.
/// `askedInTranscript` says whether the turn that is ending posted a question without waiting
/// for it (nil: unknown); it is consulted only where a turn ends.
func transition(from current: Watch?, service: String, event: String, payload: [String: Any],
                now: Double, askedInTranscript: () -> Bool? = { nil }) -> Watch? {
    let names = toolNames(payload)
    let tool = (payload["tool_name"] ?? payload["toolName"]) as? String
    let session = sessionID(payload)
    let isSameSession = session == nil || current?.session == nil || session == current?.session
    let turn = (payload["turn_id"] ?? payload["turnId"]) as? String

    // A question left open in this turn. An event of the same session that names another turn
    // means the question's turn is over and a later one runs: the question was answered.
    var open = current?.asked
    if let asked = open, let turn, isSameSession, !asked.isEmpty, asked != turn { open = nil }
    let isOutdatedQuestion = current?.kind == .question && current?.asked != nil && open == nil
    // Waiting on the person in a way that holds the agent up.
    let isHeldUp = current?.kind == .permission
        || (current?.kind == .question && current?.via == "dialog" && current?.asked == nil)

    func make(_ kind: Kind, tool: String? = nil, via: String? = nil, asked: String? = nil,
              since: Double? = nil) -> Watch {
        var next = Watch(kind: kind, since: since ?? now, service: service, tool: tool, via: via, asked: asked,
                         session: session ?? (current?.service == service ? current?.session : nil))
        next.transcript = payload["transcript_path"] as? String
            ?? (current?.service == service ? current?.transcript : nil)
        return next
    }
    func openQuestion(_ asked: String) -> Watch {
        // The same open question keeps its start.
        let isShown = current?.kind == .question && current?.asked != nil
        return make(.question, via: "dialog", asked: asked, since: isShown ? current?.since : nil)
    }
    /// Back to work, or back to the question still open.
    func resumed() -> Watch { open.map(openQuestion) ?? make(.working) }
    func blockingQuestion() -> Watch { open.map(openQuestion) ?? make(.question, via: "dialog") }

    switch event.lowercased() {
    case "userpromptsubmit", "userpromptsubmitted":
        return make(.working)
    case "stop", "agentstop":
        // A hook saw the question go out in this very turn.
        if let open, let turn, open == turn { return openQuestion(open) }
        switch askedInTranscript() {
        case true?: return openQuestion(open ?? turn ?? "")
        case false?: break
        case nil: if let open { return openQuestion(open) }
        }
        if endsWithQuestion(payload["last_assistant_message"] as? String ?? "") {
            return make(.question, via: "answer")
        }
        return make(.finished)
    case "permissionrequest":
        // Copilot runs this hook for every tool decision, whether it asks the person or not;
        // the overlay reads the prompts Copilot really shows from its event log instead.
        if service == "copilot" { return nil }
        if asksWithoutWaiting(names) { return openQuestion(turn ?? "") }
        if asksAndWaits(names) { return blockingQuestion() }
        return make(.permission, tool: tool, asked: open)
    case "notification":
        let type = (payload["notification_type"] ?? payload["notificationType"]) as? String
        if type == "elicitation_dialog" { return blockingQuestion() }
        if type == "permission_prompt" && !isHeldUp { return make(.permission, asked: open) }
        return nil
    case "pretooluse":
        if asksWithoutWaiting(names) { return openQuestion(turn ?? "") }
        if asksAndWaits(names) { return blockingQuestion() }
        // Another tool starts: what held the agent up was answered.
        return isHeldUp || isOutdatedQuestion ? resumed() : nil
    case "posttooluse", "posttoolusefailure":
        if asksWithoutWaiting(names) { return openQuestion(turn ?? "") }
        // A tool ran, so the permission or question before it was answered.
        return isHeldUp || isOutdatedQuestion ? resumed() : nil
    default:
        return nil
    }
}

/// A hook's input: one JSON object on standard input. Where the writer leaves the pipe open,
/// this waits for the object to be whole, not for the end of the input.
func readHookInput(timeout: TimeInterval = 2) -> [String: Any] {
    let fd = STDIN_FILENO
    guard isatty(fd) == 0 else { return [:] }
    let flags = fcntl(fd, F_GETFL)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    defer { _ = fcntl(fd, F_SETFL, flags) }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    func whole() -> [String: Any]? {
        let blank: Set<UInt8> = [0x20, 0x0a, 0x0d, 0x09]
        guard data.last(where: { !blank.contains($0) }) == UInt8(ascii: "}") else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 50)
        if ready < 0 {
            if errno == EINTR { continue }
            break
        }
        if ready == 0 {
            // Nothing more for now: a whole object is all there will be.
            if let object = whole() { return object }
            continue
        }
        let count = read(fd, &buffer, buffer.count)
        if count > 0 {
            data.append(buffer, count: count)
        } else if count == 0 || (errno != EAGAIN && errno != EINTR) {
            break   // the end of the input
        }
    }
    return whole() ?? [:]
}

/// One line per hook run, and per sound, in hooks.log: names and ids, never what was said.
func logHook(_ fields: [(String, String?)], home: URL = supportHome) {
    let url = hookLogURL(home)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    // Past 400 KB the log keeps its newer half.
    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    if size > 400_000, let kept = tail(of: url, maxBytes: 200_000) {
        try? Data(String(kept.drop { $0 != "\n" }.dropFirst()).utf8).write(to: url, options: .atomic)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    let text = fields.compactMap { key, value -> String? in
        guard let value, !value.isEmpty else { return nil }
        return value.contains(" ") ? "\(key)=\"\(value)\"" : "\(key)=\(value)"
    }.joined(separator: " ")
    let line = formatter.string(from: Date()) + " " + text + "\n"
    let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return }
    _ = line.withCString { write(fd, $0, strlen($0)) }
    close(fd)
}

func runHook(service: String, event explicit: String?) -> Int32 {
    let payload = readHookInput()
    let event = explicit ?? (payload["hook_event_name"] as? String) ?? ""
    let now = Date().timeIntervalSince1970

    var marker: String?
    var place: String
    var found = origin(of: getpid(), vscode: vscodePIDs)
    // However its hooks are started, Copilot's own record names the sessions of the shared host.
    // (REPLY_CLOCK_ASSUME_SHARED_HOST is for trying this path from a terminal.)
    if found == .elsewhere, service == "copilot", isAgentHostSession(payload) { found = .sharedHost }
    if ProcessInfo.processInfo.environment["REPLY_CLOCK_ASSUME_SHARED_HOST"] != nil { found = .sharedHost }
    switch found {
    case .window(let name):
        (marker, place) = (name, "window")
    case .otherWindow:
        place = "not-an-agent-window"
    case .elsewhere:
        place = "outside-vscode"
    case .sharedHost:
        let tied = sessionMarker(service: service, event: event, payload: payload) { frontVSCodeWindow(vscodePIDs()) }
        (marker, place) = (tied.marker, "shared-host:" + tied.note)
    }

    var outcome: String? = nil
    if let marker {
        let current = readWatch(marker)
        let next = transition(from: current, service: service, event: event, payload: payload, now: now) {
            guard service == "codex", let path = payload["transcript_path"] as? String else { return nil }
            return askedWithoutWaiting(inTranscript: path)
        }
        if let next {
            try? writeWatch(next, marker: marker)
            outcome = (current?.kind.rawValue ?? "none") + ">" + next.kind.rawValue
                + (next.kind == .question ? (next.asked != nil ? "(open)" : "(\(next.via ?? ""))") : "")
        } else {
            outcome = "kept:" + (current?.kind.rawValue ?? "none")
        }
    }
    logHook([("svc", service), ("evt", event), ("tool", toolNames(payload).joined(separator: ",")),
             ("session", sessionID(payload).map { String($0.prefix(8)) }),
             ("turn", ((payload["turn_id"] ?? payload["turnId"]) as? String).map { String($0.suffix(6)) }),
             ("at", place), ("window", marker), ("state", outcome)])

    // Codex reads a Stop hook's output as JSON; an empty object asks for nothing.
    if service == "codex" && event.lowercased() == "stop" { print("{}") }
    return 0
}

// MARK: - What to draw for a state

enum Icon { case clock, question, permission }

struct Look: Equatable {
    var hex: String
    var icon: Icon
    /// The ring: the share of the reply window left, 0 to 1.
    var remaining: Double
    var readout: String
    var caption: String
    /// The second hand, degrees from 12 o'clock; nil where none ticks.
    var secondDeg: Double? = nil
    /// True where nothing counts down: the ring is drawn dotted.
    var isDotted = false
}

let SLATE = "#64748B"  // working
let VIOLET = "#8B5CF6" // a question for you
let CYAN = "#06B6D4"   // a permission request: a hue the countdown never passes through

func hslHex(_ h: Double, _ s: Double, _ l: Double) -> String {
    let a = s * min(l, 1 - l)
    func channel(_ n: Double) -> Double {
        let k = (n + h / 30).truncatingRemainder(dividingBy: 12)
        return l - a * max(-1, min(k - 3, 9 - k, 1))
    }
    func hex(_ x: Double) -> String { String(format: "%02x", Int((x * 255).rounded())) }
    return "#" + hex(channel(0)) + hex(channel(8)) + hex(channel(4))
}

/// All the time left is green; half is yellow, a quarter orange, none red.
func countdownHex(_ remaining: Double) -> String { hslHex(120 * min(1, max(0, remaining)), 0.85, 0.45) }

func clockText(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded(.up)))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
}

/// What to draw, or nil for nothing: a window shows no clock until its first prompt.
func look(_ watch: Watch?, now: Double, minutes: Double) -> Look? {
    guard let watch else { return nil }
    switch watch.kind {
    case .idle:
        return nil
    case .working:
        return Look(hex: SLATE, icon: .clock, remaining: 1, readout: "• • •", caption: "WORKING", isDotted: true)
    case .question where watch.via == "answer":
        // The agent finished on a question: the reply window runs like any finished answer.
        return countdown(since: watch.since, now: now, minutes: minutes)
    case .question:
        return Look(hex: VIOLET, icon: .question, remaining: 1, readout: "?", caption: "QUESTION", isDotted: true)
    case .permission:
        return Look(hex: CYAN, icon: .permission, remaining: 1, readout: "!", caption: "PERMISSION", isDotted: true)
    case .finished:
        return countdown(since: watch.since, now: now, minutes: minutes)
    }
}

func countdown(since: Double, now: Double, minutes: Double) -> Look {
    let span = max(1, minutes * 60)
    let left = since + span - now
    let secondDeg = Double(Int(max(0, now - since)) % 60) * 6
    if left > 0 {
        return Look(hex: countdownHex(left / span), icon: .clock, remaining: left / span,
                    readout: clockText(left), caption: "LEFT", secondDeg: secondDeg)
    }
    return Look(hex: countdownHex(0), icon: .clock, remaining: 0,
                readout: "+" + clockText(-left), caption: "OVERDUE", secondDeg: secondDeg)
}

// MARK: - Sounds
//
//   the agent answers        answer_sound_1, then clock-tick as the reply window starts
//   5 minutes left to reply  low_on_time
//   a turn fails             fail-sound-effect where the credits ran out, then clock-tick
//   the agent asks you       question-mark
//   permission needed        exclamation_mark
//   every 7 minutes of work  long_thinking, then clock-tick
//   a credit meter drops     under 50%: 50_percent_credits, under 20%: punch-sound-effect-meme,
//                            to 10%: bruh, to nothing: fail-sound-effect

/// A sound, named by the file in sounds/ (without ".mp3") that replaces its built-in one.
enum Cue: String {
    case answer = "answer_sound_1", tick = "clock-tick", longThinking = "long_thinking"
    case question = "question-mark", permission = "exclamation_mark", fail = "fail-sound-effect"
    case credits50 = "50_percent_credits", credits20 = "punch-sound-effect-meme", credits10 = "bruh"
    case lowOnTime = "low_on_time"

    /// The macOS system sound played where sounds/ holds no file of this name.
    var builtIn: String {
        switch self {
        case .answer: return "Glass"
        case .tick: return "Tink"
        case .lowOnTime: return "Submarine"
        case .longThinking: return "Purr"
        case .question: return "Ping"
        case .permission: return "Funk"
        case .fail: return "Basso"
        case .credits50: return "Pop"
        case .credits20: return "Blow"
        case .credits10: return "Sosumi"
        }
    }
}

/// The errors that end a turn because the credits ran out: Claude Code's names, and "quota"
/// for Copilot's.
let creditFailures: Set<String> = ["rate_limit", "billing_error", "quota"]
let thinkingMark = 7 * 60.0
/// The reply time left at which low_on_time sounds.
let lowOnTime = 5 * 60.0

/// What the sounds last made of a window.
struct Heard: Equatable {
    /// The state and what tells one instance of it from the next: "countdown 1700000000.0".
    var stage: String
    /// The question last announced: an open one that shows again after a permission is not
    /// announced twice.
    var question: String? = nil
    /// The countdown whose 5-minutes-left sound is done with: played, or come too late for.
    var warned: String? = nil
    /// Since when the agent has worked without a stop, and the 7-minute marks of that passed.
    var workingFrom = 0.0
    var marks = 0
}

func stage(_ watch: Watch?) -> String {
    guard let watch else { return "none" }
    switch watch.kind {
    case .idle: return "none"
    case .working: return "working"
    case .question where watch.via != "answer":
        return "question " + (watch.asked.flatMap { $0.isEmpty ? nil : $0 } ?? "\(watch.since)")
    case .finished, .question: return "countdown \(watch.since)"
    case .permission: return "permission \(watch.since)"
    }
}

/// The sounds for a window that was last heard as `heard` and is in the state `watch` now;
/// `minutes` is the reply window.
func sounds(from heard: Heard?, to watch: Watch?, now: Double, minutes: Double) -> (cues: [Cue], heard: Heard) {
    let name = stage(watch)
    /// The reply time left, where a countdown runs.
    let left = name.hasPrefix("countdown") ? watch.map { $0.since + minutes * 60 - now } : nil
    // A window met for the first time makes no sound: its state began before anyone listened.
    guard var next = heard else {
        let from = watch?.since ?? now
        return ([], Heard(stage: name, question: name.hasPrefix("question") ? name : nil,
                          warned: left.map { $0 <= lowOnTime } == true ? name : nil,
                          workingFrom: from, marks: Int((now - from) / thinkingMark)))
    }
    var cues: [Cue] = []
    if name != next.stage {
        if name.hasPrefix("countdown") {
            switch watch?.failure {
            case nil: cues = [.answer, .tick]
            case let failure? where creditFailures.contains(failure): cues = [.fail, .tick]
            default: cues = [.tick]   // another error: no answer, but the reply window starts
            }
        } else if name.hasPrefix("question") {
            if name != next.question { cues = [.question] }
            next.question = name
        } else if name.hasPrefix("permission") {
            cues = [.permission]
        } else if name == "working" {
            (next.workingFrom, next.marks) = (now, 0)
        }
        next.stage = name
    } else if name == "working" {
        let marks = Int((now - next.workingFrom) / thinkingMark)
        if marks > next.marks { cues = [.longThinking, .tick] }
        next.marks = marks
    } else if let left, left <= lowOnTime, next.warned != name {
        // Once per countdown, and not for one found already overdue (after sleep, say).
        if left > 0 { cues = [.lowOnTime] }
        next.warned = name
    }
    return (cues, next)
}

/// How far down a credit meter is, by the percentage UsageBar shows: 0 from 50% up, 1 under
/// 50%, 2 under 20%, 3 from 10% down, 4 with nothing left.
func creditLevel(_ left: Double) -> Int {
    let shown = left.rounded()
    return shown <= 0 ? 4 : shown <= 10 ? 3 : shown < 20 ? 2 : shown < 50 ? 1 : 0
}

/// The sound for a meter that newly dropped to each level.
let creditCues: [Cue?] = [nil, .credits50, .credits20, .credits10, .fail]

/// Plays one sound after another, never two at once. The sounds of one moment (an answer and
/// its tick) stay together, and a moment that already waits its turn is not added again: three
/// windows finishing together make two rounds of sound, not three.
final class SoundPlayer: NSObject, NSSoundDelegate {
    var volume: Float = 1
    private var waiting: [[Cue]] = []
    /// What is left of the moment being played.
    private var rest: [Cue] = []
    private var playing: NSSound?

    func play(_ cues: [Cue]) {
        guard !cues.isEmpty, !waiting.contains(cues) else { return }
        waiting.append(cues)
        if let current = playing, !current.isPlaying { playing = nil }   // it ended without saying so
        next()
    }

    private func next() {
        while playing == nil {
            if rest.isEmpty {
                guard !waiting.isEmpty else { return }
                rest = waiting.removeFirst()
            }
            let cue = rest.removeFirst()
            // The person's own file, or else the built-in sound (a copy: the named one is shared).
            let file = soundsDir(supportHome).appendingPathComponent(cue.rawValue + ".mp3")
            let own = FileManager.default.fileExists(atPath: file.path) ? NSSound(contentsOf: file, byReference: true) : nil
            guard let sound = own ?? (NSSound(named: cue.builtIn)?.copy() as? NSSound) else {
                logHook([("sound-missing", cue.rawValue)])
                continue
            }
            sound.delegate = self
            sound.volume = volume
            if sound.play() { playing = sound }
        }
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        playing = nil
        next()
    }
}

// MARK: - Drawing

extension NSColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0x808080
        self.init(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}

/// A point `r` from the center of a 120 x 120 clock, `deg` clockwise from 12 o'clock (y runs down).
func polar(_ deg: Double, _ r: Double, cx: Double = 60, cy: Double = 60) -> NSPoint {
    let rad = deg * .pi / 180
    return NSPoint(x: cx + r * sin(rad), y: cy - r * cos(rad))
}

func circle(_ r: CGFloat, cy: CGFloat = 60) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: 60 - r, y: cy - r, width: 2 * r, height: 2 * r))
}

func line(_ a: NSPoint, _ b: NSPoint, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: a); path.line(to: b)
    path.lineWidth = width; path.lineCapStyle = .round
    color.setStroke(); path.stroke()
}

/// Draws `text` centered on `cx`, glyph by glyph. Not through an attributed string: on a busy
/// Mac, macOS can fail to lay one out in the system font, with an exception that ends the app
/// (with six agent windows, about every ten minutes). The labels are plain Latin, so nothing
/// is lost by placing the glyphs here; `kern` is the space added between them.
func centeredText(_ text: String, font: NSFont, color: NSColor, baseline: CGFloat, kern: CGFloat = 0, cx: CGFloat = 60) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    let face = font as CTFont
    let characters = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(face, characters, &glyphs, characters.count) else { return }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(face, .horizontal, glyphs, &advances, glyphs.count)
    let width = advances.reduce(0) { $0 + $1.width } + kern * CGFloat(max(0, glyphs.count - 1))
    var x = cx - width / 2
    var positions: [CGPoint] = []
    // The view's y runs down, glyphs are designed with y running up: the text matrix turns
    // them over, and with them the positions, which are therefore given at -baseline.
    for advance in advances {
        positions.append(CGPoint(x: x, y: -baseline))
        x += advance.width + kern
    }
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.setFillColor(color.cgColor)
    CTFontDrawGlyphs(face, glyphs, positions, glyphs.count, context)
}

/// The clock, in a 120 x 120 box with y running down; the same picture the side pane drew.
func drawClock(_ l: Look, color: NSColor) {
    func dottedRing() {
        let ring = circle(54)
        ring.lineWidth = 4; ring.lineCapStyle = .round
        ring.setLineDash([0.1, 9], count: 2, phase: 0)
        color.withAlphaComponent(0.55).setStroke(); ring.stroke()
    }
    func polygon(corners: Int, firstDeg: Double, r: Double, cy: Double) {
        let path = NSBezierPath()
        for i in 0..<corners {
            let point = polar(firstDeg + 360 / Double(corners) * Double(i), r, cy: cy)
            if i == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        path.lineWidth = 5; path.lineJoinStyle = .round
        color.withAlphaComponent(0.18).setFill(); path.fill()
        color.setStroke(); path.stroke()
    }
    func glyph(_ text: String, baseline: CGFloat, size: CGFloat) {
        centeredText(text, font: .systemFont(ofSize: size, weight: .heavy), color: color, baseline: baseline)
    }

    switch l.icon {
    case .question:
        dottedRing(); polygon(corners: 3, firstDeg: 0, r: 44, cy: 63); glyph("?", baseline: 80, size: 40)
    case .permission:
        dottedRing(); polygon(corners: 8, firstDeg: 22.5, r: 41, cy: 60); glyph("!", baseline: 76, size: 44)
    case .clock:
        if l.isDotted {
            dottedRing()
        } else {
            let track = circle(54)
            track.lineWidth = 7
            color.withAlphaComponent(0.18).setStroke(); track.stroke()
            if l.remaining > 0 {
                // The arc left runs clockwise from 12 o'clock.
                let arc = NSBezierPath()
                let end = 360 * min(1, l.remaining), steps = max(2, Int(end / 3))
                for i in 0...steps {
                    let point = polar(end * Double(i) / Double(steps), 54)
                    if i == 0 { arc.move(to: point) } else { arc.line(to: point) }
                }
                arc.lineWidth = 7; arc.lineCapStyle = .round; arc.lineJoinStyle = .round
                color.setStroke(); arc.stroke()
            }
        }
        // The face; the minute hand marks the ring's end.
        let face = circle(44)
        color.withAlphaComponent(0.12).setFill(); face.fill()
        face.lineWidth = 2; color.setStroke(); face.stroke()
        for i in 0..<12 {
            let isQuarter = i % 3 == 0
            line(polar(Double(i) * 30, isQuarter ? 34 : 37), polar(Double(i) * 30, 41),
                 width: isQuarter ? 2.5 : 1.5, color: color)
        }
        line(NSPoint(x: 60, y: 60), polar(360 * l.remaining, 27), width: 3, color: color)
        if let second = l.secondDeg { line(NSPoint(x: 60, y: 60), polar(second, 33), width: 1.2, color: color) }
        color.setFill(); circle(3).fill()
        let size: CGFloat = l.readout.count > 6 ? 13 : 17
        centeredText(l.readout, font: .monospacedSystemFont(ofSize: size, weight: .bold), color: color, baseline: 81)
        centeredText(l.caption, font: .systemFont(ofSize: 6.5, weight: .semibold), color: color, baseline: 92, kern: 1.2)
    }
}

/// Covers one agent window: a frame in the state's color around its edge, and the clock
/// in its center (or at its top) at `clockAlpha`. It takes no clicks.
final class OverlayView: NSView {
    var look: Look? = nil { didSet { if look != oldValue { needsDisplay = true } } }
    var clockAlpha: CGFloat = 0.5 { didSet { if clockAlpha != oldValue { needsDisplay = true } } }
    /// The clock's height as a share of the window's height.
    var heightShare: CGFloat = 0.15 { didSet { if heightShare != oldValue { needsDisplay = true } } }
    /// Under the title bar instead of in the middle of the window.
    var isAtTop = false { didSet { if isAtTop != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let look, let context = NSGraphicsContext.current?.cgContext else { return }
        let color = NSColor(hex: look.hex)

        let border: CGFloat = 4
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: border / 2, dy: border / 2), xRadius: 10, yRadius: 10)
        frame.lineWidth = border
        color.setStroke(); frame.stroke()

        let side = max(48, min(bounds.height * heightShare, 220, bounds.width - 24))
        context.saveGState()
        context.setAlpha(clockAlpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.translateBy(x: bounds.midX - side / 2, y: isAtTop ? 36 : bounds.midY - side / 2)
        context.scaleBy(x: side / 120, y: side / 120)
        drawClock(look, color: color)
        context.endTransparencyLayer()
        context.restoreGState()
    }
}

final class Overlay {
    let panel: NSPanel
    let view = OverlayView()

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.contentView = view
    }
}

// MARK: - Following the VS Code windows

let vscodeBundleIDs = ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func axValue(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func axPoint(_ element: AXUIElement) -> CGPoint? {
    guard let value = axValue(element, kAXPositionAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(value as! AXValue, .cgPoint, &point) ? point : nil
}

func axSize(_ element: AXUIElement) -> CGSize? {
    guard let value = axValue(element, kAXSizeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(value as! AXValue, .cgSize, &size) ? size : nil
}

func onScreenWindowIDs() -> Set<CGWindowID> {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] ?? []
    return Set(list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
}

let axCallback: AXObserverCallback = { _, _, _, _ in Tracker.shared.syncSoon() }

let logStamps: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

/// A time as the services' session logs write it, in seconds since 1970.
func logTime(_ stamp: Any?) -> Double? {
    (stamp as? String).flatMap(logStamps.date(from:))?.timeIntervalSince1970
}

func fileSize(_ path: String) -> UInt64? {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
}

func copilotEventsURL(session: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".copilot/session-state/\(fileKey(session))/events.jsonl")
}

/// A turn that ended without a closing hook, as the service's own session log records it.
struct TurnEnd: Equatable {
    var at: Double
    /// nil where the person interrupted the turn; else the error that ended it.
    var failure: String? = nil
}

func jsonLine(_ line: Substring) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
}

/// Claude Code's transcript: its last entry in the main thread is the note an interrupt
/// leaves, or the message an API error leaves in place of an answer.
func claudeTurnEnd(in text: String) -> TurnEnd? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"type\":\"user\"") || line.contains("\"type\":\"assistant\""),
              let entry = jsonLine(line), let type = entry["type"] as? String, type == "user" || type == "assistant",
              entry["isSidechain"] as? Bool != true, entry["isMeta"] as? Bool != true else { continue }
        guard let at = logTime(entry["timestamp"]) else { return nil }
        if type == "assistant" {
            guard entry["isApiErrorMessage"] as? Bool == true else { return nil }
            return TurnEnd(at: at, failure: entry["error"] as? String ?? "unknown")
        }
        let content = (entry["message"] as? [String: Any])?["content"]
        let said = content as? String ?? (content as? [[String: Any]])?.first?["text"] as? String ?? ""
        return said.hasPrefix("[Request interrupted") ? TurnEnd(at: at) : nil
    }
    return nil
}

/// Codex's rollout: the last turn it names was aborted.
func codexTurnEnd(in text: String) -> TurnEnd? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"turn_aborted\"") || line.contains("\"task_started\"") || line.contains("\"task_complete\""),
              let entry = jsonLine(line), entry["type"] as? String == "event_msg",
              let type = (entry["payload"] as? [String: Any])?["type"] as? String else { continue }
        if type == "turn_aborted" { return logTime(entry["timestamp"]).map { TurnEnd(at: $0) } }
        if type == "task_started" || type == "task_complete" { return nil }
    }
    return nil
}

/// Copilot's event log: an abort or a session error that no model turn follows.
func copilotTurnEnd(in text: String) -> TurnEnd? {
    for line in text.split(separator: "\n").reversed() {
        guard line.contains("\"abort\"") || line.contains("\"session.error\"")
                || line.contains("\"assistant.turn_start\"") || line.contains("\"user.message\""),
              let event = jsonLine(line), let type = event["type"] as? String else { continue }
        switch type {
        case "assistant.turn_start", "user.message":
            return nil
        case "abort":
            return logTime(event["timestamp"]).map { TurnEnd(at: $0) }
        case "session.error":
            let data = event["data"] as? [String: Any]
            let kind = data?["errorType"] as? String ?? "error"
            let said = (kind + " " + (data?["message"] as? String ?? "")).lowercased()
            let isOutOfCredits = ["quota", "rate limit", "rate_limit", "premium request"].contains(where: said.contains)
            return logTime(event["timestamp"]).map { TurnEnd(at: $0, failure: isOutOfCredits ? "quota" : kind) }
        default:
            continue
        }
    }
    return nil
}

/// How a window's turn ended where no hook said so; each log is read again only once it has grown.
final class TurnLog {
    private var cache: [String: (size: UInt64, end: TurnEnd?)] = [:]

    func end(of watch: Watch) -> TurnEnd? {
        let path: String?
        let read: (String) -> TurnEnd?
        switch watch.service {
        case "claude": (path, read) = (watch.transcript, claudeTurnEnd)
        case "codex": (path, read) = (watch.transcript, codexTurnEnd)
        case "copilot": (path, read) = (watch.session.map { copilotEventsURL(session: $0).path }, copilotTurnEnd)
        default: return nil
        }
        guard let path, let size = fileSize(path) else { return nil }
        if cache[path]?.size != size {
            cache[path] = (size, tail(of: URL(fileURLWithPath: path), maxBytes: 128_000).flatMap(read))
        }
        return cache[path]?.end
    }
}

/// Copilot's own record of a session, read for what its hooks do not tell: that it has
/// stopped to ask the person for a permission. It logs every permission request and, once
/// settled, its completion; the requests its own rules settle complete within milliseconds.
final class CopilotLog {
    private var cache: [String: (size: UInt64, requested: [Double])] = [:]

    /// The times of the permission requests in an event log that nothing has completed.
    func openRequests(in text: String, now: Double) -> [Double] {
        var requested: [String: Double] = [:]
        for line in text.split(separator: "\n") where line.contains("\"permission.") {
            guard let event = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = event["type"] as? String,
                  let id = (event["data"] as? [String: Any])?["requestId"] as? String else { continue }
            if type == "permission.requested" {
                requested[id] = logTime(event["timestamp"]) ?? now
            } else if type == "permission.completed" {
                requested[id] = nil
            }
        }
        return Array(requested.values)
    }

    /// Since when a session has waited for the person to settle a permission; nil where it does not.
    func permissionAsked(session: String, now: Double) -> Double? {
        let url = copilotEventsURL(session: session)
        guard let size = fileSize(url.path) else { return nil }
        if cache[session]?.size != size {
            cache[session] = (size, openRequests(in: tail(of: url, maxBytes: 512_000) ?? "", now: now))
        }
        // Half a second lets the requests that Copilot's own rules settle pass by.
        return cache[session]?.requested.filter { now - $0 > 0.5 }.min()
    }
}

final class Tracker: NSObject {
    static let shared = Tracker()

    /// The app's own settings, which UsageBar's menu writes; run as a bare binary, outside the
    /// app bundle, they are reached by name.
    let defaults = Bundle.main.bundleIdentifier == "local.replyclock"
        ? .standard : UserDefaults(suiteName: "local.replyclock") ?? .standard
    var overlays: [String: Overlay] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var isSyncPending = false
    var lastSweep = 0.0
    /// The agent windows by window number, as last written for the hooks.
    var windowIndex: [String: String]? = nil
    let copilot = CopilotLog()
    let turns = TurnLog()
    let player = SoundPlayer()
    /// What the sounds last made of each window, by file key, and of each credit meter, by name.
    var heard: [String: Heard] = [:]
    var creditLevels: [String: Int] = [:]
    var usageRead: Date? = nil

    /// 0 turns the sounds off.
    var soundVolume: Double { (defaults.object(forKey: "soundVolume") as? NSNumber)?.doubleValue ?? 1 }
    var minutes: Double { let v = defaults.double(forKey: "minutes"); return v > 0 ? v : 30 }
    var opacity: Double { (defaults.object(forKey: "opacity") as? NSNumber)?.doubleValue ?? 0.5 }
    var heightShare: Double { (defaults.object(forKey: "heightShare") as? NSNumber)?.doubleValue ?? 0.15 }
    var isAtTop: Double { defaults.double(forKey: "atTop") }

    func start() {
        // Every second for the countdown; window moves, resizes and raises also sync at once.
        let timer = Timer(timeInterval: 1, repeats: true) { _ in Tracker.shared.sync() }
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(syncSoon), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncSoon), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        sync()
    }

    @objc func syncSoon() {
        guard !isSyncPending else { return }
        isSyncPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
            self.isSyncPending = false
            self.sync()
        }
    }

    /// A window's state as the service's own log corrects it, for what no hook reports: a turn
    /// the person interrupted (nothing is waited for any more), a turn that failed (the reply
    /// window runs from the failure), and Copilot stopping to ask for a permission.
    func shown(_ recorded: Watch?, now: Double) -> Watch? {
        guard let state = recorded else { return nil }
        let isBusy = state.kind == .working || state.kind == .permission
            || (state.kind == .question && state.via == "dialog" && state.asked == nil)
        if isBusy, let end = turns.end(of: state), end.at > state.since {
            guard let failure = end.failure else { return nil }
            var failed = Watch(kind: .finished, since: end.at, service: state.service, session: state.session)
            failed.failure = failure
            return failed
        }
        if state.kind == .working, state.service == "copilot", let session = state.session,
           let asked = copilot.permissionAsked(session: session, now: now) {
            return Watch(kind: .permission, since: asked, service: "copilot", session: session)
        }
        return state
    }

    /// The state of every window that has one, by file key.
    func readStates(now: Double, home: URL = supportHome) -> [String: Watch] {
        var states: [String: Watch] = [:]
        let dir = windowsDir(home)
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
            let recorded = readJSON(dir.appendingPathComponent(name)).flatMap(Watch.init(json:))
            states[String(name.dropLast(5))] = shown(recorded, now: now)
        }
        return states
    }

    /// The agent windows that are open, file key to marker: those whose extension host still
    /// runs. The state file of a closed window would say "working" for good.
    func openWindows(home: URL) -> [String: String] {
        var open: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: hostsDir(home).path)) ?? [] {
            guard name.hasSuffix(".json"), let pid = pid_t(name.dropLast(5)), kill(pid, 0) == 0 || errno != ESRCH,
                  let marker = registeredMarker(pid, home: home) else { continue }
            open[fileKey(marker)] = marker
        }
        return open
    }

    /// The sounds due now, each with what hooks.log says of it: for the open windows that
    /// changed state, have worked another 7 minutes or have 5 minutes of the reply window
    /// (`minutes`) left, and for the credit meters that dropped.
    func dueSounds(_ states: [String: Watch], now: Double, minutes: Double,
                   home: URL = supportHome) -> [(cues: [Cue], log: [(String, String?)])] {
        var due: [(cues: [Cue], log: [(String, String?)])] = []
        for (key, marker) in openWindows(home: home).sorted(by: { $0.key < $1.key }) {
            let before = heard[key]
            let (cues, next) = sounds(from: before, to: states[key], now: now, minutes: minutes)
            heard[key] = next
            guard !cues.isEmpty, let before else { continue }
            let was = before.stage.prefix(while: { $0 != " " }), name = next.stage.prefix(while: { $0 != " " })
            let change = before.stage != next.stage ? "\(was)>\(name)"
                : name == "working" ? "working-\(Int(thinkingMark / 60) * next.marks)min" : "countdown-5min-left"
            due.append((cues, [("window", marker), ("state", change)]))
        }
        // UsageBar writes the meters about once a minute. The worst level reached sounds first.
        let written = (try? FileManager.default.attributesOfItem(atPath: usageURL(home).path))?[.modificationDate] as? Date
        guard let written, written != usageRead else { return due }
        usageRead = written
        var dropped: [Int: String] = [:]
        for meter in readJSON(usageURL(home))?["meters"] as? [[String: Any]] ?? [] {
            guard let name = meter["name"] as? String, let left = (meter["left"] as? NSNumber)?.doubleValue else { continue }
            let level = creditLevel(left)
            if let before = creditLevels[name], level > before { dropped[level] = "\(name) \(Int(left.rounded()))%" }
            creditLevels[name] = level
        }
        for (level, meter) in dropped.sorted(by: { $0.key > $1.key }) {
            if let cue = creditCues[level] { due.append(([cue], [("credits", meter)])) }
        }
        return due
    }

    func sync() {
        let now = Date().timeIntervalSince1970
        let states = readStates(now: now)
        // The sounds come first: they need no Accessibility access.
        let volume = soundVolume
        for sound in dueSounds(states, now: now, minutes: minutes) where volume > 0 {
            player.volume = Float(volume)
            player.play(sound.cues)
            logHook([("sound", sound.cues.map(\.rawValue).joined(separator: "+"))] + sound.log)
        }
        guard AXIsProcessTrusted() else {
            for overlay in overlays.values { overlay.panel.orderOut(nil) }
            overlays.removeAll()
            publishStatus(accessibility: false, shown: 0)
            return
        }
        let onScreen = onScreenWindowIDs()
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let apps = vscodeBundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        observe(apps)

        var seen = Set<String>()
        var index: [String: String] = [:]
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            for window in axValue(element, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                guard let title = axValue(window, kAXTitleAttribute) as? String,
                      let found = marker(inTitle: title) else { continue }
                var id: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &id) == .success else { continue }
                index[String(id)] = found
                guard !seen.contains(found), (axValue(window, kAXMinimizedAttribute) as? Bool) != true,
                      onScreen.contains(id), let origin = axPoint(window), let size = axSize(window) else { continue }
                seen.insert(found)

                let overlay = overlays[found] ?? Overlay()
                overlays[found] = overlay
                // Nothing at all until the window's first prompt.
                guard let shown = look(states[fileKey(found)], now: now, minutes: minutes) else {
                    overlay.panel.orderOut(nil)
                    continue
                }
                // Accessibility measures from the top of the main display, AppKit from its bottom.
                let frame = NSRect(x: origin.x, y: primaryHeight - origin.y - size.height,
                                   width: size.width, height: size.height)
                if overlay.panel.frame != frame { overlay.panel.setFrame(frame, display: false) }
                overlay.view.clockAlpha = CGFloat(opacity)
                overlay.view.heightShare = CGFloat(heightShare)
                overlay.view.isAtTop = isAtTop > 0
                overlay.view.look = shown
                // Just in front of its own window: other apps' windows still cover both.
                overlay.panel.order(.above, relativeTo: Int(id))
            }
        }
        for (name, overlay) in overlays where !seen.contains(name) {
            overlay.panel.orderOut(nil)
            overlays[name] = nil
        }
        // The hooks of a service that all windows share look their window up here.
        if index != windowIndex {
            try? writeJSON(["windows": index, "written": now], to: windowIndexURL(supportHome))
            windowIndex = index
        }
        if now - lastSweep > 60 { lastSweep = now; sweepHosts() }
        publishStatus(accessibility: true, shown: overlays.values.filter { $0.panel.isVisible }.count)
    }

    /// What UsageBar's menu shows about Reply Clock; written only when it changes.
    func publishStatus(accessibility: Bool, shown: Int) {
        if defaults.object(forKey: "statusAccessibility") as? Bool != accessibility {
            defaults.set(accessibility, forKey: "statusAccessibility")
        }
        if defaults.object(forKey: "statusShown") as? Int != shown { defaults.set(shown, forKey: "statusShown") }
    }

    func observe(_ apps: [NSRunningApplication]) {
        let pids = Set(apps.map(\.processIdentifier))
        for (pid, observer) in observers where !pids.contains(pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = nil
        }
        for pid in pids where observers[pid] == nil {
            var created: AXObserver?
            guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else { continue }
            let element = AXUIElementCreateApplication(pid)
            for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                         kAXWindowMovedNotification, kAXWindowResizedNotification, kAXWindowCreatedNotification,
                         kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                         kAXApplicationActivatedNotification, kAXTitleChangedNotification] {
                AXObserverAddNotification(observer, element, name as CFString, nil)
            }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            observers[pid] = observer
        }
    }

    /// Drops the files of extension hosts that have exited, and of sessions unused for two weeks.
    func sweepHosts() {
        let files = FileManager.default
        let dir = hostsDir(supportHome)
        for name in (try? files.contentsOfDirectory(atPath: dir.path)) ?? [] {
            guard name.hasSuffix(".json"), let pid = pid_t(name.dropLast(5)) else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? files.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        let sessions = sessionsDir(supportHome)
        for name in (try? files.contentsOfDirectory(atPath: sessions.path)) ?? [] {
            let url = sessions.appendingPathComponent(name)
            if let changed = (try? files.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
               Date().timeIntervalSince(changed) > 14 * 86_400 {
                try? files.removeItem(at: url)
            }
        }
    }
}

// MARK: - App (no menu bar icon of its own: UsageBar's menu holds the settings)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
        Tracker.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Without the overlay nobody keeps the window list current.
        try? FileManager.default.removeItem(at: windowIndexURL(supportHome))
    }
}

// MARK: - Preview and self-test

func renderPreviews(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let t = 1_000_000.0
    let states: [(String, Watch?)] = [
        ("working", Watch(kind: .working, since: t)),
        ("green", Watch(kind: .finished, since: t - 200)),
        ("yellow", Watch(kind: .finished, since: t - 900)),
        ("red-overdue", Watch(kind: .finished, since: t - 2040)),
        ("question", Watch(kind: .question, since: t, via: "dialog")),
        ("answer-question", Watch(kind: .question, since: t - 600, via: "answer")),
        ("permission", Watch(kind: .permission, since: t, tool: "Bash")),
    ]
    for (name, watch) in states {
        for (theme, background) in [("dark", NSColor(hex: "#1e1e1e")), ("light", NSColor(hex: "#ffffff"))] {
            let size = NSSize(width: 480, height: 600)
            let view = OverlayView(frame: NSRect(origin: .zero, size: size))
            view.look = look(watch, now: t, minutes: 30)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // A backdrop with stand-in chat lines, to judge how readable the chat stays under the clock.
            let text = theme == "dark" ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.15, alpha: 1)
            let image = NSImage(size: size)
            image.lockFocus()
            background.setFill(); NSRect(origin: .zero, size: size).fill()
            for row in 0..<22 {
                NSAttributedString(string: "Chat line \(row + 1): the agent's answer stays readable here.",
                                   attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: text])
                    .draw(at: NSPoint(x: 16, y: size.height - 50 - CGFloat(row) * 24))
            }
            rep.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver,
                     fraction: 1, respectFlipped: true, hints: nil)
            image.unlockFocus()
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name)-\(theme).png"))
            }
        }
    }
}

func selftest() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ name: String) {
        if !ok { failures += 1; FileHandle.standardError.write("FAIL: \(name)\n".data(using: .utf8)!) }
    }
    check(marker(inTitle: "Agent 3 [launcher-0123abcdef] - my-project") == "Agent 3 [launcher-0123abcdef]", "marker")
    check(marker(inTitle: "Agent 1 [0123abcdef] - project") == "Agent 1 [0123abcdef]", "older marker")
    check(marker(inTitle: "my-project - main.swift") == nil, "other windows have no marker")
    check(fileKey("Agent 3 [launcher-0123abcdef]") == "Agent-3--launcher-0123abcdef-", "file key")

    check(endsWithQuestion("Done.\n\nShould I deploy it?"), "question at the end")
    check(endsWithQuestion("Want me to go on with **the next step?**"), "bold question")
    check(!endsWithQuestion("Is it fixed? Yes.\n\nAll tests pass."), "question earlier only")
    check(!endsWithQuestion("Here:\n\n```\nwhy?\n```"), "question inside code")

    let t = 1000.0
    func step(_ current: Watch?, _ service: String, _ event: String, _ payload: [String: Any] = [:]) -> Watch? {
        transition(from: current, service: service, event: event, payload: payload, now: t)
    }
    check(step(nil, "codex", "UserPromptSubmit") == Watch(kind: .working, since: t, service: "codex"), "prompt")
    check(step(nil, "copilot", "userPromptSubmitted")?.kind == .working, "copilot prompt")
    check(step(nil, "claude", "Stop", ["last_assistant_message": "All done."]) == Watch(kind: .finished, since: t, service: "claude"), "finished")
    check(step(nil, "codex", "Stop", ["last_assistant_message": "Shall I push?"])?.via == "answer", "answer ends on a question")
    check(step(nil, "copilot", "agentStop")?.kind == .finished, "copilot finished")
    check(step(nil, "claude", "PermissionRequest", ["tool_name": "Bash"]) == Watch(kind: .permission, since: t, service: "claude", tool: "Bash"), "permission")
    check(step(nil, "claude", "PreToolUse", ["tool_name": "AskUserQuestion"])?.via == "dialog", "question dialog")
    let waiting = Watch(kind: .permission, since: 1, service: "claude", tool: "Bash")
    check(step(waiting, "claude", "PostToolUse", ["tool_name": "Bash"])?.kind == .working, "tool ran after approval")
    check(step(Watch(kind: .finished, since: 1), "claude", "PostToolUse") == nil, "tool use keeps a countdown")
    check(step(waiting, "claude", "Notification", ["notification_type": "permission_prompt"]) == nil, "notification keeps the tool")
    check(step(nil, "claude", "SessionStart") == nil, "other events change nothing")

    check(look(nil, now: t, minutes: 30) == nil, "no clock before the first prompt")
    check(look(Watch(kind: .idle, since: t), now: t, minutes: 30) == nil, "no clock while idle")
    let start = look(Watch(kind: .finished, since: t), now: t, minutes: 30)
    check(start?.readout == "30:00" && start?.hex == "#11d411", "a finished turn starts at 30:00, green")
    let half = look(Watch(kind: .finished, since: t), now: t + 900, minutes: 30)
    check(half?.readout == "15:00" && half?.hex == "#d4d411" && half?.caption == "LEFT", "halfway look")
    let late = look(Watch(kind: .finished, since: t), now: t + 2040, minutes: 30)
    check(late?.readout == "+04:00" && late?.caption == "OVERDUE" && late?.hex == "#d41111", "overdue look")
    check(look(Watch(kind: .working, since: t), now: t, minutes: 30)?.hex == SLATE, "working look")
    check(look(Watch(kind: .question, since: t, via: "dialog"), now: t, minutes: 30)?.icon == .question, "question look")
    let asked = look(Watch(kind: .question, since: t, via: "answer"), now: t + 900, minutes: 30)
    check(asked?.icon == .clock && asked?.readout == "15:00" && asked?.hex == "#d4d411",
          "an answer ending on a question counts down like any other")
    check(look(Watch(kind: .permission, since: t), now: t, minutes: 30)?.icon == .permission, "permission look")
    check(step(nil, "codex", "PreToolUse", ["tool_name": "request_user_input"])?.kind == .question, "codex asks")
    check(step(nil, "copilot", "preToolUse", ["toolName": "ask_user"])?.kind == .question, "copilot asks")
    check(step(nil, "codex", "PreToolUse", ["tool_name": "shell"]) == nil, "other tools change nothing")

    // Codex posts a question without waiting for it: the turn goes on and ends, the question stays.
    let codexAsk: [String: Any] = ["tool_name": "request_user_input_async", "turn_id": "T1", "session_id": "S"]
    let posted = step(Watch(kind: .working, since: 1, service: "codex", session: "S"), "codex", "PreToolUse", codexAsk)
    check(posted == Watch(kind: .question, since: t, service: "codex", via: "dialog", asked: "T1", session: "S"),
          "codex posts a question without waiting")
    let stillOpen = Watch(kind: .question, since: 5, service: "codex", via: "dialog", asked: "T1", session: "S")
    check(step(stillOpen, "codex", "PostToolUse", codexAsk) == stillOpen, "its own tool result keeps the question")
    check(step(stillOpen, "codex", "PostToolUse", ["tool_name": "Bash", "turn_id": "T1", "session_id": "S"]) == nil,
          "work in the same turn keeps the question")
    check(step(stillOpen, "codex", "Stop", ["turn_id": "T1", "session_id": "S", "last_assistant_message": "Posted."]) == stillOpen,
          "the end of the turn keeps the question")
    let needsOK = step(stillOpen, "codex", "PermissionRequest", ["tool_name": "Bash", "turn_id": "T1", "session_id": "S"])
    check(needsOK?.kind == .permission && needsOK?.asked == "T1", "a permission shows over the open question")
    check(step(needsOK, "codex", "PostToolUse", ["tool_name": "Bash", "turn_id": "T1", "session_id": "S"])?.kind == .question,
          "and gives way to the question again")
    check(step(stillOpen, "codex", "UserPromptSubmit", ["turn_id": "T2", "session_id": "S"])
          == Watch(kind: .working, since: t, service: "codex", session: "S"), "the answer starts a turn")
    check(step(stillOpen, "codex", "PostToolUse", ["tool_name": "Bash", "turn_id": "T2", "session_id": "S"])?.kind == .working,
          "a later turn's work closes the question")
    check(step(stillOpen, "codex", "PostToolUse", ["tool_name": "Bash", "turn_id": "T9", "session_id": "other"]) == nil,
          "another session's work does not")
    check(step(stillOpen, "codex", "Stop", ["turn_id": "T2", "session_id": "S"])?.kind == .finished,
          "a later turn's end closes the question")
    func stop(_ current: Watch?, transcript: Bool?) -> Watch? {
        transition(from: current, service: "codex", event: "Stop", payload: ["turn_id": "T1", "session_id": "S"],
                   now: t, askedInTranscript: { transcript })
    }
    let working = Watch(kind: .working, since: 1, service: "codex", session: "S")
    check(stop(working, transcript: true) == Watch(kind: .question, since: t, service: "codex", via: "dialog", asked: "T1", session: "S"),
          "the transcript shows a question no hook reported")
    check(stop(working, transcript: false)?.kind == .finished && stop(working, transcript: nil)?.kind == .finished,
          "no question in the transcript")

    // Copilot names its tools in a list, asks through ask_user, and runs permissionRequest for every tool.
    let copilotAsk: [String: Any] = ["sessionId": "C", "toolCalls": [["id": "1", "name": "ask_user", "args": [:] as [String: Any]]]]
    let copilotQuestion = step(Watch(kind: .working, since: 1, service: "copilot", session: "C"), "copilot", "preToolUse", copilotAsk)
    check(copilotQuestion == Watch(kind: .question, since: t, service: "copilot", via: "dialog", session: "C"), "copilot asks through a tool list")
    check(step(copilotQuestion, "copilot", "postToolUse", ["sessionId": "C", "toolName": "ask_user"])?.kind == .working, "copilot got its answer")
    check(step(Watch(kind: .working, since: 1, service: "copilot"), "copilot", "permissionRequest", ["toolName": "bash"]) == nil,
          "copilot's permission hook is no prompt")
    check(step(nil, "copilot", "preToolUse", ["toolCalls": [["name": "view"], ["name": "bash"]]]) == nil, "copilot's other tools change nothing")
    let log = CopilotLog()
    let events = """
        {"type":"permission.requested","timestamp":"1970-01-01T00:16:30.000Z","data":{"requestId":"a"}}
        {"type":"permission.completed","timestamp":"1970-01-01T00:16:30.010Z","data":{"requestId":"a"}}
        {"type":"assistant.message","data":{"content":"about \"permission.requested\""}}
        {"type":"permission.requested","timestamp":"1970-01-01T00:16:38.000Z","data":{"requestId":"b"}}
        """
    check(log.openRequests(in: events, now: t) == [998], "copilot's log shows the one permission still open")

    // A hook end to end, with this process's parent standing in for an extension host.
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("replyclock-selftest-\(getpid())")
    try? FileManager.default.createDirectory(at: hostsDir(home), withIntermediateDirectories: true)
    let name = "Agent 9 [launcher-0123456789]"
    // Where a hook runs, with made-up processes: 9 is VS Code, 7 a window's extension host.
    let names: [pid_t: String] = [5: "bash", 6: "copilot-runtime", 7: "Code Helper (Plugin)", 8: "Code Helper", 9: "Code"]
    func place(_ chain: [pid_t], registered: [pid_t: String] = [:]) -> Origin {
        origin(chain: chain, marker: { registered[$0] }, name: { names[$0] ?? "" }, vscode: { [9] })
    }
    check(place([5, 7, 9], registered: [7: name]) == .window(name), "a hook under an agent window")
    check(place([5, 7, 9]) == .otherWindow, "a hook under a window that is no agent window")
    check(place([5, 6, 8, 9]) == .sharedHost, "a hook under the host all windows share")
    check(place([5, 1]) == .elsewhere, "a hook run outside VS Code")
    try? JSONSerialization.data(withJSONObject: ["marker": name])
        .write(to: hostsDir(home).appendingPathComponent("\(getppid()).json"))
    check(hostMarker(from: getpid(), home: home) == name, "finds the window through parent processes")
    check(origin(of: getpid(), home: home, vscode: { [] }) == .window(name), "this process under a registered parent")
    try? writeWatch(Watch(kind: .finished, since: t, service: "claude"), marker: name, home: home)
    check(readWatch(name, home: home) == Watch(kind: .finished, since: t, service: "claude"), "state round trip")
    let kept = Watch(kind: .question, since: t, service: "codex", via: "dialog", asked: "T1", session: "S")
    try? writeWatch(kept, marker: name, home: home)
    check(readWatch(name, home: home) == kept, "an open question round trip")

    // A session of the shared host is tied to the window in front at its first prompt, and stays.
    let other = "Agent 2 [launcher-0123456789]"
    func tie(_ event: String, session: String = "C1", front: CGWindowID?) -> (marker: String?, note: String) {
        sessionMarker(service: "copilot", event: event, payload: ["sessionId": session], home: home) { front }
    }
    check(tie("userPromptSubmitted", front: 11).marker == nil, "no window list, no tie")
    try? writeJSON(["windows": ["11": name, "22": other]], to: windowIndexURL(home))
    check(tie("preToolUse", front: 11).marker == nil, "only a prompt ties a session")
    check(tie("userPromptSubmitted", front: 99).marker == nil, "a window that is no agent window ties nothing")
    check(tie("userPromptSubmitted", front: 11) == (name, "front-window"), "the first prompt ties the session to the window in front")
    check(tie("agentStop", front: 22) == (name, "session"), "later events follow the session")
    check(tie("userPromptSubmitted", front: 22) == (name, "session"), "a later prompt does not move it")
    check(tie("sessionStart", front: 22).marker == other, "a session that starts again is tied again")
    check(tie("sessionStart", session: "C2", front: 11).marker == name, "sessions are tied one by one")
    try? writeJSON(["windows": ["22": other]], to: windowIndexURL(home))
    check(tie("userPromptSubmitted", session: "C2", front: 22).marker == other, "a session whose window is gone moves on")

    // The end of a Codex transcript: was a question posted since the turn began?
    let transcript = home.appendingPathComponent("rollout.jsonl")
    let ask = #"{"type":"response_item","payload":{"type":"function_call","name":"request_user_input_async","call_id":"c1"}}"#
    let begin = #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"T"}}"#
    let talk = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":"request_user_input_async \"task_started\""}}"#
    func asks(_ lines: [String]) -> Bool? {
        try? Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        return askedWithoutWaiting(inTranscript: transcript.path)
    }
    check(asks([begin, talk, ask, talk]) == true, "a question posted in this turn")
    check(asks([begin, ask, talk, begin, talk]) == false, "a question posted in an earlier turn")
    check(asks([talk, ask]) == true && asks([talk]) == nil, "a transcript that does not show the turn's start")
    let said = #"{"type":"event_msg","payload":{"type":"user_message","message":"<send_user_message_question_reply> request_user_input_async"}}"#
    check(asks([begin, said, ask, talk]) == true, "a question posted after the prompt")
    check(asks([begin, said, ask, said, talk]) == false, "a question answered while its turn still runs")
    check(asks([begin, said, ask, said, talk, ask]) == true, "a second question after the answer")
    // The same from the hooks' side, as Codex ran them: the answer is a prompt in the turn that asked.
    let answered = step(stillOpen, "codex", "UserPromptSubmit", ["turn_id": "T1", "session_id": "S"])
    check(answered == Watch(kind: .working, since: t, service: "codex", session: "S"), "an answer in the same turn sets the agent to work")
    check(step(answered, "codex", "PostToolUse", ["tool_name": "Bash", "turn_id": "T1", "session_id": "S"]) == nil
          && stop(answered, transcript: false)?.kind == .finished, "and its turn ends on the countdown, not on the question")
    check(askedWithoutWaiting(inTranscript: home.appendingPathComponent("none").path) == nil, "no transcript")

    // Sounds: what a window's change of state plays.
    func hear(_ before: Heard?, _ watch: Watch?, at now: Double) -> (cues: [Cue], heard: Heard) {
        sounds(from: before, to: watch, now: now, minutes: 30)
    }
    let met = hear(nil, Watch(kind: .finished, since: t - 60), at: t)
    check(met.cues.isEmpty, "a window met for the first time makes no sound")
    let atWork = hear(met.heard, Watch(kind: .working, since: t), at: t)
    check(atWork.cues.isEmpty, "a prompt makes no sound")
    check(hear(atWork.heard, Watch(kind: .finished, since: t + 60), at: t + 60).cues == [.answer, .tick], "an answer, then the tick")
    check(hear(atWork.heard, Watch(kind: .question, since: t + 60, via: "answer"), at: t + 60).cues == [.answer, .tick],
          "an answer that ends on a question sounds like any other")
    check(hear(met.heard, Watch(kind: .finished, since: t + 60), at: t + 60).cues == [.answer, .tick], "a second answer without a prompt between")
    check(hear(atWork.heard, Watch(kind: .question, since: t + 60, via: "dialog"), at: t + 60).cues == [.question], "a question sounds")
    check(hear(atWork.heard, Watch(kind: .permission, since: t + 60), at: t + 60).cues == [.permission], "a permission sounds")
    check(hear(atWork.heard, nil, at: t + 60).cues.isEmpty, "an interrupted turn is silent")
    var failed = Watch(kind: .finished, since: t + 60)
    failed.failure = "rate_limit"
    check(hear(atWork.heard, failed, at: t + 60).cues == [.fail, .tick], "a turn that ran out of credits")
    failed.failure = "server_error"
    check(hear(atWork.heard, failed, at: t + 60).cues == [.tick], "a turn that failed otherwise only starts the clock")
    let busy = Watch(kind: .working, since: t)
    let seven = hear(atWork.heard, busy, at: t + 420)
    check(hear(atWork.heard, busy, at: t + 419).cues.isEmpty && seven.cues == [.longThinking, .tick], "7 minutes of work")
    check(hear(seven.heard, busy, at: t + 421).cues.isEmpty && hear(seven.heard, busy, at: t + 840).cues == [.longThinking, .tick],
          "and every 7 minutes after")
    let metAtWork = hear(nil, busy, at: t + 500)
    check(hear(metAtWork.heard, busy, at: t + 501).cues.isEmpty && hear(metAtWork.heard, busy, at: t + 840).cues == [.longThinking, .tick],
          "a window met at work keeps its own 7-minute marks")
    let ok = hear(seven.heard, Watch(kind: .permission, since: t + 500), at: t + 500)
    let again = hear(ok.heard, Watch(kind: .working, since: t + 600), at: t + 600)
    check(hear(again.heard, Watch(kind: .working, since: t + 600), at: t + 900).cues.isEmpty
          && hear(again.heard, Watch(kind: .working, since: t + 600), at: t + 1020).cues == [.longThinking, .tick],
          "the 7 minutes start again after a permission")
    let pending = Watch(kind: .question, since: t + 10, service: "codex", via: "dialog", asked: "T1")
    let posed = hear(atWork.heard, pending, at: t + 10)
    let over = hear(posed.heard, Watch(kind: .permission, since: t + 20, asked: "T1"), at: t + 20)
    var back = pending
    back.since = t + 30
    check(posed.cues == [.question] && over.cues == [.permission] && hear(over.heard, back, at: t + 30).cues.isEmpty,
          "an open question that shows again is not announced twice")
    let done = Watch(kind: .finished, since: t)
    let counting = hear(atWork.heard, done, at: t)
    let fiveLeft = hear(counting.heard, done, at: t + 1500)
    check(hear(counting.heard, done, at: t + 1499).cues.isEmpty && fiveLeft.cues == [.lowOnTime], "5 minutes of the reply window left")
    check(hear(fiveLeft.heard, done, at: t + 1501).cues.isEmpty && hear(fiveLeft.heard, done, at: t + 1900).cues.isEmpty,
          "which sounds once per countdown")
    let nextAnswer = hear(fiveLeft.heard, Watch(kind: .finished, since: t + 2000), at: t + 2000)
    check(nextAnswer.cues == [.answer, .tick]
          && hear(nextAnswer.heard, Watch(kind: .finished, since: t + 2000), at: t + 3500).cues == [.lowOnTime], "and again for the next answer")
    check(hear(counting.heard, done, at: t + 1801).cues.isEmpty, "not for a countdown found overdue")
    check(hear(hear(nil, done, at: t + 1600).heard, done, at: t + 1601).cues.isEmpty
          && hear(hear(nil, done, at: t + 100).heard, done, at: t + 1500).cues == [.lowOnTime],
          "a window met with under 5 minutes left stays silent, one met earlier does not")
    check(sounds(from: counting.heard, to: done, now: t + 299, minutes: 10).cues.isEmpty
          && sounds(from: counting.heard, to: done, now: t + 300, minutes: 10).cues == [.lowOnTime],
          "the 5 minutes follow the reply window set in the menu")
    check([100, 50, 49.6, 49.4, 20, 19, 10.4, 1, 0.4].map(creditLevel) == [0, 0, 0, 1, 1, 2, 3, 3, 4], "credit levels")

    // A turn that ended without a hook, in each service's own log.
    let note = #"{"type":"user","isSidechain":false,"timestamp":"1970-01-01T00:16:45.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#
    let queued = #"{"type":"queue-operation","operation":"enqueue","content":"\"type\":\"user\""}"#
    let toolCall = #"{"type":"assistant","isSidechain":false,"timestamp":"1970-01-01T00:16:50.000Z","message":{"role":"assistant","stop_reason":"tool_use","content":[]}}"#
    let limit = #"{"type":"assistant","isSidechain":false,"timestamp":"1970-01-01T00:16:50.000Z","error":"rate_limit","isApiErrorMessage":true,"message":{"role":"assistant","content":[{"type":"text","text":"limit"}]}}"#
    check(claudeTurnEnd(in: [toolCall, note, queued].joined(separator: "\n")) == TurnEnd(at: 1005), "claude: an interrupted turn")
    check(claudeTurnEnd(in: [note, toolCall].joined(separator: "\n")) == nil, "claude: work after an interrupt")
    check(claudeTurnEnd(in: [note, limit].joined(separator: "\n")) == TurnEnd(at: 1010, failure: "rate_limit"), "claude: a turn the usage limit ended")
    let aborted = #"{"timestamp":"1970-01-01T00:16:45.000Z","type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#
    check(codexTurnEnd(in: [begin, talk, aborted, talk].joined(separator: "\n")) == TurnEnd(at: 1005), "codex: an aborted turn")
    check(codexTurnEnd(in: [aborted, begin].joined(separator: "\n")) == nil && codexTurnEnd(in: talk) == nil, "codex: a turn that runs")
    let stopped = #"{"type":"abort","data":{"reason":"user_initiated"},"timestamp":"1970-01-01T00:16:45.000Z"}"#
    let turnEnd = #"{"type":"assistant.turn_end","data":{"turnId":"3"},"timestamp":"1970-01-01T00:16:45.100Z"}"#
    let turnStart = #"{"type":"assistant.turn_start","data":{"turnId":"4"},"timestamp":"1970-01-01T00:16:46.000Z"}"#
    let timedOut = #"{"type":"session.error","data":{"errorType":"query","message":"Execution failed: operation timed out"},"timestamp":"1970-01-01T00:16:45.000Z"}"#
    let noQuota = #"{"type":"session.error","data":{"errorType":"quota","message":"No premium requests left"},"timestamp":"1970-01-01T00:16:45.000Z"}"#
    check(copilotTurnEnd(in: [stopped, turnEnd].joined(separator: "\n")) == TurnEnd(at: 1005), "copilot: an aborted turn")
    check(copilotTurnEnd(in: [stopped, turnEnd, turnStart].joined(separator: "\n")) == nil, "copilot: a turn after an abort")
    check(copilotTurnEnd(in: timedOut) == TurnEnd(at: 1005, failure: "query") && copilotTurnEnd(in: noQuota) == TurnEnd(at: 1005, failure: "quota"),
          "copilot: a turn an error ended")

    // The overlay end to end, on files: a window's state corrected by its log, and the sounds due.
    let tracker = Tracker()
    let key = fileKey(name)
    func record(_ kind: Kind, since: Double, log lines: [String]) {
        try? Data(lines.joined(separator: "\n").utf8).write(to: transcript)
        var watch = Watch(kind: kind, since: since, service: "claude", session: "S")
        watch.transcript = transcript.path
        try? writeWatch(watch, marker: name, home: home)
    }
    func listen(at now: Double) -> [[Cue]] {
        tracker.dueSounds(tracker.readStates(now: now, home: home), now: now, minutes: 30, home: home).map(\.cues)
    }
    try? FileManager.default.removeItem(at: hostsDir(home).appendingPathComponent("\(getppid()).json"))
    record(.working, since: t, log: [toolCall])
    check(listen(at: t).isEmpty, "a closed window makes no sound")
    try? writeJSON(["marker": name, "pid": Int(getpid())], to: hostsDir(home).appendingPathComponent("\(getpid()).json"))
    check(listen(at: t).isEmpty && tracker.heard[key]?.stage == "working", "an open window is listened to")
    check(listen(at: t + 420) == [[.longThinking, .tick]], "the overlay hears 7 minutes of work")
    record(.working, since: t, log: [toolCall, note])
    check(tracker.readStates(now: t + 430, home: home)[key] == nil && listen(at: t + 840).isEmpty,
          "an interrupted turn shows nothing and stops the 7-minute sound")
    record(.working, since: 1006, log: [toolCall, note])
    check(tracker.readStates(now: 1007, home: home)[key]?.kind == .working, "an interrupt before the prompt is an older turn's")
    record(.permission, since: t, log: [note, limit])
    let ranOut = tracker.readStates(now: 1011, home: home)[key]
    check(ranOut?.kind == .finished && ranOut?.since == 1010 && ranOut?.failure == "rate_limit" && listen(at: 1011) == [[.fail, .tick]],
          "a turn the usage limit ended starts the reply window and sounds the failure")
    func meters(_ left: [String: Double]) -> [[Cue]] {
        try? writeJSON(["meters": left.map { ["name": $0.key, "left": $0.value] as [String: Any] }], to: usageURL(home))
        tracker.usageRead = nil
        return listen(at: 1012)
    }
    check(meters(["Claude 5-hour": 51, "Codex Weekly": 80]).isEmpty, "credit meters met for the first time make no sound")
    check(meters(["Claude 5-hour": 49, "Codex Weekly": 49]) == [[.credits50]], "two meters under 50% sound once")
    check(meters(["Claude 5-hour": 48, "Codex Weekly": 49]).isEmpty, "a meter sounds once per level")
    check(meters(["Claude 5-hour": 8, "Codex Weekly": 18]) == [[.credits10], [.credits20]], "a meter that skips a level sounds the lower one")
    check(meters(["Claude 5-hour": 0, "Codex Weekly": 100]) == [[.fail]], "a meter with nothing left")
    check(meters(["Claude 5-hour": 100, "Codex Weekly": 100]).isEmpty && meters(["Claude 5-hour": 19]) == [[.credits20]],
          "a meter that was reset sounds again")
    try? FileManager.default.removeItem(at: home)

    print(failures == 0 ? "Reply Clock self-test passed" : "Reply Clock self-test: \(failures) failure(s)")
    return failures == 0 ? 0 : 1
}

// MARK: - Main

let arguments = CommandLine.arguments
if arguments.count >= 3, arguments[1] == "--hook" {
    exit(runHook(service: arguments[2], event: arguments.count >= 4 ? arguments[3] : nil))
}
if arguments.count >= 2, arguments[1] == "--selftest" { exit(selftest()) }
if arguments.count >= 3, arguments[1] == "--preview" {
    renderPreviews(to: URL(fileURLWithPath: arguments[2]))
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

import AppKit
import CoreGraphics
import ApplicationServices

struct Display {
    let id: Int
    let key: String
    let name: String
    let frame: NSRect
    let visible: NSRect
    let builtIn: Bool
}

func connectedDisplays() -> [Display] {
    NSScreen.screens.compactMap { screen in
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let id = number.intValue
        let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(id))?.takeRetainedValue()
        let key = uuid.map { CFUUIDCreateString(nil, $0) as String } ?? String(id)
        var visible = screen.visibleFrame
        let menuBottom = screen.frame.maxY - max(25, screen.safeAreaInsets.top)
        if visible.maxY > menuBottom { visible.size.height -= visible.maxY - menuBottom }
        return Display(id: id, key: key, name: screen.localizedName, frame: screen.frame,
                       visible: visible, builtIn: CGDisplayIsBuiltin(CGDirectDisplayID(id)) != 0)
    }.sorted { a, b in a.frame.minX == b.frame.minX ? a.frame.maxY > b.frame.maxY : a.frame.minX < b.frame.minX }
}

func grid(_ rect: NSRect, _ count: Int) -> (Int, Int) {
    let portrait = rect.height > rect.width
    switch count {
    case 0, 1: return (1, 1)
    case 2, 3: return portrait ? (1, count) : (count, 1)
    case 4: return (2, 2)
    case 5, 6: return portrait ? (2, 3) : (3, 2)
    default:
        let cols = (1...count).min { a, b in
            func score(_ c: Int) -> Double {
                let rows = Int(ceil(Double(count) / Double(c)))
                return abs(log(Double(rect.width / CGFloat(c) / (rect.height / CGFloat(rows))) / 1.3)) + 0.7 * Double(c * rows - count)
            }
            return score(a) < score(b)
        }!
        return (cols, Int(ceil(Double(count) / Double(cols))))
    }
}

class FlippedView: NSView { override var isFlipped: Bool { true } }

class Preview: FlippedView {
    var displays: [Display] = []
    var allocation: [Int: Int] = [:]
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
        guard let first = displays.first else { return }
        let world = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let scale = min((bounds.width - 36) / world.width, (bounds.height - 24) / world.height)
        let ox = (bounds.width - world.width * scale) / 2
        let oy = (bounds.height - world.height * scale) / 2
        var agent = 1
        for display in displays {
            let r = NSRect(x: ox + (display.frame.minX - world.minX) * scale,
                           y: oy + (world.maxY - display.frame.maxY) * scale,
                           width: display.frame.width * scale, height: display.frame.height * scale)
            let count = allocation[display.id, default: 0]
            let border = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
            (count > 0 ? NSColor.controlAccentColor.withAlphaComponent(0.1) : NSColor.quaternaryLabelColor.withAlphaComponent(0.1)).setFill()
            border.fill()
            (count > 0 ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            border.lineWidth = count > 0 ? 2 : 1
            border.stroke()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            let label = display.builtIn ? "Laptop" : display.name
            (label as NSString).draw(in: NSRect(x: r.minX + 5, y: r.minY + 5, width: r.width - 10, height: 15),
                                    withAttributes: [.font: NSFont.systemFont(ofSize: 9, weight: .medium), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            guard count > 0 else { continue }
            let (columns, rows) = grid(display.visible, count)
            let inside = NSRect(x: r.minX + 5, y: r.minY + 23, width: r.width - 10, height: max(4, r.height - 28))
            for i in 0..<count {
                let cell = NSRect(x: inside.minX + CGFloat(i % columns) * inside.width / CGFloat(columns) + 1,
                                  y: inside.minY + CGFloat(i / columns) * inside.height / CGFloat(rows) + 1,
                                  width: inside.width / CGFloat(columns) - 2, height: inside.height / CGFloat(rows) - 2)
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 2, yRadius: 2).fill()
                let text = String(agent) as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor]
                let size = text.size(withAttributes: attrs)
                if cell.height > 10 && cell.width > 10 {
                    text.draw(at: NSPoint(x: cell.midX - size.width / 2, y: cell.midY - size.height / 2), withAttributes: attrs)
                }
                agent += 1
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, NSWindowDelegate {
    var window: NSWindow!
    var root: FlippedView!
    var displays = connectedDisplays()
    var allocation: [Int: Int] = [:]
    var total = 6
    var running = false
    var process: Process?
    var project = ""
    let defaults = UserDefaults.standard
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AgentLauncher")
    var folderLabel: NSTextField!
    var totalField: NSTextField!
    var totalStepper: NSStepper!
    var displayDocument = FlippedView()
    var checks: [Int: NSButton] = [:]
    var fields: [Int: NSTextField] = [:]
    var steppers: [Int: NSStepper] = [:]
    var controls: [NSControl] = []
    var preview: Preview!
    var summary: NSTextField!
    var status: NSTextField!
    var launchButton: NSButton!
    var chatButton: NSButton!
    var spinner: NSProgressIndicator!
    var activity = ""
    var activeLogURL: URL?
    var logWindow: NSWindow?
    var logView: NSTextView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        project = defaults.string(forKey: "project") ?? (Bundle.main.object(forInfoDictionaryKey: "AgentDefaultProject") as? String ?? FileManager.default.homeDirectoryForCurrentUser.path)
        let saved = defaults.dictionary(forKey: "allocation") ?? [:]
        for d in displays {
            if let count = saved[d.key] as? Int, count > 0 { allocation[d.id] = min(count, 24) }
        }
        if allocation.isEmpty, let first = displays.first { allocation[first.id] = 6 }
        total = allocation.values.reduce(0, +)
        buildMenu()
        buildWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--launch-last") || CommandLine.arguments.contains("--lifecycle-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.launch(nil) }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--smoke-test"), CommandLine.arguments.count > index + 1 {
            let output = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let original = self.allocation
                let originalTotal = self.total
                if self.displays.count >= 2 {
                    let left = self.displays[0].id, right = self.displays.last!.id
                    self.allocation = [left: 1, right: 1]; self.total = 8; self.balance()
                    precondition(self.allocation[left] == 4 && self.allocation[right] == 4)
                    self.setDisplayCount(left, 3)
                    precondition(self.total == 7 && self.allocation[right] == 4)
                    let request: [String: Any] = ["project": self.project, "open_chat": false,
                        "allocations": [["screen_id": left, "count": 3], ["screen_id": right, "count": 4]]]
                    try! JSONSerialization.data(withJSONObject: request).write(to: URL(fileURLWithPath: output + ".request.json"))
                }
                self.allocation = original; self.total = originalTotal; self.update()
                self.window.displayIfNeeded()
                if let rep = self.root.bitmapImageRepForCachingDisplay(in: self.root.bounds) {
                    self.root.cacheDisplay(in: self.root.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output))
                }
                print("UI smoke test: \(self.displays.count) displays; balanced and custom allocation passed; \(self.total) windows; launch enabled=\(self.launchButton.isEnabled)")
                NSApp.terminate(nil)
            }
        }
    }

    func buildMenu() {
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Agent Launcher", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Agent Launcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu
        menu.addItem(item)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @discardableResult func label(_ text: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat = 22, _ size: CGFloat = 13, _ weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        field.font = .systemFont(ofSize: size, weight: weight)
        root.addSubview(field)
        return field
    }
    @discardableResult func button(_ title: String, _ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.frame = NSRect(x: x, y: y, width: width, height: 30)
        b.bezelStyle = .rounded
        root.addSubview(b)
        controls.append(b)
        return b
    }
    func numberField(_ value: Int, _ tag: Int, _ frame: NSRect) -> NSTextField {
        let field = NSTextField(frame: frame)
        field.integerValue = value
        field.alignment = .center
        field.tag = tag
        field.delegate = self
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = 0
        formatter.maximum = 24
        field.formatter = formatter
        return field
    }
    func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 776), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Agent Launcher"
        window.appearance = NSAppearance(named: .aqua)
        window.delegate = self
        window.isReleasedWhenClosed = false
        root = FlippedView(frame: NSRect(x: 0, y: 0, width: 820, height: 776))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.96, alpha: 1).cgColor
        window.contentView = root
        label("Agent Launcher", 28, 22, 700, 36, 28, .bold)
        label("Choose your project, agent windows, and displays.", 29, 64, 760).textColor = .secondaryLabelColor
        label("PROJECT FOLDER", 30, 102, 600, 18, 11, .semibold).textColor = .secondaryLabelColor
        folderLabel = label(project, 30, 126, 640, 28)
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.isSelectable = true
        button("Choose…", 685, 120, 105, #selector(chooseProject))
        label("Total agent windows", 30, 174, 160, 26, 14, .medium)
        totalField = numberField(total, -1, NSRect(x: 188, y: 171, width: 48, height: 26))
        totalField.setAccessibilityLabel("Total agent windows")
        root.addSubview(totalField)
        totalStepper = NSStepper(frame: NSRect(x: 243, y: 169, width: 20, height: 30))
        totalStepper.minValue = 1; totalStepper.maxValue = 24; totalStepper.integerValue = total
        totalStepper.target = self; totalStepper.action = #selector(totalChanged)
        root.addSubview(totalStepper)
        button("Distribute evenly", 292, 168, 155, #selector(distributeEvenly))
        label("Adjust a display count below for a custom split.", 30, 205, 640, 18, 12).textColor = .secondaryLabelColor
        label("DISPLAYS · LEFT TO RIGHT", 30, 234, 600, 18, 11, .semibold).textColor = .secondaryLabelColor
        button("Refresh", 694, 224, 96, #selector(refreshDisplays))
        let scroll = NSScrollView(frame: NSRect(x: 28, y: 262, width: 764, height: 152))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = displayDocument
        root.addSubview(scroll)
        preview = Preview(frame: NSRect(x: 28, y: 430, width: 764, height: 150))
        root.addSubview(preview)
        summary = label("", 30, 594, 760, 24, 13, .medium)
        chatButton = NSButton(checkboxWithTitle: "Show only Codex chat in each window", target: nil, action: nil)
        chatButton.frame = NSRect(x: 28, y: 625, width: 700, height: 24)
        chatButton.state = defaults.object(forKey: "openChat") == nil || defaults.bool(forKey: "openChat") ? .on : .off
        root.addSubview(chatButton)
        label("One-time setup. The launcher closes when the windows are ready.", 30, 652, 760, 20, 12).textColor = .secondaryLabelColor
        status = label("", 30, 681, 760, 34, 12)
        status.maximumNumberOfLines = 2
        spinner = NSProgressIndicator(frame: NSRect(x: 30, y: 713, width: 760, height: 5))
        spinner.style = .bar; spinner.isIndeterminate = true; spinner.isDisplayedWhenStopped = false
        root.addSubview(spinner)
        button("View activity…", 24, 731, 130, #selector(showActivity))
        button("macOS permissions…", 157, 731, 172, #selector(openPermissions))
        launchButton = button("Open agent windows", 592, 728, 204, #selector(launch))
        launchButton.keyEquivalent = "\r"
        launchButton.bezelColor = .controlAccentColor
        buildDisplayRows()
        update()
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func buildDisplayRows() {
        displayDocument.subviews.forEach { $0.removeFromSuperview() }
        checks.removeAll(); fields.removeAll(); steppers.removeAll()
        displayDocument.frame = NSRect(x: 0, y: 0, width: 744, height: max(152, displays.count * 52))
        for (index, d) in displays.enumerated() {
            let y = CGFloat(index * 52)
            let check = NSButton(checkboxWithTitle: "\(index + 1). \(d.builtIn ? "Laptop — " : "")\(d.name)", target: self, action: #selector(selectionChanged))
            check.tag = d.id
            check.frame = NSRect(x: 0, y: y + 1, width: 540, height: 25)
            check.font = .systemFont(ofSize: 13, weight: .medium)
            displayDocument.addSubview(check)
            checks[d.id] = check
            let detail = NSTextField(labelWithString: "\(Int(d.visible.width)) × \(Int(d.visible.height)) points · \(d.frame.height > d.frame.width ? "Portrait" : "Landscape")")
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = .secondaryLabelColor
            detail.frame = NSRect(x: 23, y: y + 27, width: 490, height: 18)
            displayDocument.addSubview(detail)
            let field = numberField(allocation[d.id, default: 0], d.id, NSRect(x: 605, y: y + 8, width: 45, height: 26))
            field.setAccessibilityLabel("Windows on \(d.name)")
            displayDocument.addSubview(field)
            fields[d.id] = field
            let stepper = NSStepper(frame: NSRect(x: 657, y: y + 6, width: 20, height: 30))
            stepper.minValue = 0; stepper.maxValue = 24; stepper.tag = d.id
            stepper.target = self; stepper.action = #selector(displayCountChanged)
            displayDocument.addSubview(stepper)
            steppers[d.id] = stepper
            let suffix = NSTextField(labelWithString: "windows")
            suffix.frame = NSRect(x: 685, y: y + 13, width: 59, height: 20)
            suffix.font = .systemFont(ofSize: 11)
            suffix.textColor = .secondaryLabelColor
            displayDocument.addSubview(suffix)
        }
    }

    func update() {
        totalField.integerValue = total
        totalStepper.integerValue = total
        for d in displays {
            checks[d.id]?.state = allocation[d.id, default: 0] > 0 ? .on : .off
            checks[d.id]?.isEnabled = !running
            fields[d.id]?.integerValue = allocation[d.id, default: 0]
            fields[d.id]?.isEnabled = !running
            steppers[d.id]?.integerValue = allocation[d.id, default: 0]
            steppers[d.id]?.isEnabled = !running
        }
        totalField.isEnabled = !running; totalStepper.isEnabled = !running; chatButton.isEnabled = !running
        controls.forEach { $0.isEnabled = !running }
        preview.displays = displays; preview.allocation = allocation; preview.needsDisplay = true
        let selected = displays.filter { allocation[$0.id, default: 0] > 0 }
        let actual = allocation.values.reduce(0, +)
        var isDirectory: ObjCBool = false
        let projectExists = FileManager.default.fileExists(atPath: project, isDirectory: &isDirectory) && isDirectory.boolValue
        let valid = actual == total && total > 0 && total <= 24 && !selected.isEmpty && projectExists
        launchButton.isEnabled = valid && !running
        summary.stringValue = "\(actual) agent window\(actual == 1 ? "" : "s") across \(selected.count) display\(selected.count == 1 ? "" : "s")"
        if !running {
            if selected.isEmpty { status.stringValue = "Select a display to place your agent windows." }
            else if total > 24 { status.stringValue = "Choose up to 24 windows in total." }
            else {
                let small = selected.contains { d in
                    let (c, r) = grid(d.visible, allocation[d.id]!)
                    return d.visible.width / CGFloat(c) < 400 || d.visible.height / CGFloat(r) < 270
                }
                status.stringValue = small ? "Some tiles are small; VS Code may need more space. Reduce the count or add a display." : "Ready. Your choices will be remembered for next time."
            }
        }
    }

    func balance() {
        let selected = displays.filter { allocation[$0.id, default: 0] > 0 }
        guard !selected.isEmpty else { update(); return }
        total = max(total, selected.count)
        for (i, d) in selected.enumerated() { allocation[d.id] = total / selected.count + (i < total % selected.count ? 1 : 0) }
        update()
    }
    @objc func totalChanged(_ sender: NSStepper) { total = sender.integerValue; balance() }
    @objc func distributeEvenly(_ sender: Any?) { balance() }
    @objc func selectionChanged(_ sender: NSButton) {
        if sender.state == .on { allocation[sender.tag] = 1 } else { allocation.removeValue(forKey: sender.tag) }
        balance()
    }
    @objc func displayCountChanged(_ sender: NSStepper) {
        setDisplayCount(sender.tag, sender.integerValue)
    }
    func setDisplayCount(_ id: Int, _ count: Int) {
        if count > 0 { allocation[id] = count } else { allocation.removeValue(forKey: id) }
        total = allocation.values.reduce(0, +)
        update()
    }
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field.tag == -1 { total = max(1, min(24, field.integerValue)); balance() }
        else { setDisplayCount(field.tag, max(0, min(24, field.integerValue))) }
    }
    @objc func chooseProject(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Use project"
        panel.directoryURL = URL(fileURLWithPath: project)
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url { self.project = url.path; self.folderLabel.stringValue = url.path; self.update() }
        }
    }
    @objc func displaysChanged(_ notification: Notification) { if !running { refreshDisplays(nil) } }
    @objc func refreshDisplays(_ sender: Any?) {
        let old = Dictionary(uniqueKeysWithValues: displays.map { ($0.key, allocation[$0.id, default: 0]) })
        displays = connectedDisplays()
        allocation = [:]
        for d in displays { if let n = old[d.key], n > 0 { allocation[d.id] = n } }
        total = allocation.values.reduce(0, +)
        buildDisplayRows(); update()
    }

    @objc func launch(_ sender: Any?) {
        window.makeFirstResponder(nil)
        guard launchButton.isEnabled else { return }
        let dryRun = CommandLine.arguments.contains("--lifecycle-test")
        if !dryRun && !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            status.stringValue = "Allow Agent Launcher in macOS Accessibility settings, then click Open agent windows again."
            return
        }
        let selected = displays.filter { allocation[$0.id, default: 0] > 0 }
        let request: [String: Any] = ["project": project, "open_chat": chatButton.state == .on,
            "allocations": selected.map { ["screen_id": $0.id, "count": allocation[$0.id]!] }]
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let requestURL = support.appendingPathComponent("request-\(UUID().uuidString).json")
            try JSONSerialization.data(withJSONObject: request, options: .prettyPrinted).write(to: requestURL, options: .atomic)
            if !dryRun {
                defaults.set(project, forKey: "project")
                defaults.set(Dictionary(uniqueKeysWithValues: selected.map { ($0.key, allocation[$0.id]!) }), forKey: "allocation")
                defaults.set(chatButton.state == .on, forKey: "openChat")
            }
            let backend = Bundle.main.resourceURL!.appendingPathComponent("agent_launcher.py")
            let python = Bundle.main.object(forInfoDictionaryKey: "AgentPythonExecutable") as? String ?? "/usr/bin/python3"
            let task = Process()
            task.executableURL = URL(fileURLWithPath: python)
            task.arguments = ["-u", backend.path, "--request", requestURL.path]
            if dryRun { task.arguments!.append("--dry-run") }
            var env = ProcessInfo.processInfo.environment
            env.removeValue(forKey: "ELECTRON_RUN_AS_NODE"); env.removeValue(forKey: "VSCODE_IPC_HOOK_CLI")
            env["PYTHONUNBUFFERED"] = "1"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            task.environment = env
            activity = "Opening \(total) agent windows…\n"
            let logURL = support.appendingPathComponent(dryRun ? "lifecycle-test.log" : "last-run.log")
            activeLogURL = logURL
            try activity.write(to: logURL, atomically: true, encoding: .utf8)
            let outputHandle = try FileHandle(forWritingTo: logURL)
            try outputHandle.seekToEnd()
            task.standardOutput = outputHandle; task.standardError = outputHandle
            task.terminationHandler = { finished in
                DispatchQueue.main.async {
                    self.activity = (try? String(contentsOf: logURL, encoding: .utf8)) ?? self.activity
                    self.running = false; self.process = nil
                    self.spinner.stopAnimation(nil)
                    self.update()
                    self.status.stringValue = finished.terminationStatus == 0 ? "Finished. Your agent windows are ready." : "The layout could not finish. Open View activity for details and permission instructions."
                    try? FileManager.default.removeItem(at: requestURL)
                    if finished.terminationStatus == 0 {
                        // No helper, polling timer, or chooser remains after a
                        // successful launch. The Desktop icon opens it again.
                        NSApp.terminate(nil)
                    } else { self.showActivity(nil) }
                }
            }
            running = true; process = task; update()
            status.stringValue = "Opening windows… Leave the keyboard and mouse idle while the layout runs."
            spinner.startAnimation(nil)
            try task.run()
            // The child owns its inherited descriptor. Closing the parent's
            // copy avoids pipe readers or retained handles holding setup open.
            try? outputHandle.close()
            // Keep this window from regaining focus during focus-bound actions.
            window.orderBack(nil)
        } catch {
            running = false; process = nil; spinner.stopAnimation(nil); update()
            status.stringValue = "Could not launch: \(error.localizedDescription)"
        }
    }
    func appendActivity(_ text: String) {
        activity += text
        logView?.string = activity
        logView?.scrollToEndOfDocument(nil)
        if running, let line = text.split(separator: "\n").last { status.stringValue = String(line) }
    }
    @objc func showActivity(_ sender: Any?) {
        if let url = activeLogURL, let text = try? String(contentsOf: url, encoding: .utf8) { activity = text }
        if logWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Agent Launcher — Activity"; w.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: w.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.autoresizingMask = [.width]; text.isVerticallyResizable = true
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; w.contentView!.addSubview(scroll)
            logView = text; logWindow = w; w.center()
        }
        logView?.string = activity.isEmpty ? "Activity will appear here when you open a layout." : activity
        logWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func openPermissions(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !running }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if running { status.stringValue = "The layout is still running. You can quit after it finishes."; window.makeKeyAndOrderFront(nil); return .terminateCancel }
        return .terminateNow
    }
}

func renderIcon(_ path: String) {
    let size = NSSize(width: 1024, height: 1024)
    let image = NSImage(size: size, flipped: false) { rect in
        NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect.insetBy(dx: 36, dy: 36), xRadius: 210, yRadius: 210).fill()
        for row in 0..<2 { for col in 0..<3 {
            let cell = NSRect(x: 150 + col * 248, y: 200 + row * 315, width: 224, height: 280)
            NSColor(calibratedRed: 0.28 + Double(col) * 0.08, green: 0.66, blue: 0.96, alpha: 1).setFill()
            NSBezierPath(roundedRect: cell, xRadius: 28, yRadius: 28).fill()
            NSColor.white.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: NSRect(x: cell.minX + 27, y: cell.maxY - 53, width: 94, height: 10), xRadius: 5, yRadius: 5).fill()
        } }
        return true
    }
    if let data = image.tiffRepresentation, let rep = NSBitmapImageRep(data: data), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: path))
    }
}

if CommandLine.arguments.contains("--self-test") {
    let output: [[String: Any]] = connectedDisplays().map { d in
        ["id": d.id, "key": d.key, "name": d.name, "builtIn": d.builtIn,
         "width": d.visible.width, "height": d.visible.height]
    }
    print(String(data: try! JSONSerialization.data(withJSONObject: output, options: .prettyPrinted), encoding: .utf8)!)
} else if let i = CommandLine.arguments.firstIndex(of: "--render-icon"), CommandLine.arguments.count > i + 1 {
    renderIcon(CommandLine.arguments[i + 1])
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}

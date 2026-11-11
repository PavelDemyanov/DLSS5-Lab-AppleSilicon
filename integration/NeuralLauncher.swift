import AppKit
import Carbon
import Darwin

@main struct NeuralLauncher {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = NeuralLauncherDelegate()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class NeuralLauncherDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var status: NSTextField!
    private var shortcutLabel: NSTextField!
    private var startButton: NSButton!
    private var enableButton: NSButton!
    private var process: Process?
    private var activeRun: URL?
    private var cancellationInProgress = false
    private var cancellationRequested = false
    private var quitAfterCancellation = false
    private var timer: Timer?
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var runtime: URL { Bundle.main.resourceURL!.appendingPathComponent("runtime", isDirectory: true) }
    private var artifacts: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/HTInGameLab", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "HT in Cyberpunk — Experimental"
        window.isReleasedWhenClosed = false
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        let title = NSTextField(labelWithString: "HT In-Game Processing")
        title.font = .boldSystemFont(ofSize: 22)
        let text = NSTextField(wrappingLabelWithString: "Independent HT neural processing, not NVIDIA DLSS.\n\nPress comma (,) to show or hide the compact panel in the lower-right corner during gameplay. Tab or ↑↓ selects a setting, ←→ adjusts it, and Shift gives finer steps. The panel includes HT on/off, three sliders, processing resolution, and an original/processed comparison. Period (.) toggles HT even when the panel is closed. Esc also closes the panel. Shortcuts use the same physical keys on any keyboard layout.\n\nHDR must be off. Lower processing resolution improves speed at the cost of detail. Keep Steam open. Close Cyberpunk and the old Lab before launching.")
        text.font = .systemFont(ofSize: 14)
        startButton = NSButton(title: "Launch Cyberpunk", target: self, action: #selector(start))
        enableButton = NSButton(title: "Enable HT (HDR must be off)", target: self, action: #selector(enable))
        enableButton.isEnabled = false
        let stop = NSButton(title: "Emergency stop / Cancel launch", target: self, action: #selector(disable))
        shortcutLabel = NSTextField(labelWithString: "Checking the emergency shortcut…")
        shortcutLabel.font = .systemFont(ofSize: 12)
        status = NSTextField(wrappingLabelWithString: "Ready to launch. Period (.) toggles HT. An emergency stop requires restarting the game.")
        [title, text, startButton, enableButton, stop, shortcutLabel, status].forEach { stack.addArrangedSubview($0) }
        window.contentView = stack; window.center(); window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let item = NSMenuItem(); let submenu = NSMenu()
        submenu.addItem(withTitle: "Emergency stop HT", action: #selector(disable), keyEquivalent: "")
        submenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = submenu; menu.addItem(item); NSApplication.shared.mainMenu = menu
        registerStopKey()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    private func errorSummary(_ error: Error) -> String {
        let detail = error as NSError
        return "\(detail.domain) (code \(detail.code))"
    }

    private func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func controlRun() -> URL? {
        if let activeRun { return activeRun }
        guard let path = json(artifacts.appendingPathComponent("current-neural-run.json"))?["run"] as? String else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        let parent = artifacts.appendingPathComponent("runs").standardizedFileURL.resolvingSymlinksInPath()
        return url.deletingLastPathComponent() == parent ? url : nil
    }

    @objc private func start() {
        guard process == nil, !cancellationInProgress else { return }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            status.stringValue = "Python 3 from Apple's developer tools is required. Install the documented Xcode/Command Line Tools prerequisites, then retry. The game was not started."
            return
        }
        let run = artifacts.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let child = Process()
        do {
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            // This exact token and control inode exist before the child starts.
            try Data("{\"phase\":\"preflight\"}\n".utf8).write(to: run.appendingPathComponent("launch.lock"), options: .atomic)
            activeRun = run; cancellationRequested = false
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.currentDirectoryURL = runtime
            child.arguments = ["-B", runtime.appendingPathComponent("launch_neural.py").path, "--run-directory", run.path]
            let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in
                    guard let self, self.activeRun == run, !self.cancellationRequested else { return }
                    self.status.stringValue = message.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            child.terminationHandler = { [weak self] _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    guard let self, self.activeRun == run else { return }
                    self.process = nil; self.startButton.isEnabled = !self.cancellationInProgress
                    self.enableButton.isEnabled = false
                }
            }
            try child.run(); process = child
            startButton.isEnabled = false; enableButton.isEnabled = false
            status.stringValue = "Checking the game, module, and Steam connection…"
        } catch {
            status.stringValue = "Could not launch the game: " + errorSummary(error)
            startButton.isEnabled = true
        }
    }

    @objc private func enable() {
        guard process?.isRunning == true, !cancellationRequested, let run = activeRun,
              !FileManager.default.fileExists(atPath: run.appendingPathComponent("disable-ht").path) else { return }
        do {
            try Data().write(to: run.appendingPathComponent("enable-ht"), options: .atomic)
            enableButton.isEnabled = false
            status.stringValue = "Enabling HT for compatible SDR frames."
        } catch { status.stringValue = "Could not enable HT: " + errorSummary(error) }
    }

    // Runs outside MainActor. The short lock linearizes cancellation against
    // Python's token-check + Popen + phase publication. It never waits for GPU.
    nonisolated private static func cancel(_ run: URL) throws -> Bool {
        try Data().write(to: run.appendingPathComponent("disable-ht"), options: .atomic)
        let fd = Darwin.open(run.appendingPathComponent("launch.lock").path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { flock(fd, LOCK_UN) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        let phase = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["phase"] as? String
        // Only an explicit pre-spawn phase permits terminating our Python child.
        // Missing PID alone is insufficient: metadata writing can fail after Popen.
        return phase == "preflight" || phase == "cancelled"
    }

    @objc func disable() { beginCancellation(quitAfterward: false) }
    private func beginCancellation(quitAfterward: Bool) {
        quitAfterCancellation = quitAfterCancellation || quitAfterward
        if cancellationInProgress { return }
        guard let run = controlRun() else {
            if quitAfterCancellation { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
            else { status.stringValue = "No active session found." }
            return
        }
        cancellationRequested = true; cancellationInProgress = true
        startButton.isEnabled = false; enableButton.isEnabled = false
        status.stringValue = "Stopping HT and checking launch cancellation…"
        Task { [weak self] in
            let result = await Task.detached { () -> Result<Bool, Error> in
                Result { try Self.cancel(run) }
            }.value
            guard let self else { return }
            self.cancellationInProgress = false
            switch result {
            case .success(let beforeSpawn):
                if beforeSpawn, self.activeRun == run, let child = self.process, child.isRunning {
                    child.terminate() // Proven pre-spawn; token prevents any later Popen.
                }
                self.status.stringValue = beforeSpawn ? "Launch cancelled. The game was not started." : "HT was stopped. The game is still running; restart it to enable HT again."
                self.startButton.isEnabled = self.process == nil
                if self.quitAfterCancellation { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
            case .failure(let error):
                self.status.stringValue = "Could not confirm the stop: " + errorSummary(error)
                if self.quitAfterCancellation {
                    self.quitAfterCancellation = false
                    NSApplication.shared.reply(toApplicationShouldTerminate: false)
                }
            }
        }
    }

    private func refresh() {
        guard !cancellationRequested, process != nil, let run = activeRun else { return }
        guard let log = json(run.appendingPathComponent("neural.json")) else { return }
        let count = log["processed"] as? Int ?? 0
        let disabled = log["disabled"] as? Bool == true
        let installed = log["installed"] as? Bool == true
        let armed = log["armed"] as? Bool == true
        let enabled = log["enabled"] as? Bool ?? armed
        let warming = log["warming"] as? Bool == true
        let recovering = log["recovering"] as? Bool == true
        let requestedEnabled = log["requestedEnabled"] as? Bool ?? enabled
        enableButton.isEnabled = installed && !disabled && !armed
        if disabled {
            status.stringValue = "HT stopped. Restart the game to enable it again. Reason: \(log["lastReason"] as? String ?? "stopped")."
        } else if recovering {
            status.stringValue = requestedEnabled ? "HT is temporarily paused after a delayed frame. Processing will resume automatically when the game delivers a ready frame." : "HT is off. Finishing the previous frame; press period (.) in the game to enable HT."
        } else if !installed || warming {
            status.stringValue = "Preparing HT. The game is showing original frames."
        } else if !armed {
            status.stringValue = "HT is ready but off. With HDR disabled, press period (.) in the game to enable it."
        } else if !enabled {
            status.stringValue = "HT is off. Press period (.) in the game to enable it."
        } else if count > 0 {
            let edge = log["processingLongEdge"] as? Int ?? 1920
            status.stringValue = "HT is on at \(edge). Frames processed: \(count). In-game settings: comma (,)."
        } else {
            status.stringValue = "Waiting for a compatible SDR frame. \(log["lastReason"] as? String ?? "")"
        }
    }

    private func registerStopKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard result == noErr, key.signature == 0x4E524854, key.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<NeuralLauncherDelegate>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in owner.disable() }; return noErr
        }, 1, &spec, pointer, &eventHandler)
        guard handlerStatus == noErr else {
            shortcutLabel.stringValue = "Could not register the emergency shortcut. Use the stop button."
            return
        }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_0), UInt32(cmdKey | optionKey), EventHotKeyID(signature: 0x4E524854, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        shortcutLabel.stringValue = result == noErr ? "Emergency stop: ⌥⌘0. Panel: comma (,). Toggle HT: period (.)." : "Emergency shortcut is unavailable. Use the stop button."
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard process != nil || cancellationInProgress else { return .terminateNow }
        beginCancellation(quitAfterward: true)
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

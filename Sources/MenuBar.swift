import AppKit

struct MenuState: Equatable {
    let mode: RoutingMode
    let root: URL
    let isExternal: Bool
    let error: String?

    var storageTitle: String {
        if isExternal { return "Caches: DevCache SSD" }
        return mode == .main ? "Caches: Main drive" : "Caches: Main drive (DevCache unavailable)"
    }

    var symbol: String { isExternal ? "externaldrive" : "internaldrive" }
}

final class CacheMenuBar: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let router: Router
    let worker = DispatchQueue(label: "local.dev-cache-router.storage", qos: .utility)
    let statusItem: NSStatusItem
    let menu = NSMenu()
    let storageItem = NSMenuItem(title: "Checking cache storage...", action: nil, keyEquivalent: "")
    let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let automaticItem = NSMenuItem(title: "Switch Automatically", action: #selector(toggleAutomatic), keyEquivalent: "")
    let mainItem = NSMenuItem(title: "Use Main Drive (Manual)", action: #selector(useMain), keyEquivalent: "")
    let devItem = NSMenuItem(title: "Use DevCache (Manual)", action: #selector(useDev), keyEquivalent: "")
    let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "")
    let ejectItem = NSMenuItem(title: "Safely Eject DevCache...", action: #selector(ejectDrive), keyEquivalent: "")
    private var timer: Timer?
    private var state: MenuState?
    private(set) var busy = false
    private var lastError: String?
    private var showingAlert = false
    private var menuTracking = false
    private var pendingUpdate: (Result<MenuState, Error>, Bool)?

    init(router: Router) {
        self.router = router
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        storageItem.isEnabled = false
        errorItem.isEnabled = false
        errorItem.isHidden = true
        menu.addItem(storageItem)
        menu.addItem(errorItem)
        menu.addItem(.separator())
        for item in [automaticItem, mainItem, devItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        refreshItem.target = self
        menu.addItem(refreshItem)
        ejectItem.target = self
        menu.addItem(ejectItem)
        menu.addItem(.separator())
        let logs = NSMenuItem(title: "Open Process Logs...", action: #selector(openLogs), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)
        let folder = NSMenuItem(title: "Open Active Cache Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        statusItem.menu = menu
        statusItem.button?.title = "Cache"
        statusItem.button?.setAccessibilityLabel("Development caches: checking storage")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("Native menu-bar manager started")
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func render(_ state: MenuState) {
        guard state != self.state else { return }
        self.state = state
        storageItem.title = state.storageTitle
        automaticItem.state = state.mode == .automatic ? .on : .off
        mainItem.state = state.mode == .main ? .on : .off
        devItem.state = state.mode == .dev ? .on : .off
        errorItem.isHidden = state.error == nil
        errorItem.title = state.error == nil ? "" : "Error - open process logs for details"
        errorItem.toolTip = state.error
        statusItem.button?.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.storageTitle)
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = state.error == nil ? "" : "!"
        statusItem.button?.toolTip = "\(state.storageTitle)\n\(state.mode.title)\(state.error.map { "\nError: \($0)" } ?? "")"
        statusItem.button?.setAccessibilityLabel("\(state.storageTitle), \(state.mode.title)")
    }

    private func setBusy(_ busy: Bool, updateControls: Bool) {
        self.busy = busy
        if updateControls {
            for item in [automaticItem, mainItem, devItem, ejectItem, refreshItem] {
                item.isEnabled = !busy
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) { menuTracking = true }

    func menuDidClose(_ menu: NSMenu) {
        menuTracking = false
        if let (result, notify) = pendingUpdate {
            pendingUpdate = nil
            completeRefresh(result, notifyOnError: notify)
        }
    }

    func refresh(mode: RoutingMode? = nil, eject: Bool = false, notifyOnError: Bool = false) {
        guard !busy, !showingAlert, !menuTracking else { return }
        setBusy(true, updateControls: notifyOnError)
        worker.async { [router] in
            let result: Result<MenuState, Error> = Result {
                try router.locked {
                    var operationError: String?
                    do {
                        if let mode = mode { try router.setMode(mode) }
                        if eject { try router.eject() }
                        _ = try router.sync()
                    } catch {
                        operationError = String(describing: error)
                    }
                    guard let target = try router.target() else {
                        throw RouterError("Cache routing is not initialized")
                    }
                    return MenuState(mode: try router.mode(), root: URL(fileURLWithPath: target),
                                     isExternal: target != router.local.path, error: operationError)
                }
            }
            DispatchQueue.main.async {
                if self.menuTracking {
                    self.setBusy(false, updateControls: false)
                    self.pendingUpdate = (result, notifyOnError)
                } else {
                    self.completeRefresh(result, notifyOnError: notifyOnError)
                }
            }
        }
    }

    private func completeRefresh(_ result: Result<MenuState, Error>, notifyOnError: Bool) {
        setBusy(false, updateControls: notifyOnError)
        let message: String?
        switch result {
        case .success(let state):
            render(state)
            message = state.error
        case .failure(let error):
            message = String(describing: error)
            if state != nil || message != lastError {
                state = nil
                storageItem.title = "Cache state unavailable"
                errorItem.isHidden = false
                errorItem.title = "Error - open process logs for details"
                statusItem.button?.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Cache routing error")
                statusItem.button?.title = ""
                statusItem.button?.toolTip = message
            }
        }
        if let message = message, message != lastError { log(message) }
        lastError = message
        if notifyOnError, let message = message { alert("Cache operation failed", message) }
    }

    private func alert(_ title: String, _ detail: String) {
        showingAlert = true
        defer { showingAlert = false }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func choose(_ mode: RoutingMode) {
        guard !busy, mode != state?.mode else { return }
        showingAlert = true
        let alert = NSAlert()
        alert.messageText = "Change cache mode to \(mode.title)?"
        alert.informativeText = """
        Pause builds and package installations before switching storage.
        Selecting DevCache clears managed Main-drive fallback caches. Programs that \
        keep resolved cache paths or open files may need restarting.
        """
        alert.addButton(withTitle: "Change Mode")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        showingAlert = false
        if response == .alertFirstButtonReturn { refresh(mode: mode, notifyOnError: true) }
    }

    @objc private func toggleAutomatic() {
        choose(state?.mode == .automatic ? (state?.isExternal == true ? .dev : .main) : .automatic)
    }

    @objc private func useMain() { choose(.main) }
    @objc private func useDev() { choose(.dev) }
    @objc private func refreshNow() { refresh(notifyOnError: true) }

    @objc private func ejectDrive() {
        guard !busy else { return }
        showingAlert = true
        let alert = NSAlert()
        alert.messageText = "Safely eject DevCache?"
        alert.informativeText = "Pause builds and package installations first. Caches will switch to Main before macOS attempts to eject the SSD."
        alert.addButton(withTitle: "Eject")
        alert.addButton(withTitle: "Cancel")
        NSApplication.shared.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        showingAlert = false
        if response == .alertFirstButtonReturn { refresh(eject: true, notifyOnError: true) }
    }

    @objc private func openLogs() {
        let file = router.base.appendingPathComponent("agent.log")
        guard NSWorkspace.shared.open(file) else {
            log("Could not open process log: \(file.path)")
            alert("Could not open process logs", "Log file: \(file.path)")
            return
        }
    }

    @objc private func openFolder() {
        guard let state = state else {
            alert("Cache state unavailable", "Open process logs for details.")
            return
        }
        if !NSWorkspace.shared.open(state.root) {
            log("Could not open active cache folder: \(state.root.path)")
            alert("Could not open active cache folder", state.root.path)
        }
    }
}

func runMenuBar(router: Router) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let controller = CacheMenuBar(router: router)
    app.delegate = controller
    withExtendedLifetime(controller) { app.run() }
}

func testMenuBar() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let router = Router()
    let controller = CacheMenuBar(router: router)
    defer { NSStatusBar.system.removeStatusItem(controller.statusItem) }
    for mode in RoutingMode.allCases {
        for external in [false, true] {
            for error in [nil, "Example routing error"] {
                let state = MenuState(mode: mode, root: router.local, isExternal: external, error: error)
                controller.render(state)
                guard controller.statusItem.button?.image != nil,
                      controller.storageItem.title == state.storageTitle,
                      controller.automaticItem.state == (mode == .automatic ? .on : .off),
                      controller.mainItem.state == (mode == .main ? .on : .off),
                      controller.devItem.state == (mode == .dev ? .on : .off),
                      controller.errorItem.isHidden == (error == nil),
                      controller.statusItem.button?.title == (error == nil ? "" : "!") else {
                    throw RouterError("Native menu rendering failed for \(mode.title)")
                }
            }
        }
    }
    let titles = controller.menu.items.map(\.title)
    guard titles.contains("Open Process Logs..."), titles.contains("Safely Eject DevCache..."),
          titles.contains("Open Active Cache Folder"),
          controller.automaticItem.action != nil, controller.mainItem.action != nil,
          controller.devItem.action != nil,
          controller.automaticItem.target === controller,
          controller.mainItem.target === controller,
          controller.devItem.target === controller else { throw RouterError("Menu controls are missing") }
    let logFile = router.base.appendingPathComponent("agent.log")
    guard NSWorkspace.shared.urlForApplication(toOpen: logFile) != nil else {
        throw RouterError("No application is registered to open process logs")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dev-cache-menu-test-\(UUID().uuidString)")
    let testRouter = Router(home: temporary, uuid: "not-a-real-volume", paths: [".cache/test"])
    defer {
        do { if testRouter.exists(temporary) { try testRouter.removeCache(temporary) } }
        catch { log("Menu test cleanup failed: \(error)") }
    }
    try testRouter.locked { try Data().write(to: testRouter.activated) }
    let polling = CacheMenuBar(router: testRouter)
    defer { NSStatusBar.system.removeStatusItem(polling.statusItem) }
    let controls = [polling.automaticItem, polling.mainItem, polling.devItem, polling.refreshItem, polling.ejectItem]
    var enabledMutations = 0
    let observations = controls.map { item in
        item.observe(\.isEnabled, options: [.new]) { _, _ in enabledMutations += 1 }
    }
    func finishPoll() throws {
        let deadline = Date().addingTimeInterval(5)
        while polling.busy && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        guard !polling.busy else { throw RouterError("Menu polling test timed out") }
    }
    try withExtendedLifetime(observations) {
        polling.refresh()
        try finishPoll()
        let image = polling.statusItem.button?.image
        for _ in 0..<3 {
            polling.refresh()
            guard controls.allSatisfy(\.isEnabled) else { throw RouterError("Background polling disabled menu controls") }
            try finishPoll()
            guard polling.statusItem.button?.image === image else { throw RouterError("Unchanged poll replaced the menu-bar image") }
        }
        guard enabledMutations == 0 else { throw RouterError("Background polls mutated menu enabled state \(enabledMutations) times") }
        polling.menuWillOpen(polling.menu)
        polling.refresh()
        guard !polling.busy else { throw RouterError("Polling started while menu was open") }
        polling.menuDidClose(polling.menu)
        try testRouter.locked { try testRouter.setMode(.main) }
        polling.refresh()
        polling.menuWillOpen(polling.menu)
        try finishPoll()
        guard polling.mainItem.state == .off else { throw RouterError("In-flight refresh updated an open menu") }
        polling.menuDidClose(polling.menu)
        guard polling.mainItem.state == .on else { throw RouterError("Deferred mode update was lost") }
        try Data("\"invalid-mode\"".utf8).write(to: testRouter.base.appendingPathComponent("mode.json"))
        polling.refresh()
        try finishPoll()
        let errorImage = polling.statusItem.button?.image
        polling.refresh()
        try finishPoll()
        guard polling.statusItem.button?.image === errorImage else {
            throw RouterError("Unchanged error poll replaced the icon")
        }
    }
    print("PASS: menu controls, drive icons, mode checkmarks, errors, zero enabled-state mutations during polling, unchanged image retention, open-menu update deferral")
}

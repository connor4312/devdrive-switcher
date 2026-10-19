import Foundation
import Darwin

// Only rebuildable cache directories belong here, never tool homes or credentials.
let cachePaths = [
    ".npm/_cacache", ".npm/_prebuilds", ".npm/_logs",
    ".cache/clang", ".cache/gh", ".cache/puppeteer", ".cache/uv",
    ".cache/node", ".cache/copilot-bazel-incremental", ".cache/copilot-bazel-disk",
    ".cache/bazel", ".cache/ccache", ".cache/sccache", ".cache/pre-commit",
    ".cache/ruff", ".cache/mypy", ".cache/pip", ".cache/huggingface",
    ".cache/torch", ".cache/trivy",
    "Library/pnpm/store", ".pnpm-store", ".yarn/cache", ".bun/install/cache",
    ".cargo/registry", ".cargo/git", "go/pkg/mod",
    ".gradle/caches", ".gradle/wrapper/dists",
    ".rustup/downloads", ".rustup/tmp",
    "Library/Developer/Xcode/DerivedData",
    "Library/Developer/CoreSimulator/Caches",
    "Library/Caches/Homebrew", "Library/Caches/pnpm", "Library/Caches/Yarn",
    "Library/Caches/bazel", "Library/Caches/bazelisk",
    "Library/Caches/go-build", "Library/Caches/golangci-lint",
    "Library/Caches/goimports", "Library/Caches/pip", "Library/Caches/pypoetry",
    "Library/Caches/uv", "Library/Caches/org.swift.swiftpm",
    "Library/Caches/node-gyp", "Library/Caches/node", "Library/Caches/typescript",
    "Library/Caches/ms-playwright", "Library/Caches/org.webkit.Playwright",
    "Library/Caches/electron", "Library/Caches/ffmpeg-static-nodejs",
    "Library/Caches/bun", "Library/Caches/deno", "Library/Caches/ccache",
    "Library/Caches/Mozilla.sccache", "Library/Caches/dprint",
    "Library/Caches/dev.biomejs.biome"
]

struct RouterError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func log(_ text: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(timestamp)] [dev-cache:\(getpid())] \(text)\n".utf8))
}

enum RoutingMode: String, Codable, CaseIterable {
    case automatic = "auto"
    case main = "main"
    case dev = "dev"

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .main: return "Main drive (manual)"
        case .dev: return "DevCache (manual)"
        }
    }
}

struct RouterConfiguration: Codable {
    let volumeUUID: String
}

final class Router {
    let fm = FileManager.default
    let home: URL
    let base: URL
    let uuid: String
    var local: URL { base.appendingPathComponent("local", isDirectory: true) }
    var current: URL { base.appendingPathComponent("current") }
    var activated: URL { base.appendingPathComponent("activated") }
    let paths: [String]

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         uuid: String = "",
         paths: [String] = cachePaths) {
        self.home = home
        self.base = home.appendingPathComponent(".local/share/dev-cache-router", isDirectory: true)
        self.uuid = uuid
        self.paths = paths
    }

    func key(_ path: String) -> String { path.replacingOccurrences(of: "/", with: "--") }

    static func configured(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Router {
        let file = home.appendingPathComponent(".local/share/dev-cache-router/config.json")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw RouterError("No drive configuration found. Run scripts/install.sh with your mounted external volume.")
        }
        let configuration = try JSONDecoder().decode(RouterConfiguration.self, from: Data(contentsOf: file))
        guard UUID(uuidString: configuration.volumeUUID) != nil else {
            throw RouterError("Invalid volume UUID in \(file.path)")
        }
        return Router(home: home, uuid: configuration.volumeUUID)
    }

    func mode() throws -> RoutingMode {
        let file = base.appendingPathComponent("mode.json")
        guard exists(file) else { return .automatic }
        return try JSONDecoder().decode(RoutingMode.self, from: Data(contentsOf: file))
    }

    func setMode(_ mode: RoutingMode) throws {
        try JSONEncoder().encode(mode).write(to: base.appendingPathComponent("mode.json"), options: .atomic)
        log("Selected mode: \(mode.title)")
    }

    func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    func isLink(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    func directory(_ url: URL) throws {
        if exists(url) {
            var isDirectory: ObjCBool = false
            guard !isLink(url), fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw RouterError("Refusing non-directory or symlink: \(url.path)")
            }
            return
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func locked<T>(_ body: () throws -> T) throws -> T {
        try directory(base)
        let fd = open(base.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw RouterError("Cannot open router lock: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw RouterError("Cannot lock router") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    func external() throws -> URL? {
        guard let volumes = fm.mountedVolumeURLs(includingResourceValuesForKeys: [
            .volumeUUIDStringKey, .volumeIsReadOnlyKey
        ]) else { throw RouterError("Cannot enumerate mounted volumes") }
        for volume in volumes {
            let values = try volume.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeIsReadOnlyKey])
            if values.volumeUUIDString?.caseInsensitiveCompare(uuid) == .orderedSame {
                guard values.volumeIsReadOnly == false else {
                    throw RouterError("DevCache is mounted read-only")
                }
                return volume.appendingPathComponent("DeveloperCaches/\(home.lastPathComponent)", isDirectory: true)
            }
        }
        return nil
    }

    func prepare(_ root: URL) throws {
        try directory(root)
        for path in paths { try directory(root.appendingPathComponent(key(path))) }
    }

    func replaceLink(_ url: URL, target: URL) throws {
        if exists(url) && !isLink(url) {
            throw RouterError("Refusing to replace non-symlink: \(url.path)")
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".dev-cache-link-\(UUID().uuidString)")
        try fm.createSymbolicLink(atPath: temporary.path, withDestinationPath: target.path)
        guard rename(temporary.path, url.path) == 0 else {
            let message = String(cString: strerror(errno))
            try fm.removeItem(at: temporary)
            throw RouterError("Cannot replace \(url.path): \(message)")
        }
    }

    func removeCache(_ url: URL) throws {
        func makeDirectoryWritable(_ entry: URL) throws {
            var st = stat()
            guard lstat(entry.path, &st) == 0 else {
                throw RouterError("Cannot inspect cache before deletion: \(entry.path)")
            }
            if (st.st_mode & S_IFMT) == S_IFDIR {
                guard st.st_uid == getuid() else {
                    throw RouterError("Cache directory belongs to another user: \(entry.path)")
                }
                if (st.st_mode & S_IRWXU) != S_IRWXU && chmod(entry.path, st.st_mode | S_IRWXU) != 0 {
                    throw RouterError("Cannot make cache directory removable: \(entry.path)")
                }
            }
        }
        try makeDirectoryWritable(url)
        if !isLink(url) {
            var traversalError: Error?
            guard let entries = fm.enumerator(at: url, includingPropertiesForKeys: nil,
                errorHandler: { _, error in traversalError = error; return false }) else {
                throw RouterError("Cannot enumerate cache for deletion: \(url.path)")
            }
            for case let entry as URL in entries { try makeDirectoryWritable(entry) }
            if let error = traversalError { throw error }
        }
        try fm.removeItem(at: url)
    }

    func target() throws -> String? {
        guard exists(current) else { return nil }
        guard isLink(current) else { throw RouterError("Router current path is not a symlink") }
        return try fm.destinationOfSymbolicLink(atPath: current.path)
    }

    // Delete only explicitly managed cache slots, not the enclosing state directory.
    func clearLocal() throws {
        for path in paths {
            let slot = local.appendingPathComponent(key(path))
            guard !isLink(local) else { throw RouterError("Local fallback root became a symlink") }
            if exists(slot) { try removeCache(slot) }
        }
    }

    func maintainLinks() throws {
        for path in paths {
            let source = home.appendingPathComponent(path)
            let link = current.appendingPathComponent(key(path))
            if !exists(source) {
                try directory(source.deletingLastPathComponent())
                try replaceLink(source, target: link)
            } else {
                guard isLink(source),
                      try fm.destinationOfSymbolicLink(atPath: source.path) == link.path else {
                    throw RouterError("A tool replaced the managed cache link at \(source.path); pause cache users and run dev-cache migrate")
                }
            }
        }
    }

    @discardableResult
    func sync(external override: URL? = nil, simulate: Bool = false) throws -> URL {
        let selectedMode = try mode()
        let disk = selectedMode == .main ? nil : (simulate ? override : try external())
        let next = disk ?? local
        let previous = try target()
        // Cache-clean commands may remove slots; recreate them without waiting for a drive switch.
        try prepare(next)
        if previous != next.path {
            if disk != nil {
                // A durable marker makes interrupted cleanup retryable.
                try Data().write(to: base.appendingPathComponent("cleanup-pending"), options: .atomic)
            }
            try replaceLink(current, target: next)
            log("Using \(disk == nil ? "local fallback" : "external SSD"): \(next.path)")
        }
        let pending = base.appendingPathComponent("cleanup-pending")
        if disk != nil && exists(pending) {
            try clearLocal()
            try fm.removeItem(at: pending)
            log("Cleared local fallback caches")
        }
        if exists(activated) { try maintainLinks() }
        return next
    }

    func run(_ arguments: [String], capture: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = arguments
        let pipe = Pipe()
        if capture { process.standardOutput = pipe }
        try process.run()
        let data = capture ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RouterError("rsync failed (\(process.terminationStatus)); original cache preserved")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func migrate() throws {
        guard let disk = try external() else { throw RouterError("The confirmed DevCache SSD is not mounted") }
        try prepare(disk)
        try replaceLink(current, target: disk)
        let backupRoot = base.appendingPathComponent("migration")
        try directory(backupRoot)
        for path in paths {
            let source = home.appendingPathComponent(path)
            let destination = disk.appendingPathComponent(key(path))
            let link = current.appendingPathComponent(key(path))
            let backup = backupRoot.appendingPathComponent(key(path))
            if isLink(source) {
                guard try fm.destinationOfSymbolicLink(atPath: source.path) == link.path else {
                    throw RouterError("Existing unrelated symlink; inspect before migrating: \(source.path)")
                }
            } else if exists(source) {
                guard !exists(backup) else {
                    throw RouterError("Unfinished migration backup exists: \(backup.path)")
                }
                log("Copying \(path)")
                _ = try run(["-aH", source.path + "/", destination.path + "/"])
                let changes = try run(["-acni", "--out-format=%i %n", source.path + "/", destination.path + "/"], capture: true)
                guard changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RouterError("Cache changed during copy or failed verification: \(source.path). Stop its users and retry.")
                }
                try fm.moveItem(at: source, to: backup)
                try replaceLink(source, target: link)
            } else {
                try directory(source.deletingLastPathComponent())
                try replaceLink(source, target: link)
            }
            if exists(backup) {
                guard !isLink(backupRoot), !isLink(backup),
                      try fm.destinationOfSymbolicLink(atPath: source.path) == link.path else {
                    throw RouterError("Unsafe migration backup cleanup: \(backup.path)")
                }
                log("Verified \(path); removing internal copy")
                try removeCache(backup)
            }
        }
        try Data().write(to: activated, options: .atomic)
        _ = try sync()
        log("Migration complete: \(paths.count) cache paths managed")
    }

    func startFresh(external override: URL? = nil, simulate: Bool = false) throws {
        guard let disk = simulate ? override : try external() else {
            throw RouterError("The confirmed DevCache SSD is not mounted")
        }
        let backupRoot = base.appendingPathComponent("migration")
        for path in paths {
            let source = home.appendingPathComponent(path)
            if isLink(source) {
                guard try fm.destinationOfSymbolicLink(atPath: source.path) == current.appendingPathComponent(key(path)).path else {
                    throw RouterError("Refusing to discard an unrelated symlink: \(source.path)")
                }
            } else if exists(source) && exists(backupRoot.appendingPathComponent(key(path))) {
                throw RouterError("Both cache and migration backup exist; inspect \(source.path)")
            }
        }
        try directory(disk)
        try directory(backupRoot)
        try Data().write(to: base.appendingPathComponent("cleanup-pending"), options: .atomic)
        try replaceLink(current, target: disk)
        for path in paths {
            let source = home.appendingPathComponent(path)
            let slot = disk.appendingPathComponent(key(path))
            let backup = backupRoot.appendingPathComponent(key(path))
            log("Starting fresh: \(path)")
            if exists(slot) { try removeCache(slot) }
            try directory(slot)
            if exists(source) && !isLink(source) {
                try fm.moveItem(at: source, to: backup)
            }
            try directory(source.deletingLastPathComponent())
            try replaceLink(source, target: current.appendingPathComponent(key(path)))
            if exists(backup) {
                guard !isLink(backupRoot), !isLink(backup) else {
                    throw RouterError("Unsafe cache backup: \(backup.path)")
                }
                try removeCache(backup)
            }
        }
        try Data().write(to: activated, options: .atomic)
        _ = try sync(external: disk, simulate: simulate)
        log("Fresh setup complete: \(paths.count) cache paths managed")
    }

    func status() throws {
        print("Mode: \(try mode().title)")
        print("Volume UUID: \(uuid)")
        print("SSD: \(try external()?.path ?? "not mounted")")
        print("Routing: \(try target() ?? "not initialized")")
        print("Migration: \(exists(activated) ? "complete" : "not complete")")
        print("Managed paths: \(paths.count)")
        print("npm _npx executable environments, tools, credentials, projects, Maven and Docker stay internal.")
    }

    func testLiveRouting() throws {
        guard try mode() == .automatic else {
            throw RouterError("Run the live routing test in Automatic mode")
        }
        guard exists(activated), let disk = try external() else {
            throw RouterError("Live routing test requires an activated setup and mounted DevCache")
        }
        let name = ".router-test-\(UUID().uuidString)"
        let ssdMarker = home.appendingPathComponent(".cache/copilot-bazel-disk/\(name)")
        let localMarker = home.appendingPathComponent(".npm/_cacache/\(name)")
        let storedLocal = local.appendingPathComponent("\(key(".npm/_cacache"))/\(name)")
        func check(_ root: URL) throws {
            for path in paths {
                let resolved = home.appendingPathComponent(path).resolvingSymlinksInPath()
                guard resolved.path == root.appendingPathComponent(key(path)).path else {
                    throw RouterError("Cache did not resolve to selected storage: \(path)")
                }
            }
        }
        _ = try sync()
        try Data("SSD retained".utf8).write(to: ssdMarker)
        do {
            _ = try sync(external: nil, simulate: true)
            try check(local)
            try Data("local discarded".utf8).write(to: localMarker)
            guard exists(storedLocal) else { throw RouterError("Fallback write did not reach internal disk") }
            _ = try sync()
            try check(disk)
            guard !exists(storedLocal), !exists(localMarker),
                  try Data(contentsOf: ssdMarker) == Data("SSD retained".utf8) else {
                throw RouterError("Reconnect failed to clear fallback or retain SSD data")
            }
            try fm.removeItem(at: ssdMarker)
        } catch {
            _ = try sync()
            if exists(ssdMarker) { try fm.removeItem(at: ssdMarker) }
            throw error
        }
        print("PASS: all \(paths.count) real cache paths, internal fallback writes, SSD retention, reconnect cleanup")
        print("Volume absence was simulated; this does not test physical unmount notifications.")
    }

    func eject() throws {
        guard let disk = try external() else { throw RouterError("DevCache is not mounted") }
        _ = try sync(external: nil, simulate: true)
        let volume = disk.deletingLastPathComponent().deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eject", volume.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RouterError("Eject failed; stop processes using the SSD, then retry")
        }
    }
}

func selfTest() throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("dev-cache-test-\(UUID().uuidString)")
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer {
        do { try Router(home: temporary).removeCache(temporary) }
        catch { log("Test cleanup failed: \(error)") }
    }
    let router = Router(home: temporary, uuid: "not-a-real-volume", paths: [".cache/test"])
    try router.locked {
        let disk = temporary.appendingPathComponent("ssd")
        let other = temporary.appendingPathComponent("unmanaged")
        try Data("keep".utf8).write(to: other)
        guard try router.external() == nil else { throw RouterError("Wrong UUID accepted") }
        let fallback = try router.sync(external: nil, simulate: true)
        guard fallback == router.local else { throw RouterError("Fallback selection failed") }
        let slot = router.local.appendingPathComponent(router.key(".cache/test"))
        try Data("local".utf8).write(to: slot.appendingPathComponent("local-item"))
        _ = try router.sync(external: disk, simulate: true)
        guard !router.exists(slot), router.exists(other),
              try router.target() == disk.path else { throw RouterError("Reconnect/cleanup failed") }
        let externalSlot = disk.appendingPathComponent(router.key(".cache/test"))
        try Data("ssd".utf8).write(to: externalSlot.appendingPathComponent("ssd-item"))
        _ = try router.sync(external: nil, simulate: true)
        guard router.exists(slot), router.exists(externalSlot.appendingPathComponent("ssd-item")) else {
            throw RouterError("Disconnect damaged SSD or failed to recreate local caches")
        }
        try fm.createSymbolicLink(atPath: slot.appendingPathComponent("outside").path,
                                  withDestinationPath: other.path)
        _ = try router.sync(external: disk, simulate: true)
        guard router.exists(other) else { throw RouterError("Cleanup followed a symlink") }
        _ = try router.sync(external: nil, simulate: true)
        let readonly = slot.appendingPathComponent("readonly")
        try fm.createDirectory(at: readonly, withIntermediateDirectories: false)
        try Data("module".utf8).write(to: readonly.appendingPathComponent("file"))
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonly.path)
        _ = try router.sync(external: disk, simulate: true)
        guard !router.exists(slot) else { throw RouterError("Readonly cache cleanup failed") }
        let copySource = temporary.appendingPathComponent("copy-source")
        let copyTarget = temporary.appendingPathComponent("copy-target")
        try fm.createDirectory(at: copySource, withIntermediateDirectories: false)
        try fm.createDirectory(at: copyTarget, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: copySource.appendingPathComponent("data"))
        _ = try router.run(["-aH", copySource.path + "/", copyTarget.path + "/"])
        let verified = try router.run(["-acni", "--out-format=%i %n", copySource.path + "/", copyTarget.path + "/"], capture: true)
        guard verified.isEmpty else { throw RouterError("Copy verification failed: \(verified)") }
        try Data("modified".utf8).write(to: copyTarget.appendingPathComponent("data"))
        let corrupted = try router.run(["-acni", "--out-format=%i %n", copySource.path + "/", copyTarget.path + "/"], capture: true)
        guard !corrupted.isEmpty else { throw RouterError("Checksum failed to detect corruption") }
        try Data().write(to: router.activated)
        _ = try router.sync(external: disk, simulate: true)
        let alias = temporary.appendingPathComponent(".cache/test")
        try fm.removeItem(at: alias)
        try router.removeCache(externalSlot)
        _ = try router.sync(external: disk, simulate: true)
        guard router.isLink(alias), router.exists(externalSlot) else {
            throw RouterError("Recovery after cache-clean removed a link or slot failed")
        }
        try fm.removeItem(at: router.current)
        try fm.createDirectory(at: router.current, withIntermediateDirectories: false)
        do {
            _ = try router.sync(external: disk, simulate: true)
            throw RouterError("Non-symlink route was overwritten")
        } catch let error as RouterError {
            guard error.description == "Router current path is not a symlink" else { throw error }
        }
    }
    let fresh = Router(home: temporary.appendingPathComponent("fresh-home"),
                       uuid: "not-a-real-volume", paths: [".cache/test"])
    try fresh.locked {
        let original = fresh.home.appendingPathComponent(".cache/test")
        let disk = temporary.appendingPathComponent("fresh-ssd")
        let slot = disk.appendingPathComponent(fresh.key(".cache/test"))
        try fresh.directory(original)
        try fresh.directory(slot)
        try Data("old local".utf8).write(to: original.appendingPathComponent("old"))
        try Data("partial copy".utf8).write(to: slot.appendingPathComponent("partial"))
        let preserve = fresh.home.appendingPathComponent("installed-tool")
        try Data("keep".utf8).write(to: preserve)
        try fresh.startFresh(external: disk, simulate: true)
        guard fresh.isLink(original), fresh.exists(fresh.activated),
              !fresh.exists(slot.appendingPathComponent("partial")),
              !fresh.exists(original.appendingPathComponent("old")),
              fresh.exists(preserve) else {
            throw RouterError("Start-fresh did not discard only managed cache data")
        }
        try fresh.setMode(.main)
        guard try fresh.sync(external: disk, simulate: true) == fresh.local,
              try Router(home: fresh.home).mode() == .main else {
            throw RouterError("Manual Main did not persist or ignored the selection")
        }
        let manualLocal = fresh.local.appendingPathComponent(fresh.key(".cache/test") + "/manual")
        try Data("local".utf8).write(to: manualLocal)
        _ = try fresh.sync(external: disk, simulate: true)
        guard fresh.exists(manualLocal) else { throw RouterError("Manual Main caches were cleared while SSD was present") }
        try fresh.setMode(.dev)
        guard try fresh.sync(external: nil, simulate: true) == fresh.local else {
            throw RouterError("Manual DevCache did not fall back when absent")
        }
        guard try fresh.sync(external: disk, simulate: true) == disk,
              !fresh.exists(manualLocal), try fresh.mode() == .dev else {
            throw RouterError("Manual DevCache did not return to SSD and clear fallback")
        }
        try fresh.setMode(.automatic)
        guard try fresh.sync(external: nil, simulate: true) == fresh.local,
              try fresh.sync(external: disk, simulate: true) == disk else {
            throw RouterError("Returning to Automatic failed")
        }
        try Data("\"invalid-mode\"".utf8).write(to: fresh.base.appendingPathComponent("mode.json"))
        do {
            _ = try fresh.mode()
            throw RouterError("Invalid saved mode was accepted")
        } catch is DecodingError {
            try fresh.setMode(.automatic)
        }
        let configurationFile = fresh.base.appendingPathComponent("config.json")
        let testUUID = UUID().uuidString
        try JSONEncoder().encode(RouterConfiguration(volumeUUID: testUUID)).write(to: configurationFile)
        guard try Router.configured(home: fresh.home).uuid == testUUID else {
            throw RouterError("Drive configuration was not loaded")
        }
        try JSONEncoder().encode(RouterConfiguration(volumeUUID: "invalid")).write(to: configurationFile)
        do {
            _ = try Router.configured(home: fresh.home)
            throw RouterError("Invalid disk configuration was accepted")
        } catch let error as RouterError {
            guard error.description.hasPrefix("Invalid volume UUID") else { throw error }
        }
    }
    print("PASS: routing safety, cache cleanup, copy verification, fresh activation, persistent manual modes, DevCache fallback/reconnect, invalid-preference rejection")
}

do {
    let launchedAsApp = CommandLine.arguments[0].contains("/DevCache.app/Contents/MacOS/")
    let command = CommandLine.arguments.dropFirst().first ?? (launchedAsApp ? "menubar" : "status")
    let configurationFree = ["help", "--help", "-h", "self-test", "menu-test", "paths"]
    let router = configurationFree.contains(command) ? Router() : try Router.configured()
    switch command {
    case "help", "--help", "-h":
        print("""
        dev-cache: native developer-cache router
          status     Show SSD identity, current route and migration state
          paths      List managed cache locations
          migrate    Copy and checksum-verify caches, then replace their paths with symlinks
          start-fresh --discard-caches
                     Discard managed caches and activate empty SSD caches (destructive)
          sync       Select SSD or internal fallback immediately
          mode [auto|main|dev]
                     Show or persist a selection (pause cache users before changing)
          eject      Select local fallback and safely eject DevCache
          self-test  Test routing and copy safety in an isolated temporary directory
          test-routing
                     Test real cache paths by simulating absence, then restoring SSD routing
          daemon     Monitor mounted volumes once per second (run by launchd)
          menubar    Native menu-bar interface and cache manager (run by launchd)
          menu-test  Test native menu presentation without changing real cache routing

        Pause builds and package installations before migration or drive switches.
        After switching, restart programs that keep resolved cache paths or open files.
        Reconnecting discards managed local fallback caches; it never merges them.
        Automatic prefers the SSD. Manual Main stays internal, even with the SSD connected.
        Manual DevCache falls back internally while disconnected and returns on reconnect.
        The menu-bar drive icon reflects actual storage; ! indicates an error (see logs).
        Stop cache users and run 'dev-cache eject' before unplugging the SSD.
        Never forcibly unplug a drive in use: active jobs cannot transparently recover.
        The SSD is selected by filesystem UUID, not by volume name or disk number.
        npm _npx executable environments stay internal so running services remain usable.
        Installed toolchains, projects, credentials, Maven artifacts and Docker data stay internal.
        Project-specific node_modules, target, .venv and custom cache overrides are not relocated.

        Source: Sources/main.swift and Sources/MenuBar.swift in the devdrive-switcher checkout
        Drive configuration: ~/.local/share/dev-cache-router/config.json
        Agent: ~/Library/LaunchAgents/local.dev-cache-router.plist
        Log: ~/.local/share/dev-cache-router/agent.log
        Build and test: make test
        Install or update: bash scripts/install.sh /Volumes/YourExternalVolume
        The installer never formats a disk or activates cache migration automatically.
        """)
    case "self-test":
        try selfTest()
    case "menu-test":
        try testMenuBar()
    case "menubar":
        guard router.exists(router.activated) else { throw RouterError("Run dev-cache migrate first") }
        runMenuBar(router: router)
    case "mode":
        let values = Array(CommandLine.arguments.dropFirst(2))
        if values.isEmpty {
            print(try router.mode().title)
        } else {
            guard values.count == 1, let mode = RoutingMode(rawValue: values[0]) else {
                throw RouterError("Usage: dev-cache mode [auto|main|dev]")
            }
            try router.locked {
                try router.setMode(mode)
                _ = try router.sync()
            }
        }
    case "test-routing":
        try router.locked { try router.testLiveRouting() }
    case "status":
        try router.status()
    case "paths":
        for path in cachePaths { print(router.home.appendingPathComponent(path).path) }
    case "migrate":
        try router.locked { try router.migrate() }
    case "start-fresh":
        guard CommandLine.arguments.dropFirst(2).elementsEqual(["--discard-caches"]) else {
            throw RouterError("This deletes managed cache contents. Usage: dev-cache start-fresh --discard-caches")
        }
        try router.locked { try router.startFresh() }
    case "sync":
        try router.locked {
            guard router.exists(router.activated) else { throw RouterError("Run dev-cache migrate first") }
            _ = try router.sync()
        }
    case "eject":
        try router.locked { try router.eject() }
    case "daemon":
        guard router.exists(router.activated) else { throw RouterError("Run dev-cache migrate first") }
        var lastError: String?
        while true {
            do {
                try router.locked { _ = try router.sync() }
                lastError = nil
            } catch {
                let message = String(describing: error)
                if message != lastError { log(message) }
                lastError = message
            }
            Thread.sleep(forTimeInterval: 1)
        }
    default:
        throw RouterError("Unknown command. Run dev-cache --help for available controls.")
    }
} catch {
    log(String(describing: error))
    exit(1)
}

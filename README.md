# DevDrive Switcher

A native Swift macOS menu-bar app that routes rebuildable development caches to an
external SSD, with internal-storage fallback when the SSD is disconnected.

## Menu bar

- The internal/external drive icon shows the storage actually in use.
- **Switch Automatically** prefers the configured SSD whenever it is mounted.
- **Use Main Drive (Manual)** stays internal, even with the SSD connected.
- **Use DevCache (Manual)** prefers the SSD, falls back internally if disconnected,
  and returns to the SSD when it reconnects.
- **Open Process Logs**, **Open Active Cache Folder**, **Refresh Now**, and
  **Safely Eject DevCache** provide operational controls.
- Selections persist across restarts. Errors appear in the menu and logs.

The native process checks mounted volumes once per second. Background checks do
not toggle menu controls or replace an unchanged icon. Updates that finish while
the menu is open are deferred until it closes, preventing refresh flicker.

## Requirements

- macOS 26 or later (the initial tested platform).
- Xcode or Command Line Tools providing Swift, `make`, and Apple's signing tools.
- A mounted, writable external volume. APFS is recommended.
- A logged-in graphical macOS session for the menu-bar app and menu tests.

No Python, Node, or third-party runtime is required. The app is locally ad-hoc
signed, not notarized.

## Build and test

```sh
make test
make app
```

`make test-router` runs isolated filesystem/routing tests. `make test-menu` checks
native menu presentation and runs background polling to verify **zero enabled-state
mutations**, stable icon identity, and open-menu update deferral. Tests do not alter
your real cache routing.

## Install

This installer **never formats disks** and never automatically migrates or deletes
caches. Format a suitable external volume separately.

```sh
bash scripts/install.sh /Volumes/YourExternalVolume
```

The installer records the filesystem UUID, not the volume name or device number.
Local paths, usernames, and disk identity are generated at install time and are not
checked into this repository. Reinstalling refuses a different SSD UUID.

On a first install, pause **all** builds, package installations, and cache-using
processes, inspect `~/.local/bin/dev-cache paths`, then choose one:

```sh
# Preserve existing caches through checksum-verified migration:
~/.local/bin/dev-cache migrate

# OR discard managed caches and start fresh (DESTRUCTIVE):
~/.local/bin/dev-cache start-fresh --discard-caches
```

Rerun `bash scripts/install.sh` after activation to start the menu-bar login agent.
For updates to an existing installation, run `make test` and
`bash scripts/install.sh`. Updates preserve the selected mode and cache contents.

Installed locations:

- App: `~/Applications/DevCache.app`
- CLI: `~/.local/bin/dev-cache` (add `~/.local/bin` to `PATH`)
- State/configuration: `~/.local/share/dev-cache-router/`
- Drive configuration: `~/.local/share/dev-cache-router/config.json`
- Launch agent: `~/Library/LaunchAgents/local.dev-cache-router.plist`
- Process log: `~/.local/share/dev-cache-router/agent.log`
- External caches: `<volume>/DeveloperCaches/<home-folder-name>/`

## Cache scope and safety

The explicit cache allowlist is in [Sources/main.swift](Sources/main.swift).
It covers common npm downloads, pnpm, Bazel, Python/uv, Rust/Cargo, Go, Gradle,
Homebrew, compiler, browser-download, and other development caches. Original cache
paths become symlinks through one atomically replaced routing symlink, so existing
tool configurations continue to work.

**Returning from internal storage to the SSD deletes managed internal fallback
caches rather than merging them.** This applies to automatic reconnects and manual
switches. Previously cached SSD data is retained.

Installed toolchains, credentials, projects, project-local `node_modules`, `target`,
and virtual environments, Docker data, Maven artifacts, and npm `_npx` executable
environments stay internal. Custom cache overrides outside the allowlist are not
relocated.

Stop cache users before changing storage. Processes that hold open files or
canonicalized paths may require restarting. This cannot make an in-progress build
survive unplugging its storage. Use **Safely Eject DevCache** before removing the
SSD; never force-unmount it. Endpoint protection or other programs may prevent
ejection; stop the relevant activity rather than bypassing those protections.

## CLI

```sh
dev-cache status
dev-cache paths
dev-cache mode auto   # or main / dev; pause cache users before changing
dev-cache sync
dev-cache eject
dev-cache --help
```

`dev-cache test-routing` tests writes and cleanup through real cache paths by
simulating absence, then restoring SSD routing. It **clears fallback caches** and
requires Automatic mode, a connected SSD, and paused cache users. It does not test
physical unmount events.

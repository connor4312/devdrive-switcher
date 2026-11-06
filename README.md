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

## Optional npm registry bridge

For an enterprise that permits only the approved npm feed, the native Swift bridge
forwards hard-coded `https://registry.npmjs.org/...` requests to
`https://packagefeedproxy.microsoft.io/npm/...`. It is independent of cache routing:

### Setup

Use a logged-in macOS account with Xcode Command Line Tools and administrator
authorization available. Port 443 must be free on both loopback addresses, and the
approved feed must be reachable. No SSD or cache-router installation is required.
Run these commands from this checkout, **without sudo**:

```sh
make test-bridge
bash scripts/npm-bridge.sh install
```

Installation prompts for administrator authorization to add IPv4/IPv6 `/etc/hosts` entries.
It trusts a locally generated, **non-CA server certificate** in your login keychain,
restricted to SSL, with a SAN for only `registry.npmjs.org`. Only install this if your
enterprise permits local TLS interception. TLS verification is never disabled,
including on upstream connections.
The certificate expires after one year; uninstall/reinstall to renew it.

Restart terminals and VS Code after installation, then verify ordinary registry
requests without disabling certificate checks:

```sh
curl --fail --silent --show-error https://registry.npmjs.org/is-number -o /dev/null
npm view is-number version --registry=https://registry.npmjs.org/
launchctl print "gui/$(id -u)/local.dev-cache-npm-bridge"
```

Rerun the installer after rebuilding or pulling updates; it preserves the existing
certificate and avoids duplicate hosts/shell entries. To undo the setup:

```sh
bash scripts/npm-bridge.sh uninstall
```

Restart clients after uninstalling too, so they drop the removed certificate setting.
If installation or requests fail, inspect
`~/.local/share/dev-cache-router/npm-bridge/agent.log`. The installer refuses
conflicting hosts entries and Node CA overrides; do not disable TLS verification to
work around these failures.

### Operation and limitations

The unprivileged login agent listens only on `127.0.0.1:443` and `[::1]:443`. It uses
Apple's Network framework, streaming 64 KiB buffers with backpressure, without a third-party runtime,
subprocess per request, or buffering whole packages. HTTP/1.x methods and
Content-Length/chunked uploads are supported. Each request uses a separate upstream
connection; pipelined requests are not forwarded. Headers are capped at 64 KiB,
connections at 128, and idle connections expire after 60 seconds.
Authorization/Cookie headers, request trailers, CONNECT, TRACE and protocol upgrades
are rejected explicitly: this is for public feed traffic, not npm credentials or
authenticated publishing. Response bodies and upstream redirects are preserved.

State, the private TLS identity (and its password file), installed binary and logs live in
`~/.local/share/dev-cache-router/npm-bridge/`. The separate launch agent is
`~/Library/LaunchAgents/local.dev-cache-npm-bridge.plist`. Readiness is verified
before changing hosts/trust; uninstall removes only this bridge's mapping and
certificate, preserving unrelated settings and logs. If the service is stopped,
registry requests fail closed until it is restarted or uninstalled.

Programs using the macOS trust store (including `/usr/bin/curl`) need no additional
configuration. The installer adds a marked `NODE_EXTRA_CA_CERTS` export to `~/.zshenv`
and configures it in the login-session environment on each bridge startup. Uninstall
removes only its marked line and matching login environment value. Installation
refuses to overwrite existing Node CA overrides or a symlinked shell configuration.
Restart already-running apps (including terminals and VS Code) to inherit the setting.
Node's system-CA option alone does not recognize this leaf certificate on the tested
machine. Clients with private CA bundles (some curl/Python/Java builds) need this
certificate in their own trust store.
Certificate pinning, explicit HTTP proxies, custom DNS/DoH, or already-running
connections can bypass local routing; restart clients after installation. This is
not a guaranteed override of every application's networking stack.

### Future Podman containers

On macOS, Podman's Linux VM has separate hosts and trust configuration. After
installing the Mac bridge, configure the running default VM once:

```sh
bash scripts/podman-npm-bridge.sh install
# Optional: select another running machine explicitly:
bash scripts/podman-npm-bridge.sh install machine-name
```

The VM must share this checkout and your Mac bridge certificate under the same
absolute paths (the default `/Users` share), and provide Python 3.11+ and the Fedora
CA bundle. The installer verifies gateway connectivity before applying defaults.
It preserves existing defaults using append-only certificate mounts/environment
arrays and refuses conflicting hosts or certificate configuration.

New containers use a hosts-file mapping to the Mac gateway, a read-only mount
containing **only public certificates**, and trust settings for Node, curl and Python.
The combined CA bundle retains the VM's existing trusted public/enterprise roots.
No private bridge key is exposed, TLS verification remains enabled, and the Mac
listener remains loopback-only. Verify without extra run flags:

```sh
podman run --rm node:latest npm view is-number version
```

These defaults apply automatically to `podman run`/`create`, not to certificate
environment variables in image-build `RUN` steps. Builds inherit the hosts mapping
and public certificate mount, but need an explicit build-only certificate setting:

```sh
podman build --env NODE_EXTRA_CA_CERTS=/run/dev-cache-npm-bridge/certificate.pem \
  --unsetenv NODE_EXTRA_CA_CERTS .
```

For curl/Python build steps, also pass
`--env SSL_CERT_FILE=/run/dev-cache-npm-bridge/ca-bundle.pem` and the corresponding
`CURL_CA_BUNDLE`/`REQUESTS_CA_BUNDLE` variables if needed. Use `--unsetenv` for each
added variable so machine-specific trust paths are not baked into the final image.

Existing containers must be recreated. The installer briefly restarts active Podman
API services to reload defaults, without stopping containers. Defaults persist across
VM restarts; rerun setup after replacing the VM or renewing the Mac certificate.
Run it once for each VM you use. To remove these defaults before uninstalling the
Mac bridge:

```sh
bash scripts/podman-npm-bridge.sh uninstall
```

The generated VM configuration is
`/etc/containers/containers.conf.d/90-dev-cache-npm-bridge.conf`; public trust material
and the container base hosts file are in `/var/lib/dev-cache-npm-bridge/`.
The base hosts file snapshots the VM's existing hosts entries at setup time; rerun
setup after changing them. Container-specific CA bundles are not merged into the
VM bundle, but Node's extra certificate setting preserves its built-in roots.
Explicit environment/mount/hosts overrides, `--no-hosts`, isolated networking,
custom DNS or pinned certificates can defeat the defaults. Applications ignoring
these CA environment variables (for example Java) need their own trust setup.

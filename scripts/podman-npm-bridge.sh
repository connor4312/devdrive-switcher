#!/bin/bash
set -euo pipefail

if [ "${1:-}" = --vm ]; then
    if [ "$(id -u)" != 0 ] || [ "$#" != 4 ]; then
        echo "VM-only usage: --vm install|uninstall certificate.pem user-home" >&2
        exit 1
    fi
    action="$2"
    certificate="$3"
    userHome="$4"
    state="/var/lib/dev-cache-npm-bridge"
    configuration="/etc/containers/containers.conf.d/90-dev-cache-npm-bridge.conf"
    temporary="$(mktemp -d /tmp/dev-cache-podman-npm.XXXXXX)"
    trap 'rm -f "$temporary/containers.conf" "$temporary/hosts" "$temporary/ca-bundle.pem"; rmdir "$temporary"' EXIT
    cat > "$temporary/containers.conf" <<'CONFIG'
# Managed by dev-cache podman-npm-bridge; remove with its uninstall command.
[containers]
base_hosts_file = "/var/lib/dev-cache-npm-bridge/hosts"
volumes = ["/var/lib/dev-cache-npm-bridge:/run/dev-cache-npm-bridge:ro", {append = true}]
env = [
    "NODE_EXTRA_CA_CERTS=/run/dev-cache-npm-bridge/certificate.pem",
    "SSL_CERT_FILE=/run/dev-cache-npm-bridge/ca-bundle.pem",
    "CURL_CA_BUNDLE=/run/dev-cache-npm-bridge/ca-bundle.pem",
    "REQUESTS_CA_BUNDLE=/run/dev-cache-npm-bridge/ca-bundle.pem",
    {append = true},
]
CONFIG
    if [ -L "$configuration" ] || [ -L "$state" ]; then
        echo "Refusing symlinked Podman bridge configuration/state" >&2
        exit 1
    fi
    if [ -e "$configuration" ] && ! cmp -s "$configuration" "$temporary/containers.conf"; then
        echo "Podman bridge configuration was modified; refusing to overwrite or remove it" >&2
        exit 1
    fi
    if [ "$action" = uninstall ]; then
        rm -f "$configuration" "$state/hosts" "$state/certificate.pem" "$state/ca-bundle.pem"
        if [ -d "$state" ]; then rmdir "$state"; fi
        systemctl try-restart podman.service
        exit 0
    fi
    if [ "$action" != install ]; then
        echo "Invalid Podman bridge action" >&2
        exit 1
    fi
    if [ ! -f "$certificate" ]; then
        echo "Mac bridge certificate is not visible inside the VM; install the Mac bridge first" >&2
        exit 1
    fi
    # Reject overrides that would defeat routing/trust rather than replacing user settings.
    python3 - "$configuration" "$userHome" <<'PYTHON'
import pathlib
import sys
import tomllib

owned = pathlib.Path(sys.argv[1])
paths = [pathlib.Path("/usr/share/containers/containers.conf")]
for base in [pathlib.Path("/etc/containers"),
             pathlib.Path(sys.argv[2]) / ".config/containers",
             pathlib.Path("/root/.config/containers")]:
    paths.extend([base / "containers.conf", base / "containers.rootless.conf"])
    for pattern in ["containers.conf.d/*.conf", "containers.rootless.d/**/*.conf"]:
        paths.extend(sorted(base.glob(pattern)))
trust_keys = {"NODE_EXTRA_CA_CERTS", "SSL_CERT_FILE", "CURL_CA_BUNDLE", "REQUESTS_CA_BUNDLE"}
for path in paths:
    if path == owned or not path.is_file():
        continue
    with path.open("rb") as stream:
        settings = tomllib.load(stream).get("containers", {})
    if settings.get("base_hosts_file") or settings.get("no_hosts"):
        sys.exit(f"Conflicting hosts configuration in {path}; no defaults changed")
    for value in settings.get("env", []):
        if isinstance(value, str) and value.split("=", 1)[0] in trust_keys:
            sys.exit(f"Existing certificate environment in {path}; no defaults changed")
    for key in ["volumes", "mounts"]:
        for value in settings.get(key, []):
            if isinstance(value, str) and "/run/dev-cache-npm-bridge" in value:
                sys.exit(f"Conflicting certificate mount in {path}; no defaults changed")
PYTHON
    gateway="$(getent ahostsv4 host.containers.internal | awk 'NR == 1 { print $1 }')"
    if [[ ! "$gateway" =~ ^([0-9]+\.){3}[0-9]+$ ]]; then
        echo "Cannot resolve the macOS host gateway from this VM" >&2
        exit 1
    fi
    if awk '
        { sub(/#.*/, ""); for (i=2; i<=NF; i++) if ($i == "registry.npmjs.org") found=1 }
        END { exit !found }
    ' /etc/hosts; then
        echo "A registry mapping already exists in the VM hosts file; refusing to override it" >&2
        exit 1
    fi
    curl --fail --silent --show-error --connect-timeout 5 --max-time 30 \
        --noproxy registry.npmjs.org --resolve "registry.npmjs.org:443:$gateway" \
        --cacert "$certificate" https://registry.npmjs.org/is-number -o /dev/null
    cat /etc/hosts > "$temporary/hosts"
    printf '\n%s registry.npmjs.org # dev-cache npm-bridge\n' "$gateway" >> "$temporary/hosts"
    cat /etc/pki/tls/certs/ca-bundle.crt "$certificate" > "$temporary/ca-bundle.pem"
    install -d -m 755 "$state" /etc/containers/containers.conf.d
    install -m 644 "$temporary/hosts" "$state/hosts"
    install -m 644 "$certificate" "$state/certificate.pem"
    install -m 644 "$temporary/ca-bundle.pem" "$state/ca-bundle.pem"
    restorecon -R "$state"
    chcon -R -t container_file_t "$state"
    install -m 644 "$temporary/containers.conf" "$configuration"
    systemctl try-restart podman.service
    exit 0
fi

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] ||
    { [ "$1" != install ] && [ "$1" != uninstall ]; }; then
    echo "Usage: bash scripts/podman-npm-bridge.sh install|uninstall [machine-name]" >&2
    exit 1
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
certificate="$HOME/.local/share/dev-cache-router/npm-bridge/certificate.pem"
ssh_vm() {
    if [ -n "${machine:-}" ]; then
        podman machine ssh "$machine" "$1"
    else
        podman machine ssh "$1"
    fi
}
machine="${2:-}"

# Quote paths for the Linux shell, including checkouts with spaces or apostrophes.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
vmHome="$(ssh_vm 'printf "%s" "$HOME"')"
command="sudo /bin/bash $(quote "$repo/scripts/podman-npm-bridge.sh") --vm $(quote "$1") $(quote "$certificate") $(quote "$vmHome")"
ssh_vm "$command"
ssh_vm 'systemctl --user try-restart podman.service'
echo "Podman bridge defaults $1 completed. Existing containers are unchanged; create new ones to use these defaults."

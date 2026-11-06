#!/bin/bash
set -euo pipefail
umask 077

marker="# dev-cache npm-bridge"
hostline="127.0.0.1 registry.npmjs.org $marker"
hostline6="::1 registry.npmjs.org $marker"

# Only hosts-file changes run with administrator privileges.
if [ "${1:-}" = --system ]; then
    if [ "$(id -u)" != 0 ] || [ "$#" != 3 ]; then
        echo "Administrator-only usage: --system install|uninstall certificate.pem" >&2
        exit 1
    fi
    action="$2"
    certificate="$3"
    if [ "$action" != install ] && [ "$action" != uninstall ]; then
        echo "Invalid system action" >&2
        exit 1
    fi
    if [ -L /etc/hosts ] || [ -L "$certificate" ] || [ ! -f "$certificate" ]; then
        echo "Refusing symlink or missing hosts/certificate file" >&2
        exit 1
    fi
    if awk -v own="$hostline" -v own6="$hostline6" '
        $0 != own && $0 != own6 { sub(/#.*/, ""); for (i=2; i<=NF; i++) if ($i == "registry.npmjs.org") found=1 }
        END { exit !found }
    ' /etc/hosts; then
        echo "A different registry.npmjs.org hosts entry exists; refusing to modify it" >&2
        exit 1
    fi
    temporary="$(mktemp /private/etc/dev-cache-npm-bridge.XXXXXX)"
    trap 'rm -f "$temporary"' EXIT
    cp -p /etc/hosts "$temporary"
    awk -v own="$hostline" -v own6="$hostline6" '$0 != own && $0 != own6' /etc/hosts > "$temporary"
    if [ "$action" = install ]; then
        /usr/bin/openssl x509 -in "$certificate" -noout -checkend 86400
        printf '%s\n%s\n' "$hostline" "$hostline6" >> "$temporary"
        mv "$temporary" /etc/hosts
    else
        mv "$temporary" /etc/hosts
    fi
    /usr/bin/dscacheutil -flushcache
    dnsPID="$(/usr/bin/pgrep -x mDNSResponder)"
    case "$dnsPID" in
        ''|*[!0-9]*) echo "Cannot identify mDNSResponder to refresh DNS" >&2; exit 1 ;;
    esac
    /bin/kill -HUP "$dnsPID"
    exit 0
fi

if [ "$#" != 1 ] || { [ "$1" != install ] && [ "$1" != uninstall ]; }; then
    echo "Usage: bash scripts/npm-bridge.sh install|uninstall" >&2
    exit 1
fi
if [ "$(id -u)" = 0 ]; then
    echo "Run as your logged-in user; only trust and hosts changes need administrator approval" >&2
    exit 1
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
script="$repo/scripts/npm-bridge.sh"
state="$HOME/.local/share/dev-cache-router/npm-bridge"
agent="$HOME/Library/LaunchAgents/local.dev-cache-npm-bridge.plist"
domain="gui/$(id -u)"
job="$domain/local.dev-cache-npm-bridge"
certificate="$state/certificate.pem"
environmentLine='export NODE_EXTRA_CA_CERTS="$HOME/.local/share/dev-cache-router/npm-bridge/certificate.pem" # dev-cache npm-bridge'

if [ -L "$HOME/.zshenv" ]; then
    echo "Refusing to edit a symlinked ~/.zshenv; configure Node CA trust separately." >&2
    exit 1
fi

system_changes() {
    # AppleScript's quoted form handles spaces and quotes in the checkout/home paths.
    /usr/bin/osascript - "$script" "$1" "$certificate" <<'APPLESCRIPT'
on run argv
    set command to "/bin/bash " & quoted form of (item 1 of argv) & " --system " & ¬
        quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv)
    do shell script command with administrator privileges
end run
APPLESCRIPT
}

if [ "$1" = uninstall ]; then
    system_changes uninstall
    if launchctl print "$job" > /dev/null 2>&1; then
        launchctl bootout "$job"
    fi
    /usr/bin/security remove-trusted-cert "$certificate"
    fingerprint="$(/usr/bin/openssl x509 -in "$certificate" -noout -fingerprint -sha1 |
        sed 's/.*=//; s/://g')"
    /usr/bin/security delete-certificate -Z "$fingerprint" "$HOME/Library/Keychains/login.keychain-db"
    if [ -f "$HOME/.zshenv" ]; then
        temporary="$(mktemp "${TMPDIR:-/tmp}/dev-cache-npm-env.XXXXXX")"
        trap 'rm -f "$temporary"' EXIT
        awk -v own="$environmentLine" '$0 != own' "$HOME/.zshenv" > "$temporary"
        cat "$temporary" > "$HOME/.zshenv"
    fi
    if [ "$(launchctl getenv NODE_EXTRA_CA_CERTS)" = "$certificate" ]; then
        launchctl unsetenv NODE_EXTRA_CA_CERTS
    fi
    rm -f "$agent" "$state/dev-cache" "$state/identity.p12" "$state/identity.p12.password" "$certificate"
    echo "Removed registry routing, certificate trust and login service. Logs remain in $state."
    exit 0
fi

loginCA="$(launchctl getenv NODE_EXTRA_CA_CERTS)"
if { [ -n "${NODE_EXTRA_CA_CERTS:-}" ] && [ "$NODE_EXTRA_CA_CERTS" != "$certificate" ]; } ||
    { [ -n "$loginCA" ] && [ "$loginCA" != "$certificate" ]; }; then
    echo "An existing NODE_EXTRA_CA_CERTS override is set; refusing to replace your CA configuration." >&2
    exit 1
fi
make -C "$repo" test-bridge
mkdir -p "$state" "$HOME/Library/LaunchAgents"
chmod 700 "$state"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/dev-cache-npm-bridge.XXXXXX")"
trap 'rm -f "$temporary/key.pem" "$temporary/openssl.cnf" "$temporary/agent.plist"; rmdir "$temporary"' EXIT
if [ ! -f "$state/identity.p12" ] && [ ! -f "$certificate" ]; then
    cat > "$temporary/openssl.cnf" <<'CONFIG'
[req]
distinguished_name = name
x509_extensions = server
prompt = no
[name]
CN = registry.npmjs.org
[server]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:registry.npmjs.org
CONFIG
    /usr/bin/openssl req -x509 -newkey rsa:2048 \
        -nodes -sha256 -days 365 -config "$temporary/openssl.cnf" \
        -keyout "$temporary/key.pem" -out "$certificate"
    /usr/bin/openssl rand -hex 32 > "$state/identity.p12.password"
    /usr/bin/openssl pkcs12 -export -inkey "$temporary/key.pem" -in "$certificate" \
        -out "$state/identity.p12" -passout "file:$state/identity.p12.password"
fi
if [ ! -f "$state/identity.p12" ] || [ ! -f "$state/identity.p12.password" ] || [ ! -f "$certificate" ]; then
    echo "Incomplete certificate state in $state; refusing to regenerate existing identity" >&2
    exit 1
fi
/usr/bin/openssl x509 -in "$certificate" -noout -checkend 86400

plutil -create xml1 "$temporary/agent.plist"
plutil -insert Label -string local.dev-cache-npm-bridge "$temporary/agent.plist"
plutil -insert ProgramArguments -json '[]' "$temporary/agent.plist"
plutil -insert ProgramArguments.0 -string "$state/dev-cache" "$temporary/agent.plist"
plutil -insert ProgramArguments.1 -string npm-bridge "$temporary/agent.plist"
plutil -insert ProgramArguments.2 -string "$state/identity.p12" "$temporary/agent.plist"
plutil -insert ProgramArguments.3 -string --login-environment "$temporary/agent.plist"
plutil -insert RunAtLoad -bool true "$temporary/agent.plist"
plutil -insert KeepAlive -bool true "$temporary/agent.plist"
plutil -insert ThrottleInterval -integer 10 "$temporary/agent.plist"
plutil -insert StandardOutPath -string "$state/agent.log" "$temporary/agent.plist"
plutil -insert StandardErrorPath -string "$state/agent.log" "$temporary/agent.plist"
plutil -lint "$temporary/agent.plist"
if launchctl print "$job" > /dev/null 2>&1; then
    launchctl bootout "$job"
fi
cp "$repo/.build/dev-cache" "$state/dev-cache.new"
mv "$state/dev-cache.new" "$state/dev-cache"
codesign --force --sign - "$state/dev-cache"
mv "$temporary/agent.plist" "$agent"
launchctl bootstrap "$domain" "$agent"

ready=false
for ((attempt=0; attempt<20; attempt++)); do
    if /usr/bin/curl --silent --fail --connect-timeout 1 --max-time 15 \
        --noproxy registry.npmjs.org --resolve registry.npmjs.org:443:127.0.0.1 \
        --cacert "$certificate" https://registry.npmjs.org/is-number -o /dev/null; then
        ready=true
        break
    fi
    sleep 1
done
if [ "$ready" != true ]; then
    launchctl bootout "$job"
    echo "Bridge failed readiness; no hosts/trust changes made. See $state/agent.log" >&2
    exit 1
fi
if ! /usr/bin/curl --silent --show-error --fail --max-time 15 --noproxy registry.npmjs.org \
    --resolve 'registry.npmjs.org:443:[::1]' --cacert "$certificate" \
    https://registry.npmjs.org/is-number -o /dev/null; then
    launchctl bootout "$job"
    echo "IPv6 readiness failed; service stopped and hosts unchanged." >&2
    exit 1
fi
if ! /usr/bin/security add-trusted-cert -r trustRoot -p ssl \
    -k "$HOME/Library/Keychains/login.keychain-db" "$certificate"; then
    launchctl bootout "$job"
    echo "User certificate trust failed; service stopped and hosts unchanged." >&2
    exit 1
fi
touch "$HOME/.zshenv"
if ! grep -Fqx "$environmentLine" "$HOME/.zshenv"; then
    printf '\n%s\n' "$environmentLine" >> "$HOME/.zshenv"
fi
if ! system_changes install; then
    launchctl bootout "$job"
    echo "Administrator setup failed; service stopped. Certificate remains in the login keychain." >&2
    exit 1
fi
/usr/bin/curl --silent --show-error --fail --max-time 30 \
    --retry 2 --retry-all-errors --retry-delay 1 --retry-max-time 15 \
    https://registry.npmjs.org/is-number -o /dev/null
echo "Installed loopback registry bridge. Log: $state/agent.log"
echo "Node CA environment installed for new zsh shells and newly launched apps; restart existing apps."

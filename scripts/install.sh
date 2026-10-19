#!/bin/bash
set -euo pipefail

if [ "$#" -gt 1 ]; then
    echo "Usage: bash scripts/install.sh [mounted-external-volume]" >&2
    exit 1
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
state="$HOME/.local/share/dev-cache-router"
app="$HOME/Applications/DevCache.app"
agent="$HOME/Library/LaunchAgents/local.dev-cache-router.plist"
domain="gui/$(id -u)"
job="$domain/local.dev-cache-router"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/dev-cache-install.XXXXXX")"
trap 'rm -f "$temporary/volume.plist" "$temporary/config.json" "$temporary/agent.plist"; rmdir "$temporary"' EXIT

if [ "$#" -eq 1 ]; then
    diskutil info -plist "$1" > "$temporary/volume.plist"
    volumeUUID="$(/usr/libexec/PlistBuddy -c 'Print :VolumeUUID' "$temporary/volume.plist")"
    internal="$(/usr/libexec/PlistBuddy -c 'Print :Internal' "$temporary/volume.plist")"
    writable="$(/usr/libexec/PlistBuddy -c 'Print :WritableVolume' "$temporary/volume.plist")"
    mounted="$(/usr/libexec/PlistBuddy -c 'Print :MountPoint' "$temporary/volume.plist")"
    if [ "$internal" != false ] || [ "$writable" != true ] || [ -z "$mounted" ]; then
        echo "Select a mounted, writable external volume. No disk has been changed." >&2
        exit 1
    fi
    if [ -e "$state/config.json" ]; then
        previousUUID="$(plutil -extract volumeUUID raw "$state/config.json")"
        if [ "$previousUUID" != "$volumeUUID" ]; then
            echo "A different SSD is already configured. Refusing to change an existing cache setup." >&2
            exit 1
        fi
    fi
    plutil -create xml1 "$temporary/config.json"
    plutil -insert volumeUUID -string "$volumeUUID" "$temporary/config.json"
    plutil -convert json "$temporary/config.json"
elif [ ! -f "$state/config.json" ]; then
    echo "First install requires a mounted external volume: bash scripts/install.sh /Volumes/YourVolume" >&2
    exit 1
fi

make -C "$repo" app
mkdir -p "$state" "$HOME/Applications" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
if [ -f "$temporary/config.json" ]; then
    mv "$temporary/config.json" "$state/config.json"
fi

plutil -create xml1 "$temporary/agent.plist"
plutil -insert Label -string local.dev-cache-router "$temporary/agent.plist"
plutil -insert ProgramArguments -json '[]' "$temporary/agent.plist"
plutil -insert ProgramArguments.0 -string "$app/Contents/MacOS/dev-cache" "$temporary/agent.plist"
plutil -insert ProgramArguments.1 -string menubar "$temporary/agent.plist"
plutil -insert RunAtLoad -bool true "$temporary/agent.plist"
plutil -insert KeepAlive -bool true "$temporary/agent.plist"
plutil -insert ThrottleInterval -integer 10 "$temporary/agent.plist"
plutil -insert ProcessType -string Interactive "$temporary/agent.plist"
plutil -insert StandardOutPath -string "$state/agent.log" "$temporary/agent.plist"
plutil -insert StandardErrorPath -string "$state/agent.log" "$temporary/agent.plist"
plutil -lint "$temporary/agent.plist"

if launchctl print "$job" > /dev/null 2>&1; then
    launchctl bootout "$job"
    sleep 1
fi
mkdir -p "$app/Contents/MacOS"
cp "$repo/.build/DevCache.app/Contents/MacOS/dev-cache" "$app/Contents/MacOS/dev-cache.new"
mv "$app/Contents/MacOS/dev-cache.new" "$app/Contents/MacOS/dev-cache"
cp "$repo/resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ln -s "$app/Contents/MacOS/dev-cache" "$HOME/.local/bin/dev-cache.new"
mv -f "$HOME/.local/bin/dev-cache.new" "$HOME/.local/bin/dev-cache"
mv "$temporary/agent.plist" "$agent"
touch "$state/agent.log"

if [ -f "$state/activated" ]; then
    launchctl bootstrap "$domain" "$agent"
    sleep 2
    launchctl print "$job"
    "$HOME/.local/bin/dev-cache" status
else
    cat <<'MESSAGE'
Installed without changing cache data or starting the login agent.
Pause all builds, package installs and cache-using processes, then choose ONE:
  ~/.local/bin/dev-cache migrate
    Copy existing caches to the SSD and checksum-verify them before deleting originals.
  ~/.local/bin/dev-cache start-fresh --discard-caches
    DESTRUCTIVE: discard all managed cache contents and start empty on the SSD.
After activation, rerun this installer to enable the menu-bar login agent.
MESSAGE
fi

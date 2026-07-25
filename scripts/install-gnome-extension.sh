#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
extension_uuid="cachewatch@cneuralnetwork.github.com"
extension_source="$repository_root/packaging/gnome-shell/$extension_uuid"
extension_target="${XDG_DATA_HOME:-$HOME/.local/share}/gnome-shell/extensions/$extension_uuid"
binary_target="$HOME/.local/bin/cachewatch"
swift_command="${SWIFT:-swift}"

if ! command -v "$swift_command" >/dev/null 2>&1; then
    echo "Swift 6 or newer is required. Install swift-lang and run this script again." >&2
    exit 1
fi

"$swift_command" build -c release --package-path "$repository_root"

install -d "$(dirname "$binary_target")"
install -m 755 "$repository_root/.build/release/Cachewatch" "$binary_target"

install -d "$extension_target/icons"
install -m 644 "$extension_source/metadata.json" "$extension_target/metadata.json"
install -m 644 "$extension_source/extension.js" "$extension_target/extension.js"
install -m 644 "$extension_source/stylesheet.css" "$extension_target/stylesheet.css"
install -m 644 \
    "$extension_source/icons/cachewatch-symbolic.svg" \
    "$extension_target/icons/cachewatch-symbolic.svg"

echo "Installed Cachewatch CLI at $binary_target"
echo "Installed GNOME extension at $extension_target"

if gnome-extensions info "$extension_uuid" >/dev/null 2>&1; then
    gnome-extensions enable "$extension_uuid"
    echo "Enabled $extension_uuid"
else
    echo "GNOME Shell must reload before it can see a newly installed extension."
    echo "On Wayland, log out and back in. On X11, press Alt-F2, enter r, and press Enter."
    echo "Then run: gnome-extensions enable $extension_uuid"
fi

echo "Run 'cachewatch setup' once if Claude quota is not configured yet."

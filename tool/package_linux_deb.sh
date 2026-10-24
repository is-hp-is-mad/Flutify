#!/usr/bin/env bash
# Package a `flutter build linux --release` bundle into a Debian package (.deb).
#
# Usage:
#   tool/package_linux_deb.sh --label v0.13 [--bundle build/linux/x64/release/bundle] \
#     [--output dist] [--version 0.0.13] [--arch amd64]
#
# The bundled executable is expected at <bundle>/flutify (see linux/CMakeLists.txt
# BINARY_NAME). Runtime dependencies (GTK3, libmpv) are declared in the control file.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
label=""
bundle="$repo/build/linux/x64/release/bundle"
output="$repo/dist"
version=""
arch="amd64"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --label) label="$2"; shift 2 ;;
    --bundle) bundle="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --version) version="$2"; shift 2 ;;
    --arch) arch="$2"; shift 2 ;;
    -h|--help) grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$label" ]]; then
  echo "missing --label" >&2
  exit 2
fi
label_safe="$(printf '%s' "$label" | tr -c 'a-zA-Z0-9._-' '-')"
if [[ -z "$version" ]]; then
  version="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\).*/\1/p' "$repo/pubspec.yaml" | head -1)"
fi
if [[ -z "$version" ]]; then
  echo "could not determine version (pass --version)" >&2
  exit 2
fi

if [[ ! -x "$bundle/flutify" ]]; then
  echo "missing release build executable: $bundle/flutify" >&2
  exit 1
fi
for required in lib data; do
  if [[ ! -d "$bundle/$required" ]]; then
    echo "missing bundle directory: $bundle/$required" >&2
    exit 1
  fi
done

artifact="Flutify-${label_safe}-linux-x64"
mkdir -p "$output"
output="$(cd "$output" && pwd)"
stage="$(mktemp -d "${TMPDIR:-/tmp}/flutify-deb.XXXXXX")"
trap 'rm -rf "$stage"' EXIT

install_root="$stage/opt/flutify"
mkdir -p "$install_root"
cp -a "$bundle/." "$install_root/"

# Do not ship a debug kernel if a debug build lingered in the shared assets dir.
for name in kernel_blob.bin vm_snapshot_data isolate_snapshot_data; do
  rm -f "$install_root/data/flutter_assets/$name"
done

cp -f "$repo/LICENSE" "$install_root/LICENSE"
cp -f "$repo/THIRD_PARTY_NOTICES.md" "$install_root/THIRD_PARTY_NOTICES.md"

# Launcher on PATH.
mkdir -p "$stage/usr/bin"
cat > "$stage/usr/bin/flutify" <<'LAUNCHER'
#!/bin/sh
exec /opt/flutify/flutify "$@"
LAUNCHER
chmod 0755 "$stage/usr/bin/flutify"

# Desktop entry + icons.
mkdir -p "$stage/usr/share/applications" \
         "$stage/usr/share/icons/hicolor/256x256/apps" \
         "$stage/usr/share/pixmaps" \
         "$stage/usr/share/doc/flutify"
cat > "$stage/usr/share/applications/com.flutify.music.flutify_app.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=Flutify
Comment=A third-party Spotify client
Exec=flutify %U
Icon=flutify
Terminal=false
Categories=Audio;AudioVideo;Player;
StartupWMClass=com.flutify.music.flutify_app
MimeType=x-scheme-handler/spotify;
DESKTOP
icon="$repo/assets/brand/flutify_logo_1024.png"
if [[ -f "$icon" ]]; then
  cp -f "$icon" "$stage/usr/share/icons/hicolor/256x256/apps/flutify.png"
  cp -f "$icon" "$stage/usr/share/pixmaps/flutify.png"
fi
cp -f "$repo/LICENSE" "$stage/usr/share/doc/flutify/copyright"

# Debian control metadata.
installed_size="$(du -sk "$install_root" | cut -f1)"
mkdir -p "$stage/DEBIAN"
cat > "$stage/DEBIAN/control" <<CONTROL
Package: flutify
Version: ${version}
Section: sound
Priority: optional
Architecture: ${arch}
Maintainer: Flutify <noreply@github.com>
Installed-Size: ${installed_size}
Depends: libc6, libstdc++6, libgtk-3-0 (>= 3.24), libmpv2 | libmpv1 | libmpv-dev, libglib2.0-0
Recommends: google-chrome-stable | google-chrome | chromium | chromium-browser, libasound2t64 | libasound2
Description: A third-party Spotify client (Flutify)
 Flutify is an unofficial Spotify client built with Flutter. It plays full
 tracks through your own account and also supports lyrics, Spotify Connect
 and a desktop-first Material 3 Expressive interface.
 .
 Linux support is experimental: full-track playback uses a system Google
 Chrome / Chromium (with Widevine) driven in the background, so installing
 Chrome is recommended.
CONTROL

deb="$output/${artifact}.deb"
rm -f "$deb"
dpkg-deb --build --root-owner-group "$stage" "$deb" >/dev/null
echo "Built $deb"

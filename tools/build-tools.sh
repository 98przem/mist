#!/usr/bin/env bash
# Builds/fetches Mist's helper tools into <outdir>:
#   AchievementRelay  — our SteamKit2 relay (built from tools/AchievementRelay/)
#   DepotDownloader   — SteamRE's downloader + our token-reuse patch (cloned + patched)
#   gbe/*.dll         — gbe_fork Steamworks-emulator DLLs (prebuilt, downloaded)
#
# Requires: dotnet SDK (net10), git, curl, tar (libarchive w/ 7z), shasum.
# Usage: tools/build-tools.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: build-tools.sh <output-dir>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT/gbe"

# Locate a usable dotnet (PATH, then the local per-user install).
if command -v dotnet >/dev/null 2>&1; then DOTNET=dotnet
elif [ -x "$HOME/.dotnet/dotnet" ]; then DOTNET="$HOME/.dotnet/dotnet"
else echo "ERROR: dotnet SDK not found (install .NET 10 SDK)"; exit 1; fi
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

# .NET runtime identifier for this Mac.
case "$(uname -m)" in
  arm64) RID=osx-arm64 ;;
  x86_64) RID=osx-x64 ;;
  *) echo "ERROR: unsupported arch $(uname -m)"; exit 1 ;;
esac

pub() { # <csproj> <outdir>
  "$DOTNET" publish "$1" -c Release -r "$RID" --self-contained true \
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
    -o "$2" >/dev/null
}

echo "[tools] building AchievementRelay ($RID)…"
RELAY_TMP="$(mktemp -d)"
pub "$HERE/AchievementRelay/AchievementRelay.csproj" "$RELAY_TMP"
install -m 0755 "$RELAY_TMP/AchievementRelay" "$OUT/AchievementRelay"
rm -rf "$RELAY_TMP"

echo "[tools] building patched DepotDownloader…"
DD_TMP="$(mktemp -d)"
DD_PIN="$(cat "$HERE/depotdownloader.pin")"
git clone --quiet https://github.com/SteamRE/DepotDownloader "$DD_TMP/src"
git -C "$DD_TMP/src" checkout --quiet "$DD_PIN"
git -C "$DD_TMP/src" apply "$HERE/depotdownloader.patch"
pub "$DD_TMP/src/DepotDownloader/DepotDownloader.csproj" "$DD_TMP/out"
install -m 0755 "$DD_TMP/out/DepotDownloader" "$OUT/DepotDownloader"
rm -rf "$DD_TMP"

echo "[tools] fetching gbe_fork DLLs…"
GBE_URL="$(sed -n 's/^url=//p' "$HERE/gbe_fork.pin")"
GBE_SHA="$(sed -n 's/^sha256=//p' "$HERE/gbe_fork.pin")"
GBE_TMP="$(mktemp -d)"
curl -fsSL -o "$GBE_TMP/emu.7z" "$GBE_URL"
echo "$GBE_SHA  $GBE_TMP/emu.7z" | shasum -a 256 -c - >/dev/null
# macOS `tar` (libarchive) usually reads .7z; fall back to p7zip if not.
if ! tar xf "$GBE_TMP/emu.7z" -C "$GBE_TMP" 2>/dev/null || [ ! -d "$GBE_TMP/release" ]; then
  if ! command -v 7z >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then brew install -q p7zip; fi
  7z x -y -o"$GBE_TMP" "$GBE_TMP/emu.7z" >/dev/null
fi
GBE_R="$GBE_TMP/release"
cp "$GBE_R/experimental/x64/steam_api64.dll"                 "$OUT/gbe/steam_api64.dll"
cp "$GBE_R/experimental/x64/steamclient64.dll"              "$OUT/gbe/steamclient64.dll"
cp "$GBE_R/steamclient_experimental/GameOverlayRenderer64.dll" "$OUT/gbe/GameOverlayRenderer64.dll"
rm -rf "$GBE_TMP"

echo "[tools] fetching DXVK-macOS (D3D10/11 on Apple Silicon)…"
mkdir -p "$OUT/dxvk"
DXVK_URL="$(sed -n 's/^url=//p' "$HERE/dxvk_macos.pin")"
DXVK_SHA="$(sed -n 's/^sha256=//p' "$HERE/dxvk_macos.pin")"
DXVK_TMP="$(mktemp -d)"
curl -fsSL -o "$DXVK_TMP/dxvk.tar.gz" "$DXVK_URL"
echo "$DXVK_SHA  $DXVK_TMP/dxvk.tar.gz" | shasum -a 256 -c - >/dev/null
tar xf "$DXVK_TMP/dxvk.tar.gz" -C "$DXVK_TMP"
DXVK_X64="$(dirname "$(find "$DXVK_TMP" -path '*/x64/d3d11.dll' | head -1)")"
cp "$DXVK_X64/d3d11.dll"     "$OUT/dxvk/d3d11.dll"
cp "$DXVK_X64/d3d10core.dll" "$OUT/dxvk/d3d10core.dll"
rm -rf "$DXVK_TMP"

echo "[tools] done → $OUT"
ls -la "$OUT" "$OUT/gbe" "$OUT/dxvk"

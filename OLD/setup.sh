#!/bin/bash
# Mist Setup — Downloads and configures Wine (CrossOver edition) for running Windows Steam on macOS
# Supports Apple Silicon (M1/M2/M3/M4) via Rosetta 2
#
# Usage: ./setup.sh [--target-dir DIR] [--quiet]
#   --target-dir DIR  Install Wine to DIR instead of ./wine/
#   --quiet           Only output PROGRESS: lines (for GUI parsing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENGINE_NAME="WS12WineCX24.0.7_7"
WINE_URL="https://github.com/Sikarugir-App/Engines/releases/download/v1.0/${ENGINE_NAME}.tar.xz"
WINE_SHA256="203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c"

# Parse arguments
TARGET_DIR=""
QUIET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-dir) [[ $# -ge 2 ]] || { echo "ERROR: --target-dir requires a value" >&2; exit 1; }; TARGET_DIR="$2"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        *) shift ;;
    esac
done

WINE_DIR="${TARGET_DIR:-${SCRIPT_DIR}/wine}"
CREATE_SYMLINKS=1
[[ -n "${TARGET_DIR}" ]] && CREATE_SYMLINKS=0

log() { [[ $QUIET -eq 0 ]] && echo "$@" || true; }
progress() { echo "PROGRESS:$1"; }

log "=== Mist Setup ==="
log ""

# Check architecture
if [[ "$(uname -m)" == "arm64" ]]; then
    if ! /usr/bin/pgrep -q oahd; then
        progress "Installing Rosetta 2..."
        log "Installing Rosetta 2 (required for x86_64 Wine)..."
        softwareupdate --install-rosetta --agree-to-license
    fi
    log "  Platform: Apple Silicon ($(sysctl -n machdep.cpu.brand_string))"
    log "  Rosetta 2: installed"
else
    log "  Platform: Intel Mac"
fi
log ""

# Download Wine if not present.
# Check the wine binary AND lib/ AND share/ — not just bin/ — so an install that
# was interrupted mid-copy is treated as incomplete and re-done, not "complete".
if [[ -x "${WINE_DIR}/bin/wine" && -d "${WINE_DIR}/lib" && -d "${WINE_DIR}/share" ]]; then
    log "  Wine: already installed at ${WINE_DIR}"
    progress "done"
else
    progress "downloading"
    log "Downloading Wine engine ${ENGINE_NAME}..."

    if [[ -f "$HOME/Downloads/${ENGINE_NAME}.tar.xz" ]]; then
        TARBALL="$HOME/Downloads/${ENGINE_NAME}.tar.xz"
        log "  (Using existing download from ~/Downloads)"
    else
        TARBALL="$(mktemp /tmp/wine-engine-XXXXXX.tar.xz)"
        curl -L -o "${TARBALL}" "${WINE_URL}"
    fi

    progress "verifying"
    log "Verifying checksum..."
    ACTUAL_SHA256="$(shasum -a 256 "${TARBALL}" | awk '{print $1}')"
    if [[ "${ACTUAL_SHA256}" != "${WINE_SHA256}" ]]; then
        echo "ERROR: Checksum mismatch!" >&2
        echo "  Expected: ${WINE_SHA256}" >&2
        echo "  Got:      ${ACTUAL_SHA256}" >&2
        echo "  The download may be corrupted or tampered with." >&2
        exit 1
    fi

    progress "extracting"
    log "Extracting..."
    EXTRACT_DIR=$(mktemp -d)
    tar xf "${TARBALL}" -C "${EXTRACT_DIR}"

    # Sikarugir engines extract to wswine.bundle/ at the archive root
    WINE_BUNDLE="${EXTRACT_DIR}/wswine.bundle"
    if [[ ! -d "${WINE_BUNDLE}" ]]; then
        echo "ERROR: Could not find wswine.bundle in engine archive" >&2
        exit 1
    fi

    # Stage into a temp dir on the same filesystem, then move into place in one
    # atomic rename. An interrupted copy never leaves a half-installed (and
    # falsely "complete") Wine tree at ${WINE_DIR}.
    PARENT_DIR="$(dirname "${WINE_DIR}")"
    mkdir -p "${PARENT_DIR}"
    STAGING_DIR="$(mktemp -d "${WINE_DIR}.staging.XXXXXX")"
    cp -R "${WINE_BUNDLE}/bin"   "${STAGING_DIR}/bin"
    cp -R "${WINE_BUNDLE}/lib"   "${STAGING_DIR}/lib"
    cp -R "${WINE_BUNDLE}/share" "${STAGING_DIR}/share"
    rm -rf "${WINE_DIR}"
    mv "${STAGING_DIR}" "${WINE_DIR}"

    rm -rf "${EXTRACT_DIR}"

    # Create convenience symlinks (only for git-clone layout)
    if [[ $CREATE_SYMLINKS -eq 1 ]]; then
        ln -sf wine/bin "${SCRIPT_DIR}/bin"
        ln -sf wine/lib "${SCRIPT_DIR}/lib"
        ln -sf wine/share "${SCRIPT_DIR}/share"
    fi

    log "  Wine engine ${ENGINE_NAME} installed."
    progress "done"
fi

log ""
log "Setup complete! Launch Steam with:"
log "  ./launch-steam.sh"
log ""
log "Or double-click Mist.app"
log ""

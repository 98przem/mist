# Build targets for Mist
# Requires: Xcode command line tools (swiftc)

# Marketing version baked into Info.plist (CFBundleShortVersionString) and used by
# the in-app updater to compare against the latest GitHub release. CI passes this
# from the git tag (see .github/workflows/release.yml) so releases get a clean
# number; this default only labels local dev builds, hence the "-preview" suffix.
# Bump it to the next target release when starting work toward one.
VERSION ?= 0.14.0-preview

PREFIX ?= $(HOME)/Library/Application Support/Mist
CEF_DIR = $(PREFIX)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64

# Bundle paths
BUNDLE = dist/Mist.app
BUNDLE_CONTENTS = $(BUNDLE)/Contents
BUNDLE_MACOS = $(BUNDLE_CONTENTS)/MacOS
BUNDLE_RESOURCES = $(BUNDLE_CONTENTS)/Resources

.PHONY: all app tools clean bundle dmg release bundle-clean test-build test \
       reset-steam reset-all reset-depotdownloader-cache

# Helper tools live in the app bundle's Resources; the relay binary doubles as
# the "are the tools built?" sentinel so `make app` builds them once, then skips.
TOOLS_APP = Mist.app/Contents/Resources/tools
TOOLS_SENTINEL = $(TOOLS_APP)/AchievementRelay

all: app

# ── Developer targets (git-clone workflow) ────────────────────────────

# Native macOS SwiftUI app (+ bundled helper tools).
app: Mist.app/Contents/MacOS/Mist

# Build/fetch the helper tools (AchievementRelay, patched DepotDownloader,
# gbe_fork DLLs). Requires the .NET SDK — see tools/build-tools.sh. Run directly
# to refresh them after changing anything under tools/.
tools:
	tools/build-tools.sh "$(TOOLS_APP)"

$(TOOLS_SENTINEL):
	tools/build-tools.sh "$(TOOLS_APP)"

Mist.app/Contents/MacOS/Mist: MistApp.swift $(TOOLS_SENTINEL) Mist.icns
	@mkdir -p Mist.app/Contents/MacOS Mist.app/Contents/Resources
	swiftc -O -parse-as-library -target arm64-apple-macos14 -o $@ $<
	@cp Mist.icns Mist.app/Contents/Resources/Mist.icns
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > Mist.app/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> Mist.app/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>Mist</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>com.mist.app</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>Mist</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>2.0</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleIconFile</key><string>Mist.icns</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> Mist.app/Contents/Info.plist
	@echo '</dict></plist>' >> Mist.app/Contents/Info.plist
	codesign --force --deep -s - Mist.app

# Generate the app icon from tools/make_icon.swift (regenerate: rm Mist.icns).
Mist.icns: tools/make_icon.swift
	swift tools/make_icon.swift

# ── Distribution targets (self-contained .app) ───────────────────────

bundle: Mist.icns
	@echo "Assembling Mist.app..."
	rm -rf dist/
	mkdir -p "$(BUNDLE_MACOS)" "$(BUNDLE_RESOURCES)"
	# Compile Swift app
	swiftc -O -parse-as-library -target arm64-apple-macos14 -o "$(BUNDLE_MACOS)/Mist" MistApp.swift
	# Info.plist
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<plist version="1.0"><dict>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleExecutable</key><string>Mist</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleIdentifier</key><string>com.mist.app</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleName</key><string>Mist</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleVersion</key><string>2.0</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleShortVersionString</key><string>$(VERSION)</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleIconFile</key><string>Mist.icns</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>LSMinimumSystemVersion</key><string>14.0</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '</dict></plist>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	# App icon
	@cp Mist.icns "$(BUNDLE_RESOURCES)/Mist.icns" 2>/dev/null || echo "(no Mist.icns yet)"
	# Bundle the helper tools (relay, patched DepotDownloader, gbe_fork DLLs).
	tools/build-tools.sh "$(BUNDLE_RESOURCES)/tools"
	# Ad-hoc code sign the whole bundle (tools included).
	codesign --force --deep -s - "$(BUNDLE)"
	@echo ""
	@echo "Bundle ready at dist/Mist.app"
	@echo "Test with: open dist/Mist.app"

release: dmg
	cd dist && zip -qr Mist.zip Mist.app
	@echo "Release archives: dist/Mist.dmg and dist/Mist.zip"

# Drag-to-install disk image with an Applications shortcut.
dmg: bundle
	@echo "Building dist/Mist.dmg..."
	rm -f dist/Mist.dmg
	rm -rf dist/dmg && mkdir -p dist/dmg
	cp -R "$(BUNDLE)" dist/dmg/Mist.app
	ln -s /Applications dist/dmg/Applications
	# hdiutil intermittently fails on GitHub's shared macOS runners with
	# "No space left on device" even with tens of GB genuinely free (confirmed via
	# df — not a real space issue, a known flaky runner behavior) — retry instead
	# of chasing free space further.
	@for i in 1 2 3; do \
		if hdiutil create -volname "Mist" -srcfolder dist/dmg -ov -format UDZO dist/Mist.dmg >/dev/null; then \
			exit 0; \
		fi; \
		echo "hdiutil attempt $$i failed, retrying…"; sleep 5; \
	done; \
	echo "hdiutil failed after 3 attempts"; exit 1
	rm -rf dist/dmg
	@echo "DMG ready at dist/Mist.dmg"

# ── Anti-cheat test targets ───────────────────────────────────────────

# Compile all test binaries
test-build: tests/mach_syscall_test tests/nt_api_check.exe

# Mach exception handler syscall interception PoC (native x86_64)
tests/mach_syscall_test: tests/mach_syscall_test.c
	clang -arch x86_64 -O0 -o $@ $< -lpthread

# NT API validation (Windows PE, runs under Wine)
tests/nt_api_check.exe: tests/nt_api_check.c
	x86_64-w64-mingw32-gcc -O2 -o $@ $< -lntdll

# Run all tests
test: test-build
	./tests/run_tests.sh

# ── Cleanup ───────────────────────────────────────────────────────────

clean:
	rm -f Mist.app/Contents/MacOS/Mist
	rm -rf "$(TOOLS_APP)"
	rm -f tests/mach_syscall_test tests/nt_api_check.exe

bundle-clean:
	rm -rf dist/

# ── Dev/testing resets ─────────────────────────────────────────────────
#
# These wipe real local state (Steam logins, game installs, prefs) — for
# repeatable from-scratch testing, not something a shipped build ever runs.
# Always quits Mist first so nothing writes back into what we're deleting.

# Fast reset: wipes Steam install/login, DepotDownloader's own cached session,
# Mist's native login session, per-game settings, and relevant UserDefaults keys
# — but keeps the downloaded Wine ENGINE (wine/) so you're not stuck redownloading
# ~200MB before every test run. Use this for iterating on Steam/login/achievements
# work. Prefix registry (system.reg/user.reg) is also wiped, forcing Steam's
# ActiveProcess state to start clean, which reinitializes on next wineboot.
reset-steam:
	@pkill -f "Mist.app/Contents/MacOS/Mist" 2>/dev/null || true
	@"$(PREFIX)/wine/bin/wineserver" -k 2>/dev/null || true
	@sleep 1
	rm -rf "$(PREFIX)/drive_c"
	rm -f "$(PREFIX)"/*.reg "$(PREFIX)/.update-timestamp"
	rm -rf "$(PREFIX)/tools"
	rm -f "$(PREFIX)/steam_session.json" "$(PREFIX)/game_settings.json"
	defaults delete com.mist.app 2>/dev/null || true
	@echo "Reset done: Steam/login/game state cleared, Wine engine kept."
	@echo "NOTE: DepotDownloader's own cached session lives outside this prefix"
	@echo "(.NET IsolatedStorage) — run 'make reset-depotdownloader-cache' too if"
	@echo "you need that cleared as well."

# DepotDownloader's own session cache is NOT inside our prefix — it's .NET
# IsolatedStorage, keyed by the DepotDownloader binary's own path/identity, at a
# fixed machine-wide location. Separate target since it's outside Mist's own
# folder and (in principle, if this Mac ever ran another .NET app using
# IsolatedStorage) not exclusively Mist's to delete — kept explicit, not bundled
# into reset-all by default.
reset-depotdownloader-cache:
	rm -rf "$(HOME)/Library/Application Support/IsolatedStorage"
	@echo "DepotDownloader's cached Steam session cleared."

# Full reset: everything reset-steam does, PLUS the Wine engine itself — puts
# Mist back to the exact first-launch state (onboarding/"Download & Install"
# screen). Slow to recover from (~200MB Wine download) — only use this to
# specifically test first-run setup, not for routine iteration.
reset-all:
	@pkill -f "Mist.app/Contents/MacOS/Mist" 2>/dev/null || true
	@"$(PREFIX)/wine/bin/wineserver" -k 2>/dev/null || true
	@sleep 1
	rm -rf "$(PREFIX)"
	defaults delete com.mist.app 2>/dev/null || true
	@echo "Full reset done: Mist is back to first-launch state (Wine engine removed too)."

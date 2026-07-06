# Build targets for Mist
# Requires: Xcode command line tools (swiftc)

PREFIX ?= $(HOME)/Library/Application Support/Mist
CEF_DIR = $(PREFIX)/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64

# Bundle paths
BUNDLE = dist/Mist.app
BUNDLE_CONTENTS = $(BUNDLE)/Contents
BUNDLE_MACOS = $(BUNDLE_CONTENTS)/MacOS
BUNDLE_RESOURCES = $(BUNDLE_CONTENTS)/Resources

.PHONY: all app clean bundle release bundle-clean test-build test

all: app

# ── Developer targets (git-clone workflow) ────────────────────────────

# Native macOS SwiftUI app
app: Mist.app/Contents/MacOS/Mist

Mist.app/Contents/MacOS/Mist: MistApp.swift
	@mkdir -p Mist.app/Contents/MacOS
	swiftc -O -parse-as-library -o $@ $<
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > Mist.app/Contents/Info.plist
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> Mist.app/Contents/Info.plist
	@echo '<plist version="1.0"><dict>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleExecutable</key><string>Mist</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleIdentifier</key><string>com.mist.app</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleName</key><string>Mist</string>' >> Mist.app/Contents/Info.plist
	@echo '<key>CFBundleVersion</key><string>2.0</string>' >> Mist.app/Contents/Info.plist
	@echo '</dict></plist>' >> Mist.app/Contents/Info.plist
	codesign --force --deep -s - Mist.app

# ── Distribution targets (self-contained .app) ───────────────────────

bundle:
	@echo "Assembling Mist.app..."
	rm -rf dist/
	mkdir -p "$(BUNDLE_MACOS)" "$(BUNDLE_RESOURCES)"
	# Compile Swift app
	swiftc -O -parse-as-library -o "$(BUNDLE_MACOS)/Mist" MistApp.swift
	# Info.plist
	@echo '<?xml version="1.0" encoding="UTF-8"?>' > "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<plist version="1.0"><dict>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleExecutable</key><string>Mist</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleIdentifier</key><string>com.mist.app</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleName</key><string>Mist</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '<key>CFBundleVersion</key><string>2.0</string>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	@echo '</dict></plist>' >> "$(BUNDLE_CONTENTS)/Info.plist"
	# Ad-hoc code sign — no runtime resources to bundle; all setup/launch logic is
	# native Swift and Mist downloads DepotDownloader itself on first use
	codesign --force --deep -s - "$(BUNDLE)"
	@echo ""
	@echo "Bundle ready at dist/Mist.app"
	@echo "Test with: open dist/Mist.app"

release: bundle
	cd dist && zip -r Mist.zip Mist.app
	@echo "Release archive: dist/Mist.zip"

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
	rm -f tests/mach_syscall_test tests/nt_api_check.exe

bundle-clean:
	rm -rf dist/

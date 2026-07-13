import SwiftUI
import Cocoa
import Foundation
import CryptoKit
import CoreImage.CIFilterBuiltins
import GameController
import UniformTypeIdentifiers

// MARK: - Foglight design tokens
//
// Mist's visual identity: a dark shelf lit by a soft periwinkle glow, titles set
// in the system serif for a quieter voice than another sans-only launcher.
// Deliberately dark-only — a "daytime fog" mode would dilute the idea — so these
// are fixed hex values, not adaptive system colors.
enum Fog {
    static let bg = Color(red: 0x0d/255, green: 0x10/255, blue: 0x15/255)
    static let bgElevated = Color(red: 0x14/255, green: 0x17/255, blue: 0x1f/255)
    static let haze = Color(red: 0x1c/255, green: 0x21/255, blue: 0x30/255)
    static let hairline = Color(red: 0x26/255, green: 0x2c/255, blue: 0x3c/255)
    static let accent = Color(red: 0x7c/255, green: 0x9c/255, blue: 1.0)
    static let accentSoft = Fog.accent.opacity(0.14)
    static let ink = Color(red: 0xe9/255, green: 0xec/255, blue: 0xf5/255)
    static let inkDim = Color(red: 0x87/255, green: 0x90/255, blue: 0xa8/255)
    static let inkFaint = Color(red: 0x5b/255, green: 0x62/255, blue: 0x74/255)
    static let steam = Color(red: 0x6f/255, green: 0x9b/255, blue: 1.0)
    static let epic = Color(red: 0xb9/255, green: 0x8a/255, blue: 0xf0/255)
    static let custom = Color(red: 0x9a/255, green: 0xa4/255, blue: 0xb2/255)  // steel — a custom app isn't from a storefront
    static let good = Color(red: 0x6b/255, green: 0xcf/255, blue: 0x9a/255)
    static let warn = Color(red: 0xe6/255, green: 0xb3/255, blue: 0x58/255)
    static let display = Font.system(.title3, design: .serif)
    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
}

// MARK: - Data Models

enum GameSource: String, Codable {
    case steam = "Steam"
    case epic = "Epic"
    case custom = "My Apps"   // a .exe the user pointed Mist at directly — not from a store
}

enum AntiCheatStatus: String {
    case none = "None"
    case eacEOS = "EAC (EOS)"
    case eacLegacy = "EAC (Legacy)"
    case battleye = "BattlEye"
    case unknown = "Unknown"
}

struct Game: Identifiable, Hashable {
    let id: String          // appid for Steam, app_name for Epic
    let name: String
    let source: GameSource
    let installDir: String
    let sizeBytes: Int64
    let isInstalled: Bool
    var antiCheat: AntiCheatStatus = .none
    var hasLinuxEAC: Bool = false
    var imageURL: String = ""  // cover art URL
    var isFamilyShared: Bool = false  // available via Steam Family library sharing, not owned outright
    var playtimeMinutes: Int = 0     // total, from IPlayerService (0 if unknown)
    var lastPlayed: Date? = nil      // last time this account launched it
    var addedAt: Date? = nil         // when it first appeared in Mist's library (for the "New" ribbon)
    var customExePath: String? = nil // source == .custom: the exact .exe to launch (installDir is just its parent folder)

    var sizeFormatted: String {
        if sizeBytes > 1_073_741_824 {
            return String(format: "%.1f GB", Double(sizeBytes) / 1_073_741_824)
        } else if sizeBytes > 1_048_576 {
            return "\(sizeBytes / 1_048_576) MB"
        } else if sizeBytes > 0 {
            return "\(sizeBytes / 1024) KB"
        }
        return "—"
    }

    // "6h 40m" / "42m" / nil when never played.
    var playtimeFormatted: String? {
        guard playtimeMinutes > 0 else { return nil }
        let h = playtimeMinutes / 60, m = playtimeMinutes % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // "Yesterday" / "3 days ago" / "Jul 8" — a quiet recency line.
    var lastPlayedFormatted: String? {
        guard let lastPlayed else { return nil }
        let days = Calendar.current.dateComponents([.day], from: lastPlayed, to: Date()).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Yesterday"
        case 2...6: return "\(days) days ago"
        default:
            let f = DateFormatter(); f.dateFormat = "MMM d"
            return f.string(from: lastPlayed)
        }
    }

    // Freshly added to the library within the last day → gets a "New" ribbon.
    var isNew: Bool {
        guard let addedAt else { return false }
        return Date().timeIntervalSince(addedAt) < 24 * 3600
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }
}

// Decides how to actually run a game so the UI can offer one obvious "Play" button
// instead of a menu of cryptic runtime choices. Shared by the library card and the
// game detail view so they never disagree.
enum GameActions {
    struct Bundle {
        let onLaunch: () -> Void      // Epic's own launcher (legendary)
        let onLaunchNoEAC: () -> Void // direct exe, basic renderer
        let onLaunchGPTK: () -> Void  // D3DMetal (GPTK/CrossOver), also nulls anti-cheat
    }

    struct Alternate {
        let title: String
        let icon: String
        let run: (Bundle) -> Void
    }

    // The single best way to launch `game` right now.
    static func bestPlay(for game: Game, d3dMetalAvailable: Bool) -> (Bundle) -> Void {
        if game.source == .steam {
            // D3DMetal handles D3D11/12 far better than the built-in renderer; use it
            // when present, otherwise the direct launch.
            return d3dMetalAvailable ? { $0.onLaunchGPTK() } : { $0.onLaunchNoEAC() }
        }
        // Epic: an anti-cheat title can only run offline (Mist doesn't defeat anti-
        // cheat); D3DMetal's path already runs offline, so prefer it there.
        if game.antiCheat != .none { return d3dMetalAvailable ? { $0.onLaunchGPTK() } : { $0.onLaunchNoEAC() } }
        return { $0.onLaunch() }
    }

    // Everything the primary button DIDN'T pick, for the ••• menu.
    static func alternates(for game: Game, d3dMetalAvailable: Bool) -> [Alternate] {
        var out: [Alternate] = []
        if game.source == .steam {
            if d3dMetalAvailable {
                out.append(.init(title: "Play with basic renderer", icon: "square.stack.3d.up") { $0.onLaunchNoEAC() })
            }
        } else {
            if game.antiCheat == .none {
                out.append(.init(title: "Play offline (no anti-cheat)", icon: "shield.slash") {
                    d3dMetalAvailable ? $0.onLaunchGPTK() : $0.onLaunchNoEAC()
                })
            } else {
                out.append(.init(title: "Launch through Epic", icon: "arrowshape.turn.up.right") { $0.onLaunch() })
            }
        }
        return out
    }
}

// MARK: - Mist Environment (native Wine paths + env — no shell scripts)

enum MistEnv {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Mist")

    // Helper tools (AchievementRelay, patched DepotDownloader, gbe_fork DLLs) ship
    // inside the app bundle at Contents/Resources/tools (see `make tools`). Fall
    // back to the support dir for dev runs of the bare binary, or installs that
    // fetched a tool there. Wine itself is NOT bundled (too big) — still downloaded.
    static var toolsDir: URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("tools")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return supportDir.appendingPathComponent("tools")
    }

    static let wineDir = supportDir.appendingPathComponent("wine")
    static let winePrefix = supportDir
    static var wineBinary: URL { wineDir.appendingPathComponent("bin/wine") }
    static var wineserverBinary: URL { wineDir.appendingPathComponent("bin/wineserver") }

    // Wine binary AND lib/ AND share/ — an interrupted install is incomplete, not "installed"
    static var wineInstalled: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: wineBinary.path)
            && fm.fileExists(atPath: wineDir.appendingPathComponent("lib").path)
            && fm.fileExists(atPath: wineDir.appendingPathComponent("share").path)
    }

    // The Sikarugir CX engine ships no support dylibs (it expects the host app to
    // provide them) — they're merged in as a separate setup step. libinotify is the
    // marker: without it wineserver can't even start.
    static var runtimeLibsInstalled: Bool {
        FileManager.default.fileExists(
            atPath: wineDir.appendingPathComponent("lib/libinotify.0.dylib").path)
    }

    static func baseEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = winePrefix.path
        env["WINEARCH"] = "win64"
        env["WINEDATADIR"] = wineDir.appendingPathComponent("share/wine").path
        env["DYLD_LIBRARY_PATH"] = wineDir.appendingPathComponent("lib").path
        env["PATH"] = "\(wineDir.appendingPathComponent("bin").path):/usr/bin:/bin:/usr/sbin:/sbin"
        env["WINESERVER"] = wineserverBinary.path
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
        return env
    }

    @discardableResult
    static func run(_ tool: URL, _ args: [String], env: [String: String]? = nil,
                    cwd: URL? = nil) -> Int32 {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        if let env = env { p.environment = env }
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func killWineserver() {
        run(wineserverBinary, ["-k"], env: baseEnvironment())
    }

    static func waitWineserver() {
        run(wineserverBinary, ["-w"], env: baseEnvironment())
    }
}

struct SetupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Setup Manager (downloads Wine engine + Steam — all native)

final class SetupManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let engineName = "WS12WineCX24.0.7_7"
    static let engineURL = URL(string:
        "https://github.com/Sikarugir-App/Engines/releases/download/v1.0/WS12WineCX24.0.7_7.tar.xz")!
    static let engineSHA256 = "203f9e9fd6c2cc77e6525d798a434ced326145db34a356355e05659d3445fd1c"
    // Donor for support dylibs (freetype, gnutls, libinotify…) the CX engine doesn't
    // bundle. Only lib/*.dylib is taken from this archive — the Wine binaries in use
    // remain CrossOver's.
    static let runtimeLibsURL = URL(string:
        "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.7/wine-staging-11.7-osx64.tar.xz")!
    static let runtimeLibsSHA256 = "fd0b9e54c7c17d972d922b686301c37fe4f3e9986f01f49fdff858118c045d94"

    @Published var wineInstalled = MistEnv.wineInstalled && MistEnv.runtimeLibsInstalled
    @Published var isWorking = false
    @Published var statusText = ""
    @Published var downloadProgress: Double? = nil  // nil = indeterminate
    @Published var errorText: String?

    var isComplete: Bool { wineInstalled }

    func refresh() {
        wineInstalled = MistEnv.wineInstalled && MistEnv.runtimeLibsInstalled
    }

    func runFullSetup() {
        guard !isWorking else { return }
        isWorking = true
        errorText = nil
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                #if arch(arm64)
                if MistEnv.run(URL(fileURLWithPath: "/usr/bin/pgrep"), ["-q", "oahd"]) != 0 {
                    throw SetupError(message: "Rosetta 2 is required to run Wine on Apple Silicon.\nInstall it in Terminal:  softwareupdate --install-rosetta --agree-to-license")
                }
                #endif
                try FileManager.default.createDirectory(
                    at: MistEnv.supportDir, withIntermediateDirectories: true)
                if !MistEnv.wineInstalled { try await self.installWineEngine() }
                if !MistEnv.runtimeLibsInstalled { try await self.installRuntimeLibs() }
                try await self.initPrefixIfNeeded()
                await MainActor.run {
                    self.refresh()
                    self.isWorking = false
                    self.statusText = "Ready!"
                }
            } catch {
                await MainActor.run {
                    self.refresh()
                    self.isWorking = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    // ── Steps ─────────────────────────────────────────────────────────

    private func installWineEngine() async throws {
        let tarball = try await download(Self.engineURL,
                                         status: "Downloading Wine engine (CrossOver 24)…")
        defer { try? FileManager.default.removeItem(at: tarball) }

        await setStatus("Verifying checksum…", progress: nil)
        let hash = try sha256(of: tarball)
        guard hash == Self.engineSHA256 else {
            throw SetupError(message: "The Wine download failed checksum verification. Try again.")
        }

        await setStatus("Extracting Wine…", progress: nil)
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent("mist-engine-\(UUID().uuidString)")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }
        guard MistEnv.run(URL(fileURLWithPath: "/usr/bin/tar"),
                          ["xf", tarball.path, "-C", extractDir.path]) == 0 else {
            throw SetupError(message: "Failed to extract the Wine engine archive.")
        }
        // Sikarugir engines extract to wswine.bundle/ at the archive root
        let bundle = extractDir.appendingPathComponent("wswine.bundle")
        guard fm.isExecutableFile(atPath: bundle.appendingPathComponent("bin/wine").path) else {
            throw SetupError(message: "Unexpected engine archive layout (wswine.bundle missing).")
        }

        await setStatus("Installing Wine…", progress: nil)
        // Stage on the same filesystem, then one atomic rename — an interrupted copy
        // never leaves a half-installed (and falsely "complete") Wine tree.
        let staging = MistEnv.supportDir.appendingPathComponent("wine.staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        for sub in ["bin", "lib", "share"] {
            try fm.copyItem(at: bundle.appendingPathComponent(sub),
                            to: staging.appendingPathComponent(sub))
        }
        if fm.fileExists(atPath: MistEnv.wineDir.path) { try fm.removeItem(at: MistEnv.wineDir) }
        try fm.moveItem(at: staging, to: MistEnv.wineDir)
    }

    private func installRuntimeLibs() async throws {
        let tarball = try await download(Self.runtimeLibsURL,
                                         status: "Downloading runtime libraries…")
        defer { try? FileManager.default.removeItem(at: tarball) }

        await setStatus("Verifying checksum…", progress: nil)
        let hash = try sha256(of: tarball)
        guard hash == Self.runtimeLibsSHA256 else {
            throw SetupError(message: "The runtime libraries download failed checksum verification. Try again.")
        }

        await setStatus("Installing runtime libraries…", progress: nil)
        let fm = FileManager.default
        let extractDir = fm.temporaryDirectory.appendingPathComponent("mist-libs-\(UUID().uuidString)")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }
        guard MistEnv.run(URL(fileURLWithPath: "/usr/bin/tar"),
                          ["xf", tarball.path, "-C", extractDir.path]) == 0 else {
            throw SetupError(message: "Failed to extract the runtime libraries archive.")
        }
        guard let app = try fm.contentsOfDirectory(at: extractDir, includingPropertiesForKeys: nil)
            .first(where: { $0.lastPathComponent.hasSuffix(".app") }) else {
            throw SetupError(message: "Unexpected runtime libraries archive layout.")
        }
        let donorLib = app.appendingPathComponent("Contents/Resources/wine/lib")
        let targetLib = MistEnv.wineDir.appendingPathComponent("lib")
        // Copy every top-level dylib (and its version symlinks) into the engine's lib/.
        // These are generic support libraries — the Wine binaries stay CrossOver's.
        for item in try fm.contentsOfDirectory(at: donorLib, includingPropertiesForKeys: nil) {
            guard item.lastPathComponent.hasSuffix(".dylib") else { continue }
            let dst = targetLib.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: dst.path) { continue }
            try fm.copyItem(at: item, to: dst)
        }
        guard MistEnv.runtimeLibsInstalled else {
            throw SetupError(message: "Runtime libraries did not install correctly.")
        }
    }

    private func initPrefixIfNeeded() async throws {
        // Check drive_c/windows, not just drive_c — a failed wineboot can leave an
        // empty drive_c behind, which must not count as an initialized prefix.
        let windowsDir = MistEnv.winePrefix.appendingPathComponent("drive_c/windows")
        guard !FileManager.default.fileExists(atPath: windowsDir.path) else { return }
        await setStatus("Creating Wine prefix (first run takes a minute)…", progress: nil)
        MistEnv.run(MistEnv.wineBinary, ["wineboot", "--init"], env: MistEnv.baseEnvironment())
        MistEnv.waitWineserver()
        guard FileManager.default.fileExists(atPath: windowsDir.path) else {
            throw SetupError(message: "Failed to initialize the Wine prefix.")
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────

    private func setStatus(_ text: String, progress: Double?) async {
        await MainActor.run {
            self.statusText = text
            self.downloadProgress = progress
        }
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 8 * 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // ── Download with progress (URLSession delegate) ──────────────────

    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default,
                                          delegate: self, delegateQueue: nil)

    private func download(_ url: URL, status: String) async throws -> URL {
        await setStatus(status, progress: 0)
        return try await withCheckedThrowingContinuation { cont in
            self.downloadContinuation = cont
            self.session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.downloadProgress = frac }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
            downloadContinuation?.resume(throwing:
                SetupError(message: "Download failed (HTTP \(http.statusCode))."))
            downloadContinuation = nil
            return
        }
        let name = downloadTask.originalRequest?.url?.lastPathComponent ?? "download"
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(name)")
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            downloadContinuation?.resume(returning: dest)
        } catch {
            downloadContinuation?.resume(throwing: error)
        }
        downloadContinuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            downloadContinuation?.resume(throwing: error)
            downloadContinuation = nil
        }
    }
}

// MARK: - Game Scanner

// Find the full path to legendary, since .app bundles have a minimal PATH
class LegendaryLocator {
    static let shared = LegendaryLocator()
    lazy var path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Library/Frameworks/Python.framework/Versions/3.9/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.11/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/legendary",
            "/Library/Frameworks/Python.framework/Versions/3.13/bin/legendary",
            "/usr/local/bin/legendary",
            "/opt/homebrew/bin/legendary",
            "\(home)/.local/bin/legendary",
            "\(home)/Library/Python/3.9/bin/legendary",
            "\(home)/Library/Python/3.11/bin/legendary",
            "\(home)/Library/Python/3.12/bin/legendary",
        ]
        for p in candidates {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        // Last resort: try shell
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-l", "-c", "which legendary"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !out.isEmpty && FileManager.default.isExecutableFile(atPath: out) { return out }
        return "/usr/local/bin/legendary"
    }()
}

var legendaryPath: String { LegendaryLocator.shared.path }

class GameLibrary: ObservableObject {
    @Published var games: [Game] = []
    @Published var isScanning = false
    @Published var lastError: String?

    // scan() (local file/legendary scan) and applyOwnedSteamGames() (network fetch)
    // run independently and can finish in either order. Both write through
    // recomputeGames() instead of assigning `games` directly, so whichever finishes
    // last doesn't clobber the other's contribution.
    private var scannedGames: [Game] = []
    private var ownedSteamGames: [OwnedGame] = []
    private var familySharedGames: [FamilySharedGame] = []

    let supportDir = MistEnv.supportDir
    let wineDir = MistEnv.wineDir
    let steamAppsDir = MistEnv.supportDir
        .appendingPathComponent("drive_c/Program Files (x86)/Steam/steamapps")
    let epicDir = MistEnv.supportDir.appendingPathComponent("drive_c/Epic Games")

    var wineExists: Bool { MistEnv.wineInstalled }

    func scan() {
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var found: [Game] = []

            // Scan Steam games (fast, local file reads)
            found.append(contentsOf: scanSteamGames())

            // Scan Epic games (may call legendary, slower)
            found.append(contentsOf: scanEpicGames())

            // Detect anti-cheat for all games
            for i in found.indices {
                detectAntiCheat(game: &found[i])
            }

            // Custom apps: local JSON, no network/anti-cheat detection needed.
            found.append(contentsOf: CustomAppsManifest.asGames(supportDir: supportDir))

            DispatchQueue.main.async {
                self.scannedGames = found
                self.recomputeGames()
                self.isScanning = false
            }
        }
    }

    // MARK: - Custom apps (Phase 2: install/point-at any .exe)

    func addCustomApp(name: String, exePath: String) {
        CustomAppsManifest.add(name: name, exePath: exePath, supportDir: supportDir)
        scan()
    }

    func removeCustomApp(id: String) {
        CustomAppsManifest.remove(id: id, supportDir: supportDir)
        scan()
    }

    func relocateCustomApp(id: String, newExePath: String) {
        CustomAppsManifest.relocate(id: id, newExePath: newExePath, supportDir: supportDir)
        scan()
    }

    private func recomputeGames() {
        // Playtime / last-played come from the owned-games fetch (IPlayerService),
        // keyed by appid — overlay them onto every matching game, installed or not.
        let statsByID: [String: (playtime: Int, last: Int)] = Dictionary(
            ownedSteamGames.map { ($0.id, ($0.playtimeForever, $0.lastPlayed)) },
            uniquingKeysWith: { a, _ in a })
        func withStats(_ g: Game) -> Game {
            guard g.source == .steam, let s = statsByID[g.id] else { return g }
            var g = g
            g.playtimeMinutes = s.playtime
            g.lastPlayed = s.last > 0 ? Date(timeIntervalSince1970: TimeInterval(s.last)) : nil
            return g
        }

        let existingIDs = Set(scannedGames.filter { $0.source == .steam }.map(\.id))
        let placeholders = ownedSteamGames.filter { !existingIDs.contains($0.id) }.map { og in
            Game(id: og.id, name: og.name, source: .steam, installDir: "",
                sizeBytes: 0, isInstalled: false, imageURL: og.coverURL)
        }
        let ownedOrScannedIDs = existingIDs.union(ownedSteamGames.map(\.id))
        // Games available via Steam Family library sharing that this account doesn't
        // already own/have installed outright. Same install path as any other Steam
        // game (handleInstall/DepotDownloader) — Steam authorizes the download based
        // on the account's real (if temporary) family-shared license, no special-
        // casing needed there.
        var seenFamilyIDs = Set<String>()
        var seenFamilyNames = Set<String>()
        let familyPlaceholders = familySharedGames
            .filter {
                !ownedOrScannedIDs.contains($0.id) && seenFamilyIDs.insert($0.id).inserted
                    && seenFamilyNames.insert($0.name.lowercased()).inserted
            }
            .map { fg in
                Game(id: fg.id, name: fg.name, source: .steam, installDir: "",
                    sizeBytes: 0, isInstalled: false,
                    imageURL: SteamLibraryService.coverURL(forAppID: fg.id), isFamilyShared: true)
            }
        let merged = (scannedGames + placeholders + familyPlaceholders).map(withStats)
        games = stampFirstSeen(merged).sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // Records when each game first appeared so the "New" ribbon only marks genuinely
    // new arrivals — not the whole library on first run (that batch is backfilled as
    // "already seen"). Stored in UserDefaults as [gameKey: unix-seconds].
    private func stampFirstSeen(_ list: [Game]) -> [Game] {
        let key = "libraryFirstSeen"
        var seen = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let firstRun = seen.isEmpty
        let now = Date().timeIntervalSince1970
        var changed = false
        for g in list {
            let k = "\(g.source.rawValue):\(g.id)"
            if seen[k] == nil { seen[k] = firstRun ? 0 : now; changed = true }
        }
        if changed { UserDefaults.standard.set(seen, forKey: key) }
        return list.map { g in
            var g = g
            if let t = seen["\(g.source.rawValue):\(g.id)"], t > 0 { g.addedAt = Date(timeIntervalSince1970: t) }
            return g
        }
    }

    private func scanSteamGames() -> [Game] {
        var games: [Game] = []
        var seenIDs = Set<String>()
        let fm = FileManager.default

        if fm.fileExists(atPath: steamAppsDir.path) {
            let enumerator = fm.enumerator(atPath: steamAppsDir.path)
            while let file = enumerator?.nextObject() as? String {
                enumerator?.skipDescendants()
                guard file.hasPrefix("appmanifest_"), file.hasSuffix(".acf") else { continue }

                let manifestPath = steamAppsDir.appendingPathComponent(file).path
                guard let content = try? String(contentsOfFile: manifestPath, encoding: .utf8) else { continue }

                let name = vdfGet(content, key: "name") ?? "Unknown"
                let appid = vdfGet(content, key: "appid") ?? ""
                let installdir = vdfGet(content, key: "installdir") ?? ""
                let sizeStr = vdfGet(content, key: "SizeOnDisk") ?? "0"
                let size = Int64(sizeStr) ?? 0

                // Skip redistributables
                if name.contains("Redistributable") || name.contains("Proton") { continue }

                let gameDir = steamAppsDir
                    .appendingPathComponent("common")
                    .appendingPathComponent(installdir)

                games.append(Game(
                    id: appid,
                    name: name,
                    source: .steam,
                    installDir: gameDir.path,
                    sizeBytes: size,
                    isInstalled: fm.fileExists(atPath: gameDir.path)
                ))
                seenIDs.insert(appid)
            }
        }

        // Games Mist installed itself via DepotDownloader don't have a Steam-format
        // appmanifest.acf, so they're tracked separately — merge those in too.
        for g in MistManifest.installedGames(steamAppsDir: steamAppsDir) where !seenIDs.contains(g.id) {
            games.append(g)
            seenIDs.insert(g.id)
        }

        return games
    }

    // Owned-but-not-yet-installed Steam games (from the Web API) so they show up in
    // the library with an "Install" button, matching how Epic games already work.
    func applyOwnedSteamGames(_ owned: [OwnedGame]) {
        ownedSteamGames = owned
        recomputeGames()
    }

    // Games shared into this account's Steam Family library (see RelayManager.familyLibrary).
    func applyFamilyLibraryGames(_ shared: [FamilySharedGame]) {
        familySharedGames = shared
        recomputeGames()
    }

    // Handles both games Mist installed itself (tracked in mist_manifest.json,
    // the common case) and games with a real Steam-format appmanifest.acf (from
    // the legacy OLD/ CLI path) — whichever is present gets cleaned up.
    func uninstallSteamGame(_ game: Game) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: game.installDir)
        MistManifest.remove(appid: game.id, steamAppsDir: steamAppsDir)
        let acf = steamAppsDir.appendingPathComponent("appmanifest_\(game.id).acf")
        try? fm.removeItem(at: acf)
        scan()
    }

    private func scanEpicGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default

        // legendary isn't bundled — it's an optional, separately-installed CLI for
        // Epic support. If it's missing, Process.run() throws (silently swallowed by
        // try?), but reading from the pipe afterward then hangs forever waiting for a
        // process that never started, since nothing ever closes the write end. That
        // hang blocks scan() indefinitely, which also silently prevents the Steam
        // side of this same scan from ever completing — bail out early instead.
        guard fm.isExecutableFile(atPath: legendaryPath) else { return games }

        // 1. Get all owned games from legendary (includes uninstalled)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: legendaryPath)
        proc.arguments = ["list", "--platform", "Windows", "--json"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        // Read BEFORE waitUntilExit to avoid pipe buffer deadlock
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        // 2. Get installed games for cross-reference
        var installedApps: [String: [String: Any]] = [:]
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/legendary/installed.json")
        if let installedData = try? Data(contentsOf: installedPath),
           let installedJson = try? JSONSerialization.jsonObject(with: installedData) as? [String: Any] {
            for (key, val) in installedJson {
                if let info = val as? [String: Any] {
                    installedApps[key] = info
                }
            }
        }

        // 3. Parse owned games list
        if let jsonArray = try? JSONSerialization.jsonObject(with: outData) as? [[String: Any]] {
            for entry in jsonArray {
                let metadata = entry["metadata"] as? [String: Any] ?? [:]
                let appName = entry["app_name"] as? String ?? ""
                let title = entry["app_title"] as? String
                    ?? metadata["title"] as? String
                    ?? appName

                // Skip DLCs and add-ons
                if let mainGameList = metadata["mainGameItemList"] as? [[String: Any]], !mainGameList.isEmpty {
                    // This is likely a DLC
                    if let categories = metadata["categories"] as? [[String: String]] {
                        let isDLC = categories.contains { $0["path"] == "addons" || $0["path"] == "dlc" }
                        if isDLC { continue }
                    }
                }

                // Extract cover art URL (prefer tall portrait, fall back to wide box)
                var imageURL = ""
                if let keyImages = metadata["keyImages"] as? [[String: Any]] {
                    let tall = keyImages.first { ($0["type"] as? String) == "DieselGameBoxTall" }
                    let wide = keyImages.first { ($0["type"] as? String) == "DieselGameBox" }
                    let thumb = keyImages.first { ($0["type"] as? String) == "Thumbnail" }
                    imageURL = (tall ?? wide ?? thumb)?["url"] as? String ?? ""
                }

                let installed = installedApps[appName]
                let installPath = installed?["install_path"] as? String ?? ""
                let installSize = installed?["install_size"] as? Int64 ?? 0
                // Game is installed if legendary tracks it — the directory should exist
                let isInstalled = installed != nil && !installPath.isEmpty

                games.append(Game(
                    id: appName,
                    name: title,
                    source: .epic,
                    installDir: installPath,
                    sizeBytes: installSize,
                    isInstalled: isInstalled,
                    imageURL: imageURL
                ))
            }
        }

        return games
    }

    private func detectAntiCheat(game: inout Game) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: game.installDir) else { return }

        let gameURL = URL(fileURLWithPath: game.installDir)

        // Recursively search for anti-cheat files (max depth 4)
        if let enumerator = fm.enumerator(at: gameURL, includingPropertiesForKeys: nil,
                                           options: [.skipsHiddenFiles]) {
            var depth = 0
            while let fileURL = enumerator.nextObject() as? URL {
                // Approximate depth limit
                let components = fileURL.pathComponents.count - gameURL.pathComponents.count
                if components > 4 {
                    enumerator.skipDescendants()
                    continue
                }

                let filename = fileURL.lastPathComponent.lowercased()

                if filename.contains("easyanticheat") || filename.contains("eac") {
                    if filename.contains("eos_setup") || filename.contains("_eos") {
                        game.antiCheat = .eacEOS
                    } else if game.antiCheat == .none {
                        game.antiCheat = .eacLegacy
                    }
                    if filename == "easyanticheat_x64.so" {
                        game.hasLinuxEAC = true
                    }
                }

                if filename.contains("battleye") || filename.contains("beservice") {
                    game.antiCheat = .battleye
                }

                depth += 1
                if depth > 5000 { break } // safety limit
            }
        }
    }

    private func vdfGet(_ content: String, key: String) -> String? {
        let pattern = "\"\(key)\"\\s*\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let range = NSRange(content.startIndex..., in: content)
        if let match = regex.firstMatch(in: content, range: range) {
            if let valueRange = Range(match.range(at: 1), in: content) {
                return String(content[valueRange])
            }
        }
        return nil
    }
}

// MARK: - Steam Login (native QR / password, no Wine or embedded browser)
//
// Runs Valve's public IAuthenticationService directly over HTTPS — the same
// mechanism the Steam Mobile app and steamcommunity.com's own login page use.
// This gets us an instant native login window (matching GameHub's UX) without
// ever needing to render Steam's real client under Wine, which is what all the
// CEF/websocket rendering trouble was about.

struct SteamAuthError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct SteamAuthSession: Codable {
    var accountName: String
    var steamID: String
    var refreshToken: String
    // Issued directly by PollAuthSessionStatus at login time. Steam access tokens
    // last ~1 day, which comfortably covers a session — using this instead of
    // separately re-minting one via GenerateAccessTokenForApp avoids that endpoint's
    // audience-scope quirk entirely for as long as this token is still valid.
    var accessToken: String
}

final class SteamAuthManager: ObservableObject {
    @Published var isLoggedIn = false
    @Published var accountName: String = ""
    @Published var steamID: String = ""
    @Published var qrChallengeURL: String?
    @Published var qrStatusText: String = ""
    @Published var isPolling = false
    @Published var errorText: String?

    private var pollTask: Task<Void, Never>?
    private static let apiBase = "https://api.steampowered.com/IAuthenticationService"
    // Plain file, not Keychain: Keychain access is tied to the app's code signature,
    // and Mist is ad-hoc signed (no stable Developer ID identity). Every rebuild
    // re-signs it with a different signature, so macOS treats it as "a different app"
    // and re-prompts for Keychain access on every single launch after a rebuild.
    private static let sessionFileURL = MistEnv.supportDir.appendingPathComponent("steam_session.json")

    init() {
        loadSession()
    }

    // MARK: Session persistence

    private func saveSession(_ session: SteamAuthSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        try? FileManager.default.createDirectory(at: MistEnv.supportDir, withIntermediateDirectories: true)
        try? data.write(to: Self.sessionFileURL)
        // Owner read/write only — this file holds a bearer credential (Steam refresh
        // token), so it shouldn't be world-readable like a normal file defaults to.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: Self.sessionFileURL.path)
    }

    private func loadRawSession() -> SteamAuthSession? {
        guard let data = try? Data(contentsOf: Self.sessionFileURL) else { return nil }
        return try? JSONDecoder().decode(SteamAuthSession.self, from: data)
    }

    private func loadSession() {
        guard let session = loadRawSession() else { return }
        accountName = session.accountName
        steamID = session.steamID
        isLoggedIn = true
    }

    func logOut() {
        try? FileManager.default.removeItem(at: Self.sessionFileURL)
        isLoggedIn = false
        accountName = ""
        steamID = ""
    }

    // MARK: QR login

    private struct QRBegin {
        let clientID: String
        let challengeURL: String
        let requestID: String
        let interval: Double
    }

    func startQRLogin() {
        stopPolling()
        errorText = nil
        qrChallengeURL = nil
        qrStatusText = "Generating QR code…"
        pollTask = Task {
            do {
                let begin = try await beginAuthSessionViaQR()
                await MainActor.run {
                    self.qrChallengeURL = begin.challengeURL
                    self.qrStatusText = "Scan with the Steam Mobile app"
                }
                try await pollUntilConfirmed(clientID: begin.clientID, requestID: begin.requestID,
                                             interval: begin.interval)
            } catch is CancellationError {
                // expected on stopPolling()/view teardown
            } catch {
                await MainActor.run {
                    self.errorText = error.localizedDescription
                    self.qrStatusText = ""
                }
            }
        }
    }

    private func beginAuthSessionViaQR() async throws -> QRBegin {
        var request = URLRequest(url: URL(string: "\(Self.apiBase)/BeginAuthSessionViaQR/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let deviceName = Host.current().localizedName ?? "Mist"
        let encodedName = deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mist"
        // platform_type=1 (SteamClient) — this is the device requesting login (us),
        // not the device confirming it (the phone), so this should stay SteamClient
        // regardless of scope quirks below; platform_type=3 (MobileApp) broke the QR
        // flow itself (Steam Mobile reported "sign in request expired" right after
        // confirming), since this device isn't actually a phone.
        //
        // persistence=1 (ESessionPersistence_Persistent) is REQUIRED for the refresh
        // token to be reusable across multiple client-protocol logons. Without it
        // Steam issues an ephemeral token that dies after a single CM logon (and even
        // its renewal is then AccessDenied) — which is fine for Mist's own one-shot
        // Web-API use, but breaks anything that logs into Steam's CM repeatedly with
        // it (game downloads, the achievement relay). DepotDownloader sets the same
        // flag (IsPersistentSession=true), which is why its session survives reuse.
        request.httpBody = "device_friendly_name=\(encodedName)&platform_type=1&persistence=1".data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Steam login request failed (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        struct Resp: Decodable {
            struct Inner: Decodable {
                let client_id: String
                let challenge_url: String
                let request_id: String
                let interval: Double
            }
            let response: Inner
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return QRBegin(clientID: decoded.response.client_id, challengeURL: decoded.response.challenge_url,
                       requestID: decoded.response.request_id, interval: decoded.response.interval)
    }

    private func pollUntilConfirmed(clientID: String, requestID: String, interval: Double) async throws {
        await MainActor.run { self.isPolling = true }
        defer { Task { @MainActor in self.isPolling = false } }

        // ~15 minutes at the server-specified interval before giving up.
        let maxAttempts = max(1, Int(900 / max(interval, 1)))
        for _ in 0..<maxAttempts {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            var request = URLRequest(url: URL(string: "\(Self.apiBase)/PollAuthSessionStatus/v1/")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "client_id=\(clientID)&request_id=\(requestID)".data(using: .utf8)
            let (data, _) = try await URLSession.shared.data(for: request)

            struct Resp: Decodable {
                struct Inner: Decodable {
                    let refresh_token: String?
                    let access_token: String?
                    let account_name: String?
                    let had_remote_interaction: Bool?
                }
                let response: Inner
            }
            let decoded = try? JSONDecoder().decode(Resp.self, from: data)
            if let refreshToken = decoded?.response.refresh_token {
                let name = decoded?.response.account_name ?? "Steam User"
                let sid = Self.steamID(fromJWT: refreshToken) ?? ""
                let accessToken = decoded?.response.access_token ?? ""
                await MainActor.run {
                    self.saveSession(SteamAuthSession(accountName: name, steamID: sid,
                                                      refreshToken: refreshToken, accessToken: accessToken))
                    self.accountName = name
                    self.steamID = sid
                    self.isLoggedIn = true
                    self.qrChallengeURL = nil
                    self.qrStatusText = "Logged in as \(name)!"
                }
                return
            }
            if decoded?.response.had_remote_interaction == true {
                await MainActor.run { self.qrStatusText = "Confirm on your phone…" }
            }
        }
        throw SteamAuthError(message: "QR code expired. Try again.")
    }

    // Steam refresh tokens are JWTs; the steamid is the "sub" claim in the
    // (unsigned-here, unverified) payload segment — fine since we only read our
    // own freshly-issued token, we don't trust a token from elsewhere.
    private static func steamID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String else { return nil }
        return sub
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    // Refresh tokens last ~1 year; access tokens ~1 day. Web API calls that need an
    // access_token (e.g. GetOwnedGames) mint one fresh from the stored refresh token
    // via this endpoint rather than persisting a short-lived token ourselves.
    // Prefers the access_token Steam issued directly at login time (valid ~1 day) —
    // only re-mints one via GenerateAccessTokenForApp if we don't have that (shouldn't
    // normally happen) or it's been rejected by a caller.
    func mintAccessToken(forceRenew: Bool = false) async throws -> String {
        guard let session = loadRawSession() else {
            throw SteamAuthError(message: "Not logged in.")
        }
        if !forceRenew && !session.accessToken.isEmpty {
            return session.accessToken
        }

        var request = URLRequest(url: URL(string: "\(Self.apiBase)/GenerateAccessTokenForApp/v1/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "refresh_token=\(session.refreshToken.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&steamid=\(session.steamID)"
        request.httpBody = body.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Could not refresh Steam session (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)). Try logging in again.")
        }
        struct Resp: Decodable {
            struct Inner: Decodable { let access_token: String? }
            let response: Inner
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data),
              let token = decoded.response.access_token else {
            throw SteamAuthError(message: "Steam session expired. Please log in again.")
        }
        var updated = session
        updated.accessToken = token
        saveSession(updated)
        return token
    }
}

func steamQRCodeImage(from string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
}

// MARK: - Steam Owned Games (Web API)

struct OwnedGame: Identifiable, Hashable {
    let id: String  // appid
    let name: String
    let playtimeForever: Int
    let coverURL: String
    var lastPlayed: Int = 0   // unix seconds, 0 if never
}

enum SteamLibraryService {
    static func fetchOwnedGames(accessToken: String, steamID: String) async throws -> [OwnedGame] {
        var comps = URLComponents(string: "https://api.steampowered.com/IPlayerService/GetOwnedGames/v1/")!
        comps.queryItems = [
            URLQueryItem(name: "steamid", value: steamID),
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Could not fetch your Steam library (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        struct Resp: Decodable {
            struct Game: Decodable {
                let appid: Int
                let name: String?
                let playtime_forever: Int?
            }
            struct Inner: Decodable { let games: [Game]? }
            let response: Inner
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        return (decoded.response.games ?? []).map { g in
            OwnedGame(id: String(g.appid), name: g.name ?? "Unknown App \(g.appid)",
                     playtimeForever: g.playtime_forever ?? 0, coverURL: coverURL(forAppID: String(g.appid)))
        }
    }

    // Steam's own library "capsule" art, keyed purely by appid (no per-game hash
    // needed) — much higher resolution than GetOwnedGames' tiny 32x32 img_icon_url,
    // and matches what the real Steam client's library shows. Deterministic from the
    // appid alone, so it can be reconstructed anywhere a Game needs one (e.g. for
    // Mist-installed games, which don't come from this API response at all).
    static func coverURL(forAppID appid: String) -> String {
        "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_600x900.jpg"
    }

    // Wide "hero" art for the game detail banner — much more dramatic than the
    // store's 460x215 header.jpg, same deterministic-from-appid pattern as the
    // library capsule above.
    static func heroURL(forAppID appid: String) -> String {
        "https://cdn.cloudflare.steamstatic.com/steam/apps/\(appid)/library_hero.jpg"
    }

    // This game's achievement list + the user's unlock status, read over Steam's
    // client protocol by the bundled AchievementRelay helper — powered by Mist's
    // single QR login (no Steam Web API key, no Steam client running). See
    // RelayManager. The old ISteamUserStats/GetPlayerAchievements path needed a
    // separate Web API key because it rejects the user access_token; the client
    // protocol has no such restriction.
    static func fetchAchievements(appid: String, steamID: String) async throws -> [SteamAchievement] {
        try await RelayManager.achievements(appid: appid)
    }

    // Global unlock rarity — what fraction of ALL owners have each achievement.
    // Public, keyless. Keyed by apiname, so it joins directly onto the per-user
    // list from fetchAchievements. Returns [apiname: percent].
    static func fetchGlobalAchievementPercents(appid: String) async -> [String: Double] {
        var comps = URLComponents(string: "https://api.steampowered.com/ISteamUserStats/GetGlobalAchievementPercentagesForApp/v2/")!
        comps.queryItems = [URLQueryItem(name: "gameid", value: appid)]
        guard let url = comps.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [:] }
        struct Resp: Decodable {
            struct Entry: Decodable { let name: String; let percent: Double }
            struct Inner: Decodable { let achievements: [Entry]? }
            let achievementpercentages: Inner?
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { return [:] }
        var map: [String: Double] = [:]
        for e in decoded.achievementpercentages?.achievements ?? [] { map[e.name] = e.percent }
        return map
    }

    // Real achievement icons. Steam's client-protocol schema (what the relay reads
    // for viewing/unlocking) carries only name/description/hidden — no icon fields
    // at all, confirmed by dumping a live schema — and the Web API's schema
    // endpoint that DOES include icons (ISteamUserStats/GetSchemaForGame) requires
    // a per-developer Web API key, which Mist deliberately doesn't ask users for.
    // The public, keyless community stats page lists the same game's achievements
    // with real icon URLs, in the same order the schema defines them in — so we
    // scrape that ordering and zip it onto the relay's list positionally. Global,
    // not per-user (same icon for everyone), so this needs no login either.
    static func fetchAchievementIcons(appid: String) async -> [String] {
        guard let url = URL(string: "https://steamcommunity.com/stats/\(appid)/achievements/"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return [] }
        // Each achievement row embeds one icon <img src="https://.../community_assets/images/apps/<appid>/<hash>.jpg">.
        guard let regex = try? NSRegularExpression(
            pattern: #"https://[^"']+/community_assets/images/apps/\#(appid)/[a-fA-F0-9]+\.jpg"#
        ) else { return [] }
        let ns = html as NSString
        var urls: [String] = []
        var seen = Set<String>()
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range)
            if seen.insert(u).inserted { urls.append(u) }
        }
        return urls
    }

    // Browse an app's Workshop. Uses the logged-in user's access_token (the same
    // webapi token GetOwnedGames/GetPlayerAchievements accept). If Steam rejects
    // it, throws — the caller keeps the manual URL/ID install path as a fallback.
    // query_type 3 = RankedByTrend (what the Workshop "Popular" tab shows).
    static func fetchWorkshopItems(appid: String, accessToken: String, page: Int = 1,
                                   search: String = "") async throws -> [WorkshopBrowseItem] {
        var comps = URLComponents(string: "https://api.steampowered.com/IPublishedFileService/QueryFiles/v1/")!
        var items = [
            URLQueryItem(name: "access_token", value: accessToken),
            URLQueryItem(name: "appid", value: appid),
            URLQueryItem(name: "numperpage", value: "30"),
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "query_type", value: search.isEmpty ? "3" : "12"),
            URLQueryItem(name: "return_metadata", value: "true"),
            URLQueryItem(name: "return_previews", value: "true"),
            URLQueryItem(name: "return_short_description", value: "true"),
            URLQueryItem(name: "filetype", value: "0"),
        ]
        if !search.isEmpty { items.append(URLQueryItem(name: "search_text", value: search)) }
        comps.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse else {
            throw SteamAuthError(message: "Couldn't reach the Steam Workshop.")
        }
        guard http.statusCode == 200 else {
            throw SteamAuthError(message: "Steam wouldn't authorize a Workshop search (HTTP \(http.statusCode)). You can still install items by ID below.")
        }
        struct Resp: Decodable {
            struct Inner: Decodable { let publishedfiledetails: [WorkshopBrowseItem]? }
            let response: Inner?
        }
        let decoded = try JSONDecoder().decode(Resp.self, from: data)
        // Only items that actually resolved (result == 1) and aren't hidden.
        return (decoded.response?.publishedfiledetails ?? []).filter { $0.result == 1 }
    }

    // Search the whole Steam catalog — not just what the user owns — so Mist can
    // show games to browse/wishlist even if they're not installed or owned. Public,
    // keyless; the same endpoint store.steampowered.com's own search box calls.
    static func searchStore(query: String) async throws -> [StoreSearchResult] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        var comps = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        comps.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "cc", value: "us"),
            URLQueryItem(name: "l", value: "english"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Couldn't reach the Steam store.")
        }
        struct Resp: Decodable { let items: [StoreSearchResult] }
        return try JSONDecoder().decode(Resp.self, from: data).items
    }

    // Public store metadata (description, tags) — no login needed, same endpoint
    // the store page itself uses.
    static func fetchAppDetails(appid: String) async throws -> SteamAppDetails {
        var comps = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        comps.queryItems = [
            URLQueryItem(name: "appids", value: appid),
            URLQueryItem(name: "l", value: "english"),
        ]
        let (data, response) = try await URLSession.shared.data(from: comps.url!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Couldn't load the store page for this game.")
        }
        struct Wrapper: Decodable { let success: Bool; let data: SteamAppDetails? }
        let decoded = try JSONDecoder().decode([String: Wrapper].self, from: data)
        guard let wrapper = decoded[appid], wrapper.success, let details = wrapper.data else {
            throw SteamAuthError(message: "No store page found for this game.")
        }
        return details
    }
}

struct SteamAchievement: Identifiable, Decodable {
    var id: String { apiname }
    let apiname: String
    let achieved: Int
    let unlocktime: Int?
    let name: String?
    let description: String?
    // Joined in from GetGlobalAchievementPercentagesForApp after fetch (not part
    // of the GetPlayerAchievements response, so it's a mutable overlay).
    var globalPercent: Double? = nil
    // Joined in from fetchAchievementIcons after fetch — see that function for why
    // this can't come from the relay/client-protocol schema.
    var iconURL: String? = nil

    private enum CodingKeys: String, CodingKey {
        case apiname, achieved, unlocktime, name, description
    }

    var rarityLabel: String? {
        guard let p = globalPercent else { return nil }
        if p < 5 { return "Ultra Rare" }
        if p < 15 { return "Rare" }
        return nil
    }
}

struct SteamAppDetails: Decodable {
    struct Genre: Decodable { let description: String }
    struct Screenshot: Decodable { let id: Int; let path_full: String? }
    struct Release: Decodable { let date: String? }
    let short_description: String?
    let genres: [Genre]?
    let developers: [String]?
    let publishers: [String]?
    let screenshots: [Screenshot]?
    let release_date: Release?

    var genreNames: [String] { (genres ?? []).map(\.description) }
    var developerName: String? { developers?.first ?? publishers?.first }
    // Steam returns "8 Jun, 2021" etc.; pull a year if present.
    var releaseYear: String? {
        guard let d = release_date?.date else { return nil }
        if let m = d.range(of: #"\d{4}"#, options: .regularExpression) { return String(d[m]) }
        return nil
    }
    var screenshotURLs: [String] { (screenshots ?? []).compactMap(\.path_full) }
}

// One result from the public storesearch API — the wider Steam catalog, not
// filtered to what the signed-in account owns.
struct StoreSearchResult: Identifiable, Decodable {
    let id: Int
    let name: String
    let tiny_image: String?
    struct Price: Decodable { let final_formatted: String? }
    let price: Price?
    var appid: String { String(id) }
    // The search API only includes `price` for some listings even when the game
    // isn't free, so an absent price means "unknown," not "free" — don't guess.
    var priceLabel: String { price?.final_formatted ?? "View on Steam" }
}

// One Epic Games Store weekly free promotion. Mist can't run Epic's checkout
// flow (that needs an authenticated purchase-flow call we don't reverse-
// engineer — see claimURL), so this is a discovery surface: what's free right
// now / coming up, with a direct link to actually claim it on epicgames.com.
struct EpicFreeGame: Identifiable {
    let id: String
    let title: String
    let imageURL: String?
    let pageSlug: String?
    let endDate: Date?
    let isCurrentlyFree: Bool

    var claimURL: URL? {
        guard let pageSlug else { return URL(string: "https://store.epicgames.com/en-US/free-games") }
        return URL(string: "https://store.epicgames.com/en-US/p/\(pageSlug)")
    }
}

enum EpicPromotionsService {
    // Public, keyless endpoint — the same one store.epicgames.com's own free-games
    // shelf calls. No Epic login needed to see what's free.
    static func fetchFreeGames() async -> [EpicFreeGame] {
        guard let url = URL(string: "https://store-site-backend-static.ak.epicgames.com/freeGamesPromotions?locale=en-US&country=US&allowCountries=US"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }

        struct Resp: Decodable {
            struct DataWrap: Decodable { let Catalog: Catalog }
            struct Catalog: Decodable { let searchStore: SearchStore }
            struct SearchStore: Decodable { let elements: [Element] }
            struct Element: Decodable {
                let title: String
                let id: String
                let keyImages: [KeyImage]?
                let offerMappings: [Mapping]?
                let promotions: Promotions?
            }
            struct KeyImage: Decodable { let type: String; let url: String }
            struct Mapping: Decodable { let pageSlug: String }
            struct Promotions: Decodable {
                let promotionalOffers: [OfferWindow]?
                let upcomingPromotionalOffers: [OfferWindow]?
            }
            struct OfferWindow: Decodable { let promotionalOffers: [Offer] }
            struct Offer: Decodable { let endDate: String }
            let data: DataWrap
        }
        guard let decoded = try? JSONDecoder().decode(Resp.self, from: data) else { return [] }

        let iso = ISO8601DateFormatter()
        return decoded.data.Catalog.searchStore.elements.compactMap { el -> EpicFreeGame? in
            let active = el.promotions?.promotionalOffers?.first?.promotionalOffers.first
            let upcoming = el.promotions?.upcomingPromotionalOffers?.first?.promotionalOffers.first
            guard let window = active ?? upcoming else { return nil }
            let image = el.keyImages?.first(where: { $0.type == "OfferImageWide" || $0.type == "Thumbnail" })?.url
            return EpicFreeGame(
                id: el.id, title: el.title, imageURL: image,
                pageSlug: el.offerMappings?.first?.pageSlug,
                endDate: iso.date(from: window.endDate),
                isCurrentlyFree: active != nil
            )
        }
    }
}

struct WorkshopBrowseItem: Identifiable, Decodable {
    var id: String { publishedfileid }
    let publishedfileid: String
    let result: Int
    let title: String?
    let short_description: String?
    let preview_url: String?
    let file_size: String?   // bytes, as a string
    let time_updated: Int?
    let subscriptions: Int?
    let favorited: Int?

    var sizeFormatted: String? {
        guard let s = file_size, let bytes = Int64(s), bytes > 0 else { return nil }
        if bytes > 1_073_741_824 { return "\(bytes / 1_073_741_824) GB" }
        if bytes > 1_048_576 { return "\(bytes / 1_048_576) MB" }
        return "\(bytes / 1024) KB"
    }
}

// MARK: - Achievement Relay (client protocol via Mist's single login)

// Bridges to the bundled AchievementRelay helper (a self-contained SteamKit2 tool,
// like DepotDownloader) which speaks Steam's client protocol using Mist's single
// QR-login session — reading achievement state and (when a game unlocks one)
// writing it to the real profile, with no Steam Web API key and no Steam client.
enum RelayManager {
    static var binaryPath: URL { MistEnv.toolsDir.appendingPathComponent("AchievementRelay") }
    static var sessionPath: URL { MistEnv.supportDir.appendingPathComponent("steam_session.json") }
    static var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: binaryPath.path) }

    // Runs the relay off the main thread and returns its stdout (JSON). The read
    // happens on a background queue so the pipe never deadlocks and the UI never
    // blocks on the ~seconds-long Steam round-trip.
    private static func run(_ args: [String]) async throws -> Data {
        guard isInstalled else { throw SteamAuthError(message: "The achievements helper isn't installed yet.") }
        guard FileManager.default.fileExists(atPath: sessionPath.path) else {
            throw SteamAuthError(message: "Sign in to Steam first to load achievements.")
        }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = binaryPath
                p.arguments = [sessionPath.path] + args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = FileHandle.nullDevice
                do { try p.run() } catch { cont.resume(throwing: error); return }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                if p.terminationStatus == 0 {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: SteamAuthError(message: "This game has no achievements, or they couldn't be loaded."))
                }
            }
        }
    }

    static func achievements(appid: String) async throws -> [SteamAchievement] {
        let data = try await run([appid])
        return try JSONDecoder().decode([SteamAchievement].self, from: data)
    }

    // Push one achievement to the real Steam profile. Returns true when it's
    // confirmed present afterward — either freshly stored (ok) OR already earned
    // (alreadyUnlocked), since "already on your profile" is a success, not a
    // failure, for our sync-what-you-earned flow.
    @discardableResult
    static func unlock(appid: String, apiname: String) async throws -> Bool {
        let data = try await run([appid, "--unlock", apiname])
        struct R: Decodable { let ok: Bool?; let alreadyUnlocked: Bool? }
        let r = try? JSONDecoder().decode(R.self, from: data)
        return (r?.ok ?? false) || (r?.alreadyUnlocked ?? false)
    }

    // The achievement schema in gbe_fork's steam_settings/achievements.json format.
    static func gbeSchema(appid: String) async throws -> Data {
        try await run([appid, "--schema"])
    }

    // Steam Family library sharing: appids another family member owns that this
    // account can currently install/play, over the same client-protocol session
    // (no separate family-management login). Empty array if not in a family.
    static func familyLibrary() async throws -> [FamilySharedGame] {
        let data = try await run(["--family"])
        return try JSONDecoder().decode([FamilySharedGame].self, from: data)
    }

    // The account's own owned games over the same client-protocol session — used
    // instead of the Steam Web API's GetOwnedGames (which needs a separately-minted
    // web token Mist's one-QR flow doesn't reliably have). Empty on any failure.
    static func ownedLibrary() async throws -> [RelayOwnedGame] {
        let data = try await run(["--owned"])
        return try JSONDecoder().decode([RelayOwnedGame].self, from: data)
    }
}

struct FamilySharedGame: Decodable {
    let appid: Int
    let name: String
    let ownerSteamID: UInt64
    var id: String { String(appid) }
}

struct RelayOwnedGame: Decodable {
    let appid: Int
    let name: String
    var playtimeForever: Int = 0   // minutes
    var lastPlayed: Int = 0        // unix seconds, 0 if never
    var id: String { String(appid) }
}

// MARK: - GBE (Steamworks emulator) — in-game achievements + overlay

// Deploys gbe_fork's steam_api64.dll/steamclient64.dll/overlay into a game so it
// runs under Wine thinking Steam is present — recording achievement unlocks (and
// showing the overlay) with no Steam client. Unlocks land in a local gse_save/
// folder next to the exe; after the game exits, syncAchievements() pushes any new
// Deploys DXVK-macOS (a MoltenVK-tuned DXVK) into the Wine prefix so D3D10/11
// games render on Mist's OWN engine — no CrossOver or Game Porting Toolkit
// needed. Stock upstream DXVK can't do this on Apple Silicon (it needs Vulkan
// 1.3 + geometry/tessellation shaders the GPU lacks); this build targets Vulkan
// 1.1 and relaxes those. Verified to bring up a native "Apple M2" D3D11 device.
// D3D12-only titles still need the D3DMetal path (D3DMetalProvider); D3D12 games
// with a D3D11 fallback (most Unity) auto-select DXVK here and work.
enum DXVKManager {
    static var dllDir: URL { MistEnv.toolsDir.appendingPathComponent("dxvk") }
    static var isBundled: Bool {
        FileManager.default.fileExists(atPath: dllDir.appendingPathComponent("d3d11.dll").path)
    }

    // The DXVK-macOS DLLs to drop over wine's builtins. dxgi stays builtin — this
    // build pairs with wine's dxgi rather than shipping its own.
    private static let dlls = ["d3d11.dll", "d3d10core.dll"]

    // WINEDLLOVERRIDES value: DXVK d3d11/d3d10core as native, everything else
    // (dxgi, d3d12, d3d9) left to wine's builtins. Only meaningful once deploy()
    // has copied the DLLs into system32.
    static let overrides = "d3d11,d3d10core=n;dxgi,d3d9,d3d12,d3d12core=b"

    // Copy the DLLs into the prefix's system32 (idempotent — skips if the bundled
    // and installed files already match by size). Safe to call before every launch.
    static func deployIfNeeded() {
        guard isBundled else { return }
        let fm = FileManager.default
        let sys32 = MistEnv.winePrefix.appendingPathComponent("drive_c/windows/system32")
        guard fm.fileExists(atPath: sys32.path) else { return }
        for name in dlls {
            let src = dllDir.appendingPathComponent(name)
            let dst = sys32.appendingPathComponent(name)
            let srcSize = (try? fm.attributesOfItem(atPath: src.path)[.size] as? Int) ?? nil
            let dstSize = (try? fm.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? nil
            if srcSize != nil, srcSize == dstSize { continue }  // already deployed
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }
}

// ones to the real Steam profile via RelayManager. This is the emulator half of
// the in-game achievements feature; the relay is the "make it real" half.
enum GBEManager {
    static var dllDir: URL { MistEnv.toolsDir.appendingPathComponent("gbe") }
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: dllDir.appendingPathComponent("steam_api64.dll").path)
    }

    // Portable save dir gbe_fork writes unlocks into (set via local_save_path),
    // relative to the game's steam_api64.dll. Kept local so Mist can read it back.
    static let saveDirName = "gse_save"

    // Swap gbe_fork's DLLs into the game dir + write steam_settings. Idempotent:
    // the game's original steam_api64.dll is backed up once to .mist-orig so the
    // swap can be reverted, and re-deploying just refreshes the emu files.
    static func deploy(gameDir: String, appid: String) throws {
        guard isInstalled else { throw SteamAuthError(message: "The achievements emulator isn't installed yet.") }
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: gameDir)

        // steam_api64.dll sits wherever the game keeps it — find it (some games
        // nest it under a data subfolder). Deploy beside each one we find.
        let apiDLLs = locateSteamAPIDLLs(in: dir)
        let targets = apiDLLs.isEmpty ? [dir.appendingPathComponent("steam_api64.dll")] : apiDLLs
        for target in targets {
            let folder = target.deletingLastPathComponent()
            // Back up the original once.
            let backup = target.appendingPathExtension("mist-orig")
            if fm.fileExists(atPath: target.path), !fm.fileExists(atPath: backup.path) {
                try? fm.moveItem(at: target, to: backup)
            }
            try? fm.removeItem(at: target)
            try fm.copyItem(at: dllDir.appendingPathComponent("steam_api64.dll"), to: target)
            for extra in ["steamclient64.dll", "GameOverlayRenderer64.dll"] {
                let dst = folder.appendingPathComponent(extra)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: dllDir.appendingPathComponent(extra), to: dst)
            }
            try writeSteamSettings(in: folder, appid: appid)
        }
    }

    private static func writeSteamSettings(in folder: URL, appid: String) throws {
        let fm = FileManager.default
        let settings = folder.appendingPathComponent("steam_settings")
        try fm.createDirectory(at: settings, withIntermediateDirectories: true)
        try appid.write(to: settings.appendingPathComponent("steam_appid.txt"), atomically: true, encoding: .utf8)
        // Portable local saves so unlocks land in <folder>/gse_save/ for the sync.
        let userIni = "[user::saves]\nlocal_save_path=./\(saveDirName)\n"
        try userIni.write(to: settings.appendingPathComponent("configs.user.ini"), atomically: true, encoding: .utf8)
    }

    // Fetch the game's achievement schema and write it into every steam_settings
    // folder as achievements.json. CRITICAL: gbe_fork silently ignores any
    // SetAchievement() call for an achievement not in this schema, so without it
    // nothing is ever recorded. Fetched over the client protocol (Mist's login) —
    // best-effort: a game with no achievements, or a transient Steam hiccup, just
    // means no schema (the game still runs fine).
    static func installSchema(gameDir: String, appid: String) async {
        guard let data = try? await RelayManager.gbeSchema(appid: appid), data.count > 2 else { return }
        for folder in steamSettingsFolders(in: gameDir) {
            try? data.write(to: folder.appendingPathComponent("achievements.json"))
        }
    }

    // Synchronous scan (kept out of async context — DirectoryEnumerator iteration
    // isn't async-safe) for every steam_settings folder deploy created.
    private static func steamSettingsFolders(in gameDir: String) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: URL(fileURLWithPath: gameDir), includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.lastPathComponent == "steam_settings" { out.append(url) }
        return out
    }

    // Find the game's steam_api64.dll(s), skipping ones we already replaced.
    private static func locateSteamAPIDLLs(in root: URL) -> [URL] {
        var found: [URL] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return found }
        for case let url as URL in en where url.lastPathComponent == "steam_api64.dll" {
            found.append(url)
        }
        return found
    }

    // API names of achievements gbe_fork recorded as unlocked during play. It
    // writes them under <dll folder>/gse_save/<appid>/achievements.json; we scan
    // for any such file (the dll can be nested) and read the earned entries.
    // Parser is deliberately lenient about gbe_fork's exact on-disk shape.
    static func locallyUnlocked(gameDir: String, appid: String) -> [String] {
        let fm = FileManager.default
        var result: Set<String> = []
        guard let en = fm.enumerator(at: URL(fileURLWithPath: gameDir), includingPropertiesForKeys: nil) else { return [] }
        for case let url as URL in en where url.lastPathComponent == "achievements.json"
            && url.deletingLastPathComponent().pathComponents.contains(saveDirName) {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            for (name, val) in obj {
                if let d = val as? [String: Any] {
                    let earned = (d["earned"] as? Bool) ?? ((d["earned"] as? Int) == 1)
                        || ((d["Achieved"] as? Int) == 1) || ((d["achieved"] as? Int) == 1)
                    if earned { result.insert(name) }
                }
            }
        }
        return Array(result)
    }
}

// MARK: - Steam Game Downloads (DepotDownloader — native, no Wine needed to download)
//
// DepotDownloader (SteamRE, MIT) talks Steam's real depot protocol directly, so games
// can be downloaded without ever running Steam's own client under Wine. It manages its
// own Steam session (a deeper CM connection than SteamAuthManager's lightweight Web API
// calls), so the first download may prompt its own QR scan; the session is then cached
// on disk for subsequent installs.

// Mist downloads and manages DepotDownloader itself — no Homebrew, no external
// package manager. This also sidesteps Gatekeeper: Homebrew's cask installer applies
// com.apple.quarantine to DepotDownloader (it's only ad-hoc signed, so quarantined
// binaries get blocked until the user manually approves them in System Settings).
// A file Mist downloads and extracts itself (via URLSession + /usr/bin/unzip, the
// same pattern already used for the Wine engine) never gets that attribute set, so
// it just runs.
enum DepotDownloaderManager {
    static let version = "3.4.0"
    #if arch(arm64)
    static let downloadURL = URL(string:
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-macos-arm64.zip")!
    static let sha256 = "60e80c7c496f3f9a079cd3c62036b35d088c27bc0149baf38f009eb57a52f6a5"
    #else
    static let downloadURL = URL(string:
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_3.4.0/DepotDownloader-macos-x64.zip")!
    static let sha256 = "3214b689564d73e9342a8a4aef693de6ad3d293801b0f300a4466f60ec75befb"
    #endif

    static var installPath: URL {
        MistEnv.toolsDir.appendingPathComponent("DepotDownloader")
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: installPath.path)
    }

    // Downloads, verifies, and extracts DepotDownloader into Mist's own support
    // directory. Safe to call repeatedly — no-ops once installed.
    static func ensureInstalled(progress: @escaping (String) -> Void) async throws {
        guard !isInstalled else { return }

        progress("Downloading DepotDownloader…")
        let (tmpFile, response) = try await URLSession.shared.download(from: downloadURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SteamAuthError(message: "Failed to download DepotDownloader (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)).")
        }
        let fm = FileManager.default
        // download(from:)'s temp file is removed as soon as this function returns
        // control to the caller once, so move it somewhere stable before awaiting again.
        let zipPath = fm.temporaryDirectory.appendingPathComponent("depotdownloader-\(UUID().uuidString).zip")
        try fm.moveItem(at: tmpFile, to: zipPath)
        defer { try? fm.removeItem(at: zipPath) }

        progress("Verifying checksum…")
        guard try sha256Hex(of: zipPath) == sha256 else {
            throw SteamAuthError(message: "DepotDownloader download failed checksum verification. Try again.")
        }

        progress("Installing DepotDownloader…")
        let extractDir = fm.temporaryDirectory.appendingPathComponent("depotdownloader-extract-\(UUID().uuidString)")
        try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: extractDir) }
        guard MistEnv.run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-o", zipPath.path, "-d", extractDir.path]) == 0 else {
            throw SteamAuthError(message: "Failed to extract the DepotDownloader archive.")
        }
        let extractedBinary = extractDir.appendingPathComponent("DepotDownloader")
        guard fm.fileExists(atPath: extractedBinary.path) else {
            throw SteamAuthError(message: "Unexpected DepotDownloader archive layout.")
        }

        try fm.createDirectory(at: installPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: installPath.path) { try fm.removeItem(at: installPath) }
        try fm.moveItem(at: extractedBinary, to: installPath)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installPath.path)
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 8 * 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private struct MistInstalledGame: Codable {
    let appid: String
    let name: String
    let installDir: String
    let sizeBytes: Int64
}

// Windows (and therefore Wine) silently strip trailing dots and spaces from every
// path component. A game whose Steam title ends in one — e.g. "Easy Delivery Co."
// — installs into a folder Wine then can't address, so launching fails with
// "could not open working directory". Trim those trailing chars (and replace "/")
// so the on-disk folder name is Wine-safe.
func wineSafeDirName(_ name: String) -> String {
    var s = name.replacingOccurrences(of: "/", with: "-")
    while let c = s.last, c == "." || c == " " { s.removeLast() }
    return s.isEmpty ? "game" : s
}

// DepotDownloader doesn't write Steam-format appmanifest_*.acf files, so Mist tracks
// what it has installed itself in a small JSON file alongside the real Steam manifests.
enum MistManifest {
    static func fileURL(steamAppsDir: URL) -> URL {
        steamAppsDir.appendingPathComponent("mist_manifest.json")
    }

    fileprivate static func load(steamAppsDir: URL) -> [MistInstalledGame] {
        guard let data = try? Data(contentsOf: fileURL(steamAppsDir: steamAppsDir)),
              let list = try? JSONDecoder().decode([MistInstalledGame].self, from: data) else { return [] }
        return list
    }

    fileprivate static func add(_ game: MistInstalledGame, steamAppsDir: URL) {
        var list = load(steamAppsDir: steamAppsDir)
        list.removeAll { $0.appid == game.appid }
        list.append(game)
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: steamAppsDir, withIntermediateDirectories: true)
        try? data.write(to: fileURL(steamAppsDir: steamAppsDir))
    }

    // Games Mist installed itself, in Game model form for merging into the library.
    // Also migrates any legacy install folder with a Wine-unsafe name (trailing
    // dot/space) by renaming it in place and rewriting the manifest — so games
    // installed before wineSafeDirName existed become launchable.
    static func installedGames(steamAppsDir: URL) -> [Game] {
        let fm = FileManager.default
        var list = load(steamAppsDir: steamAppsDir)
        var changed = false
        for i in list.indices {
            let url = URL(fileURLWithPath: list[i].installDir)
            let safe = wineSafeDirName(url.lastPathComponent)
            guard safe != url.lastPathComponent else { continue }
            let newURL = url.deletingLastPathComponent().appendingPathComponent(safe)
            if fm.fileExists(atPath: url.path), !fm.fileExists(atPath: newURL.path) {
                try? fm.moveItem(at: url, to: newURL)
            }
            list[i] = MistInstalledGame(appid: list[i].appid, name: list[i].name,
                                        installDir: newURL.path, sizeBytes: list[i].sizeBytes)
            changed = true
        }
        if changed, let data = try? JSONEncoder().encode(list) {
            try? data.write(to: fileURL(steamAppsDir: steamAppsDir))
        }
        return list.map {
            Game(id: $0.appid, name: $0.name, source: .steam, installDir: $0.installDir,
                sizeBytes: $0.sizeBytes, isInstalled: fm.fileExists(atPath: $0.installDir),
                imageURL: SteamLibraryService.coverURL(forAppID: $0.appid))
        }
    }

    static func remove(appid: String, steamAppsDir: URL) {
        var list = load(steamAppsDir: steamAppsDir)
        list.removeAll { $0.appid == appid }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: fileURL(steamAppsDir: steamAppsDir))
    }
}

// A .exe the user pointed Mist at directly — software Mist didn't install and
// doesn't own. exePath is a real macOS path (never copied into the Wine prefix;
// Wine addresses host paths directly, so nothing gets duplicated).
struct CustomApp: Codable, Identifiable, Equatable {
    let id: String          // UUID string, stable across renames/moves
    var name: String
    var exePath: String
    var addedAt: Double     // unix seconds
    var lastPlayed: Double = 0
}

// Separate from MistManifest (which is Steam/depot-specific) since custom apps
// aren't tied to a Steam appid or any store at all.
enum CustomAppsManifest {
    static func fileURL(supportDir: URL) -> URL {
        supportDir.appendingPathComponent("custom_apps.json")
    }

    static func load(supportDir: URL) -> [CustomApp] {
        guard let data = try? Data(contentsOf: fileURL(supportDir: supportDir)),
              let list = try? JSONDecoder().decode([CustomApp].self, from: data) else { return [] }
        return list
    }

    private static func save(_ list: [CustomApp], supportDir: URL) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        try? data.write(to: fileURL(supportDir: supportDir))
    }

    // Adding the same exe path twice updates the existing entry (keeps its id,
    // playtime, etc.) instead of creating a duplicate — the user re-picking a file
    // they already added shouldn't split it into two cards.
    @discardableResult
    static func add(name: String, exePath: String, supportDir: URL) -> [CustomApp] {
        var list = load(supportDir: supportDir)
        if let idx = list.firstIndex(where: { $0.exePath == exePath }) {
            list[idx].name = name
        } else {
            list.append(CustomApp(id: UUID().uuidString, name: name, exePath: exePath,
                                  addedAt: Date().timeIntervalSince1970))
        }
        save(list, supportDir: supportDir)
        return list
    }

    @discardableResult
    static func remove(id: String, supportDir: URL) -> [CustomApp] {
        var list = load(supportDir: supportDir)
        list.removeAll { $0.id == id }
        save(list, supportDir: supportDir)
        return list
    }

    // Re-point an entry at a new file location after the original moved/was
    // deleted ("Locate…" in the UI) — keeps the same id and history.
    @discardableResult
    static func relocate(id: String, newExePath: String, supportDir: URL) -> [CustomApp] {
        var list = load(supportDir: supportDir)
        if let idx = list.firstIndex(where: { $0.id == id }) { list[idx].exePath = newExePath }
        save(list, supportDir: supportDir)
        return list
    }

    static func recordLastPlayed(id: String, supportDir: URL) {
        var list = load(supportDir: supportDir)
        if let idx = list.firstIndex(where: { $0.id == id }) { list[idx].lastPlayed = Date().timeIntervalSince1970 }
        save(list, supportDir: supportDir)
    }

    static func asGames(supportDir: URL) -> [Game] {
        let fm = FileManager.default
        return load(supportDir: supportDir).map { app in
            let exists = fm.fileExists(atPath: app.exePath)
            return Game(id: app.id, name: app.name, source: .custom,
                       installDir: URL(fileURLWithPath: app.exePath).deletingLastPathComponent().path,
                       sizeBytes: 0, isInstalled: exists,
                       lastPlayed: app.lastPlayed > 0 ? Date(timeIntervalSince1970: app.lastPlayed) : nil,
                       addedAt: Date(timeIntervalSince1970: app.addedAt),
                       customExePath: app.exePath)
        }
    }
}

struct WorkshopItem: Identifiable {
    let id: String  // pubfile ID (the folder name DepotDownloader creates)
    let sizeBytes: Int64

    var sizeFormatted: String {
        if sizeBytes > 1_073_741_824 {
            return "\(sizeBytes / 1_073_741_824) GB"
        } else if sizeBytes > 1_048_576 {
            return "\(sizeBytes / 1_048_576) MB"
        } else if sizeBytes > 0 {
            return "\(sizeBytes / 1024) KB"
        }
        return "—"
    }
}

// Workshop items are tracked purely by scanning steamapps/workshop/content/<appid>/
// (Steam's own layout — see SteamDownloadManager.installWorkshopItem) rather than a
// separate manifest, since the folder itself is the source of truth.
enum MistWorkshop {
    static func installedItems(appid: String, steamAppsDir: URL) -> [WorkshopItem] {
        let dir = steamAppsDir.appendingPathComponent("workshop/content/\(appid)")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .map { WorkshopItem(id: $0.lastPathComponent, sizeBytes: directorySize($0)) }
            .sorted { $0.id < $1.id }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// Per-game preferences (currently just custom launch arguments), keyed by
// Game.id (appid for Steam, app_name for Epic). Separate from MistManifest
// since it applies to every game, not just ones Mist itself installed.
private struct GameLaunchSettings: Codable {
    var customArgs: String = ""
}

enum GameSettingsStore {
    private static var fileURL: URL {
        MistEnv.supportDir.appendingPathComponent("game_settings.json")
    }

    private static func load() -> [String: GameLaunchSettings] {
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONDecoder().decode([String: GameLaunchSettings].self, from: data) else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: GameLaunchSettings]) {
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? FileManager.default.createDirectory(at: MistEnv.supportDir, withIntermediateDirectories: true)
        try? data.write(to: fileURL)
    }

    static func customArgs(for gameID: String) -> String {
        load()[gameID]?.customArgs ?? ""
    }

    static func setCustomArgs(_ args: String, for gameID: String) {
        var dict = load()
        var entry = dict[gameID] ?? GameLaunchSettings()
        entry.customArgs = args
        dict[gameID] = entry
        save(dict)
    }

    // Naive shell-style tokenizer: splits on whitespace, honoring double quotes
    // for args containing spaces (e.g. custom paths). Good enough for the
    // simple flag-style arguments games typically take.
    static func tokenize(_ args: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for char in args {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

enum DownloadState: Equatable {
    case queued
    case downloading
    case paused
    case failed(String)
    case done
}

// A single entry in the download queue — a Steam app or one of its Workshop
// items. `id` disambiguates the two: a plain appid for the base game, or
// "appid:pubfileID" for a workshop item, so a game and its own workshop
// content can queue independently without colliding.
struct DownloadQueueItem: Identifiable, Equatable {
    let id: String
    let appid: String
    var name: String
    let pubfileID: String?
    let coverURL: URL?
    var state: DownloadState = .queued
    var progress: Double? = nil
    var statusText: String = ""
    var bytesPerSecond: Double? = nil
    var etaSeconds: Double? = nil

    var speedFormatted: String? {
        guard let bps = bytesPerSecond, bps > 1024 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }

    var etaFormatted: String? {
        guard let s = etaSeconds, s.isFinite, s > 0 else { return nil }
        let mins = Int(s) / 60
        if mins < 1 { return "< 1 min left" }
        if mins < 60 { return "\(mins) min left" }
        return "\(mins / 60)h \(mins % 60)m left"
    }
}

final class SteamDownloadManager: ObservableObject {
    @Published var queue: [DownloadQueueItem] = []

    private var process: Process?
    private var activeID: String?
    private var onCompleteHandlers: [String: () -> Void] = [:]
    private var steamAccountName: String = ""
    private let steamAppsDir: URL

    // downloadStatusText only ever shows the latest line, which is useless for
    // diagnosing a failure (the real error scrolls past before anyone can read it).
    // Keep the last several lines so a failure message can actually explain itself.
    private var recentOutputLines: [String] = []
    private let maxRecentLines = 12

    // Steam's CM (client protocol) servers occasionally fail a connection attempt
    // outright rather than just being slow — a well-documented flaky pattern (see
    // SteamRE/DepotDownloader issues #540, #543) unrelated to local network health.
    // A bounded auto-retry papers over this instead of failing the whole install on
    // what's usually a one-off hiccup.
    private var connectionRetryCount = 0
    private let maxConnectionRetries = 2
    private static let connectionFailureMarkers = [
        "TryAnotherCM", "InitializeSteam failed", "AsyncJobFailedException",
        "Unable to get steam3 credentials", "Timeout connecting to Steam3",
    ]

    // Set right before intentionally terminating a process (pause/cancel) so its
    // terminationHandler can tell "we did this on purpose" apart from a real
    // failure and skip the retry/failed-state logic entirely.
    private var intentionalStop: Set<String> = []

    private var speedTimer: Timer?
    private var speedTrackingID: String?
    private var speedSample: (bytes: Int64, at: Date)?

    init(steamAppsDir: URL) {
        self.steamAppsDir = steamAppsDir
    }

    func enqueue(appid: String, name: String, steamAccountName: String, coverURL: URL? = nil,
                 onComplete: @escaping () -> Void) {
        self.steamAccountName = steamAccountName
        guard !queue.contains(where: { $0.id == appid }) else { return }
        queue.append(DownloadQueueItem(id: appid, appid: appid, name: name, pubfileID: nil, coverURL: coverURL))
        onCompleteHandlers[appid] = onComplete
        processQueueIfIdle()
    }

    // Workshop items share the exact same queue/retry machinery as base games —
    // the only difference is the "-pubfile" flag and a workshop-shaped destination
    // folder instead of steamapps/common.
    //
    // Caveat: this places files where Steam's own client would (steamapps/workshop/
    // content/<appid>/<pubfileid>/), but whether a given game actually reads mods
    // from there is entirely up to that game — many query Steam's ISteamUGC API at
    // runtime instead of scanning the folder directly, and Mist doesn't (and can't,
    // without running a real Steam client) implement that API. Works for games that
    // load workshop content straight off disk; does nothing for ones that don't.
    func enqueueWorkshopItem(appid: String, pubfileID: String, gameName: String, steamAccountName: String,
                              onComplete: @escaping () -> Void) {
        self.steamAccountName = steamAccountName
        let id = "\(appid):\(pubfileID)"
        guard !queue.contains(where: { $0.id == id }) else { return }
        let name = "\(gameName) — Workshop Item \(pubfileID)"
        queue.append(DownloadQueueItem(id: id, appid: appid, name: name, pubfileID: pubfileID, coverURL: nil))
        onCompleteHandlers[id] = onComplete
        processQueueIfIdle()
    }

    private func processQueueIfIdle() {
        guard activeID == nil, let next = queue.first(where: { $0.state == .queued }) else { return }
        start(id: next.id)
    }

    private func start(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].state = .downloading
        queue[idx].statusText = "Preparing…"
        queue[idx].progress = nil
        queue[idx].bytesPerSecond = nil
        queue[idx].etaSeconds = nil
        activeID = id
        connectionRetryCount = 0
        recentOutputLines = []

        Task {
            do {
                try await DepotDownloaderManager.ensureInstalled { [weak self] status in
                    Task { @MainActor in
                        guard let self, let idx = self.queue.firstIndex(where: { $0.id == id }) else { return }
                        self.queue[idx].statusText = status
                    }
                }
                await MainActor.run { self.runDepotDownloader(id: id) }
            } catch {
                await MainActor.run { self.finishWithFailure(id: id, message: error.localizedDescription) }
            }
        }
    }

    private func runDepotDownloader(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        let item = queue[idx]
        let tool = DepotDownloaderManager.installPath.path
        queue[idx].statusText = "Signing in with your Steam login…"

        let installDir: URL
        if let pubfileID = item.pubfileID {
            installDir = steamAppsDir.appendingPathComponent("workshop/content/\(item.appid)/\(pubfileID)")
        } else {
            let safeName = wineSafeDirName(item.name)
            installDir = steamAppsDir.appendingPathComponent("common").appendingPathComponent(safeName)
        }
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Single-login: our patched DepotDownloader seeds Mist's own persistent
        // session token (passed via MIST_REFRESH_TOKEN) into its login store, so
        // "-username <account> -remember-password" logs in non-interactively with
        // Mist's one QR sign-in — no separate DepotDownloader QR scan, ever.
        var args = ["-app", item.appid, "-os", "windows", "-dir", installDir.path,
                    "-username", steamAccountName, "-remember-password"]
        if let pubfileID = item.pubfileID { args += ["-pubfile", pubfileID] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let token = Self.sessionRefreshToken() { env["MIST_REFRESH_TOKEN"] = token }
        proc.environment = env

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = outPipe

        // DepotDownloader prints "NN.NN% path/to/file" per chunk — the only line
        // type treated as real, user-facing progress.
        let progressRegex = try? NSRegularExpression(pattern: "^(\\d+\\.\\d+)%")

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
                    let l = String(rawLine).replacingOccurrences(of: "\r", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { continue }
                    self.recentOutputLines.append(l)
                    if self.recentOutputLines.count > self.maxRecentLines {
                        self.recentOutputLines.removeFirst()
                    }
                    guard let idx = self.queue.firstIndex(where: { $0.id == id }) else { continue }
                    if let regex = progressRegex,
                       let m = regex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                       let r = Range(m.range(at: 1), in: l), let pct = Double(l[r]) {
                        self.queue[idx].progress = pct / 100
                        self.queue[idx].statusText = "Downloading \(item.name)…"
                    } else {
                        self.queue[idx].statusText = l
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                let wasIntentional = self.intentionalStop.remove(id) != nil
                // Guard every piece of "this was the active download" cleanup on
                // identity/id checks — by the time this fires, a pause() may have
                // already moved the queue on to a different active item, and
                // blindly clearing shared state here would stomp on it.
                if self.activeID == id { self.activeID = nil }
                if self.process === p { self.process = nil }
                self.stopSpeedTracking(for: id)

                if wasIntentional {
                    // pause()/cancel() already updated queue state (or removed
                    // the item) — nothing left to do.
                    return
                }

                if p.terminationStatus == 0 {
                    self.connectionRetryCount = 0
                    if item.pubfileID == nil {
                        let size = Self.directorySize(installDir)
                        MistManifest.add(MistInstalledGame(appid: item.appid, name: item.name,
                                                           installDir: installDir.path, sizeBytes: size),
                                         steamAppsDir: self.steamAppsDir)
                    }
                    self.queue.removeAll { $0.id == id }
                    let onComplete = self.onCompleteHandlers.removeValue(forKey: id)
                    onComplete?()
                    self.processQueueIfIdle()
                    return
                }

                let looksLikeConnectionHiccup = Self.connectionFailureMarkers.contains { marker in
                    self.recentOutputLines.contains { $0.contains(marker) }
                }
                if looksLikeConnectionHiccup && self.connectionRetryCount < self.maxConnectionRetries {
                    self.connectionRetryCount += 1
                    if let idx = self.queue.firstIndex(where: { $0.id == id }) {
                        self.queue[idx].statusText = "Steam connection hiccup — retrying (\(self.connectionRetryCount)/\(self.maxConnectionRetries))…"
                        self.queue[idx].progress = nil
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        guard let idx = self.queue.firstIndex(where: { $0.id == id }), self.queue[idx].state == .downloading,
                              self.activeID == nil else { return }
                        self.activeID = id
                        self.runDepotDownloader(id: id)
                    }
                } else {
                    self.connectionRetryCount = 0
                    let tail = self.recentOutputLines.suffix(6).joined(separator: "\n")
                    self.finishWithFailure(id: id, message: "Download failed (exit \(p.terminationStatus)).\n\(tail)")
                }
            }
        }

        do {
            try proc.run()
            process = proc
            startSpeedTracking(id: id, installDir: installDir)
        } catch {
            finishWithFailure(id: id, message: "Couldn't start DepotDownloader: \(error.localizedDescription)")
        }
    }

    private func finishWithFailure(id: String, message: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[idx].state = .failed(message)
        queue[idx].progress = nil
        if activeID == id { activeID = nil }
        processQueueIfIdle()
    }

    /// Cancels the active download but leaves its partial files on disk and
    /// keeps it in the queue as `.paused` — DepotDownloader validates existing
    /// chunks by checksum on the next run, so resuming just means re-invoking it
    /// with the same args, not any byte-range logic of our own.
    func pause(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), queue[idx].state == .downloading else { return }
        intentionalStop.insert(id)
        process?.terminate()
        queue[idx].state = .paused
        queue[idx].statusText = "Paused"
        stopSpeedTracking(for: id)
        if activeID == id { activeID = nil }
        processQueueIfIdle()
    }

    /// Jumps the item to the front of the queue and starts it immediately if
    /// nothing else is downloading. Also used to retry a failed item.
    func resume(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), isResumable(queue[idx]) else { return }
        var item = queue.remove(at: idx)
        item.state = .queued
        item.statusText = ""
        queue.insert(item, at: 0)
        processQueueIfIdle()
    }

    func retry(id: String) { resume(id: id) }

    func cancel(id: String) {
        if activeID == id {
            intentionalStop.insert(id)
            process?.terminate()
            stopSpeedTracking(for: id)
            activeID = nil
        }
        queue.removeAll { $0.id == id }
        onCompleteHandlers.removeValue(forKey: id)
    }

    func moveUp(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        queue.swapAt(idx, idx - 1)
    }

    func moveDown(id: String) {
        guard let idx = queue.firstIndex(where: { $0.id == id }), idx < queue.count - 1 else { return }
        queue.swapAt(idx, idx + 1)
    }

    private func isResumable(_ item: DownloadQueueItem) -> Bool {
        if item.state == .paused { return true }
        if case .failed = item.state { return true }
        return false
    }

    // Samples the install directory's on-disk size every 2s (off the main thread —
    // a recursive enumerator over a large install shouldn't block UI) to derive a
    // real speed and, from the current percentage, a rough ETA. DepotDownloader
    // only ever prints a percentage, never a byte count, so this is the only way
    // to get either without reimplementing its manifest parsing. Guarded by
    // speedTrackingID throughout so a stale timer from an already-superseded
    // download can't clobber whatever item is actually active now.
    private func startSpeedTracking(id: String, installDir: URL) {
        speedTrackingID = id
        speedSample = nil
        speedTimer?.invalidate()
        speedTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, self.speedTrackingID == id else { return }
            DispatchQueue.global(qos: .utility).async {
                let bytes = Self.directorySize(installDir)
                let now = Date()
                DispatchQueue.main.async {
                    guard self.speedTrackingID == id,
                          let idx = self.queue.firstIndex(where: { $0.id == id }) else { return }
                    defer { self.speedSample = (bytes, now) }
                    guard let prev = self.speedSample else { return }
                    let dt = now.timeIntervalSince(prev.at)
                    guard dt > 0.5 else { return }
                    let bps = max(0, Double(bytes - prev.bytes) / dt)
                    self.queue[idx].bytesPerSecond = bps
                    if let progress = self.queue[idx].progress, progress > 0.02, bps > 0 {
                        let estTotal = Double(bytes) / progress
                        self.queue[idx].etaSeconds = max(0, estTotal - Double(bytes)) / bps
                    } else {
                        self.queue[idx].etaSeconds = nil
                    }
                }
            }
        }
    }

    private func stopSpeedTracking(for id: String) {
        guard speedTrackingID == id else { return }
        speedTimer?.invalidate()
        speedTimer = nil
        speedSample = nil
        speedTrackingID = nil
    }

    // Mist's own persistent refresh token, read from the session file — passed to
    // our patched DepotDownloader so downloads reuse the single QR login.
    private static func sessionRefreshToken() -> String? {
        let url = MistEnv.supportDir.appendingPathComponent("steam_session.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tok = obj["refreshToken"] as? String, !tok.isEmpty else { return nil }
        return tok
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - D3DMetal provider (Apple's Direct3D→Metal, for D3D11/D3D12 titles)

// Mist's bundled Wine engine renders D3D only through wined3d, whose Vulkan path
// (via the bundled MoltenVK) is too weak on Apple Silicon for many modern games —
// they fail at graphics init. Apple's D3DMetal fixes this, but it's proprietary and
// can't be redistributed. Instead we detect it on the user's machine, from either a
// Game Porting Toolkit install or a CrossOver install (both ship the same
// "apple_gptk" D3DMetal), and launch through that when present.
struct D3DMetalProvider {
    let name: String            // human label, e.g. "CrossOver"
    let wineBin: String         // wine/wineloader to exec
    let wineserverBin: String
    let prefixSuffix: String    // dedicated prefix suffix so we never touch the main one
    let extraEnv: [String: String]

    static func detect() -> D3DMetalProvider? {
        let fm = FileManager.default
        // 1) Apple's Game Porting Toolkit — its Wine bundles D3DMetal internally, so
        //    no extra wiring is needed beyond pointing PATH at it.
        let gptk = "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
        if fm.fileExists(atPath: gptk) {
            let bin = (gptk as NSString).deletingLastPathComponent
            return D3DMetalProvider(
                name: "Game Porting Toolkit", wineBin: gptk,
                wineserverBin: "\(bin)/wineserver", prefixSuffix: "-gptk",
                extraEnv: ["PATH": "\(bin):/usr/bin:/bin"])
        }
        // 2) CrossOver ships the same D3DMetal under lib64/apple_gptk, but its Wine
        //    finds it only when we wire WINEDLLPATH + libd3dshared + the framework
        //    path by hand (CrossOver's own `wine` wrapper refuses to run outside a
        //    CrossOver bottle, so we drive wineloader directly). This recipe is
        //    verified to bring up a real D3D11 device under D3DMetal.
        let cx = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
        let loader = "\(cx)/bin/wineloader"
        let gptkWin = "\(cx)/lib64/apple_gptk/wine/x86_64-windows"
        if fm.fileExists(atPath: loader), fm.fileExists(atPath: gptkWin) {
            return D3DMetalProvider(
                name: "CrossOver", wineBin: loader,
                wineserverBin: "\(cx)/bin/wineserver", prefixSuffix: "-cx",
                extraEnv: [
                    "CX_ROOT": cx,
                    "WINELOADER": loader,
                    "WINESERVER": "\(cx)/bin/wineserver",
                    "WINEDLLPATH": "\(gptkWin):\(cx)/lib/wine/x86_64-windows:\(cx)/lib/wine/i386-windows",
                    "DYLD_LIBRARY_PATH": "\(cx)/lib64:\(cx)/lib",
                    "DYLD_FALLBACK_FRAMEWORK_PATH": "\(cx)/lib64/apple_gptk/external",
                    "CX_APPLEGPTK_LIBD3DSHARED_PATH": "\(cx)/lib64/apple_gptk/external/libd3dshared.dylib",
                ])
        }
        return nil
    }
}

// MARK: - Wine/Game Process Manager

class ProcessManager: ObservableObject {
    @Published var isRunning = false
    @Published var currentGame: Game?
    @Published var outputLog: String = ""
    @Published var launchedAt: Date?      // when the current/last session started
    @Published var endedAt: Date?         // when it ended (for the session summary)

    private var process: Process?
    private var dialogKillerTimer: Timer?
    private let library: GameLibrary

    init(library: GameLibrary) {
        self.library = library
    }

    enum LaunchMode: String {
        case normal = "Normal"
        case noEAC = "No Anti-Cheat (Offline)"
        case gptk = "GPTK (Offline)"
    }

    func launchGame(_ game: Game, mode: LaunchMode = .normal) {
        currentGame = game
        outputLog = "Launching \(game.name) [\(mode.rawValue)]...\n"

        switch game.source {
        case .steam, .custom:
            // Steam games (and custom apps) always run their .exe directly under
            // Wine — Mist never runs the actual Steam client under Wine (login and
            // downloads are both native; see SteamAuthManager / SteamDownloadManager),
            // so "normal" and "no EAC" are the same thing here. Custom apps have no
            // anti-cheat/legendary concept either, so they follow the same path.
            switch mode {
            case .gptk:
                launchGameGPTK(game)
            case .noEAC, .normal:
                launchGameDirect(game)
            }
        case .epic:
            switch mode {
            case .noEAC:
                launchGameDirect(game)
            case .normal, .gptk:
                // Use legendary for the launch (handles Epic auth / cloud saves),
                // pointing it at D3DMetal (GPTK/CrossOver) when available (reliable for D3D12).
                let provider = D3DMetalProvider.detect()
                let wineBin = provider?.wineBin ?? MistEnv.wineBinary.path
                var env: [String: String]
                if let provider {
                    env = ProcessInfo.processInfo.environment
                    env["WINEPREFIX"] = MistEnv.winePrefix.path
                    env["WINEARCH"] = "win64"
                    if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
                    env["WINEMSYNC"] = "1"
                    env["WINEESYNC"] = "1"
                    // Force builtin DirectX DLLs so D3DMetal handles rendering
                    env["WINEDLLOVERRIDES"] = "d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
                    env["PATH"] = "\((provider.wineBin as NSString).deletingLastPathComponent):/usr/bin:/bin"
                    for (k, v) in provider.extraEnv { env[k] = v }
                } else {
                    env = MistEnv.baseEnvironment()
                }
                runProcess(path: legendaryPath, arguments: [
                    "launch", game.id,
                    "--wine", wineBin,
                    "--wine-prefix", MistEnv.winePrefix.path,
                ] + GameSettingsStore.tokenize(GameSettingsStore.customArgs(for: game.id)), env: env)
            }
        }
    }

    // Offline/singleplayer: run the game's main exe directly under the bundled Wine
    // with the null EOS anti-cheat client (no anti-cheat — offline only).
    private func launchGameDirect(_ game: Game) {
        let exe: String
        if game.source == .custom {
            guard let customExe = game.customExePath, FileManager.default.fileExists(atPath: customExe) else {
                outputLog += "ERROR: \(game.name)'s app is missing — it may have been moved or deleted. Use \"Locate…\" to point Mist at it again.\n"
                return
            }
            exe = customExe
            CustomAppsManifest.recordLastPlayed(id: game.id, supportDir: MistEnv.supportDir)
        } else {
            guard FileManager.default.fileExists(atPath: game.installDir),
                  let found = findMainExe(in: game.installDir) else {
                outputLog += "ERROR: couldn't find the game's executable in \(game.installDir)\n"
                return
            }
            exe = found
        }
        outputLog += "Exe: \(exe)\n\n"
        var env = MistEnv.baseEnvironment()
        // Bundled DXVK-macOS renders D3D10/11 far better than wined3d on Apple
        // Silicon (native "Apple M2" D3D11 device). Deploy it into the prefix and
        // point the overrides at it; d3d12/d3d9 stay on wine's builtins.
        if DXVKManager.isBundled {
            DXVKManager.deployIfNeeded()
            env["WINEDLLOVERRIDES"] = DXVKManager.overrides
            outputLog += "Renderer: DXVK (D3D10/11)\n"
        } else {
            env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,d3d12,d3d12core=n,b"
        }
        env["EOS_USE_ANTICHEATCLIENTNULL"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"

        // In-game achievements: for Steam games, swap in gbe_fork so the game runs
        // thinking Steam is present and records unlocks locally. After it exits we
        // push those unlocks to the real profile via the relay (see syncAchievements).
        let achievementsGame: Game? = (game.source == .steam && GBEManager.isInstalled) ? game : nil

        let launchArgs = [exe] + GameSettingsStore.tokenize(GameSettingsStore.customArgs(for: game.id))
        let launchCwd = URL(fileURLWithPath: exe).deletingLastPathComponent()
        let onExit: (() -> Void)? = achievementsGame.map { g in { [weak self] in self?.syncAchievements(for: g) } }

        let start: ([String: String]) -> Void = { [weak self] finalEnv in
            guard let self else { return }
            MistEnv.killWineserver()
            self.runProcess(path: MistEnv.wineBinary.path, arguments: launchArgs, env: finalEnv,
                            cwd: launchCwd, onExit: onExit)
            self.startDialogKiller()
        }

        guard let g = achievementsGame else { start(env); return }

        // Deploy the emulator AND fetch/write the achievement schema BEFORE the game
        // process starts — gbe_fork reads steam_settings/achievements.json once at
        // init, so the schema must already be on disk or the game's achievement
        // calls that session are silently dropped.
        Task { @MainActor in
            var gameEnv = env
            do {
                try GBEManager.deploy(gameDir: g.installDir, appid: g.id)
                gameEnv["SteamAppId"] = g.id
                gameEnv["SteamGameId"] = g.id
                self.outputLog += "Achievements: preparing the Steam emulator (appid \(g.id))…\n"
                await GBEManager.installSchema(gameDir: g.installDir, appid: g.id)
                self.outputLog += "Achievements: running through the Steam emulator.\n\n"
            } catch {
                self.outputLog += "Achievements: emulator setup skipped (\(error.localizedDescription)).\n\n"
            }
            start(gameEnv)
        }
    }

    // After a Steam game (run through gbe_fork) exits, push any achievements it
    // recorded locally to the real profile via the relay. Best-effort + async.
    private func syncAchievements(for game: Game) {
        Task { @MainActor in
            let unlocked = GBEManager.locallyUnlocked(gameDir: game.installDir, appid: game.id)
            guard !unlocked.isEmpty else { return }
            self.outputLog += "\nSyncing \(unlocked.count) achievement(s) to your Steam profile…\n"
            for apiname in unlocked {
                let ok = (try? await RelayManager.unlock(appid: game.id, apiname: apiname)) ?? false
                self.outputLog += ok ? "  ✓ \(apiname)\n" : "  ✗ \(apiname) (couldn't sync)\n"
            }
        }
    }

    // Launch via Apple's Game Porting Toolkit (D3DMetal) in a dedicated prefix, so
    // GPTK's Wine never reconfigures the bundled CX prefix. The Steam/Epic libraries
    // are symlinked in, keeping the same C:\ paths without re-downloading games.
    private func launchGameGPTK(_ game: Game) {
        let fm = FileManager.default
        guard let provider = D3DMetalProvider.detect() else {
            outputLog += "ERROR: D3DMetal isn't available.\n"
                + "Install Apple's Game Porting Toolkit, or CrossOver, to run D3D11/D3D12 games.\n"
            return
        }
        // Dedicated prefix per provider, so its (different) Wine never reconfigures
        // the bundled engine's main prefix. The game libraries are symlinked in,
        // keeping the same C:\ paths without re-downloading anything.
        let d3dPrefix = URL(fileURLWithPath: MistEnv.winePrefix.path + provider.prefixSuffix)

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = d3dPrefix.path
        env["WINEARCH"] = "win64"
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"
        // Builtin DirectX DLLs so D3DMetal (from the provider's WINEDLLPATH) renders.
        env["WINEDLLOVERRIDES"] = "d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
        env["EOS_USE_ANTICHEATCLIENTNULL"] = "1"
        env["PATH"] = "\((provider.wineBin as NSString).deletingLastPathComponent):/usr/bin:/bin"
        for (k, v) in provider.extraEnv { env[k] = v }   // provider wiring wins

        if !fm.fileExists(atPath: d3dPrefix.appendingPathComponent("system.reg").path) {
            outputLog += "Setting up dedicated \(provider.name) prefix (one-time)…\n"
            try? fm.createDirectory(at: d3dPrefix, withIntermediateDirectories: true)
            MistEnv.run(URL(fileURLWithPath: provider.wineBin), ["wineboot", "--init"], env: env)
            MistEnv.run(URL(fileURLWithPath: provider.wineserverBin), ["-w"], env: env)
        }
        let sharedC = MistEnv.winePrefix.appendingPathComponent("drive_c")
        let d3dC = d3dPrefix.appendingPathComponent("drive_c")
        let steamSrc = sharedC.appendingPathComponent("Program Files (x86)/Steam")
        if fm.fileExists(atPath: steamSrc.path) {
            let pfDir = d3dC.appendingPathComponent("Program Files (x86)")
            try? fm.createDirectory(at: pfDir, withIntermediateDirectories: true)
            let link = pfDir.appendingPathComponent("Steam")
            if !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(at: link, withDestinationURL: steamSrc)
            }
        }
        let epicSrc = sharedC.appendingPathComponent("Epic Games")
        if fm.fileExists(atPath: epicSrc.path) {
            let link = d3dC.appendingPathComponent("Epic Games")
            if !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(at: link, withDestinationURL: epicSrc)
            }
        }

        guard let exe = findMainExe(in: game.installDir) else {
            outputLog += "ERROR: couldn't find the game's executable in \(game.installDir)\n"
            return
        }
        outputLog += "Exe: \(exe)\nRenderer: D3DMetal (\(provider.name))\n\n"
        let args = [exe] + GameSettingsStore.tokenize(GameSettingsStore.customArgs(for: game.id))
        runProcess(path: provider.wineBin, arguments: args, env: env,
                   cwd: URL(fileURLWithPath: exe).deletingLastPathComponent())
        startDialogKiller()
    }

    // Pick the most likely main game .exe under a directory (port of mist_main_exe):
    // skip helper/installer/anti-cheat exes; prefer an exe named like its folder,
    // else the largest remaining exe.
    private func findMainExe(in root: String, maxDepth: Int = 4) -> String? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root)
        let rootName = rootURL.lastPathComponent.lowercased()
        let skip = ["start_protected_game", "easyanticheat", "crashhandler", "crashreport",
                    "setup", "unins", "redist", "touchup", "notification", "be_service",
                    "beservice", "epicgameslauncher", "dxsetup", "vcredist", "helper"]
        var best: (path: String, size: Int64)? = nil
        var nameMatch: String? = nil
        guard let en = fm.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey],
                                     options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in en {
            let depth = url.pathComponents.count - rootURL.pathComponents.count
            if depth > maxDepth {
                en.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe" else { continue }
            let base = url.lastPathComponent.lowercased()
            if skip.contains(where: { base.contains($0) }) { continue }
            let stem = String(base.dropLast(4))
            let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
            if stem == parent || stem == rootName { nameMatch = url.path }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if best == nil || size > best!.size { best = (url.path, size) }
        }
        return nameMatch ?? best?.path
    }

    // Wine surfaces crashes in background processes as winedbg dialog boxes that
    // block the UI without offering anything useful — kill them quietly. This needs
    // no special permissions (pkill, not UI automation), unlike the old Steam-error-
    // popup auto-dismissal this replaced, which needed Accessibility and only existed
    // because Mist used to run the real Steam client under Wine for login/launching.
    private func startDialogKiller() {
        dialogKillerTimer?.invalidate()
        dialogKillerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self, self.isRunning else {
                self?.dialogKillerTimer?.invalidate()
                self?.dialogKillerTimer = nil
                return
            }
            DispatchQueue.global(qos: .background).async {
                MistEnv.run(URL(fileURLWithPath: "/usr/bin/pkill"), ["-f", "winedbg"])
            }
        }
    }

    // waitForWineserverAfter: Steam's bootstrapper downloads an update, re-execs
    // itself as a new process under the same wineserver, and the original process
    // exits — normal behavior, not a crash. When set, the initial process's exit
    // isn't treated as "ended"; instead we block on `wineserver -w` so the UI stays
    // "Running" through the self-relaunch and only shows "ended" once Steam (and
    // everything it spawned) actually quits.
    private func runProcess(path: String, arguments: [String],
                            env: [String: String], cwd: URL? = nil,
                            waitForWineserverAfter: Bool = false,
                            onExit: (() -> Void)? = nil) {
        isRunning = true
        launchedAt = Date()
        endedAt = nil

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.environment = env
        if let cwd = cwd { proc.currentDirectoryURL = cwd }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let logHandler: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.outputLog += text
                if let log = self?.outputLog, log.count > 50000 {
                    self?.outputLog = String(log.suffix(30000))
                }
            }
        }
        outPipe.fileHandleForReading.readabilityHandler = logHandler
        errPipe.fileHandleForReading.readabilityHandler = logHandler

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil

            let finish = {
                DispatchQueue.main.async {
                    self?.outputLog += "\n[Process exited with code \(p.terminationStatus)]\n"
                    self?.isRunning = false
                    self?.endedAt = Date()
                    // currentGame is kept so the running view can show a session
                    // summary; it's replaced on the next launch.
                    self?.dialogKillerTimer?.invalidate()
                    self?.dialogKillerTimer = nil
                    onExit?()
                }
            }
            if waitForWineserverAfter {
                DispatchQueue.global(qos: .userInitiated).async {
                    MistEnv.waitWineserver()
                    finish()
                }
            } else {
                finish()
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            isRunning = false
            outputLog = "Failed to launch: \(error.localizedDescription)"
        }
    }

    func stop() {
        process?.terminate()
        DispatchQueue.global().async { MistEnv.killWineserver() }
    }

    // MARK: - Epic Games via Legendary

    @Published var epicLoggedIn = false
    @Published var epicUsername: String = ""
    @Published var epicLoginInProgress = false
    @Published var epicInstallProgress: String = ""
    @Published var epicInstalling = false
    @Published var epicUninstalling = false

    @Published var epicLoginError: String = ""

    func checkEpicLogin() {
        // legendary isn't bundled — if it's missing, Process.run() fails silently
        // (try?) and reading the pipe afterward hangs forever (nothing ever closes
        // the write end). Bail out before that read instead.
        guard FileManager.default.isExecutableFile(atPath: legendaryPath) else {
            epicLoggedIn = false
            epicUsername = ""
            return
        }
        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["status"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: outData, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                // Legendary outputs "Epic account: <username>" when logged in
                if output.contains("Epic account:") && !output.contains("<not logged in>") {
                    self?.epicLoggedIn = true
                    // Extract username from "Epic account: MellowLove_"
                    for line in output.split(separator: "\n") {
                        let l = String(line)
                        if l.contains("Epic account:") {
                            let parts = l.split(separator: ":", maxSplits: 1)
                            if parts.count >= 2 {
                                self?.epicUsername = parts[1].trimmingCharacters(in: .whitespaces)
                            }
                            break
                        }
                    }
                } else {
                    self?.epicLoggedIn = false
                    self?.epicUsername = ""
                }
            }
        }
    }

    func epicOpenLoginPage() {
        let url = URL(string: "https://legendary.gl/epiclogin")!
        NSWorkspace.shared.open(url)
    }

    func epicLoginWithCode(_ input: String) {
        epicLoginInProgress = true
        epicLoginError = ""

        // Extract authorizationCode from JSON if user pasted the whole thing
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if code.hasPrefix("{") {
            // Parse JSON to extract authorizationCode
            if let data = code.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let authCode = json["authorizationCode"] as? String {
                code = authCode
            }
        }
        // Strip any surrounding quotes
        code = code.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard !code.isEmpty, code != "null" else {
            epicLoginInProgress = false
            epicLoginError = "No authorization code found. Make sure you're copying the authorizationCode value."
            return
        }

        guard FileManager.default.isExecutableFile(atPath: legendaryPath) else {
            epicLoginInProgress = false
            epicLoginError = "legendary (Epic Games CLI) isn't installed."
            return
        }

        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["auth", "--code", code]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            try? proc.run()
            proc.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""

            DispatchQueue.main.async {
                self?.epicLoginInProgress = false
                if proc.terminationStatus == 0 {
                    self?.checkEpicLogin()
                    self?.library.scan()
                } else {
                    self?.epicLoginError = "Login failed: \(output.prefix(200))"
                    self?.checkEpicLogin()
                }
            }
        }
    }

    func epicInstall(appName: String) {
        guard FileManager.default.isExecutableFile(atPath: legendaryPath) else {
            epicInstallProgress = "legendary (Epic Games CLI) isn't installed."
            return
        }
        epicInstalling = true
        epicInstallProgress = "Starting download..."

        let installDir = library.epicDir.path
        // Ensure Epic Games directory exists
        try? FileManager.default.createDirectory(atPath: installDir, withIntermediateDirectories: true)

        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["install", appName,
                              "--base-path", installDir,
                              "--platform", "Windows",
                              "-y"]          // auto-confirm; downloads use HTTPS

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe

            // Read both stdout and stderr for progress
            for pipe in [outPipe, errPipe] {
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                    for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                        let l = String(line).trimmingCharacters(in: .whitespaces)
                        if !l.isEmpty {
                            DispatchQueue.main.async {
                                self?.epicInstallProgress = l
                            }
                        }
                    }
                }
            }

            proc.terminationHandler = { [weak self] p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.epicInstalling = false
                    if p.terminationStatus == 0 {
                        self?.epicInstallProgress = "Done!"
                        self?.library.scan()
                    } else {
                        self?.epicInstallProgress = "Install failed (exit \(p.terminationStatus))"
                    }
                }
            }

            do {
                try proc.run()
            } catch {
                // run() threw — terminationHandler won't fire, so clear state and
                // surface the error instead of wedging the install bar forever.
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async {
                    self?.epicInstalling = false
                    self?.epicInstallProgress = "Couldn't start install: \(error.localizedDescription)"
                }
            }
        }
    }

    func epicUninstall(appName: String) {
        guard FileManager.default.isExecutableFile(atPath: legendaryPath) else { return }
        epicUninstalling = true
        DispatchQueue.global().async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: legendaryPath)
            proc.arguments = ["uninstall", appName, "-y"]
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try? proc.run()
            // Drain before waiting — legendary's uninstall output is small but this
            // avoids the same pipe-buffer deadlock class as every other subprocess call.
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self?.epicUninstalling = false
                self?.library.scan()
            }
        }
    }
}

// MARK: - Views

// Tries primaryURL first; if that fails to load, falls back to fallbackURL once
// before finally giving up to `placeholder`.
struct SteamCoverImageView: View {
    let primaryURL: URL
    let fallbackURL: URL?
    let placeholder: AnyView

    @State private var useFallback = false

    var body: some View {
        AsyncImage(url: (useFallback ? fallbackURL : nil) ?? primaryURL) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            case .failure:
                if !useFallback, fallbackURL != nil {
                    Color.clear.onAppear { useFallback = true }
                } else {
                    placeholder
                }
            case .empty:
                ZStack {
                    Color.gray.opacity(0.1)
                    ProgressView()
                }
            @unknown default:
                placeholder
            }
        }
    }
}

struct GameCardView: View {
    let game: Game
    var onLaunch: () -> Void = {}
    var onLaunchNoEAC: () -> Void = {}
    var onLaunchGPTK: () -> Void = {}
    var onInstall: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onShowInFinder: () -> Void = {}
    var onLaunchOptions: () -> Void = {}
    var onInstallWorkshopItem: () -> Void = {}
    var onSelect: () -> Void = {}
    var onLocate: () -> Void = {}   // .custom source, file missing: re-point at a new location
    var downloadItem: DownloadQueueItem? = nil   // non-nil while this game is queued/downloading
    var onPauseDownload: () -> Void = {}
    var onResumeDownload: () -> Void = {}
    var onCancelDownload: () -> Void = {}
    var onRetryDownload: () -> Void = {}
    var isFocused: Bool = false

    @State private var isHovering = false

    private var d3dMetalAvailable: Bool { D3DMetalProvider.detect() != nil }

    // A single status dot encodes state at a glance (idea 10).
    private var statusColor: Color {
        if downloadItem != nil { return Fog.accent }
        if game.isInstalled { return Fog.good }
        if game.isFamilyShared { return Fog.accent }
        return Color.white.opacity(0.35)
    }
    // The primary metadata line: playtime if you've played it, else size, else state.
    private var metaPrimary: String {
        if let di = downloadItem {
            switch di.state {
            case .downloading: return di.progress.map { "Installing… \(Int($0 * 100))%" } ?? "Installing…"
            case .queued: return "Queued to install"
            case .paused: return "Install paused"
            case .failed: return "Install failed"
            case .done: break
            }
        }
        if game.isInstalled {
            if let pt = game.playtimeFormatted { return pt }
            return game.sizeBytes > 0 ? game.sizeFormatted : "Installed"
        }
        return game.isFamilyShared ? "Family shared" : "Not installed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            poster
            // Launch or Install button — must be clickable
            //
            // Steam games always launch their .exe directly under Wine (onLaunchNoEAC) —
            // Mist doesn't run the real Steam client under Wine at all (that's what all
            // the old CEF/websocket rendering trouble was about), so there's no "launch
            // through Steam" option for them. Epic games still launch via legendary
            // (onLaunch), which works fine since that's a lightweight native CLI.
            if let di = downloadItem {
                DownloadStatusView(item: di, onPause: onPauseDownload, onResume: onResumeDownload,
                                   onCancel: onCancelDownload, onRetry: onRetryDownload)
            } else if game.isInstalled {
                HStack(spacing: 6) {
                    primaryActionButton
                    overflowMenu
                }
            } else if game.source == .custom {
                // Not "not installed" — the file Mist was pointed at is missing
                // (moved/deleted). "Install" makes no sense here; re-point instead.
                Button(action: onLocate) {
                    HStack {
                        Image(systemName: "questionmark.folder")
                        Text("Locate…")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Fog.custom)
            } else {
                Button(action: onInstall) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Install")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(game.source == .steam ? Fog.steam : Fog.epic)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Fog.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isFocused ? Fog.accent : Fog.hairline, lineWidth: isFocused ? 2 : 1)
        )
        .shadow(color: .black.opacity(isHovering ? 0.4 : 0.2),
               radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
        .scaleEffect(isHovering || isFocused ? 1.015 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isHovering)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isFocused)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onSelect)
        .contextMenu {
            if game.isInstalled {
                Button(action: onShowInFinder) {
                    Label("Show in Finder", systemImage: "folder")
                }
                Button(action: onLaunchOptions) {
                    Label("Launch Options…", systemImage: "slider.horizontal.3")
                }
                if game.source == .steam {
                    Button(action: onInstallWorkshopItem) {
                        Label("Install Workshop Item…", systemImage: "shippingbox")
                    }
                }
                Divider()
                Button(role: .destructive, action: onUninstall) {
                    Label(game.source == .custom ? "Remove from Mist" : "Uninstall", systemImage: "trash")
                }
            }
        }
    }

    // Poster-style cover art (2:3, matching Steam's own library capsule ratio)
    // with the title/metadata overlaid directly on a bottom gradient scrim,
    // instead of taking up separate rows below the image.
    private var poster: some View {
        // GeometryReader forces an explicit, unambiguous frame instead of
        // relying on .aspectRatio's size inference around content that has its
        // own opinion about size (the title text wrapping to 1 vs 2 lines, or
        // the loading placeholder's fully-flexible Color fill). Letting that
        // content's "ideal size" leak into the aspectRatio calculation is what
        // caused specific cards (long names, or ones caught mid-load) to blow
        // up to a wrong, oversized frame that bled into neighboring cards.
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                coverImage
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // Cover-art fill-as-it-installs: a bottom-up wash that rises with
                // progress, so a glance at the grid shows install state without
                // reading the caption underneath.
                if let di = downloadItem, di.state == .downloading || di.state == .queued {
                    Rectangle()
                        .fill(Fog.accent.opacity(0.24))
                        .frame(width: geo.size.width, height: geo.size.height * CGFloat(di.progress ?? 0.03))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
                        .animation(.easeOut(duration: 0.4), value: di.progress)
                }

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name)
                        .font(Fog.display(14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 5) {
                        Circle().fill(statusColor).frame(width: 6, height: 6)
                        Text(metaPrimary).font(.system(size: 11))
                        if isHovering, let lp = game.lastPlayedFormatted, game.isInstalled {
                            Text("· \(lp)").font(.system(size: 10.5)).foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .foregroundColor(.white.opacity(0.72))
                }
                .padding(10)
                .frame(width: geo.size.width, alignment: .leading)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if game.antiCheat != .none {
                HStack(spacing: 3) {
                    Image(systemName: "shield.lefthalf.filled")
                    Text(game.antiCheat.rawValue)
                }
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundColor(game.hasLinuxEAC ? .orange : .red)
                .padding(7)
            }
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 5) {
                if game.isNew {
                    Text("NEW")
                        .font(.system(size: 9, weight: .heavy)).tracking(0.5)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Fog.accent, in: Capsule())
                        .foregroundColor(Color(red: 0x0b/255, green: 0x10/255, blue: 0x20/255))
                }
                if game.isFamilyShared {
                    HStack(spacing: 3) {
                        Image(systemName: "person.2.fill")
                        Text("Shared")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundColor(Fog.accent)
                }
            }
            .padding(7)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var overflowMenu: some View {
        Menu {
            // Alternate runtimes — the plain Play button already picks the best one
            // (see GameActions.bestPlay); these are here only for the rare case you
            // want to force a specific renderer or Epic's own launcher.
            ForEach(Array(GameActions.alternates(for: game, d3dMetalAvailable: d3dMetalAvailable).enumerated()), id: \.offset) { _, alt in
                Button { alt.run(actionsBundle) } label: { Label(alt.title, systemImage: alt.icon) }
            }
            if !GameActions.alternates(for: game, d3dMetalAvailable: d3dMetalAvailable).isEmpty { Divider() }

            Button(action: onShowInFinder) { Label("Show in Finder", systemImage: "folder") }
            Button(action: onLaunchOptions) { Label("Launch Options…", systemImage: "slider.horizontal.3") }
            if game.source == .steam {
                Button(action: onInstallWorkshopItem) { Label("Install Workshop Item…", systemImage: "shippingbox") }
            }
            Divider()
            Button(role: .destructive, action: onUninstall) {
                Label(game.source == .custom ? "Remove from Mist" : "Uninstall", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 8)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var actionsBundle: GameActions.Bundle {
        .init(onLaunch: onLaunch, onLaunchNoEAC: onLaunchNoEAC, onLaunchGPTK: onLaunchGPTK)
    }

    // One button, one obvious action: play the game the best way we can. The
    // runtime choice (D3DMetal vs the basic renderer, offline-vs-Epic) is decided
    // for you — see GameActions.bestPlay — with alternatives tucked into the ••• menu.
    private var primaryActionButton: some View {
        Button { GameActions.bestPlay(for: game, d3dMetalAvailable: d3dMetalAvailable)(actionsBundle) } label: {
            HStack {
                Image(systemName: "play.fill")
                Text(game.antiCheat != .none ? "Play Offline" : "Play")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(game.source == .steam ? Fog.steam : Fog.epic)
    }

    @ViewBuilder
    var coverImage: some View {
        if let url = URL(string: game.imageURL), !game.imageURL.isEmpty {
            // Not every game has a library_600x900.jpg capsule — fall back to the
            // more universally-available store header.jpg before giving up to the
            // generic placeholder.
            let fallbackURL = game.imageURL.contains("library_600x900.jpg")
                ? URL(string: game.imageURL.replacingOccurrences(of: "library_600x900.jpg", with: "header.jpg"))
                : nil
            SteamCoverImageView(primaryURL: url, fallbackURL: fallbackURL, placeholder: AnyView(fallbackCover))
        } else {
            fallbackCover
        }
    }

    var fallbackCover: some View {
        let tint = game.source == .steam ? Fog.steam : Fog.epic
        return ZStack {
            LinearGradient(colors: [Fog.haze, Fog.bg], startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [tint.opacity(0.35), .clear], center: .topLeading, startRadius: 0, endRadius: 140)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundColor(tint.opacity(0.8))
        }
    }
}

// The first-run flow: Engine -> Accounts -> Play, on a progress rail. Which step
// shows is derived from persisted state (wineInstalled, each service's login),
// never from transient wizard state — so quitting mid-download or mid-login and
// reopening Mist resumes exactly where you left off instead of restarting.
enum OnboardingStep: Int, CaseIterable {
    case engine, accounts, play

    var title: String {
        switch self {
        case .engine: return "Engine ready"
        case .accounts: return "Sign in"
        case .play: return "Pick a game"
        }
    }
    var subtitle: String {
        switch self {
        case .engine: return "Downloaded once · ~200 MB"
        case .accounts: return "Connect Steam and/or Epic"
        case .play: return "Install & play"
        }
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupManager
    @ObservedObject var steamAuth: SteamAuthManager
    @ObservedObject var processManager: ProcessManager
    var onFinishOnboarding: () -> Void

    private var currentStep: OnboardingStep {
        if !setup.isComplete { return .engine }
        if !steamAuth.isLoggedIn && !processManager.epicLoggedIn { return .accounts }
        return .play
    }

    var body: some View {
        HStack(spacing: 0) {
            OnboardingRail(current: currentStep)
                .frame(width: 220)
                .padding(.vertical, 40)
                .padding(.leading, 36)

            Divider().background(Fog.hairline).padding(.vertical, 40)

            Group {
                switch currentStep {
                case .engine: EngineStepView(setup: setup)
                case .accounts, .play:
                    AccountsStepView(steamAuth: steamAuth, processManager: processManager,
                                     onContinue: onFinishOnboarding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Fog.bg)
    }
}

private struct OnboardingRail: View {
    let current: OnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ZStack {
                    Circle()
                        .fill(RadialGradient(colors: [Color(red: 0x9d/255, green: 0xb8/255, blue: 1),
                                                       Fog.accent, Color(red: 0x47/255, green: 0x63/255, blue: 0xc2/255)],
                                             center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 20))
                        .frame(width: 30, height: 30)
                        .shadow(color: Fog.accent.opacity(0.5), radius: 10)
                    Image(systemName: "cloud.fog.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                }
                Text("Mist").font(Fog.display(19)).foregroundColor(Fog.ink)
            }
            .padding(.bottom, 22)

            ForEach(OnboardingStep.allCases, id: \.self) { step in
                OnboardingRailRow(step: step, state: state(for: step),
                                  isLast: step == OnboardingStep.allCases.last)
            }
        }
    }

    private func state(for step: OnboardingStep) -> OnboardingRailRow.RowState {
        if step.rawValue < current.rawValue { return .done }
        if step == current { return .now }
        return .next
    }
}

private struct OnboardingRailRow: View {
    enum RowState { case done, now, next }
    let step: OnboardingStep
    let state: RowState
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack {
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? Fog.good : Fog.hairline)
                        .frame(width: 1.5)
                        .offset(y: 22)
                        .frame(height: 44)
                }
                Circle()
                    .fill(state == .done ? Fog.good : state == .now ? Fog.accent : Fog.haze)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Group {
                            if state == .done {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(Color(nsColor: .black))
                            } else {
                                Text("\(step.rawValue + 1)").font(.system(size: 11, weight: .bold))
                                    .foregroundColor(state == .now ? Color(nsColor: .black) : Fog.inkFaint)
                            }
                        }
                    )
                    .shadow(color: state == .now ? Fog.accent.opacity(0.6) : .clear, radius: 6)
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.system(size: 13, weight: .semibold))
                    .foregroundColor(state == .next ? Fog.inkFaint : Fog.ink)
                Text(step.subtitle).font(.system(size: 11)).foregroundColor(Fog.inkFaint)
            }
            .padding(.bottom, 18)
        }
    }
}

private struct EngineStepView: View {
    @ObservedObject var setup: SetupManager

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Setting up Mist").font(Fog.display(26, weight: .medium)).foregroundColor(Fog.ink)
                Text("A one-time download of the Wine compatibility layer Mist runs Windows games through — a translation layer, not a virtual machine. About 200 MB.")
                    .foregroundColor(Fog.inkDim).frame(maxWidth: 420, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 14) {
                Label("Wine engine (CrossOver 24)",
                      systemImage: setup.wineInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(setup.wineInstalled ? Fog.good : Fog.inkDim)
                    .font(.callout)

                if setup.isWorking {
                    VStack(alignment: .leading, spacing: 8) {
                        if let progress = setup.downloadProgress {
                            ProgressView(value: progress).progressViewStyle(.linear).tint(Fog.accent)
                        } else {
                            ProgressView().progressViewStyle(.linear).tint(Fog.accent)
                        }
                        Text(setup.statusText).font(.caption).foregroundColor(Fog.inkFaint)
                    }
                    .frame(width: 320)
                } else {
                    if let err = setup.errorText {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                            .frame(maxWidth: 360, alignment: .leading)
                    }
                    Button(setup.errorText == nil ? "Download & Install" : "Try Again") {
                        setup.runFullSetup()
                    }
                    .buttonStyle(.borderedProminent).tint(Fog.accent).controlSize(.large)
                }
            }
            .padding(20)
            .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Fog.hairline))
        }
    }
}

// Both services shown as independently-connectable — Steam's QR and Epic's
// browser login are shaped nothing alike, so this deliberately doesn't force
// them into one generic "sign in" step. Connect either or both, or skip.
private struct AccountsStepView: View {
    @ObservedObject var steamAuth: SteamAuthManager
    @ObservedObject var processManager: ProcessManager
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sign in").font(Fog.display(26, weight: .medium)).foregroundColor(Fog.ink)
                Text("One Steam scan covers your whole library, downloads, and achievements — no separate logins. Connect Epic too if you play there.")
                    .foregroundColor(Fog.inkDim).frame(maxWidth: 460, alignment: .leading)
            }

            HStack(alignment: .top, spacing: 14) {
                OnboardingSteamTile(auth: steamAuth)
                OnboardingEpicTile(processManager: processManager)
            }

            HStack {
                Button(steamAuth.isLoggedIn || processManager.epicLoggedIn ? "Continue" : "Skip for now") {
                    onContinue()
                }
                .buttonStyle(.borderedProminent).tint(Fog.accent).controlSize(.large)
                if !steamAuth.isLoggedIn && !processManager.epicLoggedIn {
                    Text("You can always sign in later from Settings.")
                        .font(.caption).foregroundColor(Fog.inkFaint)
                }
            }
        }
    }
}

private struct OnboardingSteamTile: View {
    @ObservedObject var auth: SteamAuthManager

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "cloud.fill").foregroundColor(Fog.steam)
                Text("Steam").font(.system(size: 14, weight: .semibold)).foregroundColor(Fog.ink)
                Spacer()
                if auth.isLoggedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(Fog.good).labelStyle(.titleAndIcon)
                }
            }
            if auth.isLoggedIn {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundColor(Fog.good)
                    Text(auth.accountName).font(.callout).foregroundColor(Fog.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else if let url = auth.qrChallengeURL {
                ZStack {
                    SteamQRCodeView(urlString: url)
                        .frame(width: 116, height: 116)
                        .padding(9)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Fog.accent.opacity(0.6), lineWidth: 2)
                        .frame(width: 134, height: 134)
                }
                Text(auth.isPolling ? "Waiting for your phone…" : auth.qrStatusText)
                    .font(.caption2).foregroundColor(Fog.inkFaint)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 130)
            }
            if let err = auth.errorText {
                Text(err).font(.caption2).foregroundColor(.orange)
                Button("Try Again") { auth.startQRLogin() }.font(.caption).buttonStyle(.bordered)
            }
        }
        .padding(16)
        .frame(width: 200)
        .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Fog.hairline))
        .onAppear { if auth.qrChallengeURL == nil && !auth.isPolling && !auth.isLoggedIn { auth.startQRLogin() } }
        .onDisappear { auth.stopPolling() }
    }
}

private struct OnboardingEpicTile: View {
    @ObservedObject var processManager: ProcessManager
    @State private var showPaste = false
    @State private var code = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill").foregroundColor(Fog.epic)
                Text("Epic").font(.system(size: 14, weight: .semibold)).foregroundColor(Fog.ink)
                Spacer()
                if processManager.epicLoggedIn {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundColor(Fog.good).labelStyle(.titleAndIcon)
                }
            }
            if processManager.epicLoggedIn {
                VStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundColor(Fog.good)
                    Text(processManager.epicUsername).font(.callout).foregroundColor(Fog.ink)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else if showPaste {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste the JSON from the browser tab that opened:")
                        .font(.caption2).foregroundColor(Fog.inkFaint)
                    TextField("Paste here", text: $code)
                        .textFieldStyle(.roundedBorder).font(.system(.caption, design: .monospaced))
                    HStack {
                        Button("Log In") { processManager.epicLoginWithCode(code); showPaste = false; code = "" }
                            .buttonStyle(.borderedProminent).tint(Fog.epic).controlSize(.small)
                            .disabled(code.isEmpty)
                        Button("Cancel") { showPaste = false; code = "" }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 130, alignment: .top)
            } else if processManager.epicLoginInProgress {
                ProgressView().frame(maxWidth: .infinity, minHeight: 130)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "safari").font(.system(size: 26)).foregroundColor(Fog.inkFaint)
                    Text("Sign in via your browser").font(.caption).foregroundColor(Fog.inkDim)
                        .multilineTextAlignment(.center)
                    Button("Log In") { showPaste = true; processManager.epicOpenLoginPage() }
                        .buttonStyle(.bordered).tint(Fog.epic)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            }
            if !processManager.epicLoginError.isEmpty {
                Text(processManager.epicLoginError).font(.caption2).foregroundColor(.orange)
            }
        }
        .padding(16)
        .frame(width: 200)
        .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Fog.hairline))
    }
}

// A single sidebar entry: colored icon tile, label, optional trailing count
// badge or "needs attention" dot, with its own hover + selected background.
struct SidebarRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    var count: Int? = nil
    var needsAttention: Bool = false
    let isSelected: Bool
    let action: () -> Void
    var isFocused: Bool = false

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: 26, height: 26)
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? Fog.ink : Fog.inkDim)
                Spacer(minLength: 4)
                if needsAttention {
                    Circle()
                        .fill(Fog.warn)
                        .frame(width: 6, height: 6)
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Fog.inkFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Fog.haze)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Fog.accentSoft
                          : (isHovering ? Color.white.opacity(0.05) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isFocused ? Fog.accent : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
    }
}

struct SidebarSectionLabel: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(Fog.inkFaint)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

struct SidebarView: View {
    @Binding var selection: String?
    let steamCount: Int
    let epicCount: Int
    let customCount: Int
    let epicLoggedIn: Bool
    let steamLoggedIn: Bool
    var focusedRow: String? = nil
    var downloadQueueCount: Int = 0
    var activeDownloadProgress: Double? = nil   // nil while nothing is actively downloading
    var onOpenDownloads: () -> Void = {}

    private let navOrder = sidebarNavOrder

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand header
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(RadialGradient(colors: [Color(red: 0x9d/255, green: 0xb8/255, blue: 1),
                                                       Fog.accent, Color(red: 0x47/255, green: 0x63/255, blue: 0xc2/255)],
                                             center: .init(x: 0.3, y: 0.25), startRadius: 0, endRadius: 20))
                        .frame(width: 26, height: 26)
                        .shadow(color: Fog.accent.opacity(0.5), radius: 8)
                    Image(systemName: "cloud.fog.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text("Mist")
                    .font(Fog.display(16))
                    .foregroundColor(Fog.ink)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            SidebarSectionLabel(title: "Library")
            VStack(spacing: 2) {
                SidebarRow(title: "All Games", systemImage: "square.grid.2x2.fill", tint: Fog.accent,
                          isSelected: selection == "all", action: { selection = "all" },
                          isFocused: focusedRow == "all")
                SidebarRow(title: "Steam", systemImage: "cloud.fill", tint: Fog.steam, count: steamCount,
                          isSelected: selection == "steam", action: { selection = "steam" },
                          isFocused: focusedRow == "steam")
                SidebarRow(title: "Epic", systemImage: "bolt.fill", tint: Fog.epic, count: epicCount,
                          needsAttention: !epicLoggedIn, isSelected: selection == "epic",
                          action: { selection = "epic" }, isFocused: focusedRow == "epic")
                SidebarRow(title: "My Apps", systemImage: "app.badge.checkmark", tint: Fog.custom, count: customCount,
                          isSelected: selection == "custom", action: { selection = "custom" },
                          isFocused: focusedRow == "custom")
            }
            .padding(.horizontal, 8)

            SidebarSectionLabel(title: "Discover")
            VStack(spacing: 2) {
                SidebarRow(title: "Steam Store", systemImage: "magnifyingglass", tint: Fog.steam,
                          isSelected: selection == "store", action: { selection = "store" },
                          isFocused: focusedRow == "store")
                SidebarRow(title: "Epic Free Games", systemImage: "gift.fill", tint: Fog.epic,
                          isSelected: selection == "epicfree", action: { selection = "epicfree" },
                          isFocused: focusedRow == "epicfree")
            }
            .padding(.horizontal, 8)

            Spacer()
            if downloadQueueCount > 0 {
                downloadMeter
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
            Divider().background(Fog.hairline)
            VStack(spacing: 2) {
                SidebarRow(title: "Settings", systemImage: "gearshape.fill", tint: Fog.inkFaint,
                          needsAttention: !steamLoggedIn || !epicLoggedIn,
                          isSelected: selection == "settings", action: { selection = "settings" },
                          isFocused: focusedRow == "settings")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(LinearGradient(colors: [Fog.bgElevated, Fog.bg], startPoint: .top, endPoint: .bottom))
    }

    private var downloadMeter: some View {
        Button(action: onOpenDownloads) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().stroke(Fog.hairline, lineWidth: 2.5).frame(width: 20, height: 20)
                    Circle()
                        .trim(from: 0, to: activeDownloadProgress ?? 0.12)
                        .stroke(Fog.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 20, height: 20)
                        .rotationEffect(.degrees(-90))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(activeDownloadProgress != nil ? "Downloading…" : "Queued")
                        .font(.caption.bold()).foregroundColor(Fog.ink)
                    Text("\(downloadQueueCount) item\(downloadQueueCount == 1 ? "" : "s")")
                        .font(.caption2).foregroundColor(Fog.inkFaint)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundColor(Fog.inkFaint)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Fog.haze, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// What subset of the current source's games to show. Replaces the old opaque
// "Installed First / Title A–Z" sort menu — sorting is now always the sensible
// installed-first, then alphabetical, and these chips do the filtering instead.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case installed = "Installed"
    case notInstalled = "Not Installed"
    case shared = "Family Shared"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .installed: return "arrow.down.circle.fill"
        case .notInstalled: return "icloud"
        case .shared: return "person.2.fill"
        }
    }
}

struct GameGridView: View {
    let games: [Game]           // already source/search/filter-narrowed by ContentView
    var onLaunch: (Game) -> Void = { _ in }
    var onLaunchNoEAC: (Game) -> Void = { _ in }
    var onLaunchGPTK: (Game) -> Void = { _ in }
    var onInstall: (Game) -> Void = { _ in }
    var onUninstall: (Game) -> Void = { _ in }
    var onShowInFinder: (Game) -> Void = { _ in }
    var onLaunchOptions: (Game) -> Void = { _ in }
    var onInstallWorkshopItem: (Game) -> Void = { _ in }
    var onSelect: (Game) -> Void = { _ in }
    var onLocate: (Game) -> Void = { _ in }
    var focusedGameID: Game.ID? = nil
    @Binding var filter: LibraryFilter
    var availableFilters: [LibraryFilter] = LibraryFilter.allCases
    // Whether the current source has ANY games before the chip filter is applied —
    // so an empty grid can tell "you have games, this filter is empty" from "your
    // library is empty (probably not signed in)". With the sign-in prompt + source
    // label to word that case correctly.
    var sourceHasGames: Bool = true
    var needsSignIn: Bool = false
    var sourceLabel: String = "your"
    var isCustomSource: Bool = false   // "My Apps" — no account, empty state offers Add instead of sign-in
    var onAddCustomApp: () -> Void = {}
    var downloadStates: [String: DownloadQueueItem] = [:]   // keyed by appid
    var onPauseDownload: (String) -> Void = { _ in }
    var onResumeDownload: (String) -> Void = { _ in }
    var onCancelDownload: (String) -> Void = { _ in }
    var onRetryDownload: (String) -> Void = { _ in }
    // Reported up so gamepad up/down navigation (owned by ContentView, which
    // doesn't know the grid's actual rendered width) can move by a full row
    // instead of a single card. See onGridWidthChange below for how it's measured.
    var onGridWidthChange: (CGFloat) -> Void = { _ in }

    let columns = [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 14)]

    // The single canonical order used everywhere (grid rendering AND gamepad focus
    // index): installed first, then alphabetical. Sectioning below just draws a
    // header between the two blocks — it never reorders, so focus stays in sync.
    static func ordered(_ games: [Game]) -> [Game] {
        games.sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    private var installed: [Game] { Self.ordered(games.filter(\.isInstalled)) }
    private var notInstalled: [Game] { Self.ordered(games.filter { !$0.isInstalled }) }

    // The most-recently-played installed game, for the "Jump back in" hero (idea 6).
    private var continueGame: Game? {
        games.filter { $0.isInstalled && $0.lastPlayed != nil }
            .max { ($0.lastPlayed ?? .distantPast) < ($1.lastPlayed ?? .distantPast) }
    }

    private func jumpBackIn(_ g: Game) -> some View {
        Button { onSelect(g) } label: {
            ZStack(alignment: .leading) {
                AsyncImage(url: URL(string: SteamLibraryService.heroURL(forAppID: g.id))) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { LinearGradient(colors: [Fog.haze, Fog.bg], startPoint: .leading, endPoint: .trailing) }
                }
                .frame(height: 118).frame(maxWidth: .infinity).clipped()
                LinearGradient(colors: [Fog.bg, Fog.bg.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                HStack(spacing: 16) {
                    ZStack {
                        Circle().fill(Fog.accent).frame(width: 46, height: 46)
                        Image(systemName: "play.fill").font(.system(size: 17)).foregroundColor(Color(red: 0x0b/255, green: 0x10/255, blue: 0x20/255))
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("JUMP BACK IN").font(.system(size: 10, weight: .heavy)).tracking(0.1).foregroundColor(Fog.accent)
                        Text(g.name).font(Fog.display(20, weight: .medium)).foregroundColor(Fog.ink).lineLimit(1)
                        if let pt = g.playtimeFormatted {
                            Text("\(pt) played\(g.lastPlayedFormatted.map { " · \($0)" } ?? "")")
                                .font(.system(size: 11.5)).foregroundColor(Fog.inkDim)
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 18)
            }
            .frame(height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Fog.hairline))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        ZStack {
            FogAtmosphere()
            gridScroll
        }
    }

    private var gridScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    filterBar
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    if games.isEmpty {
                        emptyState
                    } else {
                        if filter == .all, let cg = continueGame {
                            jumpBackIn(cg).padding(.horizontal, 16)
                        }
                        if !installed.isEmpty {
                            section(title: "Installed", count: installed.count, games: installed)
                        }
                        if !notInstalled.isEmpty {
                            section(title: filter == .shared ? "Available to install" : "Not installed",
                                    count: notInstalled.count, games: notInstalled)
                        }
                    }
                }
                .padding(.bottom, 24)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: GridWidthKey.self, value: geo.size.width)
                })
            }
            .onPreferenceChange(GridWidthKey.self) { onGridWidthChange($0) }
            .onChange(of: focusedGameID) { _, newID in
                guard let newID else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newID, anchor: .center) }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(availableFilters) { f in
                Button { filter = f } label: {
                    HStack(spacing: 5) {
                        Image(systemName: f.systemImage).font(.system(size: 10))
                        Text(f.rawValue).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(filter == f ? Fog.accentSoft : Fog.haze,
                                in: Capsule())
                    .foregroundColor(filter == f ? Fog.accent : Fog.inkDim)
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if isCustomSource {
                Button(action: onAddCustomApp) {
                    Label("Add App…", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered).tint(Fog.custom)
            }
        }
    }

    private func section(title: String, count: Int, games: [Game]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(Fog.display(15, weight: .medium)).foregroundColor(Fog.ink)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Fog.inkFaint)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Fog.haze, in: Capsule())
            }
            .padding(.horizontal, 16)

            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(games) { game in
                    let g = game
                    GameCardView(
                        game: g,
                        onLaunch: { onLaunch(g) },
                        onLaunchNoEAC: { onLaunchNoEAC(g) },
                        onLaunchGPTK: { onLaunchGPTK(g) },
                        onInstall: { onInstall(g) },
                        onUninstall: { onUninstall(g) },
                        onShowInFinder: { onShowInFinder(g) },
                        onLaunchOptions: { onLaunchOptions(g) },
                        onInstallWorkshopItem: { onInstallWorkshopItem(g) },
                        onSelect: { onSelect(g) },
                        onLocate: { onLocate(g) },
                        downloadItem: downloadStates[g.id],
                        onPauseDownload: { onPauseDownload(g.id) },
                        onResumeDownload: { onResumeDownload(g.id) },
                        onCancelDownload: { onCancelDownload(g.id) },
                        onRetryDownload: { onRetryDownload(g.id) },
                        isFocused: focusedGameID == g.id
                    )
                    .id(g.id)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 15) {
            ZStack {
                // Soft accent bloom so the mark reads on the fog ground.
                Circle().fill(Fog.accent).frame(width: 96, height: 96).blur(radius: 34).opacity(0.28)
                Circle()
                    .fill(LinearGradient(colors: [Fog.bgElevated, Fog.haze], startPoint: .top, endPoint: .bottom))
                    .frame(width: 86, height: 86)
                    .overlay(Circle().strokeBorder(Fog.hairline))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                Image(systemName: emptyIcon)
                    .font(.system(size: 31, weight: .light)).foregroundColor(Fog.accent.opacity(0.85))
            }
            Text(emptyTitle).font(Fog.display(19, weight: .medium)).foregroundColor(Fog.ink)
            Text(emptySubtitle).font(.callout).foregroundColor(Fog.inkDim)
                .multilineTextAlignment(.center)
            if isCustomSource && libraryEmpty {
                Button(action: onAddCustomApp) {
                    Label("Add App…", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent).tint(Fog.custom).controlSize(.large)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
    }

    // "Your library is empty" wins over any filter-specific copy: showing
    // "everything's installed" / "nothing installed" when you simply aren't signed
    // in is nonsense, so key off that first.
    private var libraryEmpty: Bool { !sourceHasGames }

    private var emptyIcon: String {
        if isCustomSource && libraryEmpty { return "app.badge.checkmark" }
        if libraryEmpty { return needsSignIn ? "person.crop.circle.badge.plus" : "tray" }
        switch filter {
        case .installed: return "arrow.down.circle"
        case .shared: return "person.2"
        case .notInstalled: return "checkmark.circle"
        case .all: return "tray"
        }
    }
    private var emptyTitle: String {
        if isCustomSource && libraryEmpty { return "No apps added yet" }
        if libraryEmpty { return needsSignIn ? "Sign in to see your games" : "No games in \(sourceLabel) library yet" }
        switch filter {
        case .installed: return "Nothing installed yet"
        case .shared: return "No family-shared games"
        case .notInstalled: return "Everything's installed"
        case .all: return "No games here"
        }
    }
    private var emptySubtitle: String {
        if isCustomSource && libraryEmpty { return "Point Mist at any .exe to add it to your library." }
        if libraryEmpty {
            return needsSignIn
                ? "Connect \(sourceLabel) account in Settings to load your library."
                : "Games you own will appear here."
        }
        switch filter {
        case .installed: return "Install a game to see it here."
        case .shared: return "Games shared into your Steam Family will appear here."
        case .notInstalled: return "Nice — your whole library is downloaded."
        case .all: return "No games match."
        }
    }
}

private struct GridWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// A barely-moving periwinkle haze — the brand, alive but calm (idea 46). Honors
// Reduce Motion by holding still. Cheap: three big blurred blobs on a timeline.
struct FogAtmosphere: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let blobs: [(color: Color, size: CGFloat, x: CGFloat, y: CGFloat, sx: CGFloat, sy: CGFloat, period: Double)] = [
        (Color(red: 0x7c/255, green: 0x9c/255, blue: 1.0), 520, 0.15, 0.10, 0.10, 0.06, 34),
        (Color(red: 0x96/255, green: 0x78/255, blue: 0.94), 440, 0.85, 0.30, -0.09, -0.05, 44),
        (Color(red: 0x46/255, green: 0x6e/255, blue: 0.86), 380, 0.55, 0.92, 0.06, -0.08, 52),
    ]
    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1/20)) { ctx in
                let t = reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                Canvas { c, size in
                    for b in blobs {
                        let phase = sin(t / b.period * .pi * 2)
                        let cx = size.width * b.x + size.width * b.sx * phase
                        let cy = size.height * b.y + size.height * b.sy * phase
                        let rect = CGRect(x: cx - b.size/2, y: cy - b.size/2, width: b.size, height: b.size)
                        c.fill(Circle().path(in: rect),
                               with: .radialGradient(Gradient(colors: [b.color.opacity(0.34), .clear]),
                                                     center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: b.size/2))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .blur(radius: 70)
                .opacity(0.5)
            }
        }
        .allowsHitTesting(false)
    }
}

// Browse the wider Steam catalog — games you don't own yet. Mist can't buy
// anything (no checkout flow), so results link out to the real store page;
// this is a discovery/wishlist surface, not a storefront.
struct SteamStoreBrowseView: View {
    let ownedAppIDs: Set<String>

    @State private var query = ""
    @State private var results: [StoreSearchResult] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Steam Store")
                    .font(Fog.display(24, weight: .medium))
                    .foregroundColor(Fog.ink)
                Text("Browse games you don't own yet. Mist can't purchase for you — results open the real store page.")
                    .font(.callout)
                    .foregroundColor(Fog.inkDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(Fog.inkFaint)
                TextField("Search the Steam catalog", text: $query)
                    .textFieldStyle(.plain)
                    .onChange(of: query) { _, newValue in
                        searchTask?.cancel()
                        searchTask = Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }
                            await runSearch(newValue)
                        }
                    }
                if isSearching { ProgressView().controlSize(.small) }
            }
            .padding(10)
            .background(Fog.haze, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.bottom, 14)

            if results.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "cloud.fill").font(.system(size: 30)).foregroundColor(Fog.inkFaint)
                    Text(query.isEmpty ? "Search for a game" : "No results")
                        .foregroundColor(Fog.inkDim)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(results) { item in
                            StoreResultCard(item: item, owned: ownedAppIDs.contains(item.appid))
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Fog.bg)
    }

    private func runSearch(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            await MainActor.run { results = []; isSearching = false }
            return
        }
        await MainActor.run { isSearching = true }
        let found = (try? await SteamLibraryService.searchStore(query: text)) ?? []
        guard !Task.isCancelled else { return }
        await MainActor.run { results = found; isSearching = false }
    }
}

struct StoreResultCard: View {
    let item: StoreSearchResult
    let owned: Bool

    var body: some View {
        Link(destination: URL(string: "https://store.steampowered.com/app/\(item.appid)")!) {
            HStack(spacing: 12) {
                AsyncImage(url: item.tiny_image.flatMap(URL.init)) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                    else { Fog.haze }
                }
                .frame(width: 92, height: 43)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Fog.ink)
                        .lineLimit(2)
                    if owned {
                        Text("In your library").font(.system(size: 10.5)).foregroundColor(Fog.good)
                    } else {
                        Text(item.priceLabel).font(.system(size: 10.5)).foregroundColor(Fog.inkFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Fog.hairline))
        }
        .buttonStyle(.plain)
    }
}

// This week's (and next weeks') Epic Games Store free promotions. Mist can't
// run Epic's authenticated checkout flow, so "unlock" here means: tell you
// what's free before you forget, and get you one click from actually
// claiming it on the real store.
struct EpicFreeGamesView: View {
    @State private var games: [EpicFreeGame] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Epic Free Games")
                    .font(Fog.display(24, weight: .medium))
                    .foregroundColor(Fog.ink)
                Text("Claim links open the real Epic Games Store — Mist doesn't run checkout itself.")
                    .font(.callout)
                    .foregroundColor(Fog.inkDim)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            if isLoading {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            } else if games.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "gift").font(.system(size: 30)).foregroundColor(Fog.inkFaint)
                    Text("Couldn't load Epic's free games right now").foregroundColor(Fog.inkDim)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 12)], spacing: 12) {
                        ForEach(games) { game in
                            EpicFreeGameCard(game: game)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Fog.bg)
        .task {
            games = await EpicPromotionsService.fetchFreeGames()
            isLoading = false
        }
    }
}

struct EpicFreeGameCard: View {
    let game: EpicFreeGame

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: game.imageURL.flatMap(URL.init)) { phase in
                if case .success(let image) = phase { image.resizable().scaledToFill() }
                else { Fog.haze }
            }
            .frame(height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(game.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Fog.ink)
                .lineLimit(1)

            HStack {
                Label(game.isCurrentlyFree ? "Free now" : "Coming soon",
                      systemImage: game.isCurrentlyFree ? "gift.fill" : "clock")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(game.isCurrentlyFree ? Fog.good : Fog.warn)
                Spacer()
                if let end = game.endDate {
                    Text(end, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(Fog.inkFaint)
                }
            }

            if game.isCurrentlyFree, let url = game.claimURL {
                Link(destination: url) {
                    Label("Claim on Epic Games Store", systemImage: "arrow.up.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Fog.epic)
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Fog.hairline))
    }
}

struct GameDetailView: View {
    let game: Game
    @ObservedObject var steamAuth: SteamAuthManager
    let steamAppsDir: URL
    var onLaunch: () -> Void = {}
    var onLaunchNoEAC: () -> Void = {}
    var onLaunchGPTK: () -> Void = {}
    var onInstall: () -> Void = {}
    var onUninstall: () -> Void = {}
    var onShowInFinder: () -> Void = {}
    var onLaunchOptions: () -> Void = {}
    var onInstallWorkshopItem: () -> Void = {}
    var onInstallWorkshopID: (String) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onLocate: () -> Void = {}
    var downloadItem: DownloadQueueItem? = nil
    var onPauseDownload: () -> Void = {}
    var onResumeDownload: () -> Void = {}
    var onCancelDownload: () -> Void = {}
    var onRetryDownload: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var details: SteamAppDetails?
    @State private var achievements: [SteamAchievement] = []
    @State private var achievementsError: String?
    @State private var isLoadingAchievements = false
    @State private var workshopItems: [WorkshopItem] = []
    @State private var showingWorkshopBrowse = false

    private var d3dMetalAvailable: Bool { D3DMetalProvider.detect() != nil }

    var body: some View {
        // The Workshop browser is rendered INLINE (swapping the sheet's content)
        // rather than as its own sheet. A sheet presented from within this
        // already-a-sheet detail view is a nested sheet, and on macOS the
        // interactive controls inside a nested sheet's ScrollView silently stop
        // receiving clicks — verified: header buttons worked, the in-scroll
        // Install buttons didn't. Swapping content in-place keeps a single sheet.
        Group {
            if showingWorkshopBrowse {
                WorkshopBrowseView(game: game, steamAuth: steamAuth,
                                   onInstall: onInstallWorkshopID,
                                   onBack: { showingWorkshopBrowse = false })
            } else {
                detailContent
            }
        }
        .frame(width: 680, height: 620)
        .task(id: game.id) {
            await loadAll()
        }
    }

    private var detailContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 18) {
                    metaStrip
                    if let desc = details?.short_description, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundColor(Fog.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !(details?.genreNames ?? []).isEmpty {
                        tagRow(details!.genreNames)
                    }
                    actionRow
                    Divider().overlay(Fog.hairline)
                    if game.source == .steam {
                        achievementsSection
                        if !(details?.screenshotURLs ?? []).isEmpty {
                            Divider().overlay(Fog.hairline)
                            screenshotStrip
                        }
                        Divider().overlay(Fog.hairline)
                        workshopSection
                    }
                }
                .padding(20)
            }
        }
        .background(Fog.bg)
    }

    // Full-bleed hero: the game's own artwork, blurred + scrimmed, serif title over it.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: URL(string: SteamLibraryService.heroURL(forAppID: game.id))) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                default:
                    LinearGradient(colors: [Fog.haze, Fog.bg], startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(height: 210)
            .frame(maxWidth: .infinity)
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, .clear, Fog.bg.opacity(0.65), Fog.bg],
                               startPoint: .top, endPoint: .bottom)
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(Fog.display(28, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
                    .lineLimit(2)
                subtitleLine
            }
            .padding(20)
        }
        .frame(height: 210)
        .clipped()
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    private var subtitleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: game.source == .steam ? "cloud.fill" : "bolt.fill").font(.system(size: 10))
            Text(game.source.rawValue)
            if let dev = details?.developerName { Text("· \(dev)") }
            if let year = details?.releaseYear { Text("· \(year)") }
        }
        .font(.system(size: 12))
        .foregroundColor(.white.opacity(0.82))
        .shadow(color: .black.opacity(0.4), radius: 4)
    }

    // Status chips under the hero: install state/size, the "how this runs" chip,
    // and a quiet playtime/last-played history line.
    private var metaStrip: some View {
        HStack(spacing: 8) {
            if game.isInstalled {
                pill(game.sizeBytes > 0 ? game.sizeFormatted : "Installed", icon: "internaldrive", tint: Fog.good)
            } else {
                pill(game.isFamilyShared ? "Family shared" : "Not installed",
                     icon: game.isFamilyShared ? "person.2.fill" : "icloud", tint: game.isFamilyShared ? Fog.accent : Fog.inkFaint)
            }
            runChip
            Spacer()
            if game.playtimeFormatted != nil || game.lastPlayedFormatted != nil {
                HStack(spacing: 5) {
                    if let pt = game.playtimeFormatted { Text(pt) }
                    if game.playtimeFormatted != nil, game.lastPlayedFormatted != nil { Text("·").foregroundColor(Fog.inkFaint) }
                    if let lp = game.lastPlayedFormatted { Text(lp) }
                }
                .font(.system(size: 11.5)).foregroundColor(Fog.inkFaint)
            }
        }
    }

    private func pill(_ text: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundColor(tint)
    }

    // Plain-language "how this game will run" — no jargon dropdowns.
    @ViewBuilder private var runChip: some View {
        let provider = D3DMetalProvider.detect()
        if game.source == .epic {
            pill("Epic runtime", icon: "bolt.fill", tint: Fog.epic)
        } else if let provider {
            pill("D3DMetal · \(provider.name)", icon: "cpu", tint: Fog.good)
        } else if DXVKManager.isBundled {
            pill("DXVK · bundled", icon: "cpu", tint: Fog.good)
        } else {
            pill("Basic renderer", icon: "cpu", tint: Fog.warn)
        }
    }

    private var screenshotStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Screenshots").font(.system(size: 13, weight: .semibold)).foregroundColor(Fog.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array((details?.screenshotURLs ?? []).prefix(8)), id: \.self) { url in
                        AsyncImage(url: URL(string: url)) { phase in
                            if case .success(let image) = phase { image.resizable().scaledToFill() }
                            else { Fog.haze }
                        }
                        .frame(width: 208, height: 117)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Fog.hairline))
                    }
                }
            }
        }
    }

    private func tagRow(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags.prefix(8), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Fog.inkDim)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Fog.haze, in: Capsule())
                }
            }
        }
    }

    private var actionsBundle: GameActions.Bundle {
        .init(onLaunch: onLaunch, onLaunchNoEAC: onLaunchNoEAC, onLaunchGPTK: onLaunchGPTK)
    }

    @ViewBuilder
    private var actionRow: some View {
        if let di = downloadItem {
            DownloadStatusView(item: di, onPause: onPauseDownload, onResume: onResumeDownload,
                               onCancel: onCancelDownload, onRetry: onRetryDownload)
        } else if game.isInstalled {
            HStack(spacing: 8) {
                Button { GameActions.bestPlay(for: game, d3dMetalAvailable: d3dMetalAvailable)(actionsBundle) } label: {
                    Label(game.antiCheat != .none ? "Play Offline" : "Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(game.source == .steam ? Fog.steam : Fog.epic)

                let alts = GameActions.alternates(for: game, d3dMetalAvailable: d3dMetalAvailable)
                Menu {
                    ForEach(Array(alts.enumerated()), id: \.offset) { _, alt in
                        Button { alt.run(actionsBundle) } label: { Label(alt.title, systemImage: alt.icon) }
                    }
                    if !alts.isEmpty { Divider() }
                    Button("Launch Options…", action: onLaunchOptions)
                    Button("Show in Finder", action: onShowInFinder)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderedButton)
                .fixedSize()

                Spacer()
                Button(game.source == .custom ? "Remove from Mist" : "Uninstall", role: .destructive, action: onUninstall)
                    .buttonStyle(.bordered)
            }
        } else if game.source == .custom {
            Button(action: onLocate) {
                Label("Locate…", systemImage: "questionmark.folder")
            }
            .buttonStyle(.borderedProminent)
            .tint(Fog.custom)
        } else {
            Button(action: onInstall) {
                Label("Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(game.source == .steam ? Fog.steam : Fog.epic)
        }
    }

    @ViewBuilder
    // A progress ring + count, so completion reads at a glance (idea 18).
    private var achievementSummary: some View {
        let unlocked = achievements.filter { $0.achieved == 1 }.count
        let total = max(achievements.count, 1)
        let frac = Double(unlocked) / Double(total)
        return HStack(spacing: 14) {
            ZStack {
                Circle().stroke(Fog.haze, lineWidth: 6)
                Circle().trim(from: 0, to: frac)
                    .stroke(Fog.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(unlocked)").font(Fog.display(17, weight: .medium)).foregroundColor(Fog.ink)
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(unlocked) of \(achievements.count) unlocked")
                    .font(.system(size: 13, weight: .medium)).foregroundColor(Fog.ink)
                Text("\(Int(frac * 100))% complete")
                    .font(.system(size: 11.5)).foregroundColor(Fog.inkFaint)
                RoundedRectangle(cornerRadius: 3).fill(Fog.haze).frame(height: 5).frame(maxWidth: 220)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Fog.accent)
                            .frame(width: 220 * frac, height: 5)
                    }
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Achievements", systemImage: "trophy.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Fog.ink)
                Spacer()
            }

            if !achievements.isEmpty { achievementSummary }

            if isLoadingAchievements {
                ProgressView().controlSize(.small)
            } else if let err = achievementsError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if achievements.isEmpty {
                Text("No achievements for this game.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(achievements) { ach in
                        HStack(spacing: 10) {
                            achievementIcon(for: ach)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(ach.name ?? ach.apiname)
                                        .font(.system(size: 12.5, weight: .medium))
                                    if let rarity = ach.rarityLabel {
                                        Text(rarity)
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Fog.accentSoft, in: Capsule())
                                            .foregroundColor(Fog.accent)
                                    }
                                }
                                if let desc = ach.description, !desc.isEmpty {
                                    Text(desc)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            if let pct = ach.globalPercent {
                                Text(String(format: "%.1f%%", pct))
                                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                        }
                        .opacity(ach.achieved == 1 ? 1 : 0.55)
                    }
                }
            }

            Text("Your unlock status and each achievement's global rarity, read live from Steam over your single sign-in.")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
    }

    // The real Steam icon (see SteamLibraryService.fetchAchievementIcons), desaturated
    // while locked so the same real art still reads as "locked" without Valve's
    // separate gray asset. Falls back to a generic seal/lock glyph if the icon never
    // loaded (e.g. the fetch failed, or the game has zero public rarity page).
    @ViewBuilder
    private func achievementIcon(for ach: SteamAchievement) -> some View {
        Group {
            if let iconURL = ach.iconURL, let url = URL(string: iconURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: ach.achieved == 1 ? "checkmark.seal.fill" : "lock.fill")
                            .foregroundColor(ach.achieved == 1 ? Fog.warn : Fog.inkFaint)
                    }
                }
            } else {
                Image(systemName: ach.achieved == 1 ? "checkmark.seal.fill" : "lock.fill")
                    .foregroundColor(ach.achieved == 1 ? Fog.warn : Fog.inkFaint)
            }
        }
        .frame(width: 30, height: 30)
        .background(Fog.haze, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .saturation(ach.achieved == 1 ? 1 : 0.15)
        .font(.system(size: 14))
    }

    @ViewBuilder
    private var workshopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Workshop Items", systemImage: "shippingbox.fill")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    showingWorkshopBrowse = true
                } label: {
                    Label("Browse", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("By ID…", action: onInstallWorkshopItem)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if workshopItems.isEmpty {
                Text("No workshop items downloaded for this game yet. Browse to find some.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Text("Downloaded")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.secondary)
                VStack(spacing: 4) {
                    ForEach(workshopItems) { item in
                        HStack {
                            Image(systemName: "doc.zipper")
                                .foregroundColor(.secondary)
                            Text(item.id)
                                .font(.system(.caption, design: .monospaced))
                            Spacer()
                            Text(item.sizeFormatted)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func loadAll() async {
        // Custom apps have no Steam app-page or Workshop to fetch.
        guard game.source == .steam else { return }
        workshopItems = MistWorkshop.installedItems(appid: game.id, steamAppsDir: steamAppsDir)

        if let d = try? await SteamLibraryService.fetchAppDetails(appid: game.id) {
            details = d
        }

        guard steamAuth.isLoggedIn else { return }
        isLoadingAchievements = true
        do {
            var list = try await SteamLibraryService.fetchAchievements(
                appid: game.id, steamID: steamAuth.steamID)
            // Icons are positional (see fetchAchievementIcons) so zip them onto the
            // list BEFORE it gets reordered below.
            let icons = await SteamLibraryService.fetchAchievementIcons(appid: game.id)
            if icons.count == list.count {
                for i in list.indices { list[i].iconURL = icons[i] }
            }
            // Overlay global rarity (best-effort; keyless, never throws) then sort
            // unlocked-first, and within each group rarest-last so the standout
            // "Ultra Rare" ones you HAVE surface at the top.
            let percents = await SteamLibraryService.fetchGlobalAchievementPercents(appid: game.id)
            for i in list.indices { list[i].globalPercent = percents[list[i].apiname] }
            list.sort { a, b in
                if a.achieved != b.achieved { return a.achieved > b.achieved }
                return (a.globalPercent ?? 101) < (b.globalPercent ?? 101)
            }
            achievements = list
        } catch {
            achievementsError = (error as? SteamAuthError)?.errorDescription
                ?? "No achievement data available for this game."
        }
        isLoadingAchievements = false
    }
}

struct WorkshopBrowseView: View {
    let game: Game
    @ObservedObject var steamAuth: SteamAuthManager
    let onInstall: (String) -> Void
    var onBack: () -> Void = {}

    @State private var items: [WorkshopBrowseItem] = []
    @State private var search = ""
    @State private var page = 1
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var canLoadMore = true
    // Item IDs the user has clicked Install on this session — so the button can
    // flip to a confirmation without needing to watch the actual download state
    // (which lives in a different manager up in ContentView).
    @State private var requested: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { await load(reset: true) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 1) {
                Text("Workshop")
                    .font(.headline)
                Text(game.name)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                TextField("Search the Workshop", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
                    .onSubmit { Task { await load(reset: true) } }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(14)
    }

    @ViewBuilder
    private var content: some View {
        if let err = loadError, items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text(err)
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty && isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text("No workshop items found.")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        WorkshopBrowseCard(
                            item: item,
                            requested: requested.contains(item.id),
                            onInstall: {
                                requested.insert(item.id)
                                onInstall(item.id)
                            }
                        )
                    }
                }
                .padding(14)
                if canLoadMore && !items.isEmpty {
                    Button {
                        Task { await load(reset: false) }
                    } label: {
                        if isLoading { ProgressView().controlSize(.small) }
                        else { Text("Load more") }
                    }
                    .buttonStyle(.bordered)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private func load(reset: Bool) async {
        guard !isLoading else { return }
        guard steamAuth.isLoggedIn else {
            loadError = "Sign in to Steam to browse the Workshop."
            return
        }
        isLoading = true
        if reset { page = 1; canLoadMore = true }
        do {
            let token = try await steamAuth.mintAccessToken()
            let fetched = try await SteamLibraryService.fetchWorkshopItems(
                appid: game.id, accessToken: token, page: page, search: search)
            if reset { items = fetched } else { items += fetched }
            canLoadMore = !fetched.isEmpty
            if canLoadMore { page += 1 }
            loadError = nil
        } catch {
            loadError = (error as? SteamAuthError)?.errorDescription
                ?? "Couldn't load the Workshop. You can still install items by ID."
        }
        isLoading = false
    }
}

struct WorkshopBrowseCard: View {
    let item: WorkshopBrowseItem
    let requested: Bool
    let onInstall: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: URL(string: item.preview_url ?? "")) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Color.primary.opacity(0.06)
                }
            }
            .frame(height: 120)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            // scaledToFill renders past the 120px frame (workshop previews are
            // wide); .clipped() hides that visually but the overflow still
            // hit-tests over the Install button below, swallowing its clicks —
            // the image is decorative, so opt it out of hit testing entirely.
            .allowsHitTesting(false)

            Text(item.title ?? "Untitled")
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1)

            if let desc = item.short_description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10.5))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                if let subs = item.subscriptions {
                    Label(compact(subs), systemImage: "person.2.fill")
                }
                if let size = item.sizeFormatted {
                    Label(size, systemImage: "internaldrive")
                }
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)

            Button(action: onInstall) {
                Label(requested ? "Installing…" : "Install",
                      systemImage: requested ? "checkmark" : "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(requested)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    private func compact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Epic Login via Local HTTP Server
//
// Opens the login page in the system browser (Safari/Chrome) which passes
// Cloudflare checks. A tiny local HTTP server captures the redirect and
// extracts the authorization code automatically.

import Network

class EpicAuthServer {
    private var listener: NWListener?
    private var port: UInt16 = 0
    var onAuthCode: ((String) -> Void)?
    var onPageBody: ((String) -> Void)?

    func start() -> UInt16 {
        // Pick a random available port
        let params = NWParameters.tcp
        listener = try? NWListener(using: params, on: .any)

        listener?.stateUpdateHandler = { state in
            if case .ready = state, let p = self.listener?.port?.rawValue {
                self.port = p
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: DispatchQueue.global())

        // Wait briefly for port assignment
        Thread.sleep(forTimeInterval: 0.2)
        if let p = listener?.port?.rawValue {
            port = p
        }
        return port
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue.global())

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let data = data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // Parse the HTTP request for the auth code
            var authCode: String? = nil

            // Check if this is a POST with JSON body containing authorizationCode
            if request.contains("authorizationCode") {
                if let bodyStart = request.range(of: "\r\n\r\n") {
                    let body = String(request[bodyStart.upperBound...])
                    if let jsonData = body.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                       let code = json["authorizationCode"] as? String {
                        authCode = code
                    }
                }
            }

            // Check URL query params for code=
            if authCode == nil, let firstLine = request.split(separator: "\r\n").first {
                let parts = firstLine.split(separator: " ")
                if parts.count >= 2 {
                    let path = String(parts[1])
                    if let components = URLComponents(string: path),
                       let code = components.queryItems?.first(where: { $0.name == "code" })?.value {
                        authCode = code
                    }
                }
            }

            // Check for the JSON body that Epic returns (the page body forwarded by JS)
            if authCode == nil, let firstLine = request.split(separator: "\r\n").first,
               String(firstLine).contains("/callback") {
                // Extract body from POST
                if let bodyStart = request.range(of: "\r\n\r\n") {
                    let body = String(request[bodyStart.upperBound...])
                    // URL-decode the body parameter
                    if body.contains("body=") {
                        let bodyParam = body.replacingOccurrences(of: "body=", with: "")
                            .removingPercentEncoding ?? body
                        if let jsonData = bodyParam.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let code = json["authorizationCode"] as? String,
                           code != "<null>", !code.isEmpty {
                            authCode = code
                        }
                    }
                }
            }

            // Send response
            let responseBody: String
            if authCode != nil {
                responseBody = """
                <html><body style="font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:white;">
                <div style="text-align:center">
                <h1 style="font-size:48px">&#127815;</h1>
                <h2>Logged in to Mist!</h2>
                <p style="color:#888">You can close this tab and return to the app.</p>
                </div></body></html>
                """
            } else {
                responseBody = """
                <html><body style="font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#1a1a2e;color:white;">
                <div style="text-align:center">
                <h2>Waiting for login...</h2>
                <p style="color:#888">Complete the login on Epic's page.</p>
                </div></body></html>
                """
            }

            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n\(responseBody)"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })

            if let code = authCode {
                DispatchQueue.main.async {
                    self?.onAuthCode?(code)
                }
            }
        }
    }
}

// Monitors the Epic redirect page in the system browser by polling
// a known URL pattern, since we can't inject JS into Safari.
// Instead, we use a smarter approach: open the login URL with a redirect
// that includes our localhost callback, so the browser comes back to us.

class EpicAuthFlow: ObservableObject {
    @Published var isActive = false
    @Published var serverPort: UInt16 = 0

    private var server = EpicAuthServer()
    var onAuthCode: ((String) -> Void)?

    func start() {
        isActive = true

        server.onAuthCode = { [weak self] code in
            DispatchQueue.main.async {
                self?.isActive = false
                self?.server.stop()
                self?.onAuthCode?(code)
            }
        }

        serverPort = server.start()

        // Open Epic login in system browser
        // After login, Epic redirects to their API which returns JSON with the auth code.
        // We open the legendary.gl/epiclogin URL which handles the redirect properly.
        let url = URL(string: "https://legendary.gl/epiclogin")!
        NSWorkspace.shared.open(url)
    }

    func stop() {
        isActive = false
        server.stop()
    }
}

struct SteamQRCodeView: View {
    let urlString: String

    var body: some View {
        if let image = steamQRCodeImage(from: urlString) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .aspectRatio(1, contentMode: .fit)
        } else {
            Text("Could not generate QR code")
                .font(.caption2)
                .multilineTextAlignment(.center)
        }
    }
}

struct SteamLoginView: View {
    @ObservedObject var auth: SteamAuthManager

    var body: some View {
        if auth.isLoggedIn {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Logged in as \(auth.accountName)")
                        .font(.callout)
                    Text("SteamID: \(auth.steamID)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Log Out") { auth.logOut() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            .padding(4)
        } else {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sign in to Steam")
                        .font(.headline)
                    Text("Scan with the Steam Mobile app to sign in instantly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: 240, alignment: .leading)
                    if let err = auth.errorText {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.caption)
                            .frame(maxWidth: 240, alignment: .leading)
                        Button("Try Again") { auth.startQRLogin() }
                            .buttonStyle(.bordered)
                    }
                }
                Spacer()
                VStack(spacing: 8) {
                    if let url = auth.qrChallengeURL {
                        SteamQRCodeView(urlString: url)
                            .frame(width: 100, height: 100)
                            .padding(8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if auth.isPolling {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text(auth.qrStatusText)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else if auth.errorText == nil {
                        ProgressView()
                            .frame(width: 100, height: 100)
                    }
                }
            }
            .padding(4)
            .onAppear {
                if auth.qrChallengeURL == nil && !auth.isPolling { auth.startQRLogin() }
            }
            .onDisappear { auth.stopPolling() }
        }
    }
}

struct EpicStoreView: View {
    @ObservedObject var processManager: ProcessManager
    @State private var installName: String = ""
    @State private var showLoginFlow = false
    @State private var loginCode: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Login section
                Group {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: processManager.epicLoggedIn
                                  ? "checkmark.circle.fill" : "person.circle")
                                .font(.title2)
                                .foregroundColor(processManager.epicLoggedIn ? .green : .secondary)

                            VStack(alignment: .leading) {
                                if processManager.epicLoggedIn {
                                    Text("Logged in as \(processManager.epicUsername)")
                                        .font(.headline)
                                } else {
                                    Text("Not logged in")
                                        .font(.headline)
                                    Text("Log in to access your Epic Games library")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            if processManager.epicLoginInProgress {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Logging in...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else if !processManager.epicLoggedIn {
                                Button("Log In") {
                                    showLoginFlow = true
                                    processManager.epicOpenLoginPage()
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Fog.epic)
                            }
                        }

                        // Login flow: browser opens, user pastes the JSON back
                        if showLoginFlow && !processManager.epicLoggedIn {
                            Divider()
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Image(systemName: "safari")
                                        .foregroundColor(.blue)
                                    Text("A login page opened in your browser.")
                                        .font(.callout)
                                }

                                Text("After logging in, you'll see a page with JSON text. Select all the text on that page and paste it here:")
                                    .font(.callout)
                                    .foregroundColor(.secondary)

                                HStack {
                                    TextField("Paste the JSON from the browser here", text: $loginCode)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.caption, design: .monospaced))

                                    Button("Log In") {
                                        processManager.epicLoginWithCode(loginCode)
                                        showLoginFlow = false
                                        loginCode = ""
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(Fog.epic)
                                    .disabled(loginCode.isEmpty)

                                    Button("Cancel") {
                                        showLoginFlow = false
                                        loginCode = ""
                                    }
                                    .buttonStyle(.bordered)
                                }

                                Button("Re-open login page") {
                                    processManager.epicOpenLoginPage()
                                }
                                .font(.caption)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                        }

                        if !processManager.epicLoginError.isEmpty {
                            Text(processManager.epicLoginError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                // Install game section
                if processManager.epicLoggedIn {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Enter the Epic app name to install a game.")
                                .font(.callout)
                                .foregroundColor(.secondary)

                            Text("Find names with: mist epic games")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack {
                                TextField("App name (e.g. Sugar for Rocket League)", text: $installName)
                                    .textFieldStyle(.roundedBorder)

                                Button("Install") {
                                    guard !installName.isEmpty else { return }
                                    processManager.epicInstall(appName: installName)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Fog.epic)
                                .disabled(installName.isEmpty || processManager.epicInstalling)
                            }

                            if processManager.epicInstalling {
                                VStack(alignment: .leading, spacing: 4) {
                                    ProgressView()
                                        .progressViewStyle(.linear)
                                    Text(processManager.epicInstallProgress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Install Game", systemImage: "arrow.down.circle.fill")
                    }

                    // Quick install buttons for popular games
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Popular Games")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            HStack(spacing: 8) {
                                QuickInstallButton(name: "Rocket League", appName: "Sugar") {
                                    installName = "Sugar"
                                }
                                QuickInstallButton(name: "Fortnite", appName: "Fortnite") {
                                    installName = "Fortnite"
                                }
                                QuickInstallButton(name: "Fall Guys", appName: "Starter") {
                                    installName = "Starter"
                                }
                            }
                        }
                        .padding(4)
                    } label: {
                        Label("Quick Install", systemImage: "star.fill")
                    }
                }
            }
        .padding(20)
        .onAppear {
            processManager.checkEpicLogin()
        }
    }
}

struct QuickInstallButton: View {
    let name: String
    let appName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title3)
                Text(name)
                    .font(.caption)
            }
            .frame(width: 90, height: 60)
        }
        .buttonStyle(.bordered)
        .tint(Fog.epic)
    }
}

// Tuples aren't Identifiable (needed for .sheet(item:)) — this just wraps one.
struct PendingCustomAppPick: Identifiable {
    let id = UUID()
    let exePath: String
    let suggestedName: String
    let relocatingID: String?
    init(_ t: (exePath: String, suggestedName: String, relocatingID: String?)) {
        exePath = t.exePath; suggestedName = t.suggestedName; relocatingID = t.relocatingID
    }
}

// Every flow that mutates the library from outside the grid/detail views —
// the Uninstall/Remove confirmation alert, plus the confirm-name step after
// picking a .exe (for either adding a new custom app or relocating one whose
// file moved) — isolated into one ViewModifier. Folding this much
// Binding(get:set:)/switch logic directly into ContentView.body pushed
// SwiftUI's type-checker over its time limit ("unable to type-check this
// expression in reasonable time"); as a single struct it type-checks fine.
struct LibraryMutationModifiers: ViewModifier {
    @Binding var pendingUninstall: Game?
    @Binding var showingAddCustomApp: Bool
    @Binding var relocatingCustomAppID: String?
    @Binding var pendingCustomAppPick: (exePath: String, suggestedName: String, relocatingID: String?)?
    var onUninstallSteam: (Game) -> Void
    var onUninstallEpic: (Game) -> Void
    var onRemoveCustom: (Game) -> Void
    var onAddCustomApp: (String, String) -> Void       // (name, exePath)
    var onRelocateCustomApp: (String, String) -> Void  // (id, newExePath)

    func body(content: Content) -> some View {
        content
            .alert(pendingUninstall?.source == .custom
                   ? "Remove \(pendingUninstall?.name ?? "") from Mist?"
                   : "Uninstall \(pendingUninstall?.name ?? "")?",
                   isPresented: Binding(
                get: { pendingUninstall != nil },
                set: { if !$0 { pendingUninstall = nil } }
            )) {
                Button(pendingUninstall?.source == .custom ? "Remove" : "Uninstall", role: .destructive) {
                    guard let game = pendingUninstall else { return }
                    switch game.source {
                    case .steam: onUninstallSteam(game)
                    case .epic: onUninstallEpic(game)
                    case .custom: onRemoveCustom(game)
                    }
                    pendingUninstall = nil
                }
                Button("Cancel", role: .cancel) { pendingUninstall = nil }
            } message: {
                Text(pendingUninstall?.source == .custom
                     ? "Mist will forget this app. Its file on disk is never touched."
                     : "This deletes the game's installed files from disk. You can reinstall it later.")
            }
            .fileImporter(isPresented: $showingAddCustomApp,
                          allowedContentTypes: [UTType(filenameExtension: "exe") ?? .item]) { result in
                guard let url = try? result.get() else { return }
                let name = url.deletingPathExtension().lastPathComponent
                pendingCustomAppPick = (exePath: url.path, suggestedName: name, relocatingID: nil)
            }
            .fileImporter(isPresented: Binding(
                get: { relocatingCustomAppID != nil },
                set: { if !$0 { relocatingCustomAppID = nil } }
            ), allowedContentTypes: [UTType(filenameExtension: "exe") ?? .item]) { result in
                guard let url = try? result.get(), let id = relocatingCustomAppID else { return }
                let name = url.deletingPathExtension().lastPathComponent
                pendingCustomAppPick = (exePath: url.path, suggestedName: name, relocatingID: id)
                relocatingCustomAppID = nil
            }
            .sheet(item: Binding(
                get: { pendingCustomAppPick.map { PendingCustomAppPick($0) } },
                set: { if $0 == nil { pendingCustomAppPick = nil } }
            )) { pick in
                AddCustomAppView(suggestedName: pick.suggestedName) { finalName in
                    if let rid = pick.relocatingID { onRelocateCustomApp(rid, pick.exePath) }
                    else { onAddCustomApp(finalName, pick.exePath) }
                    pendingCustomAppPick = nil
                } onCancel: {
                    pendingCustomAppPick = nil
                }
            }
    }
}

// The downloads queue sheet + the install-finished toast — pulled out for the
// same reason as LibraryMutationModifiers above: keeping ContentView.body's
// modifier chain short enough for SwiftUI's type-checker.
struct DownloadsUIModifiers: ViewModifier {
    @ObservedObject var downloadManager: SteamDownloadManager
    @Binding var showingDownloadsQueue: Bool
    @Binding var installToast: Game?
    var onPlay: (Game) -> Void

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showingDownloadsQueue) {
                DownloadsQueueView(
                    downloadManager: downloadManager,
                    onPause: { downloadManager.pause(id: $0) },
                    onResume: { downloadManager.resume(id: $0) },
                    onCancel: { downloadManager.cancel(id: $0) },
                    onRetry: { downloadManager.retry(id: $0) },
                    onMoveUp: { downloadManager.moveUp(id: $0) },
                    onMoveDown: { downloadManager.moveDown(id: $0) }
                )
            }
            .overlay(alignment: .bottomTrailing) {
                if let g = installToast {
                    InstallFinishedToast(
                        game: g,
                        onPlay: { onPlay(g); installToast = nil },
                        onDismiss: { installToast = nil }
                    )
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                            if installToast?.id == g.id {
                                withAnimation { installToast = nil }
                            }
                        }
                    }
                }
            }
    }
}

struct AddCustomAppView: View {
    let suggestedName: String
    var onSave: (String) -> Void
    var onCancel: () -> Void
    @State private var name: String
    @Environment(\.dismiss) private var dismiss

    init(suggestedName: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.suggestedName = suggestedName
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Fog.custom.opacity(0.18))
                        .frame(width: 34, height: 34)
                    Image(systemName: "app.badge.checkmark").foregroundColor(Fog.custom)
                }
                Text("Add to Mist").font(Fog.display(17, weight: .medium)).foregroundColor(Fog.ink)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.caption).foregroundColor(Fog.inkFaint)
                TextField("App name", text: $name).textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button("Cancel") { onCancel(); dismiss() }.buttonStyle(.bordered)
                Button("Add") { onSave(name.isEmpty ? suggestedName : name); dismiss() }
                    .buttonStyle(.borderedProminent).tint(Fog.custom)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 340)
    }
}

// Renders one download's state (queued/downloading/paused/failed) with the
// controls appropriate to it — shared by the game card, the detail page, and
// the queue sheet so all three stay visually and behaviorally in sync.
struct DownloadStatusView: View {
    let item: DownloadQueueItem
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch item.state {
            case .queued:
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.caption2).foregroundColor(Fog.inkFaint)
                    Text("Queued").font(.caption).foregroundColor(Fog.inkDim)
                    Spacer()
                    cancelButton
                }
            case .downloading:
                ProgressView(value: item.progress ?? 0).tint(Fog.accent)
                HStack(spacing: 6) {
                    Text(item.progress.map { "\(Int($0 * 100))%" } ?? "…")
                        .font(.caption2).foregroundColor(Fog.inkDim)
                    if let s = item.speedFormatted {
                        Text("· \(s)").font(.caption2).foregroundColor(Fog.inkFaint)
                    }
                    if let e = item.etaFormatted {
                        Text("· \(e)").font(.caption2).foregroundColor(Fog.inkFaint)
                    }
                    Spacer()
                    pauseButton
                    cancelButton
                }
            case .paused:
                HStack(spacing: 6) {
                    Text("Paused").font(.caption).foregroundColor(Fog.inkDim)
                    Spacer()
                    resumeButton
                    cancelButton
                }
            case .failed(let message):
                HStack(alignment: .top, spacing: 6) {
                    Text(message).font(.caption2).foregroundColor(.red).lineLimit(2)
                    Spacer()
                    retryButton
                    cancelButton
                }
            case .done:
                EmptyView()
            }
        }
    }

    private var pauseButton: some View {
        Button(action: onPause) { Image(systemName: "pause.fill") }
            .buttonStyle(.plain).foregroundColor(Fog.inkDim)
    }
    private var resumeButton: some View {
        Button(action: onResume) { Image(systemName: "play.fill") }
            .buttonStyle(.plain).foregroundColor(Fog.accent)
    }
    private var retryButton: some View {
        Button(action: onRetry) { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).foregroundColor(Fog.accent)
    }
    private var cancelButton: some View {
        Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).foregroundColor(Fog.inkFaint)
    }
}

// The full download queue — every base-game and workshop-item entry, in
// queue order, with per-item speed/ETA and pause/resume/cancel/retry, plus
// up/down reordering of the still-pending items.
struct DownloadsQueueView: View {
    @ObservedObject var downloadManager: SteamDownloadManager
    var onPause: (String) -> Void
    var onResume: (String) -> Void
    var onCancel: (String) -> Void
    var onRetry: (String) -> Void
    var onMoveUp: (String) -> Void
    var onMoveDown: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Downloads").font(Fog.display(18, weight: .medium)).foregroundColor(Fog.ink)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.bordered)
            }
            .padding(16)
            Divider().overlay(Fog.hairline)
            if downloadManager.queue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 34)).foregroundColor(Fog.inkFaint)
                    Text("Nothing downloading").foregroundColor(Fog.inkDim)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(Array(downloadManager.queue.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(width: 420, height: 460)
        .background(Fog.bg)
    }

    private func queueRow(_ item: DownloadQueueItem, index: Int) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Fog.haze)
                Image(systemName: item.pubfileID != nil ? "shippingbox" : "square.stack.3d.up")
                    .foregroundColor(Fog.inkFaint)
            }
            .frame(width: 42, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.callout.bold()).foregroundColor(Fog.ink).lineLimit(1)
                DownloadStatusView(
                    item: item,
                    onPause: { onPause(item.id) },
                    onResume: { onResume(item.id) },
                    onCancel: { onCancel(item.id) },
                    onRetry: { onRetry(item.id) }
                )
            }

            VStack(spacing: 2) {
                Button(action: { onMoveUp(item.id) }) { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain).foregroundColor(Fog.inkFaint)
                    .disabled(index == 0)
                Button(action: { onMoveDown(item.id) }) { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain).foregroundColor(Fog.inkFaint)
                    .disabled(index == downloadManager.queue.count - 1)
            }
            .font(.caption)
        }
        .padding(10)
        .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// A transient banner offering a direct "Play" action right after a Steam
// install finishes — shown by ContentView, auto-dismissed a few seconds later.
struct InstallFinishedToast: View {
    let game: Game
    var onPlay: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill").foregroundColor(Fog.good).font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(game.name) installed").font(.callout.bold()).foregroundColor(Fog.ink)
                Text("Ready to play").font(.caption).foregroundColor(Fog.inkDim)
            }
            Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent).tint(Fog.accent)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundColor(Fog.inkFaint)
        }
        .padding(14)
        .background(Fog.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Fog.hairline))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
        .frame(maxWidth: 340)
    }
}

struct LaunchOptionsView: View {
    let game: Game
    let onShowInFinder: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customArgs: String

    init(game: Game, onShowInFinder: @escaping () -> Void) {
        self.game = game
        self.onShowInFinder = onShowInFinder
        _customArgs = State(initialValue: GameSettingsStore.customArgs(for: game.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch Options")
                        .font(.title2.bold())
                    Text(game.name)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") {
                    GameSettingsStore.setCustomArgs(customArgs, for: game.id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom Launch Arguments")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. -window -novid", text: $customArgs)
                    .textFieldStyle(.roundedBorder)
                Text("Passed directly to the game's executable on launch.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Install Location")
                    .font(.subheadline.weight(.semibold))
                HStack {
                    Text(game.installDir)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder", action: onShowInFinder)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: 260)
    }
}

struct WorkshopInstallView: View {
    let game: Game
    let onInstall: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var input: String = ""

    // Accepts either a bare numeric ID or a full workshop URL
    // (steamcommunity.com/sharedfiles/filedetails/?id=<N>).
    static func extractPubfileID(from input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.isEmpty, trimmed.allSatisfy(\.isNumber) { return trimmed }
        if let comps = URLComponents(string: trimmed),
           let idValue = comps.queryItems?.first(where: { $0.name == "id" })?.value,
           !idValue.isEmpty, idValue.allSatisfy(\.isNumber) {
            return idValue
        }
        return nil
    }

    private var extractedID: String? { Self.extractPubfileID(from: input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install Workshop Item")
                        .font(.title2.bold())
                    Text(game.name)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install") {
                    guard let id = extractedID else { return }
                    onInstall(id)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(extractedID == nil)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Workshop URL or Item ID")
                    .font(.subheadline.weight(.semibold))
                TextField("e.g. https://steamcommunity.com/sharedfiles/filedetails/?id=123456789",
                         text: $input)
                    .textFieldStyle(.roundedBorder)
                if !input.isEmpty && extractedID == nil {
                    Text("Couldn't find a workshop item ID in that.")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Label(
                "Downloads to the same folder Steam itself would use. Whether \(game.name) actually loads mods from there depends on the game — some read the Steam Workshop API directly instead of scanning the folder, which Mist doesn't implement.",
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundColor(.secondary)

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 460, height: 280)
    }
}

struct RunningGameView: View {
    @ObservedObject var processManager: ProcessManager
    let onDismiss: () -> Void

    @State private var showLog = false

    // "Launching…" for the first couple of seconds, then "Running".
    private var isEarly: Bool {
        guard let s = processManager.launchedAt else { return true }
        return Date().timeIntervalSince(s) < 2.5
    }

    // Count achievements the post-session sync pushed (logged as "  ✓ NAME").
    private var syncedCount: Int {
        processManager.outputLog.components(separatedBy: "\n").filter { $0.hasPrefix("  ✓ ") }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            if processManager.isRunning { runningCard } else { endedCard }
            Spacer()
            logDisclosure
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Fog.bg)
    }

    private var runningCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = processManager.launchedAt.map { context.date.timeIntervalSince($0) } ?? 0
            VStack(spacing: 20) {
                ZStack {
                    Circle().fill(Fog.good.opacity(0.14)).frame(width: 62, height: 62)
                    Circle().fill(Fog.good).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Fog.good, lineWidth: 2).scaleEffect(1 + (elapsed.truncatingRemainder(dividingBy: 2)) * 0.6)
                                    .opacity(1 - (elapsed.truncatingRemainder(dividingBy: 2)) / 2))
                }
                VStack(spacing: 5) {
                    Text(processManager.currentGame?.name ?? "Game")
                        .font(Fog.display(24, weight: .medium)).foregroundColor(Fog.ink)
                    Text(isEarly ? "Launching…" : "Running")
                        .font(.system(size: 13)).foregroundColor(Fog.inkDim)
                }
                Text(timeString(elapsed))
                    .font(.system(size: 30, weight: .light, design: .monospaced).monospacedDigit())
                    .foregroundColor(Fog.ink)
                if let g = processManager.currentGame { runnerChip(for: g) }
                Button { processManager.stop() } label: {
                    Label("Stop", systemImage: "stop.fill").frame(width: 120)
                }
                .buttonStyle(.bordered).tint(.red).controlSize(.large)
            }
        }
    }

    private var endedCard: some View {
        let dur = (processManager.endedAt ?? Date()).timeIntervalSince(processManager.launchedAt ?? Date())
        return VStack(spacing: 18) {
            ZStack {
                Circle().fill(Fog.accentSoft).frame(width: 62, height: 62)
                Image(systemName: "checkmark").font(.system(size: 24, weight: .semibold)).foregroundColor(Fog.accent)
            }
            VStack(spacing: 5) {
                Text(processManager.currentGame?.name ?? "Session ended")
                    .font(Fog.display(22, weight: .medium)).foregroundColor(Fog.ink)
                Text("Played \(timeString(dur))\(syncedCount > 0 ? " · \(syncedCount) achievement\(syncedCount == 1 ? "" : "s") synced" : "")")
                    .font(.system(size: 13)).foregroundColor(Fog.inkDim)
            }
            Button { onDismiss() } label: {
                Label("Back to Library", systemImage: "chevron.left").frame(width: 150)
            }
            .buttonStyle(.borderedProminent).tint(Fog.accent).controlSize(.large)
        }
    }

    @ViewBuilder private func runnerChip(for game: Game) -> some View {
        let provider = D3DMetalProvider.detect()
        let label: String = game.source == .epic ? "Epic runtime"
            : provider != nil ? "D3DMetal · \(provider!.name)"
            : DXVKManager.isBundled ? "DXVK · bundled" : "Basic renderer"
        HStack(spacing: 6) {
            Image(systemName: "cpu").font(.system(size: 10))
            Text(label)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Fog.haze, in: Capsule())
        .foregroundColor(Fog.inkDim)
    }

    private var logDisclosure: some View {
        VStack(spacing: 0) {
            Divider().overlay(Fog.hairline)
            Button { withAnimation(.easeInOut(duration: 0.2)) { showLog.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(showLog ? 90 : 0))
                    Text("Details & log").font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundColor(Fog.inkFaint)
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            if showLog {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(processManager.outputLog.isEmpty ? "Starting…" : processManager.outputLog)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(Fog.inkDim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12).id("log-bottom")
                    }
                    .frame(height: 220)
                    .background(Color.black.opacity(0.25))
                    .onChange(of: processManager.outputLog) { _ in proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t)); let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.gradient)
                        .frame(width: 22, height: 22)
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct SettingsInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// Shows exactly which graphics backends Mist found, so how a game will render is
// never a mystery — with a one-tap way to add what's missing (idea 42).
struct GraphicsSettingsView: View {
    private var provider: D3DMetalProvider? { D3DMetalProvider.detect() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("How your games will render")
                .font(.system(size: 12.5, weight: .medium)).foregroundColor(Fog.inkDim)
                .padding(.bottom, 10)

            row(name: "DXVK · bundled", detail: "Direct3D 10/11, self-contained",
                on: DXVKManager.isBundled, status: "active")

            row(name: provider != nil ? "D3DMetal · via \(provider!.name)" : "D3DMetal",
                detail: "Best for Direct3D 12 titles",
                on: provider != nil, status: provider != nil ? "detected" : nil,
                fixURL: provider == nil ? "https://github.com/98przem/mist#compatibility" : nil,
                fixLabel: "How to add")
        }
    }

    @ViewBuilder
    private func row(name: String, detail: String, on: Bool, status: String? = nil,
                     fixURL: String? = nil, fixLabel: String = "Install") -> some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(on ? Fog.good.opacity(0.16) : Fog.haze).frame(width: 20, height: 20)
                if on {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundColor(Fog.good)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).foregroundColor(Fog.ink)
                Text(detail).font(.system(size: 11.5)).foregroundColor(Fog.inkFaint)
            }
            Spacer()
            if on, let status {
                Text(status).font(.system(size: 11, design: .monospaced)).foregroundColor(Fog.good)
            } else if let fixURL, let url = URL(string: fixURL) {
                Link(fixLabel, destination: url)
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Fog.accent)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .top) { Divider().overlay(Fog.hairline) }
    }
}

struct UpdatesSettingsView: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mist \(updater.currentVersion)").font(.callout)
                    statusLine.font(.caption).foregroundColor(.secondary)
                }
                Spacer()
                primaryButton
            }
            Toggle("Check for updates automatically on launch", isOn: $updater.autoCheck)
                .font(.caption)
                .toggleStyle(.checkbox)

            if case .available(let version, let notes, _) = updater.state, !notes.isEmpty {
                Divider()
                Text("What's new in \(version)").font(.caption.weight(.semibold))
                ScrollView {
                    Text(notes)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)
            }
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch updater.state {
        case .idle: Text("Up to date, as far as we last checked.")
        case .checking: Text("Checking…")
        case .upToDate: Text("You're on the latest version.")
        case .available(let v, _, _): Text("Version \(v) is available.").foregroundColor(Fog.accent)
        case .downloading(let f): Text("Downloading… \(Int(f * 100))%")
        case .readyToRelaunch: Text("Installing — Mist will relaunch.")
        case .failed(let m): Text(m).foregroundColor(.orange)
        }
    }

    @ViewBuilder private var primaryButton: some View {
        switch updater.state {
        case .checking:
            ProgressView().controlSize(.small)
        case .downloading(let f):
            ProgressView(value: f).frame(width: 120)
        case .available(let version, _, let zipURL):
            Button("Install & Relaunch") {
                updater.downloadAndInstall(version: version, zipURL: zipURL)
            }
            .buttonStyle(.borderedProminent).tint(Fog.accent)
        case .readyToRelaunch:
            ProgressView().controlSize(.small)
        default:
            Button("Check for Updates") { Task { await updater.check(userInitiated: true) } }
                .buttonStyle(.bordered)
        }
    }
}

let sidebarNavOrder = ["all", "steam", "epic", "custom", "epicfree", "store", "settings"]

// MARK: - Gamepad navigation
//
// Basic controller support: D-pad/left stick moves a linear focus cursor
// through whatever grid is on screen (not full 2-D spatial navigation — that
// needs column-count awareness the adaptive grid doesn't expose), shoulder
// buttons switch sidebar sections, A activates, B backs out of the game
// detail sheet. Debounced so a held direction doesn't fire every poll tick.
final class GamepadNavigator: ObservableObject {
    @Published private(set) var isConnected = false

    // (dx, dy): each -1/0/1. Left/right move a column, up/down move a row — the
    // consumer decides what "a row" means (it knows the actual column count).
    var onMove: ((Int, Int) -> Void)?
    var onActivate: (() -> Void)?
    var onBack: (() -> Void)?
    var onCycleSection: ((Int) -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var lastFired: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 0.22

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            self?.configure(controller)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in
            self?.isConnected = GCController.controllers().contains { $0.extendedGamepad != nil }
        })
        GCController.controllers().forEach(configure)
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        isConnected = true
        gamepad.valueChangedHandler = { [weak self] pad, _ in
            guard let self else { return }
            let dpadX = pad.dpad.xAxis.value, dpadY = pad.dpad.yAxis.value
            let stickX = pad.leftThumbstick.xAxis.value, stickY = pad.leftThumbstick.yAxis.value
            self.handleDirectional(x: dpadX != 0 ? dpadX : stickX, y: dpadY != 0 ? dpadY : stickY)
            if pad.buttonA.isPressed { self.fire("A") { self.onActivate?() } }
            if pad.buttonB.isPressed { self.fire("B") { self.onBack?() } }
            if pad.leftShoulder.isPressed { self.fire("L1") { self.onCycleSection?(-1) } }
            if pad.rightShoulder.isPressed { self.fire("R1") { self.onCycleSection?(1) } }
        }
    }

    private func handleDirectional(x: Float, y: Float) {
        let threshold: Float = 0.5
        if abs(x) > abs(y) {
            if x > threshold { fire("right") { self.onMove?(1, 0) } }
            else if x < -threshold { fire("left") { self.onMove?(-1, 0) } }
        } else {
            // GCController convention: +y is up, -y is down.
            if y > threshold { fire("up") { self.onMove?(0, -1) } }
            else if y < -threshold { fire("down") { self.onMove?(0, 1) } }
        }
    }

    private func fire(_ key: String, _ action: () -> Void) {
        let now = Date()
        if let last = lastFired[key], now.timeIntervalSince(last) < debounceInterval { return }
        lastFired[key] = now
        action()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

// MARK: - In-app updater
//
// Checks GitHub Releases for a newer version and, on request, downloads the
// release's Mist.zip and swaps the running .app in place. Mist is ad-hoc signed
// and unsandboxed, so a small detached shell helper (waits for us to quit, moves
// the new bundle over the old, relaunches) is enough — no Sparkle, no privileged
// helper. Auto-check is opt-in and stored in UserDefaults.
// Delegate-based download so progress comes straight from the OS (didWriteData
// per chunk) instead of a manual byte-by-byte read loop.
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL!
    private let onProgress: (Double) -> Void
    private var session: URLSession!

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    func download(_ url: URL, to destination: URL) async throws {
        self.destination = destination
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                     didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                     totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                     didFinishDownloadingTo location: URL) {
        // Foundation deletes `location` as soon as this method returns, so the
        // move to our own destination has to happen synchronously, right here.
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String, zipURL: URL)
        case downloading(Double)
        case readyToRelaunch
        case failed(String)
    }

    @Published var state: State = .idle
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "autoCheckUpdates") }
    }

    static let repo = "98przem/mist"
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    init() {
        // Default on: most users want updates. Stored so they can opt out.
        if UserDefaults.standard.object(forKey: "autoCheckUpdates") == nil {
            UserDefaults.standard.set(true, forKey: "autoCheckUpdates")
        }
        autoCheck = UserDefaults.standard.bool(forKey: "autoCheckUpdates")
    }

    private struct Release: Decodable {
        let tag_name: String
        let body: String?
        let assets: [Asset]
        struct Asset: Decodable { let name: String; let browser_download_url: String }
    }

    func checkOnLaunchIfEnabled() {
        guard autoCheck else { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = state { return }
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw NSError(domain: "update", code: (resp as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
            guard Self.isNewer(latest, than: currentVersion),
                  let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let zipURL = URL(string: zip.browser_download_url) else {
                state = .upToDate
                return
            }
            state = .available(version: latest, notes: release.body ?? "", zipURL: zipURL)
        } catch {
            // A silent auto-check that fails shouldn't nag; only a manual check reports.
            state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    // Numeric, dot-separated comparison (e.g. 0.10.0 > 0.9.0). Non-numeric parts
    // are treated as 0 so a malformed tag never claims to be newer.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    func downloadAndInstall(version: String, zipURL: URL) {
        state = .downloading(0)
        Task {
            do {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("mist-update-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zipDest = tmp.appendingPathComponent("Mist.zip")

                // A real URLSessionDownloadTask, not a hand-rolled byte loop: the
                // previous version iterated `URLSession.bytes(from:)` one UInt8 at a
                // time (`for try await byte in bytes`), which suspends and resumes
                // Swift concurrency once per byte — for a multi-tens-of-MB zip that's
                // tens of millions of suspensions, slow enough to look hung and to
                // blow past any reasonable timeout. The download task hands buffering
                // to the OS and only calls back per chunk.
                let downloader = UpdateDownloader { [weak self] progress in
                    Task { @MainActor in self?.state = .downloading(progress) }
                }
                try await downloader.download(zipURL, to: zipDest)

                // Unzip and locate the new Mist.app.
                try Self.run("/usr/bin/ditto", ["-xk", zipDest.path, tmp.path])
                let newApp = tmp.appendingPathComponent("Mist.app")
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw NSError(domain: "update", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "Downloaded archive had no Mist.app"])
                }

                let currentApp = Bundle.main.bundleURL
                try Self.spawnSwapAndRelaunch(newApp: newApp, currentApp: currentApp)
                await MainActor.run { self.state = .readyToRelaunch }
                // Give the helper a beat to start waiting on our PID, then quit.
                try? await Task.sleep(nanoseconds: 500_000_000)
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                await MainActor.run { self.state = .failed("Update failed: \(error.localizedDescription)") }
            }
        }
    }

    @discardableResult
    private static func run(_ launch: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(domain: "update", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(launch) exited \(p.terminationStatus)"])
        }
        return p.terminationStatus
    }

    // A detached shell that waits for this process to exit, replaces the old
    // bundle with the new one, and relaunches. Runs via `nohup … &` so it
    // outlives us. We can't overwrite our own running bundle, hence the helper.
    private static func spawnSwapAndRelaunch(newApp: URL, currentApp: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(shq(currentApp.path))
        /bin/mv \(shq(newApp.path)) \(shq(currentApp.path))
        xattr -dr com.apple.quarantine \(shq(currentApp.path)) 2>/dev/null
        /usr/bin/open \(shq(currentApp.path))
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mist-update-\(pid).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \(shq(scriptURL.path)) >/dev/null 2>&1 &"]
        try p.run()
    }

    // Minimal shell single-quote escaping for paths we embed in the helper script.
    private static func shq(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

struct ContentView: View {
    @StateObject private var library: GameLibrary
    @StateObject private var processManager: ProcessManager
    @StateObject private var setup = SetupManager()
    @StateObject private var steamAuth = SteamAuthManager()
    @StateObject private var downloadManager: SteamDownloadManager
    @StateObject private var gamepad = GamepadNavigator()
    @StateObject private var updater = UpdateManager()
    @State private var sidebarSelection: String? = "all"
    @State private var showRunningView = false
    @State private var searchText = ""
    @State private var pendingUninstall: Game?
    @State private var gameForLaunchOptions: Game?
    @State private var gameForWorkshopInstall: Game?
    @State private var gameForDetail: Game?
    @State private var showingAddCustomApp = false
    @State private var relocatingCustomAppID: String?   // non-nil while a "Locate…" file pick is in flight
    // A file was just picked (either adding new or relocating) — opens the naming
    // confirmation sheet. relocatingID nil = adding a new entry.
    @State private var pendingCustomAppPick: (exePath: String, suggestedName: String, relocatingID: String?)?
    @State private var focusedGameIndex = 0
    @State private var libraryFilter: LibraryFilter = .all
    @State private var gridColumns = 1
    @State private var showingDownloadsQueue = false
    // The game that just finished installing — drives a transient "Play" toast,
    // auto-dismissed a few seconds after it appears (see the toast's .onAppear).
    @State private var installToast: Game?
    // Persisted so a user who skips account sign-in during first run isn't shown
    // the onboarding accounts step again on every launch — connecting an account
    // later (e.g. from Settings) also permanently satisfies this via the isLoggedIn
    // checks in the gate itself, this flag only covers the explicit-skip path.
    @State private var onboardingDismissed = UserDefaults.standard.bool(forKey: "onboardingAccountsDismissed")
    // Sections that actually contain a game grid — gamepad shoulder buttons only
    // cycle among these, so they never land on Store/Free Games/Settings and go
    // dead (no focusable grid there).
    private let gridSections = ["all", "steam", "epic"]

    init() {
        let lib = GameLibrary()
        _library = StateObject(wrappedValue: lib)
        _processManager = StateObject(wrappedValue: ProcessManager(library: lib))
        _downloadManager = StateObject(wrappedValue: SteamDownloadManager(steamAppsDir: lib.steamAppsDir))
    }

    private func refreshOwnedSteamGames() {
        guard steamAuth.isLoggedIn else { return }
        // Both fetches go over the relay's client-protocol session (owned games this
        // way so it doesn't depend on a separately-minted Steam Web API token;
        // family-shared to filter out what you already own). Each relay call opens
        // its own CM connection with the SAME refresh token — firing them as two
        // concurrent Tasks made Steam kick the second connection ("A task was
        // canceled"), silently swallowed by the family fetch's best-effort `try?`,
        // which is why Family Shared games would randomly go missing. Run them one
        // after another instead of concurrently.
        Task {
            do {
                let owned: [OwnedGame]
                if let relayOwned = try? await RelayManager.ownedLibrary(), !relayOwned.isEmpty {
                    owned = relayOwned.map { OwnedGame(id: $0.id, name: $0.name, playtimeForever: $0.playtimeForever,
                                                       coverURL: SteamLibraryService.coverURL(forAppID: $0.id),
                                                       lastPlayed: $0.lastPlayed) }
                } else {
                    let token = try await steamAuth.mintAccessToken()
                    owned = try await SteamLibraryService.fetchOwnedGames(accessToken: token, steamID: steamAuth.steamID)
                }
                await MainActor.run {
                    library.applyOwnedSteamGames(owned)
                    library.lastError = nil
                }
            } catch {
                await MainActor.run {
                    library.lastError = "Couldn't fetch your Steam library: \(error.localizedDescription)"
                }
            }
            // Best-effort: most accounts aren't in a Steam Family, so an empty/failed
            // result here just means "no shared games" — never surfaced as an error.
            if let shared = try? await RelayManager.familyLibrary() {
                await MainActor.run { library.applyFamilyLibraryGames(shared) }
            }
        }
    }

    private func handleLaunch(_ game: Game) {
        showRunningView = true
        processManager.launchGame(game)
    }

    private func handleLaunchNoEAC(_ game: Game) {
        showRunningView = true
        processManager.launchGame(game, mode: .noEAC)
    }

    private func handleLaunchGPTK(_ game: Game) {
        showRunningView = true
        processManager.launchGame(game, mode: .gptk)
    }

    private func handleInstall(_ game: Game) {
        if game.source == .epic {
            processManager.epicInstall(appName: game.id)
        } else if game.source == .steam {
            downloadManager.enqueue(appid: game.id, name: game.name,
                                    steamAccountName: steamAuth.accountName,
                                    coverURL: URL(string: SteamLibraryService.coverURL(forAppID: game.id))) {
                library.scan()
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { installToast = game }
            }
        }
    }

    private func handleShowInFinder(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDir)])
    }

    // Maps appid -> its queue entry (base-game downloads only, never a workshop
    // item) so cards/detail pages can show install progress without each one
    // observing the whole download manager.
    var downloadStates: [String: DownloadQueueItem] {
        Dictionary(downloadManager.queue.filter { $0.pubfileID == nil }.map { ($0.appid, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private var downloadBarTitle: String {
        if let active = downloadManager.queue.first(where: { $0.state == .downloading }) {
            return "Installing \(active.name)…"
        } else if downloadManager.queue.contains(where: { if case .failed = $0.state { return true }; return false }) {
            return "A download needs attention"
        } else if downloadManager.queue.contains(where: { $0.state == .paused }) {
            return "Downloads paused"
        }
        return "Preparing…"
    }

    private var downloadBarSubtitle: String {
        let remaining = downloadManager.queue.count
        if let active = downloadManager.queue.first(where: { $0.state == .downloading }) {
            let base = active.statusText.isEmpty ? "" : active.statusText
            return remaining > 1 ? "\(base) · \(remaining) in queue" : base
        }
        return remaining > 1 ? "\(remaining) items in queue" : ""
    }

    var filteredGames: [Game] {
        var games = library.games

        // Filter by source (sidebar)
        switch sidebarSelection {
        case "steam": games = games.filter { $0.source == .steam }
        case "epic": games = games.filter { $0.source == .epic }
        case "custom": games = games.filter { $0.source == .custom }
        default: break
        }

        // Filter by the library chip (All / Installed / Not Installed / Shared)
        switch libraryFilter {
        case .all: break
        case .installed: games = games.filter(\.isInstalled)
        case .notInstalled: games = games.filter { !$0.isInstalled }
        case .shared: games = games.filter(\.isFamilyShared)
        }

        // Filter by search
        if !searchText.isEmpty {
            games = games.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }

        return games
    }

    // filteredGames narrowed to just the sidebar source (no chip/search filter) —
    // whether this is empty is what actually means "your library is empty", as
    // opposed to "this filter/search matched nothing". Conflating the two is what
    // produced the "everything is installed" / "nothing is installed" nonsense
    // when signed out.
    private var sourceGames: [Game] {
        switch sidebarSelection {
        case "steam": return library.games.filter { $0.source == .steam }
        case "epic": return library.games.filter { $0.source == .epic }
        case "custom": return library.games.filter { $0.source == .custom }
        default: return library.games
        }
    }

    private var sourceLabel: String {
        switch sidebarSelection {
        case "steam": return "Steam"
        case "epic": return "Epic"
        case "custom": return "My Apps"
        default: return "your"
        }
    }

    // Only worth prompting sign-in when the relevant account(s) for the current
    // view actually aren't connected — not just whenever the grid is empty. Custom
    // apps have no account at all, so they're never gated on sign-in.
    private var sourceNeedsSignIn: Bool {
        switch sidebarSelection {
        case "steam": return !steamAuth.isLoggedIn
        case "epic": return !processManager.epicLoggedIn
        case "custom": return false
        default: return !steamAuth.isLoggedIn && !processManager.epicLoggedIn
        }
    }

    // Chips to offer for the current source: "Family Shared" only makes sense where
    // Steam games are present (Epic and custom apps have no family sharing).
    private var availableFilters: [LibraryFilter] {
        let hasShared = library.games.contains { $0.isFamilyShared &&
            (sidebarSelection != "epic" && sidebarSelection != "custom") }
        return LibraryFilter.allCases.filter { $0 != .shared || hasShared }
    }

    // The exact order GameGridView renders — computing focus over this (rather
    // than the unsorted filteredGames) is what keeps the gamepad cursor and the
    // visible grid in sync; a mismatch here is what let sorting silently skip or
    // misalign the highlighted card.
    private var displayedGames: [Game] { GameGridView.ordered(filteredGames) }

    // Wires the connected controller's D-pad/stick, A/B, and shoulder buttons to
    // grid focus, activation, sheet dismissal, and sidebar-section switching. See
    // GamepadNavigator for why this is linear-per-row focus, not full spatial nav.
    private func configureGamepad() {
        gamepad.onMove = { dx, dy in
            let games = displayedGames
            guard !games.isEmpty else { return }
            // Left/right move one card; up/down move a full row (gridColumns is
            // measured from the grid's actual on-screen width, see onGridWidthChange).
            let step = dx != 0 ? dx : dy * max(1, gridColumns)
            focusedGameIndex = max(0, min(games.count - 1, focusedGameIndex + step))
        }
        gamepad.onActivate = {
            let games = displayedGames
            guard gameForDetail == nil, games.indices.contains(focusedGameIndex) else { return }
            gameForDetail = games[focusedGameIndex]
        }
        gamepad.onBack = {
            if gameForDetail != nil { gameForDetail = nil }
            else if showRunningView { showRunningView = false }
        }
        gamepad.onCycleSection = { delta in
            guard let current = sidebarSelection, let idx = gridSections.firstIndex(of: current) else {
                sidebarSelection = gridSections.first
                focusedGameIndex = 0
                return
            }
            let next = (idx + delta + gridSections.count) % gridSections.count
            sidebarSelection = gridSections[next]
            focusedGameIndex = 0
        }
    }

    // Split out from `body` below: this is the pre-existing view tree (setup gate,
    // NavigationSplitView, running-state overlay) that already compiled fine on its
    // own. Adding the library-mutation modifiers directly onto this chain pushed
    // SwiftUI's type-checker over its time limit, so `body` now applies them on top
    // of this separately-type-checked piece instead.
    private var mainContent: some View {
        Group {
            if setup.isWorking || !setup.isComplete
                || (!onboardingDismissed && !steamAuth.isLoggedIn && !processManager.epicLoggedIn) {
                SetupView(setup: setup, steamAuth: steamAuth, processManager: processManager) {
                    onboardingDismissed = true
                    UserDefaults.standard.set(true, forKey: "onboardingAccountsDismissed")
                }
            } else {
                NavigationSplitView {
                    SidebarView(
                        selection: $sidebarSelection,
                        steamCount: library.games.filter { $0.source == .steam }.count,
                        epicCount: library.games.filter { $0.source == .epic }.count,
                        customCount: library.games.filter { $0.source == .custom }.count,
                        epicLoggedIn: processManager.epicLoggedIn,
                        steamLoggedIn: steamAuth.isLoggedIn,
                        downloadQueueCount: downloadManager.queue.count,
                        activeDownloadProgress: downloadManager.queue.first(where: { $0.state == .downloading })?.progress,
                        onOpenDownloads: { showingDownloadsQueue = true }
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                } detail: {
                    ZStack {
                        if showRunningView {
                            RunningGameView(processManager: processManager, onDismiss: {
                                showRunningView = false
                            })
                        } else if sidebarSelection == "store" {
                            SteamStoreBrowseView(ownedAppIDs: Set(library.games.filter { $0.source == .steam }.map(\.id)))
                        } else if sidebarSelection == "epicfree" {
                            EpicFreeGamesView()
                        } else if sidebarSelection == "settings" {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Settings")
                                            .font(.system(size: 26, weight: .bold))
                                        Text("Accounts, storage, and dependencies")
                                            .font(.callout)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.bottom, 4)

                                    SettingsCard(title: "Steam Account", systemImage: "cloud.fill", tint: .blue) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            SteamLoginView(auth: steamAuth)
                                            if let err = library.lastError {
                                                Label(err, systemImage: "exclamationmark.triangle.fill")
                                                    .font(.caption)
                                                    .foregroundColor(.red)
                                            }
                                            if steamAuth.isLoggedIn {
                                                Divider()
                                                Label("Your library, downloads, and achievements all use this one sign-in — no separate keys or logins needed.",
                                                      systemImage: "checkmark.seal")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }

                                    SettingsCard(title: "Epic Account", systemImage: "bolt.fill", tint: .purple) {
                                        EpicStoreView(processManager: processManager)
                                    }

                                    SettingsCard(title: "Graphics", systemImage: "cpu", tint: Fog.accent) {
                                        GraphicsSettingsView()
                                    }

                                    SettingsCard(title: "Updates", systemImage: "arrow.triangle.2.circlepath", tint: .green) {
                                        UpdatesSettingsView(updater: updater)
                                    }

                                    SettingsCard(title: "Storage & Engine", systemImage: "internaldrive.fill", tint: .gray) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            SettingsInfoRow(label: "Wine", value: library.wineDir.path)
                                            SettingsInfoRow(label: "Prefix", value: library.supportDir.path)
                                            Divider()
                                            HStack {
                                                Image(systemName: DepotDownloaderManager.isInstalled
                                                      ? "checkmark.circle.fill" : "circle.dashed")
                                                    .foregroundColor(DepotDownloaderManager.isInstalled ? .green : .secondary)
                                                VStack(alignment: .leading, spacing: 2) {
                                                    Text("DepotDownloader")
                                                        .font(.callout)
                                                    if !DepotDownloaderManager.isInstalled {
                                                        Text("Downloaded automatically the first time you install a Steam game.")
                                                            .font(.caption)
                                                            .foregroundColor(.secondary)
                                                    }
                                                }
                                                Spacer()
                                            }
                                        }
                                    }

                                    HStack {
                                        Button {
                                            library.scan()
                                        } label: {
                                            Label("Rescan Games", systemImage: "arrow.clockwise")
                                        }
                                        .buttonStyle(.bordered)
                                        Spacer()
                                    }
                                }
                                .padding(20)
                                .frame(maxWidth: 700, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            GameGridView(
                                games: filteredGames,
                                onLaunch: handleLaunch,
                                onLaunchNoEAC: handleLaunchNoEAC,
                                onLaunchGPTK: handleLaunchGPTK,
                                onInstall: handleInstall,
                                onUninstall: { game in pendingUninstall = game },
                                onShowInFinder: handleShowInFinder,
                                onLaunchOptions: { game in gameForLaunchOptions = game },
                                onInstallWorkshopItem: { game in gameForWorkshopInstall = game },
                                onSelect: { game in gameForDetail = game },
                                onLocate: { game in relocatingCustomAppID = game.id },
                                focusedGameID: (gamepad.isConnected && displayedGames.indices.contains(focusedGameIndex))
                                    ? displayedGames[focusedGameIndex].id : nil,
                                filter: $libraryFilter,
                                availableFilters: availableFilters,
                                sourceHasGames: !sourceGames.isEmpty,
                                needsSignIn: sourceNeedsSignIn,
                                sourceLabel: sourceLabel,
                                isCustomSource: sidebarSelection == "custom",
                                onAddCustomApp: { showingAddCustomApp = true },
                                downloadStates: downloadStates,
                                onPauseDownload: { id in downloadManager.pause(id: id) },
                                onResumeDownload: { id in downloadManager.resume(id: id) },
                                onCancelDownload: { id in downloadManager.cancel(id: id) },
                                onRetryDownload: { id in downloadManager.retry(id: id) },
                                onGridWidthChange: { width in
                                    // Matches SwiftUI's .adaptive(minimum:maximum:) column
                                    // count: as many 160pt (+14pt spacing) columns as fit.
                                    gridColumns = max(1, Int((width + 14) / (160 + 14)))
                                }
                            )
                        }
                    }
                    .searchable(text: $searchText, prompt: "Search games")
                    .safeAreaInset(edge: .bottom) {
                        if processManager.epicInstalling {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.small)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Installing...")
                                        .font(.callout.bold())
                                    Text(processManager.epicInstallProgress)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(.bar)
                        } else if !downloadManager.queue.isEmpty {
                            let active = downloadManager.queue.first(where: { $0.state == .downloading })
                            HStack(spacing: 12) {
                                if let p = active?.progress {
                                    ProgressView(value: p).progressViewStyle(.circular).controlSize(.small)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(downloadBarTitle)
                                        .font(.callout.bold())
                                    Text(downloadBarSubtitle)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("View Queue") { showingDownloadsQueue = true }
                                    .buttonStyle(.bordered)
                            }
                            .padding(12)
                            .background(.bar)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onAppear {
            setup.refresh()
            library.scan()
            processManager.checkEpicLogin()
            refreshOwnedSteamGames()
        }
        .onChange(of: setup.isComplete) { complete in
            if complete { library.scan() }
        }
        .onChange(of: steamAuth.isLoggedIn) { _ in
            refreshOwnedSteamGames()
        }
    }

    var body: some View {
        mainContent
        // Uninstall/Remove confirmation + Add App/Locate… pulled into their own
        // ViewModifier — folding this much Binding(get:set:)/switch logic directly
        // into this already-large body pushed SwiftUI's type-checker over its time
        // limit ("unable to type-check in reasonable time").
        .modifier(LibraryMutationModifiers(
            pendingUninstall: $pendingUninstall,
            showingAddCustomApp: $showingAddCustomApp,
            relocatingCustomAppID: $relocatingCustomAppID,
            pendingCustomAppPick: $pendingCustomAppPick,
            onUninstallSteam: { library.uninstallSteamGame($0) },
            onUninstallEpic: { processManager.epicUninstall(appName: $0.id) },
            onRemoveCustom: { library.removeCustomApp(id: $0.id) },
            onAddCustomApp: { name, path in library.addCustomApp(name: name, exePath: path) },
            onRelocateCustomApp: { id, path in library.relocateCustomApp(id: id, newExePath: path) }
        ))
        .modifier(DownloadsUIModifiers(
            downloadManager: downloadManager,
            showingDownloadsQueue: $showingDownloadsQueue,
            installToast: $installToast,
            onPlay: { game in handleLaunch(game) }
        ))
        .sheet(item: $gameForLaunchOptions) { game in
            LaunchOptionsView(game: game, onShowInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDir)])
            })
        }
        .sheet(item: $gameForWorkshopInstall) { game in
            WorkshopInstallView(game: game) { pubfileID in
                downloadManager.enqueueWorkshopItem(appid: game.id, pubfileID: pubfileID, gameName: game.name,
                                                    steamAccountName: steamAuth.accountName) {
                    library.scan()
                }
            }
        }
        .sheet(item: $gameForDetail) { game in
            GameDetailView(
                game: game, steamAuth: steamAuth, steamAppsDir: library.steamAppsDir,
                onLaunch: { handleLaunch(game) },
                onLaunchNoEAC: { handleLaunchNoEAC(game) },
                onLaunchGPTK: { handleLaunchGPTK(game) },
                onInstall: { handleInstall(game) },
                onUninstall: { pendingUninstall = game },
                onShowInFinder: { handleShowInFinder(game) },
                onLaunchOptions: { gameForLaunchOptions = game },
                onInstallWorkshopItem: { gameForWorkshopInstall = game },
                onInstallWorkshopID: { pubfileID in
                    downloadManager.enqueueWorkshopItem(appid: game.id, pubfileID: pubfileID,
                                                        gameName: game.name,
                                                        steamAccountName: steamAuth.accountName) {
                        library.scan()
                    }
                },
                onOpenSettings: {
                    gameForDetail = nil
                    sidebarSelection = "settings"
                },
                onLocate: { relocatingCustomAppID = game.id },
                downloadItem: downloadStates[game.id],
                onPauseDownload: { downloadManager.pause(id: game.id) },
                onResumeDownload: { downloadManager.resume(id: game.id) },
                onCancelDownload: { downloadManager.cancel(id: game.id) },
                onRetryDownload: { downloadManager.retry(id: game.id) }
            )
        }
        .focusedSceneValue(\.rescanAction, { library.scan() })
        .focusedSceneValue(\.showSettingsAction, { sidebarSelection = "settings" })
        .focusedSceneValue(\.checkUpdatesAction, {
            sidebarSelection = "settings"
            Task { await updater.check(userInitiated: true) }
        })
        .onAppear {
            configureGamepad()
            updater.checkOnLaunchIfEnabled()
        }
    }
}

// MARK: - Menu Bar Commands
//
// ContentView owns all the actual state (library, sidebarSelection, etc.) — these
// focused values let the app-level .commands block trigger actions on it without
// restructuring who owns what, via .focusedSceneValue in ContentView's body.

private struct RescanActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct ShowSettingsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
private struct CheckUpdatesActionKey: FocusedValueKey {
    typealias Value = () -> Void
}
extension FocusedValues {
    var rescanAction: (() -> Void)? {
        get { self[RescanActionKey.self] }
        set { self[RescanActionKey.self] = newValue }
    }
    var showSettingsAction: (() -> Void)? {
        get { self[ShowSettingsActionKey.self] }
        set { self[ShowSettingsActionKey.self] = newValue }
    }
    var checkUpdatesAction: (() -> Void)? {
        get { self[CheckUpdatesActionKey.self] }
        set { self[CheckUpdatesActionKey.self] = newValue }
    }
}

// MARK: - App Entry Point

@main
struct MistApp: App {
    @FocusedValue(\.rescanAction) private var rescanAction
    @FocusedValue(\.showSettingsAction) private var showSettingsAction
    @FocusedValue(\.checkUpdatesAction) private var checkUpdatesAction

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Library") {
                Button("Rescan Games") { rescanAction?() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(rescanAction == nil)
                Divider()
                Button("Settings…") { showSettingsAction?() }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(showSettingsAction == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { checkUpdatesAction?() }
                    .disabled(checkUpdatesAction == nil)
            }
            CommandGroup(replacing: .help) {
                Link("Mist on GitHub", destination: URL(string: "https://github.com/98przem/mist")!)
            }
        }
    }
}

import SwiftUI
import Cocoa
import Foundation
import CryptoKit
import CoreImage.CIFilterBuiltins

// MARK: - Data Models

enum GameSource: String, Codable {
    case steam = "Steam"
    case epic = "Epic"
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

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(source)
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source
    }
}

// MARK: - Mist Environment (native Wine paths + env — no shell scripts)

enum MistEnv {
    static let supportDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Mist")
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

            DispatchQueue.main.async {
                self.scannedGames = found
                self.recomputeGames()
                self.isScanning = false
            }
        }
    }

    private func recomputeGames() {
        let existingIDs = Set(scannedGames.filter { $0.source == .steam }.map(\.id))
        let placeholders = ownedSteamGames.filter { !existingIDs.contains($0.id) }.map { og in
            Game(id: og.id, name: og.name, source: .steam, installDir: "",
                sizeBytes: 0, isInstalled: false, imageURL: og.coverURL)
        }
        games = (scannedGames + placeholders).sorted { $0.name.lowercased() < $1.name.lowercased() }
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
    let short_description: String?
    let genres: [Genre]?
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
    static var binaryPath: URL { MistEnv.supportDir.appendingPathComponent("tools/AchievementRelay") }
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

    // Unlock one achievement on the real Steam profile. Returns true on success.
    @discardableResult
    static func unlock(appid: String, apiname: String) async throws -> Bool {
        let data = try await run([appid, "--unlock", apiname])
        struct R: Decodable { let ok: Bool? }
        return (try? JSONDecoder().decode(R.self, from: data))?.ok ?? false
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
        MistEnv.supportDir.appendingPathComponent("tools/DepotDownloader")
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
    static func installedGames(steamAppsDir: URL) -> [Game] {
        load(steamAppsDir: steamAppsDir).map {
            Game(id: $0.appid, name: $0.name, source: .steam, installDir: $0.installDir,
                sizeBytes: $0.sizeBytes, isInstalled: FileManager.default.fileExists(atPath: $0.installDir),
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

final class SteamDownloadManager: ObservableObject {
    @Published var isDownloading = false
    @Published var downloadingAppID: String?
    @Published var downloadingName: String?
    @Published var downloadStatusText = ""
    @Published var downloadProgress: Double?
    // This DepotDownloader version never prints a plain QR URL line — only the
    // terminal ASCII-art rendering — so downloadQRURL stays unused for now but is
    // kept in case a future version adds one (SteamQRCodeView would generate a
    // clean image from it directly, no rasterization needed).
    @Published var downloadQRURL: String?
    // Rasterized from the raw terminal ASCII-art QR — see renderTerminalQR(lines:).
    // Deliberately NOT rendered as text: SwiftUI's monospace font can't guarantee
    // perfectly square character cells, and the block pattern's leading whitespace
    // varies per row (part of the encoded data), so naive text display corrupts the
    // grid alignment enough that it doesn't scan at all.
    @Published var downloadQRImage: NSImage?
    @Published var downloadError: String?

    private var isCapturingQRArt = false
    private var qrArtBuffer: [String] = []

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

    private var process: Process?
    private let steamAppsDir: URL

    // DepotDownloader caches its own Steam session (separate from Mist's native
    // login) in an isolated-storage account.config file after a successful -qr
    // scan, and reuses it automatically when invoked with -username instead of
    // -qr — confirmed by finding that file still present and recent after a real
    // install. Once we've seen ONE successful run for an account, later installs
    // try -username first so the user isn't asked to scan again every time.
    private static let reusableAccountsKey = "DepotDownloaderReusableAccounts"
    private var reuseWatchdog: Timer?
    private var sawMeaningfulOutputThisRun = false

    private static func canReuseSession(for account: String) -> Bool {
        let accounts = UserDefaults.standard.stringArray(forKey: reusableAccountsKey) ?? []
        return accounts.contains(account.lowercased())
    }

    private static func markSessionReusable(for account: String) {
        var accounts = Set(UserDefaults.standard.stringArray(forKey: reusableAccountsKey) ?? [])
        accounts.insert(account.lowercased())
        UserDefaults.standard.set(Array(accounts), forKey: reusableAccountsKey)
    }

    private static func forgetReusableSession(for account: String) {
        var accounts = Set(UserDefaults.standard.stringArray(forKey: reusableAccountsKey) ?? [])
        accounts.remove(account.lowercased())
        UserDefaults.standard.set(Array(accounts), forKey: reusableAccountsKey)
    }

    init(steamAppsDir: URL) {
        self.steamAppsDir = steamAppsDir
    }

    func install(appid: String, name: String, steamAccountName: String, onComplete: @escaping () -> Void) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingAppID = appid
        downloadingName = name
        downloadError = nil
        downloadQRURL = nil
        downloadQRImage = nil
        downloadProgress = nil
        downloadStatusText = "Preparing…"
        connectionRetryCount = 0

        Task {
            do {
                try await DepotDownloaderManager.ensureInstalled { [weak self] status in
                    Task { @MainActor in self?.downloadStatusText = status }
                }
                await MainActor.run {
                    self.runDepotDownloader(appid: appid, name: name, steamAccountName: steamAccountName,
                                            onComplete: onComplete)
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadingAppID = nil
                    self.downloadingName = nil
                    self.downloadError = error.localizedDescription
                }
            }
        }
    }

    // Workshop items download through the exact same DepotDownloader session
    // (QR/reuse/watchdog logic all shared via runDepotDownloader below) — the only
    // difference is the "-pubfile" flag instead of a plain app download, and a
    // workshop-shaped destination folder instead of steamapps/common.
    //
    // Caveat: this places files where Steam's own client would (steamapps/workshop/
    // content/<appid>/<pubfileid>/), but whether a given game actually reads mods
    // from there is entirely up to that game — many query Steam's ISteamUGC API at
    // runtime instead of scanning the folder directly, and Mist doesn't (and can't,
    // without running a real Steam client) implement that API. Works for games that
    // load workshop content straight off disk; does nothing for ones that don't.
    func installWorkshopItem(appid: String, pubfileID: String, gameName: String,
                              steamAccountName: String, onComplete: @escaping () -> Void) {
        guard !isDownloading else { return }
        isDownloading = true
        downloadingAppID = appid
        downloadingName = "\(gameName) — Workshop Item \(pubfileID)"
        downloadError = nil
        downloadQRURL = nil
        downloadQRImage = nil
        downloadProgress = nil
        downloadStatusText = "Preparing…"
        connectionRetryCount = 0

        Task {
            do {
                try await DepotDownloaderManager.ensureInstalled { [weak self] status in
                    Task { @MainActor in self?.downloadStatusText = status }
                }
                await MainActor.run {
                    self.runDepotDownloader(appid: appid, name: downloadingName ?? gameName,
                                            steamAccountName: steamAccountName, pubfileID: pubfileID,
                                            onComplete: onComplete)
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadingAppID = nil
                    self.downloadingName = nil
                    self.downloadError = error.localizedDescription
                }
            }
        }
    }

    private func runDepotDownloader(appid: String, name: String, steamAccountName: String,
                                    pubfileID: String? = nil,
                                    onComplete: @escaping () -> Void) {
        let tool = DepotDownloaderManager.installPath.path
        downloadStatusText = "Signing in with your Steam login…"

        let installDir: URL
        if let pubfileID {
            installDir = steamAppsDir.appendingPathComponent("workshop/content/\(appid)/\(pubfileID)")
        } else {
            let safeName = name.replacingOccurrences(of: "/", with: "-")
            installDir = steamAppsDir.appendingPathComponent("common").appendingPathComponent(safeName)
        }
        try? FileManager.default.createDirectory(at: installDir, withIntermediateDirectories: true)

        // Single-login: our patched DepotDownloader seeds Mist's own persistent
        // session token (passed via MIST_REFRESH_TOKEN) into its login store, so
        // "-username <account> -remember-password" logs in non-interactively with
        // Mist's one QR sign-in — no separate DepotDownloader QR scan, ever.
        var args = ["-app", appid, "-os", "windows", "-dir", installDir.path,
                    "-username", steamAccountName, "-remember-password"]
        if let pubfileID { args += ["-pubfile", pubfileID] }

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
        recentOutputLines = []

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
                    if let regex = progressRegex,
                       let m = regex.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                       let r = Range(m.range(at: 1), in: l), let pct = Double(l[r]) {
                        self.downloadProgress = pct / 100
                        self.downloadStatusText = "Downloading \(name)…"
                    } else {
                        self.downloadStatusText = l
                    }
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            outPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                if p.terminationStatus == 0 {
                    self.isDownloading = false
                    self.downloadingAppID = nil
                    self.downloadingName = nil
                    self.downloadProgress = nil
                    self.connectionRetryCount = 0
                    self.downloadStatusText = "Done!"
                    if pubfileID == nil {
                        let size = Self.directorySize(installDir)
                        MistManifest.add(MistInstalledGame(appid: appid, name: name, installDir: installDir.path, sizeBytes: size),
                                         steamAppsDir: self.steamAppsDir)
                    }
                    onComplete()
                    return
                }

                let looksLikeConnectionHiccup = Self.connectionFailureMarkers.contains { marker in
                    self.recentOutputLines.contains { $0.contains(marker) }
                }
                if looksLikeConnectionHiccup && self.connectionRetryCount < self.maxConnectionRetries {
                    self.connectionRetryCount += 1
                    self.downloadStatusText = "Steam connection hiccup — retrying (\(self.connectionRetryCount)/\(self.maxConnectionRetries))…"
                    self.downloadProgress = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.runDepotDownloader(appid: appid, name: name, steamAccountName: steamAccountName,
                                                pubfileID: pubfileID, onComplete: onComplete)
                    }
                } else {
                    self.isDownloading = false
                    self.downloadingAppID = nil
                    self.downloadingName = nil
                    self.downloadProgress = nil
                    self.connectionRetryCount = 0
                    let tail = self.recentOutputLines.suffix(6).joined(separator: "\n")
                    self.downloadError = "Download failed (exit \(p.terminationStatus)).\n\(tail)"
                }
            }
        }

        do {
            try proc.run()
            process = proc
        } catch {
            isDownloading = false
            downloadingAppID = nil
            downloadingName = nil
            downloadError = "Couldn't start DepotDownloader: \(error.localizedDescription)"
        }
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

    func cancel() {
        process?.terminate()
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in en {
            total += Int64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    // DepotDownloader's terminal QR uses 2 characters per module (a dark module is
    // "██", a light one is two spaces) and one line per module row — confirmed by
    // counting a finder-pattern corner (14 "█" characters = 7 modules, matching the
    // standard QR finder pattern size exactly). Rasterizing directly from the raw
    // character grid guarantees square modules and exact alignment, unlike
    // rendering the text itself.
    private static func renderTerminalQR(lines: [String], moduleSize: CGFloat = 8) -> NSImage? {
        let charLines = lines.map(Array.init)
        let maxWidth = charLines.map(\.count).max() ?? 0
        guard maxWidth >= 4, charLines.count >= 4 else { return nil }

        let moduleCols = maxWidth / 2
        let moduleRows = charLines.count
        let width = CGFloat(moduleCols) * moduleSize
        let height = CGFloat(moduleRows) * moduleSize
        guard width > 0, height > 0 else { return nil }

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSColor.black.setFill()
        for (row, chars) in charLines.enumerated() {
            for col in 0..<moduleCols {
                let i = col * 2
                let c1 = i < chars.count ? chars[i] : " "
                let c2 = i + 1 < chars.count ? chars[i + 1] : " "
                guard c1 != " " || c2 != " " else { continue }
                let x = CGFloat(col) * moduleSize
                let y = height - CGFloat(row + 1) * moduleSize  // NSImage origin is bottom-left
                NSRect(x: x, y: y, width: moduleSize, height: moduleSize).fill()
            }
        }
        image.unlockFocus()
        return image
    }
}

// MARK: - Wine/Game Process Manager

class ProcessManager: ObservableObject {
    @Published var isRunning = false
    @Published var currentGame: Game?
    @Published var outputLog: String = ""

    private var process: Process?
    private var dialogKillerTimer: Timer?
    private let library: GameLibrary

    init(library: GameLibrary) {
        self.library = library
    }

    private let gptkWinePath =
        "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"

    enum LaunchMode: String {
        case normal = "Normal"
        case noEAC = "No Anti-Cheat (Offline)"
        case gptk = "GPTK (Offline)"
    }

    func launchGame(_ game: Game, mode: LaunchMode = .normal) {
        currentGame = game
        outputLog = "Launching \(game.name) [\(mode.rawValue)]...\n"

        switch game.source {
        case .steam:
            // Steam games always run their .exe directly under Wine — Mist never runs
            // the actual Steam client under Wine (login and downloads are both native;
            // see SteamAuthManager / SteamDownloadManager), so "normal" and "no EAC"
            // are the same thing for Steam games.
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
                // pointing it at GPTK/D3DMetal when installed (reliable for D3D12).
                let useGPTK = FileManager.default.fileExists(atPath: gptkWinePath)
                let wineBin = useGPTK ? gptkWinePath : MistEnv.wineBinary.path
                var env: [String: String]
                if useGPTK {
                    env = ProcessInfo.processInfo.environment
                    env["WINEPREFIX"] = MistEnv.winePrefix.path
                    env["WINEARCH"] = "win64"
                    if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
                    env["WINEMSYNC"] = "1"
                    env["WINEESYNC"] = "1"
                    // Force builtin DirectX DLLs so D3DMetal handles rendering
                    env["WINEDLLOVERRIDES"] = "d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
                    env["PATH"] = "\((gptkWinePath as NSString).deletingLastPathComponent):/usr/bin:/bin"
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
        guard FileManager.default.fileExists(atPath: game.installDir),
              let exe = findMainExe(in: game.installDir) else {
            outputLog += "ERROR: couldn't find the game's executable in \(game.installDir)\n"
            return
        }
        outputLog += "Exe: \(exe)\n\n"
        var env = MistEnv.baseEnvironment()
        env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,d3d12,d3d12core=n,b"
        env["EOS_USE_ANTICHEATCLIENTNULL"] = "1"
        env["DOTNET_EnableWriteXorExecute"] = "0"

        MistEnv.killWineserver()

        let args = [exe] + GameSettingsStore.tokenize(GameSettingsStore.customArgs(for: game.id))
        runProcess(path: MistEnv.wineBinary.path, arguments: args, env: env,
                   cwd: URL(fileURLWithPath: exe).deletingLastPathComponent())
        startDialogKiller()
    }

    // Launch via Apple's Game Porting Toolkit (D3DMetal) in a dedicated prefix, so
    // GPTK's Wine never reconfigures the bundled CX prefix. The Steam/Epic libraries
    // are symlinked in, keeping the same C:\ paths without re-downloading games.
    private func launchGameGPTK(_ game: Game) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: gptkWinePath) else {
            outputLog += "ERROR: Game Porting Toolkit is not installed.\n"
                + "Install it with: brew install --cask gcenx/wine/game-porting-toolkit\n"
            return
        }
        let gptkBin = (gptkWinePath as NSString).deletingLastPathComponent
        let gptkPrefix = URL(fileURLWithPath: MistEnv.winePrefix.path + "-gptk")

        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = gptkPrefix.path
        env["WINEARCH"] = "win64"
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
        env["WINEMSYNC"] = "1"
        env["WINEESYNC"] = "1"
        env["WINEDLLOVERRIDES"] = "d3d9,d3d10,d3d10core,d3d11,d3d12,d3d12core,dxgi=b"
        env["EOS_USE_ANTICHEATCLIENTNULL"] = "1"
        env["PATH"] = "\(gptkBin):/usr/bin:/bin"

        if !fm.fileExists(atPath: gptkPrefix.appendingPathComponent("system.reg").path) {
            outputLog += "Setting up dedicated GPTK prefix (one-time)…\n"
            try? fm.createDirectory(at: gptkPrefix, withIntermediateDirectories: true)
            MistEnv.run(URL(fileURLWithPath: gptkWinePath), ["wineboot", "--init"], env: env)
            MistEnv.run(URL(fileURLWithPath: "\(gptkBin)/wineserver"), ["-w"], env: env)
        }
        let sharedC = MistEnv.winePrefix.appendingPathComponent("drive_c")
        let gptkC = gptkPrefix.appendingPathComponent("drive_c")
        let steamSrc = sharedC.appendingPathComponent("Program Files (x86)/Steam")
        if fm.fileExists(atPath: steamSrc.path) {
            let pfDir = gptkC.appendingPathComponent("Program Files (x86)")
            try? fm.createDirectory(at: pfDir, withIntermediateDirectories: true)
            let link = pfDir.appendingPathComponent("Steam")
            if !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(at: link, withDestinationURL: steamSrc)
            }
        }
        let epicSrc = sharedC.appendingPathComponent("Epic Games")
        if fm.fileExists(atPath: epicSrc.path) {
            let link = gptkC.appendingPathComponent("Epic Games")
            if !fm.fileExists(atPath: link.path) {
                try? fm.createSymbolicLink(at: link, withDestinationURL: epicSrc)
            }
        }

        guard let exe = findMainExe(in: game.installDir) else {
            outputLog += "ERROR: couldn't find the game's executable in \(game.installDir)\n"
            return
        }
        outputLog += "Exe: \(exe)\nRenderer: D3DMetal (GPTK)\n\n"
        let args = [exe] + GameSettingsStore.tokenize(GameSettingsStore.customArgs(for: game.id))
        runProcess(path: gptkWinePath, arguments: args, env: env,
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
                            waitForWineserverAfter: Bool = false) {
        isRunning = true

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
                    self?.currentGame = nil
                    self?.dialogKillerTimer?.invalidate()
                    self?.dialogKillerTimer = nil
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

    @State private var isHovering = false

    private var gptkInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Game Porting Toolkit.app")
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
            if game.isInstalled {
                HStack(spacing: 6) {
                    primaryActionButton
                    overflowMenu
                }
            } else {
                Button(action: onInstall) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Install")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(game.source == .steam ? .blue : .purple)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
        .shadow(color: .black.opacity(isHovering ? 0.28 : 0.12),
               radius: isHovering ? 16 : 6, y: isHovering ? 8 : 3)
        .scaleEffect(isHovering ? 1.015 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: isHovering)
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
                    Label("Uninstall", systemImage: "trash")
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

                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.55), .black.opacity(0.92)],
                    startPoint: .top, endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(game.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Image(systemName: game.source == .steam ? "cloud.fill" : "bolt.fill")
                            .font(.system(size: 8))
                        Text(game.isInstalled
                             ? (game.sizeBytes > 0 ? game.sizeFormatted : game.source.rawValue)
                             : "Not installed")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.white.opacity(0.7))
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
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var overflowMenu: some View {
        Menu {
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
                Label("Uninstall", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 8)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    @ViewBuilder
    private var primaryActionButton: some View {
        Group {
            if game.antiCheat != .none {
                    // Anti-cheat game: online/multiplayer isn't supported (Mist
                    // doesn't circumvent anti-cheat). The offline launch runs the
                    // game without its anti-cheat — via Apple's Game Porting Toolkit
                    // (D3DMetal) when installed, which is required for D3D12 titles.
                    Menu {
                        Section("Online play not supported (anti-cheat)") {
                            Button(action: onLaunchNoEAC) {
                                Label(
                                    gptkInstalled
                                        ? "Play Offline — No Anti-Cheat (D3DMetal)"
                                        : "Play Offline — No Anti-Cheat",
                                    systemImage: "play.fill"
                                )
                            }
                            if !gptkInstalled {
                                Text("Install Game Porting Toolkit for D3D12 games (e.g. Elden Ring)")
                            }
                        }
                        if game.source == .epic {
                            Divider()
                            Button(action: onLaunch) {
                                Label("Standard Launch (through Epic)", systemImage: "arrowshape.turn.up.right")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderedButton)
                    .tint(game.source == .steam ? .blue : .purple)
                } else if game.source == .steam && gptkInstalled {
                    // Default to GPTK/D3DMetal (reliable for D3D11 + D3D12), direct
                    // launch as the alternative.
                    Menu {
                        Button(action: onLaunchGPTK) {
                            Label("Play (D3DMetal)", systemImage: "play.fill")
                        }
                        Button(action: onLaunchNoEAC) {
                            Label("Play (Direct)", systemImage: "arrowshape.turn.up.right")
                        }
                    } label: {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Play")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderedButton)
                    .tint(.blue)
                } else if game.source == .steam {
                    Button(action: onLaunchNoEAC) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: onLaunch) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
        }
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
        let tint = game.source == .steam ? Color.blue : Color.purple
        return ZStack {
            LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0.1)],
                          startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 34))
                .foregroundColor(tint.opacity(0.8))
        }
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupManager

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: "cloud.fog.fill")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundColor(.white)
            }
            .shadow(color: .purple.opacity(0.3), radius: 16, y: 6)

            VStack(spacing: 6) {
                Text("Welcome to Mist")
                    .font(.system(size: 26, weight: .bold))
                Text("Mist needs to download the Wine engine and its runtime libraries.\nThis is a one-time setup (~200 MB).")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }

            VStack(spacing: 14) {
                Label("Wine engine (CrossOver 24)",
                      systemImage: setup.wineInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(setup.wineInstalled ? .green : .secondary)
                    .font(.callout)

                if setup.isWorking {
                    VStack(spacing: 8) {
                        if let progress = setup.downloadProgress {
                            ProgressView(value: progress)
                                .progressViewStyle(.linear)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }
                        Text(setup.statusText)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(width: 320)
                } else {
                    if let err = setup.errorText {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                    }
                    Button(setup.errorText == nil ? "Download & Install" : "Try Again") {
                        setup.runFullSetup()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .controlSize(.large)
                }
            }
            .padding(20)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
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
                    .foregroundColor(.primary)
                Spacer(minLength: 4)
                if needsAttention {
                    Circle()
                        .fill(.orange)
                        .frame(width: 6, height: 6)
                }
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.16)
                          : (isHovering ? Color.primary.opacity(0.05) : .clear))
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
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 2)
    }
}

struct SidebarView: View {
    @Binding var selection: String?
    let steamCount: Int
    let epicCount: Int
    let epicLoggedIn: Bool
    let steamLoggedIn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand header
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 28, height: 28)
                    Image(systemName: "cloud.fog.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text("Mist")
                    .font(.system(size: 16, weight: .bold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 4)

            SidebarSectionLabel(title: "Library")
            VStack(spacing: 2) {
                SidebarRow(title: "All Games", systemImage: "square.grid.2x2.fill", tint: .indigo,
                          isSelected: selection == "all") { selection = "all" }
                SidebarRow(title: "Steam", systemImage: "cloud.fill", tint: .blue, count: steamCount,
                          isSelected: selection == "steam") { selection = "steam" }
                SidebarRow(title: "Epic", systemImage: "bolt.fill", tint: .purple, count: epicCount,
                          needsAttention: !epicLoggedIn, isSelected: selection == "epic") { selection = "epic" }
            }
            .padding(.horizontal, 8)

            Spacer()
            Divider()
            VStack(spacing: 2) {
                SidebarRow(title: "Settings", systemImage: "gearshape.fill", tint: .gray,
                          needsAttention: !steamLoggedIn || !epicLoggedIn,
                          isSelected: selection == "settings") { selection = "settings" }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(.thinMaterial)
    }
}

enum GameSortOrder: String, CaseIterable, Identifiable {
    case installedFirst = "Installed First"
    case titleAZ = "Title (A–Z)"
    var id: String { rawValue }
}

struct GameGridView: View {
    let games: [Game]
    var onLaunch: (Game) -> Void = { _ in }
    var onLaunchNoEAC: (Game) -> Void = { _ in }
    var onLaunchGPTK: (Game) -> Void = { _ in }
    var onInstall: (Game) -> Void = { _ in }
    var onUninstall: (Game) -> Void = { _ in }
    var onShowInFinder: (Game) -> Void = { _ in }
    var onLaunchOptions: (Game) -> Void = { _ in }
    var onInstallWorkshopItem: (Game) -> Void = { _ in }
    var onSelect: (Game) -> Void = { _ in }

    @State private var sortOrder: GameSortOrder = .installedFirst

    let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 14)
    ]

    var sortedGames: [Game] {
        games.sorted { a, b in
            if sortOrder == .installedFirst, a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    var installedCount: Int { games.filter(\.isInstalled).count }

    var body: some View {
        if games.isEmpty {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.primary.opacity(0.05)).frame(width: 84, height: 84)
                    Image(systemName: "tray")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                }
                Text("No games found")
                    .font(.title3.weight(.medium))
                Text("Install games through Steam or Epic Games")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(games.count) games")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Text("·")
                            .foregroundColor(.secondary)
                        Text("\(installedCount) installed")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                        Menu {
                            Picker("Sort", selection: $sortOrder) {
                                ForEach(GameSortOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                        } label: {
                            Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down")
                                .font(.system(size: 11.5))
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(sortedGames) { game in
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
                                onSelect: { onSelect(g) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
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

    @Environment(\.dismiss) private var dismiss
    @State private var details: SteamAppDetails?
    @State private var achievements: [SteamAchievement] = []
    @State private var achievementsError: String?
    @State private var isLoadingAchievements = false
    @State private var workshopItems: [WorkshopItem] = []
    @State private var showingWorkshopBrowse = false

    private var gptkInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Game Porting Toolkit.app")
    }

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
                banner
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let desc = details?.short_description, !desc.isEmpty {
                        Text(desc)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let genres = details?.genres, !genres.isEmpty {
                        tagRow(genres.map(\.description))
                    }
                    actionRow
                    Divider()
                    if game.source == .steam {
                        achievementsSection
                        Divider()
                        workshopSection
                    }
                }
                .padding(20)
            }
        }
    }

    private var banner: some View {
        AsyncImage(url: URL(string: SteamLibraryService.heroURL(forAppID: game.id))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                LinearGradient(colors: [(game.source == .steam ? Color.blue : .purple).opacity(0.35), .clear],
                              startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: 200)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.name)
                    .font(.system(size: 22, weight: .bold))
                HStack(spacing: 5) {
                    Image(systemName: game.source == .steam ? "cloud.fill" : "bolt.fill")
                        .font(.system(size: 11))
                    Text(game.source.rawValue)
                    if game.isInstalled && game.sizeBytes > 0 {
                        Text("· \(game.sizeFormatted)")
                    }
                    if !game.isInstalled {
                        Text("· Not installed")
                    }
                }
                .font(.system(size: 12.5))
                .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private func tagRow(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags.prefix(8), id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.07), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        if game.isInstalled {
            HStack(spacing: 8) {
                if game.antiCheat != .none {
                    Button(action: onLaunchNoEAC) {
                        Label("Play Offline — No Anti-Cheat", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(game.source == .steam ? .blue : .purple)
                } else if game.source == .steam && gptkInstalled {
                    Button(action: onLaunchGPTK) {
                        Label("Play (D3DMetal)", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else if game.source == .steam {
                    Button(action: onLaunchNoEAC) {
                        Label("Launch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                } else {
                    Button(action: onLaunch) {
                        Label("Launch", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                }
                Button("Launch Options…", action: onLaunchOptions)
                    .buttonStyle(.bordered)
                Button("Show in Finder", action: onShowInFinder)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Uninstall", role: .destructive, action: onUninstall)
                    .buttonStyle(.bordered)
            }
        } else {
            Button(action: onInstall) {
                Label("Install", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(game.source == .steam ? .blue : .purple)
        }
    }

    @ViewBuilder
    private var achievementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Achievements", systemImage: "trophy.fill")
                    .font(.system(size: 13, weight: .semibold))
                if !achievements.isEmpty {
                    let unlocked = achievements.filter { $0.achieved == 1 }.count
                    Text("\(unlocked)/\(achievements.count)")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

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
                            Image(systemName: ach.achieved == 1 ? "checkmark.seal.fill" : "lock.fill")
                                .foregroundColor(ach.achieved == 1 ? .yellow : .secondary)
                                .font(.system(size: 14))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(ach.name ?? ach.apiname)
                                        .font(.system(size: 12.5, weight: .medium))
                                    if let rarity = ach.rarityLabel {
                                        Text(rarity)
                                            .font(.system(size: 9, weight: .bold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color.purple.opacity(0.22), in: Capsule())
                                            .foregroundColor(.purple)
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
        workshopItems = MistWorkshop.installedItems(appid: game.id, steamAppsDir: steamAppsDir)

        if let d = try? await SteamLibraryService.fetchAppDetails(appid: game.id) {
            details = d
        }

        guard game.source == .steam, steamAuth.isLoggedIn else { return }
        isLoadingAchievements = true
        do {
            var list = try await SteamLibraryService.fetchAchievements(
                appid: game.id, steamID: steamAuth.steamID)
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
                                .tint(.purple)
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
                                    .tint(.purple)
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
                                .tint(.purple)
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
        .tint(.purple)
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

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                if processManager.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running: \(processManager.currentGame?.name ?? "Game")")
                        .font(.headline)
                } else {
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                    Text("Process ended")
                        .font(.headline)
                }

                Spacer()

                if processManager.isRunning {
                    Button("Stop") {
                        processManager.stop()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button("Back to Library") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(.bar)

            Divider()

            // Log output
            ScrollViewReader { proxy in
                ScrollView {
                    Text(processManager.outputLog.isEmpty ? "Starting..." : processManager.outputLog)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                        .id("log-bottom")
                }
                .onChange(of: processManager.outputLog) { _ in
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
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

struct ContentView: View {
    @StateObject private var library: GameLibrary
    @StateObject private var processManager: ProcessManager
    @StateObject private var setup = SetupManager()
    @StateObject private var steamAuth = SteamAuthManager()
    @StateObject private var downloadManager: SteamDownloadManager
    @State private var sidebarSelection: String? = "all"
    @State private var showRunningView = false
    @State private var searchText = ""
    @State private var pendingUninstall: Game?
    @State private var gameForLaunchOptions: Game?
    @State private var gameForWorkshopInstall: Game?
    @State private var gameForDetail: Game?

    init() {
        let lib = GameLibrary()
        _library = StateObject(wrappedValue: lib)
        _processManager = StateObject(wrappedValue: ProcessManager(library: lib))
        _downloadManager = StateObject(wrappedValue: SteamDownloadManager(steamAppsDir: lib.steamAppsDir))
    }

    private func refreshOwnedSteamGames() {
        guard steamAuth.isLoggedIn else { return }
        Task {
            do {
                let token = try await steamAuth.mintAccessToken()
                let owned = try await SteamLibraryService.fetchOwnedGames(accessToken: token, steamID: steamAuth.steamID)
                await MainActor.run {
                    library.applyOwnedSteamGames(owned)
                    library.lastError = nil
                }
            } catch {
                // Locally-installed games still show up either way — this only affects
                // owned-but-not-installed placeholders — but surface it in Settings
                // rather than failing silently, since it's otherwise invisible.
                await MainActor.run {
                    library.lastError = "Couldn't fetch your Steam library: \(error.localizedDescription)"
                }
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
            downloadManager.install(appid: game.id, name: game.name,
                                    steamAccountName: steamAuth.accountName) {
                library.scan()
            }
        }
    }

    private func handleShowInFinder(_ game: Game) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDir)])
    }

    var filteredGames: [Game] {
        var games = library.games

        // Filter by source
        switch sidebarSelection {
        case "steam": games = games.filter { $0.source == .steam }
        case "epic": games = games.filter { $0.source == .epic }
        default: break
        }

        // Filter by search
        if !searchText.isEmpty {
            games = games.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
            }
        }

        return games
    }

    var body: some View {
        Group {
            if setup.isWorking || !setup.isComplete {
                SetupView(setup: setup)
            } else {
                NavigationSplitView {
                    SidebarView(
                        selection: $sidebarSelection,
                        steamCount: library.games.filter { $0.source == .steam }.count,
                        epicCount: library.games.filter { $0.source == .epic }.count,
                        epicLoggedIn: processManager.epicLoggedIn,
                        steamLoggedIn: steamAuth.isLoggedIn
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                } detail: {
                    ZStack {
                        if showRunningView {
                            RunningGameView(processManager: processManager, onDismiss: {
                                showRunningView = false
                            })
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
                                onSelect: { game in gameForDetail = game }
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
                        } else if downloadManager.isDownloading, let qrImage = downloadManager.downloadQRImage {
                            // DepotDownloader (this version) only emits a terminal
                            // ASCII-art QR, no plain URL to re-render via CoreImage —
                            // rasterized into a real pixel image (renderTerminalQR)
                            // instead of shown as text, since text rendering can't
                            // guarantee the exact square alignment a QR needs to scan.
                            VStack(spacing: 8) {
                                Text("Installing \(downloadManager.downloadingName ?? "…") — scan with the Steam Mobile app")
                                    .font(.callout.bold())
                                Image(nsImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: 260, maxHeight: 260)
                                    .padding(8)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                Text(downloadManager.downloadStatusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Button("Cancel") { downloadManager.cancel() }
                                    .buttonStyle(.bordered)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity)
                            .background(.bar)
                        } else if downloadManager.isDownloading {
                            HStack(spacing: 12) {
                                if let qr = downloadManager.downloadQRURL {
                                    SteamQRCodeView(urlString: qr)
                                        .frame(width: 60, height: 60)
                                        .background(Color.white)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Installing \(downloadManager.downloadingName ?? "…")")
                                        .font(.callout.bold())
                                    Text(downloadManager.downloadStatusText)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                    if let progress = downloadManager.downloadProgress {
                                        ProgressView(value: progress)
                                            .progressViewStyle(.linear)
                                            .frame(maxWidth: 240)
                                    }
                                }
                                Spacer()
                                Button("Cancel") { downloadManager.cancel() }
                                    .buttonStyle(.bordered)
                            }
                            .padding(12)
                            .background(.bar)
                        } else if let err = downloadManager.downloadError {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                ScrollView {
                                    Text(err)
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(maxHeight: 120)
                                Button("Dismiss") { downloadManager.downloadError = nil }
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
        .alert("Uninstall \(pendingUninstall?.name ?? "")?", isPresented: Binding(
            get: { pendingUninstall != nil },
            set: { if !$0 { pendingUninstall = nil } }
        )) {
            Button("Uninstall", role: .destructive) {
                guard let game = pendingUninstall else { return }
                if game.source == .steam {
                    library.uninstallSteamGame(game)
                } else {
                    processManager.epicUninstall(appName: game.id)
                }
                pendingUninstall = nil
            }
            Button("Cancel", role: .cancel) { pendingUninstall = nil }
        } message: {
            Text("This deletes the game's installed files from disk. You can reinstall it later.")
        }
        .sheet(item: $gameForLaunchOptions) { game in
            LaunchOptionsView(game: game, onShowInFinder: {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.installDir)])
            })
        }
        .sheet(item: $gameForWorkshopInstall) { game in
            WorkshopInstallView(game: game) { pubfileID in
                downloadManager.installWorkshopItem(appid: game.id, pubfileID: pubfileID, gameName: game.name,
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
                    downloadManager.installWorkshopItem(appid: game.id, pubfileID: pubfileID,
                                                        gameName: game.name,
                                                        steamAccountName: steamAuth.accountName) {
                        library.scan()
                    }
                },
                onOpenSettings: {
                    gameForDetail = nil
                    sidebarSelection = "settings"
                }
            )
        }
        .focusedSceneValue(\.rescanAction, { library.scan() })
        .focusedSceneValue(\.showSettingsAction, { sidebarSelection = "settings" })
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
extension FocusedValues {
    var rescanAction: (() -> Void)? {
        get { self[RescanActionKey.self] }
        set { self[RescanActionKey.self] = newValue }
    }
    var showSettingsAction: (() -> Void)? {
        get { self[ShowSettingsActionKey.self] }
        set { self[ShowSettingsActionKey.self] = newValue }
    }
}

// MARK: - App Entry Point

@main
struct MistApp: App {
    @FocusedValue(\.rescanAction) private var rescanAction
    @FocusedValue(\.showSettingsAction) private var showSettingsAction

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
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
            CommandGroup(replacing: .help) {
                Link("Mist on GitHub", destination: URL(string: "https://github.com/98przem/mist")!)
            }
        }
    }
}

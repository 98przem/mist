import SwiftUI
import Cocoa
import Foundation
import CryptoKit

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
    static var steamExePath: URL {
        winePrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/steam.exe")
    }
    static var cefDir: URL {
        winePrefix.appendingPathComponent("drive_c/Program Files (x86)/Steam/bin/cef/cef.win64")
    }

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
    static var steamInstalled: Bool {
        FileManager.default.fileExists(atPath: steamExePath.path)
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

    static func steamEnvironment() -> [String: String] {
        var env = baseEnvironment()
        env["DOTNET_EnableWriteXorExecute"] = "0"
        // Steam CEF rendering fix: Wine's DXGI doesn't report properly, causing CEF to
        // black-screen. Force software rendering — only affects Steam's UI, not games.
        env["STEAM_DISABLE_GPU_PROCESS"] = "1"
        env["GALLIUM_DRIVER"] = "llvmpipe"
        env["STEAM_CEF_COMMAND_LINE"] = "--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing --use-gl=swiftshader --disable-software-rasterizer"
        // DXVK (d3d11) + vkd3d-proton (d3d12) for Vulkan→MoltenVK→Metal rendering
        env["WINEDLLOVERRIDES"] = "d3d11,d3d10core,d3d12,d3d12core=n,b"
        // Null EOS anti-cheat client so EOS games don't crash (offline/singleplayer only)
        env["EOS_USE_ANTICHEATCLIENTNULL"] = "1"
        return env
    }

    static let steamCEFArgs = [
        "-cef-disable-gpu", "-cef-disable-gpu-compositing", "-cef-in-process-gpu",
        "-cef-disable-sandbox", "-no-cef-sandbox", "-noverifyfiles", "-norepairfiles",
    ]

    // Bundled steamwebhelper wrapper (Resources in the .app; repo root in dev builds)
    static var webhelperWrapper: URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourcePath {
            candidates.append(URL(fileURLWithPath: res).appendingPathComponent("steamwebhelper_wrapper.exe"))
        }
        // Dev: Mist.app/Contents/MacOS/Mist → repo root is 3 levels up
        let binDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        candidates.append(binDir.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("steamwebhelper_wrapper.exe"))
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("steamwebhelper_wrapper.exe"))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
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

    // Install (or re-install after a Steam update) the webhelper wrapper that forces
    // software rendering for Steam's CEF browser — without it the UI is a black screen.
    static func installWebhelperWrapperIfNeeded() {
        guard let wrapper = webhelperWrapper else { return }
        let fm = FileManager.default
        let dst = cefDir.appendingPathComponent("steamwebhelper.exe")
        let real = cefDir.appendingPathComponent("steamwebhelper_real.exe")
        guard fm.fileExists(atPath: dst.path) else { return }
        let size = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? 0
        // The real Steam binary is always >1 MB; our wrapper is far smaller.
        if size > 1_048_576 {
            try? fm.removeItem(at: real)
            try? fm.copyItem(at: dst, to: real)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: wrapper, to: dst)
        }
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
    static let steamInstallerURL = URL(string:
        "https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe")!

    @Published var wineInstalled = MistEnv.wineInstalled && MistEnv.runtimeLibsInstalled
    @Published var steamInstalled = MistEnv.steamInstalled
    @Published var isWorking = false
    @Published var statusText = ""
    @Published var downloadProgress: Double? = nil  // nil = indeterminate
    @Published var errorText: String?

    var isComplete: Bool { wineInstalled && steamInstalled }

    func refresh() {
        wineInstalled = MistEnv.wineInstalled && MistEnv.runtimeLibsInstalled
        steamInstalled = MistEnv.steamInstalled
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
                if !MistEnv.steamInstalled { try await self.installSteam() }
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

    private func installSteam() async throws {
        let installer = try await download(Self.steamInstallerURL, status: "Downloading Steam…")
        defer { try? FileManager.default.removeItem(at: installer) }

        await setStatus("Installing Steam (takes a few minutes)…", progress: nil)
        MistEnv.run(MistEnv.wineBinary, [installer.path, "/S"], env: MistEnv.baseEnvironment())
        MistEnv.waitWineserver()
        guard MistEnv.steamInstalled else {
            throw SetupError(message: "Steam did not install correctly (steam.exe not found). Try again.")
        }
        MistEnv.installWebhelperWrapperIfNeeded()
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
                self.games = found.sorted { $0.name.lowercased() < $1.name.lowercased() }
                self.isScanning = false
            }
        }
    }

    private func scanSteamGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default

        guard fm.fileExists(atPath: steamAppsDir.path) else { return games }

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
        }

        return games
    }

    private func scanEpicGames() -> [Game] {
        var games: [Game] = []
        let fm = FileManager.default

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

    func launchSteam(extraArgs: [String] = []) {
        outputLog = "Starting Steam…\n"
            + "Sign in on Steam's screen — scan the QR code with the Steam Mobile app, or use your password.\n\n"
        MistEnv.killWineserver()
        MistEnv.installWebhelperWrapperIfNeeded()
        runProcess(path: MistEnv.wineBinary.path,
                   arguments: ["C:/Program Files (x86)/Steam/steam.exe"]
                       + MistEnv.steamCEFArgs + extraArgs,
                   env: MistEnv.steamEnvironment())
        startDialogKiller()
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
        case .steam:
            switch mode {
            case .gptk:
                launchGameGPTK(game)
            case .noEAC:
                launchGameDirect(game)
            case .normal:
                launchSteam(extraArgs: ["-applaunch", game.id])
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
                ], env: env)
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
        runProcess(path: MistEnv.wineBinary.path, arguments: [exe], env: env,
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
        runProcess(path: gptkWinePath, arguments: [exe], env: env,
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

    // Wine surfaces crashes in background processes (e.g. steamservice.exe) as
    // winedbg dialog boxes that block the UI. Kill winedbg quietly instead —
    // this replaces the old dismiss-dialogs.sh + Accessibility permission.
    private func startDialogKiller() {
        dialogKillerTimer?.invalidate()
        dialogKillerTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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

    private func runProcess(path: String, arguments: [String],
                            env: [String: String], cwd: URL? = nil) {
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
            DispatchQueue.main.async {
                self?.outputLog += "\n[Process exited with code \(p.terminationStatus)]\n"
                self?.isRunning = false
                self?.currentGame = nil
                self?.dialogKillerTimer?.invalidate()
                self?.dialogKillerTimer = nil
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

    @Published var epicLoginError: String = ""

    func checkEpicLogin() {
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
}

// MARK: - Views

struct GameCardView: View {
    let game: Game
    var onLaunch: () -> Void = {}
    var onLaunchNoEAC: () -> Void = {}
    var onLaunchGPTK: () -> Void = {}
    var onInstall: () -> Void = {}

    private var gptkInstalled: Bool {
        FileManager.default.fileExists(atPath: "/Applications/Game Porting Toolkit.app")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Cover art
            coverImage
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .allowsHitTesting(false)

            // Game name
            Text(game.name)
                .font(.headline)
                .lineLimit(2)
                .foregroundColor(game.isInstalled ? .primary : .secondary)
                .allowsHitTesting(false)

            // Source + size
            HStack(spacing: 4) {
                Text(game.source.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if game.isInstalled && game.sizeBytes > 0 {
                    Text("· \(game.sizeFormatted)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if !game.isInstalled {
                    Text("· Not installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .allowsHitTesting(false)

            // Anti-cheat badge
            if game.antiCheat != .none {
                HStack(spacing: 4) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.caption2)
                    Text(game.antiCheat.rawValue)
                        .font(.caption2)
                }
                .foregroundColor(game.hasLinuxEAC ? .orange : .red)
                .allowsHitTesting(false)
            }

            Spacer(minLength: 4)

            // Launch or Install button — must be clickable
            if game.isInstalled {
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
                        Divider()
                        Button(action: onLaunch) {
                            Label("Standard Launch (through store)", systemImage: "arrowshape.turn.up.right")
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
                    // Default to GPTK/D3DMetal (reliable for D3D11 + D3D12), with
                    // the Steam client launch as an alternative (overlay/achievements).
                    Menu {
                        Button(action: onLaunchGPTK) {
                            Label("Play (D3DMetal)", systemImage: "play.fill")
                        }
                        Button(action: onLaunch) {
                            Label("Launch via Steam", systemImage: "arrowshape.turn.up.right")
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
                } else {
                    Button(action: onLaunch) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text("Launch")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(game.source == .steam ? .blue : .purple)
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
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    @ViewBuilder
    var coverImage: some View {
        if let url = URL(string: game.imageURL), !game.imageURL.isEmpty {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    fallbackCover
                case .empty:
                    ZStack {
                        Color.gray.opacity(0.1)
                        ProgressView()
                    }
                @unknown default:
                    fallbackCover
                }
            }
        } else {
            fallbackCover
        }
    }

    var fallbackCover: some View {
        ZStack {
            (game.source == .steam ? Color.blue : Color.purple).opacity(0.15)
            VStack(spacing: 4) {
                Image(systemName: "gamecontroller.fill")
                    .font(.largeTitle)
                Text(game.source.rawValue)
                    .font(.caption)
            }
            .foregroundColor(game.source == .steam ? .blue : .purple)
        }
    }
}

struct SetupView: View {
    @ObservedObject var setup: SetupManager

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cloud.fog.fill")
                .font(.system(size: 64))
                .foregroundColor(.purple)

            Text("Welcome to Mist")
                .font(.largeTitle.bold())

            Text("Mist needs to download the Wine engine, its runtime libraries and the Windows Steam client.\nThis is a one-time setup (~400 MB).")
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Label("Wine engine (CrossOver 24)",
                      systemImage: setup.wineInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(setup.wineInstalled ? .green : .secondary)
                Label("Steam client",
                      systemImage: setup.steamInstalled ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(setup.steamInstalled ? .green : .secondary)
            }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SidebarView: View {
    @Binding var selection: String?
    let steamCount: Int
    let epicCount: Int
    let epicLoggedIn: Bool

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                Label("All Games", systemImage: "gamecontroller.fill")
                    .tag("all")
                Label("Steam (\(steamCount))", systemImage: "cloud.fill")
                    .tag("steam")
                Label {
                    HStack {
                        Text("Epic (\(epicCount))")
                        if !epicLoggedIn {
                            Circle()
                                .fill(.orange)
                                .frame(width: 6, height: 6)
                        }
                    }
                } icon: {
                    Image(systemName: "bolt.fill")
                }
                .tag("epic")
            }

            Section("Stores") {
                Label("Steam Client", systemImage: "server.rack")
                    .tag("launch-steam")
                Label {
                    Text("Epic Games")
                } icon: {
                    Image(systemName: "bolt.circle.fill")
                }
                .tag("epic-store")
            }

            Section("Tools") {
                Label("Anti-Cheat Status", systemImage: "shield.checkered")
                    .tag("anticheat")
            }

            Section("Settings") {
                Label("Wine Config", systemImage: "gearshape")
                    .tag("settings")
            }
        }
        .listStyle(.sidebar)
    }
}

struct GameGridView: View {
    let games: [Game]
    var onLaunch: (Game) -> Void = { _ in }
    var onLaunchNoEAC: (Game) -> Void = { _ in }
    var onLaunchGPTK: (Game) -> Void = { _ in }
    var onInstall: (Game) -> Void = { _ in }

    let columns = [
        GridItem(.adaptive(minimum: 280, maximum: 400), spacing: 12)
    ]

    var sortedGames: [Game] {
        games.sorted { a, b in
            if a.isInstalled != b.isInstalled { return a.isInstalled }
            return a.name.lowercased() < b.name.lowercased()
        }
    }

    var installedCount: Int { games.filter(\.isInstalled).count }

    var body: some View {
        if games.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No games found")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Text("Install games through Steam or Epic Games")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(games.count) games · \(installedCount) installed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)

                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(sortedGames) { game in
                            let g = game
                            GameCardView(
                                game: g,
                                onLaunch: { onLaunch(g) },
                                onLaunchNoEAC: { onLaunchNoEAC(g) },
                                onLaunchGPTK: { onLaunchGPTK(g) },
                                onInstall: { onInstall(g) }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
}

struct AntiCheatView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Anti-Cheat Status")
                    .font(.largeTitle.bold())

                GroupBox("Mach Syscall Interception") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("EXC_SYSCALL handler: Proven working", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("NT syscall interception: 8/8 tests pass", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("State modification under Rosetta 2: Working", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    .padding(8)
                }

                GroupBox("Wine Detection Vectors") {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("PE headers: Pass", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("Debug ports: Pass", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("PEB fields: Pass", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("Module paths: Pass", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Label("Process list: Needs patch (winedevice visible)",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Label("Kernel modules: Needs patch (only 3 reported)",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                    }
                    .padding(8)
                }

                GroupBox("How to Run Tests") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("make test-build && make test")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .padding(8)
                }
            }
            .padding(20)
        }
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

struct EpicStoreView: View {
    @ObservedObject var processManager: ProcessManager
    @State private var installName: String = ""
    @State private var showLoginFlow = false
    @State private var loginCode: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Epic Games")
                    .font(.largeTitle.bold())

                // Login section
                GroupBox {
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
                    .padding(4)
                } label: {
                    Label("Account", systemImage: "person.fill")
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
        }
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

struct ContentView: View {
    @StateObject private var library: GameLibrary
    @StateObject private var processManager: ProcessManager
    @StateObject private var setup = SetupManager()
    @State private var sidebarSelection: String? = "all"
    @State private var showRunningView = false
    @State private var searchText = ""

    init() {
        let lib = GameLibrary()
        _library = StateObject(wrappedValue: lib)
        _processManager = StateObject(wrappedValue: ProcessManager(library: lib))
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
                        epicLoggedIn: processManager.epicLoggedIn
                    )
                    .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
                } detail: {
                    ZStack {
                        if showRunningView {
                            RunningGameView(processManager: processManager, onDismiss: {
                                showRunningView = false
                            })
                        } else if sidebarSelection == "launch-steam" {
                            VStack(spacing: 20) {
                                Image(systemName: "person.badge.key.fill")
                                    .font(.system(size: 48))
                                    .foregroundColor(.blue)
                                Text("Steam")
                                    .font(.title2.bold())
                                Text("Opens the Windows Steam client.\nSign in on Steam's screen — scan the QR code with the Steam Mobile app, or use your password.")
                                    .font(.callout)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                Button {
                                    showRunningView = true
                                    processManager.launchSteam()
                                } label: {
                                    Label("Open Steam", systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                                Text("First launch: Steam updates itself before showing the sign-in screen — give it a few minutes.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if sidebarSelection == "epic-store" {
                            EpicStoreView(processManager: processManager)
                        } else if sidebarSelection == "anticheat" {
                            AntiCheatView()
                        } else if sidebarSelection == "settings" {
                            VStack(spacing: 16) {
                                Image(systemName: "gearshape")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary)
                                Text("Settings")
                                    .font(.title2.bold())

                                GroupBox("Paths") {
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Wine:")
                                                .foregroundColor(.secondary)
                                            Text(library.wineDir.path)
                                                .textSelection(.enabled)
                                        }
                                        HStack {
                                            Text("Prefix:")
                                                .foregroundColor(.secondary)
                                            Text(library.supportDir.path)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(4)
                                }
                                .frame(maxWidth: 500)

                                Button("Rescan Games") {
                                    library.scan()
                                }
                                .buttonStyle(.bordered)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            GameGridView(
                                games: filteredGames,
                                onLaunch: { game in
                                    showRunningView = true
                                    processManager.launchGame(game)
                                },
                                onLaunchNoEAC: { game in
                                    showRunningView = true
                                    processManager.launchGame(game, mode: .noEAC)
                                },
                                onLaunchGPTK: { game in
                                    showRunningView = true
                                    processManager.launchGame(game, mode: .gptk)
                                },
                                onInstall: { game in
                                    if game.source == .epic {
                                        processManager.epicInstall(appName: game.id)
                                    }
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
        }
        .onChange(of: setup.isComplete) { complete in
            if complete { library.scan() }
        }
    }
}

// MARK: - App Entry Point

@main
struct MistApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)
    }
}

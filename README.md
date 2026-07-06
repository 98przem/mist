# Mist

Run Windows **Steam** and **Epic Games** titles on macOS (Apple Silicon & Intel) using Wine + Apple's Game Porting Toolkit.

## What is this?

A native macOS launcher for Windows games. Mist.app signs in to Steam natively (no Wine involved — just a QR code, like the Steam Mobile app), downloads games with [DepotDownloader](https://github.com/SteamRE/DepotDownloader), and runs the downloaded `.exe` directly through [Wine](https://www.winehq.org/) (CrossOver engine), rendering DirectX with Apple's **Game Porting Toolkit (D3DMetal)** when available and DXVK/MoltenVK as a fallback.

Every dependency — the Wine engine and DepotDownloader — is downloaded and managed by Mist.app itself. There's nothing to install with Homebrew or any other package manager, and no separate Gatekeeper approval to grant: Mist downloads these tools the same way a browser would, but since it's not going through Homebrew's cask installer (which quarantines binaries on your behalf), they aren't quarantined and just run.

Mist never runs Steam's own Windows client under Wine — that's a deliberate design choice. Steam's client renders its UI with an embedded Chromium browser (CEF) that doesn't behave reliably under Wine (black screens, broken websocket connections between the client and its own UI process), and getting it working needs Accessibility permissions to auto-dismiss its error popups. Sidestepping the client entirely avoids all of that: no Accessibility permission, no black screens, no CEF.

**Tested on:** macOS 14+ with Apple Silicon (M1/M2/M3/M4) via Rosetta 2.

## Download

Grab the latest **Mist.zip** from the [Releases](../../releases) page. Unzip it, drag **Mist.app** to your Applications folder (or anywhere), and double-click.

> **Note:** Since the app is not notarized, macOS will block it on first open. Right-click the app and select "Open" to bypass Gatekeeper. This is the only manual Gatekeeper step — Mist's own downloads (Wine, DepotDownloader) don't need it.

For DirectX 12 games, also install Apple's Game Porting Toolkit:
```bash
brew install --cask gcenx/wine/game-porting-toolkit
```

## Quick Start

1. Open **Mist.app**. On first launch it downloads the Wine engine (~200 MB) — click **Download & Install** and wait for it to finish.
2. Click **Steam** in the sidebar and scan the QR code with the Steam Mobile app (or sign in with your password on Steam's own login page if you'd rather use a browser).
3. Your Steam library shows up — click **Install** on any owned game. The first install also downloads DepotDownloader itself (~30 MB, one-time, automatic).
4. Once installed, click **Launch** to run it directly under Wine.

Epic Games works the same way it always has, via [legendary](https://github.com/derrod/legendary) — see **Epic Games** in the sidebar.

### Command-line tool

The repo also ships a `mist` CLI and a set of shell scripts (`setup.sh`, `launch-steam.sh`, etc.) for scripted/headless use, kept in [`OLD/`](OLD/). These predate the native app and still work the *old* way — they install and run the real Windows Steam client under Wine, with all the caveats that implies (see Troubleshooting). If you just want to play games, use Mist.app instead.

```bash
cd OLD
chmod +x setup.sh && ./setup.sh   # downloads a Wine build for the CLI's own use
./launch-steam.sh                 # launch the real Steam client under Wine
./mist games                      # list installed Steam games
./mist launch <appid>             # launch a game
./mist epic games                 # list your Epic library (via legendary)
```

## How Mist.app works

1. **Login** — talks directly to Valve's public authentication API over HTTPS (the same one the Steam Mobile app uses for QR pairing) and renders the QR code natively. No Wine, no browser, no Accessibility permission.
2. **Install** — shells out to `depotdownloader` to fetch the Windows build of a game's files directly from Steam's CDN. Mist tracks what it installed in a small manifest alongside Steam's own format, so both show up in the library.
3. **Launch** — finds the game's main `.exe` and runs it directly under Wine (CrossOver engine, downloaded on first run), or through Apple's Game Porting Toolkit when installed, for D3D11/D3D12 titles.
4. On Apple Silicon, everything runs through Rosetta 2 (x86_64 → ARM).

## Game Compatibility

- **Works well:** Most indie games, many AAA single-player titles, DX9/10/11 games. With **Apple's Game Porting Toolkit** installed, DirectX 12 games also work (Mist launches them through GPTK's D3DMetal — verified with Elden Ring).
- **DirectX 12 without GPTK:** the bundled vkd3d-proton → MoltenVK path can't initialize D3D12 on macOS, so **install Game Porting Toolkit** for DX12 titles (see Download).
- **Anti-cheat (EAC, BattlEye, Vanguard):** Online/multiplayer is **not supported** — Mist does not circumvent anti-cheat. Many titles that bundle anti-cheat still have a singleplayer/offline mode; for those, Mist offers a **"Play Offline (No Anti-Cheat)"** launch that runs the game without its anti-cheat. This only works offline.

Check [ProtonDB](https://www.protondb.com/) for game-specific reports — if a game runs on Linux/Proton, it will likely work here.

## Performance Tips

- Wine runs with `WINEMSYNC`/`WINEESYNC` enabled by default for better sync performance.
- D3D12 games are most reliable through the Game Porting Toolkit path.
- Close unnecessary background apps to free up resources for Rosetta 2.

## Building from Source

Pre-built binaries are not included in the repo.

```bash
make app                   # build Mist.app in the repo root (dev workflow)
make bundle                 # build the distributable app → dist/Mist.app
make release                # also produce dist/Mist.zip
```

The `wrapper`/`install-wrapper` targets (and `OLD/webhelper_wrapper.c`) are only needed if you're using the `mist` CLI's shell-script launch path, which still runs the real Steam client under Wine and needs a CEF compatibility wrapper. They require `brew install mingw-w64`. Building Mist.app itself doesn't need them.

## File Structure

```
mist/
├── MistApp.swift            # Native SwiftUI app — Steam login, downloads, game library, launcher
├── Makefile                 # Build targets (app, wrapper, bundle, release)
├── .github/workflows/ci.yml # ShellCheck + Swift build CI
├── LICENSE
├── README.md
└── OLD/                     # Legacy CLI path — Mist.app doesn't use any of this
    ├── mist                     # CLI: games, launch, profiles, epic (classic Wine-Steam-client path)
    ├── common.sh                # Shared launch helpers for the CLI/shell scripts
    ├── setup.sh                 # Downloads & installs Wine Staging
    ├── launch-steam.sh          # Launch the real Steam client under Wine
    ├── launch-steam-game.sh     # Launch a Steam game directly (offline)
    ├── launch-steam-gptk.sh     # Launch via Game Porting Toolkit (D3DMetal)
    ├── launch-epic-game.sh      # Launch an Epic game (via legendary)
    ├── dismiss-dialogs.sh       # Auto-dismisses Steam error popups
    ├── build-wine.sh            # Build a clean Wine from source (optional)
    └── webhelper_wrapper.c      # steamwebhelper Wine-compat wrapper
```

## Troubleshooting

**First install takes a bit longer than expected:** Mist downloads DepotDownloader (~30 MB) automatically before your very first game install — that only happens once.

**Install asks me to scan a QR code again:** DepotDownloader keeps its own Steam session (separate from Mist's login, since it talks to Steam's depot-download protocol directly) and caches it after the first successful scan — Mist reuses that cached session automatically on later installs, so this should only happen once per machine. If it happens again, the cached session probably expired or was revoked (e.g. after a password change) — just scan again and it'll cache the new one.

**"wine server failed to run":** The Wine engine didn't download/extract correctly — try **Try Again** on the setup screen, or delete `~/Library/Application Support/Mist/wine` and relaunch Mist.app.

**A D3D12 game crashes immediately:** Install the Game Porting Toolkit (see Download) — the bundled D3D12 path doesn't work on macOS.

**Game crashes on launch:** Not all games work under Wine. Check ProtonDB for compatibility.

**Using the `mist` CLI / shell scripts instead of Mist.app:** those run the real Steam client under Wine and can hit the black-screen/CEF issues Mist.app was specifically redesigned to avoid — see the comments in `OLD/launch-steam.sh` and `OLD/dismiss-dialogs.sh` if you go that route.

## Credits

- [Wine](https://www.winehq.org/) — the Windows compatibility layer (LGPL)
- [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) — packages the CrossOver Wine engine Mist downloads
- [DepotDownloader](https://github.com/SteamRE/DepotDownloader) (SteamRE) — downloads Steam game depots directly, no Steam client needed
- Apple **Game Porting Toolkit** (D3DMetal) — DirectX → Metal translation
- [legendary](https://github.com/derrod/legendary) — open-source Epic Games launcher
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) / [DXVK](https://github.com/doitsujin/dxvk) — Vulkan → Metal and D3D → Vulkan

## Disclaimer

Steam is a trademark of Valve Corporation; Epic Games Store is a trademark of Epic Games, Inc. This project is not affiliated with or endorsed by either. Running their clients under Wine, or downloading their content with third-party tools, may not comply with their respective subscriber agreements — use at your own risk.

## License

MIT — see [LICENSE](LICENSE). Wine itself is LGPL v2.1.

# Mist

Run Windows **Steam** and **Epic Games** titles on macOS (Apple Silicon & Intel) using Wine + Apple's Game Porting Toolkit.

## What is this?

A native macOS launcher for Windows games. Mist.app signs in to Steam natively (no Wine involved — just a QR code, like the Steam Mobile app), downloads games with [DepotDownloader](https://github.com/SteamRE/DepotDownloader), and runs the downloaded `.exe` directly through [Wine](https://www.winehq.org/) (CrossOver engine), rendering DirectX with Apple's **Game Porting Toolkit (D3DMetal)** when available and DXVK/MoltenVK as a fallback.

Every dependency — the Wine engine and DepotDownloader — is downloaded and managed by Mist.app itself. There's nothing to install with Homebrew or any other package manager, and no separate Gatekeeper approval to grant: Mist downloads these tools the same way a browser would, but since it's not going through Homebrew's cask installer (which quarantines binaries on your behalf), they aren't quarantined and just run.

Mist never runs Steam's own Windows client under Wine — that's a deliberate design choice. Steam's client renders its UI with an embedded Chromium browser (CEF) that doesn't behave reliably under Wine (black screens, broken websocket connections between the client and its own UI process), and getting it working needs Accessibility permissions to auto-dismiss its error popups. Sidestepping the client entirely avoids all of that: no Accessibility permission, no black screens, no CEF.

**One login for everything.** A single QR scan powers your whole library, downloads, and achievements — there's no second sign-in. And you still get **real Steam achievements**: browse them in-app (unlock status + global rarity), and when you unlock one *in-game*, it syncs to your actual Steam profile — all without a running Steam client (see [Achievements](#achievements)).

**Tested on:** macOS 15.7.8 - M2 Macbook Air

## Download

Grab the latest **Mist.dmg** from the [Releases](../../releases) page, open it, and drag **Mist.app** into your Applications folder.

> **Note:** Since the app is not notarized, macOS will block it on first open. Right-click the app and select "Open" to bypass Gatekeeper. This is the only manual step — the helper tools ship inside the app, and the Wine engine it downloads itself isn't quarantined.

For DirectX 12 games, also install Apple's Game Porting Toolkit:
```bash
brew install --cask gcenx/wine/game-porting-toolkit
```

## Quick Start

1. Open **Mist.app**. On first launch it downloads the Wine engine (~200 MB) — click **Download & Install** and wait for it to finish.
2. Go to **Settings → Steam** and scan the QR code with the Steam Mobile app. That's the only login — it covers your library, downloads, and achievements.
3. Your Steam library shows up — click **Install** on any owned game (no extra sign-in).
4. Once installed, click **Launch** to run it directly under Wine. Click a game's card to see its details, description, and achievements.

Epic Games works the same way it always has, via [legendary](https://github.com/derrod/legendary) — see **Epic Games** in the sidebar.

## Achievements

Mist reads and writes your **real** Steam achievements over Steam's client protocol using your one login — no Steam client, no Web API key:

- **View** — a game's detail view lists its achievements with your unlock status and each one's global rarity.
- **Unlock in-game** — when you launch a Steam game, Mist runs it through an open-source Steamworks shim ([gbe_fork](https://github.com/Detanup01/gbe_fork)) so the game unlocks achievements normally as you play. On exit, anything you genuinely earned is synced to your real Steam profile. Mist never fabricates achievements — it only syncs what the game actually unlocked, and skips anything already on your profile.

> Achievement unlocking is experimental. The in-game **overlay** (Shift+Tab) isn't working under Wine yet — that's a known gap.

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

No binaries are committed to the repo — everything is built from source. You need the **Xcode command-line tools** (for `swiftc`) and the **[.NET 10 SDK](https://dotnet.microsoft.com/download)** (to build the two helper tools).

```bash
make app       # build Mist.app in the repo root (Swift + bundled tools; dev workflow)
make bundle    # build the distributable app → dist/Mist.app
make dmg       # build a drag-to-install disk image → dist/Mist.dmg
make release   # produce dist/Mist.dmg + dist/Mist.zip
make tools     # (re)build just the helper tools into the app's Resources
```

The first `make app` also builds the helper tools (a few minutes); later builds reuse them. Releases are produced automatically by GitHub Actions when a `v*` tag is pushed (see `.github/workflows/release.yml`).

## File Structure

```
mist/
├── MistApp.swift              # Native SwiftUI app — login, downloads, library, launcher, achievements
├── Makefile                   # Build targets (app, tools, bundle, dmg, release)
├── Mist.icns                  # App icon (regenerate with tools/make_icon.swift)
├── tools/
│   ├── AchievementRelay/      # SteamKit2 helper: read/write achievements over the client protocol
│   ├── depotdownloader.patch  # small patch so DepotDownloader reuses Mist's login (no 2nd scan)
│   ├── depotdownloader.pin    # pinned upstream DepotDownloader commit
│   ├── gbe_fork.pin           # pinned gbe_fork release (Steamworks shim, prebuilt) + checksum
│   ├── build-tools.sh         # builds/fetches all three helper tools
│   └── make_icon.swift        # generates Mist.icns
├── .github/workflows/         # ci.yml (Swift build) + release.yml (tagged DMG release)
├── LICENSE
└── README.md
```

## Troubleshooting

**A downloaded game or achievement won't authenticate:** Everything runs off your one Steam login. If it expired or was revoked (e.g. after a password change), sign out and back in from **Settings → Steam** — one fresh scan restores downloads and achievements.

**"wine server failed to run":** The Wine engine didn't download/extract correctly — try **Try Again** on the setup screen, or delete `~/Library/Application Support/Mist/wine` and relaunch Mist.app.

**A D3D12 game crashes immediately:** Install the Game Porting Toolkit (see Download) — the bundled D3D12 path doesn't work on macOS.

**Game crashes on launch:** Not all games work under Wine. Check ProtonDB for compatibility.

## Credits

- [Wine](https://www.winehq.org/) — the Windows compatibility layer (LGPL)
- [Sikarugir](https://github.com/Sikarugir-App/Sikarugir) — packages the CrossOver Wine engine Mist downloads
- [DepotDownloader](https://github.com/SteamRE/DepotDownloader) (SteamRE) — downloads Steam game depots directly, no Steam client needed
- [SteamKit2](https://github.com/SteamRE/SteamKit) (SteamRE) — Steam client-protocol library powering Mist's achievement relay
- [gbe_fork](https://github.com/Detanup01/gbe_fork) — open-source Steamworks emulator; Mist uses it as an in-game achievement shim for games you own
- Apple **Game Porting Toolkit** (D3DMetal) — DirectX → Metal translation
- [legendary](https://github.com/derrod/legendary) — open-source Epic Games launcher
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK) / [DXVK](https://github.com/doitsujin/dxvk) — Vulkan → Metal and D3D → Vulkan

## Disclaimer

Steam is a trademark of Valve Corporation; Epic Games Store is a trademark of Epic Games, Inc. This project is not affiliated with or endorsed by either. Running their clients under Wine, or downloading their content with third-party tools, may not comply with their respective subscriber agreements — use at your own risk.

## License

MIT — see [LICENSE](LICENSE). Wine itself is LGPL v2.1.

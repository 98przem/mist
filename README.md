<p align="center">
  <img src="docs/mist-icon.png" width="120" alt="Mist">
</p>

<h1 align="center">Mist</h1>

<p align="center">
  <b>Play Windows Steam &amp; Epic games on macOS.</b><br>
  One QR login, real Steam achievements, nothing to install by hand.
</p>

<p align="center">
  <a href="../../releases/latest"><img src="https://img.shields.io/badge/download-Mist.dmg-8b5cf6?style=for-the-badge" alt="Download Mist.dmg"></a>
</p>

---

Mist is a native macOS launcher that downloads and runs Windows Steam and Epic games through [Wine](https://www.winehq.org/) — **without ever running the Steam client**. You sign in once, and it handles your library, downloads, and achievements directly.

## Features

- **One login.** A single Steam QR scan covers your whole library, game downloads, *and* achievements. There's no second sign-in, ever.
- **Real achievements.** Browse them in-app with global rarity, and unlock them *in-game* — synced to your actual Steam profile. Mist only ever syncs achievements you genuinely earn; it never fabricates them.
- **No Steam client, no fuss.** Mist talks to Steam's APIs directly and downloads with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) — so there's no flaky Chromium-based Steam UI under Wine, no black screens, and no Accessibility permissions to grant.
- **Self-contained.** Helper tools ship inside the app; the Wine engine (~200 MB) downloads itself on first launch. Nothing to install with Homebrew.
- **DirectX via Metal.** Runs games through the CrossOver Wine engine, using Apple's **Game Porting Toolkit** (D3DMetal) when available and DXVK/MoltenVK as a fallback.

**Tested on** macOS 15 · Apple Silicon (M2), via Rosetta 2.

## Install

**Homebrew** (recommended — always tracks the latest release):

```sh
brew install --cask 98przem/tap/mist
```

Or download **Mist.dmg** from the [latest release](../../releases/latest), open it, and drag **Mist.app** to Applications.

> Mist isn't notarized, so on first launch macOS will block it — **right-click the app → Open** to get past Gatekeeper. That's the only manual step.

Mist keeps itself up to date — it checks for new releases on launch and can install them from **Settings → Updates**. To remove it and every trace of its data (Wine prefix, downloaded games, engine, logins):

```sh
brew uninstall --zap mist
```

## Quick Start

1. Open Mist. On first launch it downloads the Wine engine — click **Download & Install**.
2. Go to **Settings → Steam** and scan the QR with the Steam Mobile app. *(This is your only login.)*
3. Click **Install** on any owned game, then **Launch**. Click a game's card for its details and achievements.

Epic games work via [legendary](https://github.com/derrod/legendary) — see the **Epic** tab. For DirectX 12 titles, also install the Game Porting Toolkit: `brew install --cask gcenx/wine/game-porting-toolkit`.

## Achievements

Mist reads and writes your real Steam achievements over Steam's client protocol using your one login — no Steam client, no Web API key. When you launch a Steam game, it runs through an open-source Steamworks shim ([gbe_fork](https://github.com/Detanup01/gbe_fork)) that lets the game unlock achievements as you play; on exit, anything you earned syncs to your profile.

> Experimental. The in-game overlay (Shift+Tab) doesn't work under Wine yet — a known gap.

## Compatibility

Most indie games and single-player AAA titles (DX9–12) work well; DX12 needs the Game Porting Toolkit. **Online/multiplayer with anti-cheat (EAC, BattlEye, Vanguard) is not supported** — Mist doesn't circumvent anti-cheat, though many such games offer an offline mode. Check [ProtonDB](https://www.protondb.com/): if a game runs on Proton, it'll likely run here.

## Building from Source

Requires the Xcode command-line tools and the [.NET 10 SDK](https://dotnet.microsoft.com/download) (for the bundled helper tools).

```bash
make app        # build Mist.app (Swift + helper tools)
make dmg        # build a drag-to-install dist/Mist.dmg
make release    # dist/Mist.dmg + dist/Mist.zip
```

Pushing a `v*` tag builds and publishes a DMG automatically (`.github/workflows/release.yml`). No binaries are committed — everything builds from source (see `tools/`).

## Credits

Built on [Wine](https://www.winehq.org/) · [CrossOver / Sikarugir](https://github.com/Sikarugir-App/Sikarugir) engine · Apple **Game Porting Toolkit** · [DepotDownloader](https://github.com/SteamRE/DepotDownloader) & [SteamKit2](https://github.com/SteamRE/SteamKit) · [gbe_fork](https://github.com/Detanup01/gbe_fork) · [legendary](https://github.com/derrod/legendary) · [MoltenVK](https://github.com/KhronosGroup/MoltenVK) / [DXVK](https://github.com/doitsujin/dxvk).

## Disclaimer

Steam and Epic Games are trademarks of their respective owners; this project is not affiliated with or endorsed by either. Running their clients under Wine or downloading their content with third-party tools may not comply with their subscriber agreements — use at your own risk, with games you own.

## License

MIT — see [LICENSE](LICENSE). Wine is LGPL v2.1.

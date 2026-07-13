# Mist UX polish — roadmap

Working backlog for the post-Foglight polish pass. Phases ship one at a time: branch → PR → merge → tag release → tell the user, so each can be reviewed and installed via the in-app updater before the next starts.

Shipped already (pre-dates this file): Phase 0 (data foundations: playtime/last-played/screenshots), library cards/covers/badges, game pages, the running-state card, the sign-out empty-state fix, and the Foglight app icon. Also landed early, ahead of their numbered phase below: the Settings Graphics-detected panel (idea 42, part of Phase 6) and the ambient `FogAtmosphere` behind the library grid (idea 46, part of Phase 7) — both already live, so Phases 6/7 start partially done.

**Phase 1 — shipped.** Guided Engine → Sign in → Play rail, Steam (QR) and Epic (browser) as independent tiles, skip-and-remember.

**Phase 2 — shipped.** Custom apps: "My Apps" sidebar row, Add/Locate via native file picker, non-destructive "Remove from Mist", broken-file state, dedup, no achievements section on custom entries.

**Phase 3 — shipped.** Real download queue (sequential, with speed/ETA sampled from on-disk growth, pause/resume/cancel/reorder), cover-art fill-as-it-installs on the grid card, a sidebar download meter opening the full queue sheet, and a "Play" toast when a Steam install finishes.

## Graphics stack — DONE, not backlog

Both arms are implemented and verified (see memory `mist-graphics-stack`): D3DMetal via GPTK/CrossOver when present, bundled DXVK-macOS otherwise. No phase needed. Only optional follow-up: spot-test the bundled DXVK path on a couple more games beyond Easy Delivery Co, opportunistically, not as scheduled work.

## Known bugs to fix (found in Phase 1 review, 2026-07-12 — not yet scheduled to a phase)

1. **Epic sign-in doesn't work out of the box.** `LegendaryLocator` only *searches* a fixed list of paths (Homebrew, pip user-installs, etc.) for a `legendary` binary already on the system — Mist never bundles or auto-downloads it, unlike DepotDownloader/AchievementRelay/gbe_fork, which all fetch themselves via `tools/build-tools.sh`. Real fix: bundle `legendary` the same way (it publishes prebuilt single-file macOS binaries on GitHub releases) so Epic sign-in works with zero manual setup, consistent with the rest of the app's self-contained design. Until fixed, the onboarding Epic tile correctly reports "legendary isn't installed" rather than failing silently — that part is working as intended.
2. **The Steam QR code doesn't refresh when it expires.** `SteamAuthManager.pollUntilConfirmed` throws `"QR code expired. Try again."` once the challenge's server-side TTL passes, but nothing catches that and calls `startQRLogin()` again — the UI is left showing a dead QR that Steam's mobile app then rejects ("failed to load QR info"), with no visible error or auto-recovery. Real fix: on expiry, either auto-restart the QR challenge (preferred — matches how Steam's own QR login UIs behave) or at minimum show a "Code expired — tap to refresh" state instead of a QR that silently stopped working.
3. **"Add App…" in My Apps (Phase 2) does nothing.** User-reported 2026-07-13: clicking "Add App…" in the "My Apps" section doesn't open the file picker at all. Needs repro + fix — the `.fileImporter`/`showingAddCustomApp` wiring should be checked end to end (button action → state flip → sheet presentation).

## Small UX asks for later (not bugs, filed 2026-07-13)

4. **A "My Library" (or similar) filter chip**, sitting between "Not Installed" and "Family Shared" in the library filter bar. Right now there's no way to see just what you actually own, excluding Family-shared titles — "All" mixes both, and "Family Shared" only isolates the borrowed side. Add the inverse chip so both halves of the library are independently filterable.
5. **CI release runner keeps running out of disk space during DMG creation** (`hdiutil: create failed - No space left on device`) — recurring, not a one-off, first re-noticed 2026-07-13 while releasing v0.7.1. GitHub's macOS runners ship with limited free space and Xcode/simulator junk already on disk; worth adding a `rm -rf` of unneeded preinstalled SDKs/simulators (or switching the DMG step to a leaner temp/work volume) to `.github/workflows/release.yml` before the `hdiutil create` step.

---

## Phase 1 — First run (corrected)

Guided **Engine → Accounts → Play** flow with a progress rail, resume-where-interrupted.

- **Accounts step shows both services independently** — a Steam tile (hero QR, breathes → green check on scan) *and* an Epic tile (browser sign-in + code paste), each showing connected/not. Connect either or both; this replaces the earlier mockup's Steam-only assumption.
- One-login explainer (what one Steam scan actually powers: library, downloads, achievements).
- Honest engine-download progress + a plain-language line on what's downloading.

## Phase 2 — Custom apps (new) — shipped

Let the user add any `.exe` as a library entry — Wine-launchable software Mist didn't install and doesn't own.

**Design decisions (thought through up front, not just "add a file picker"):**
- **New source type**: `Game.source` gains `.custom`. A dedicated **"My Apps"** sidebar row under Library, plus these entries show in All Games.
- **Add flow**: file picker for the `.exe` (host macOS path — *not* copied into the Wine prefix; Wine addresses host paths directly under `Z:\`, so no duplication of potentially huge installs), a name field pre-filled from the filename, and an optional working-directory override (defaults to the exe's own folder).
- **Storage**: a new lightweight `custom_apps.json` manifest (id = UUID, exePath, name, addedAt, lastPlayed) — separate from `MistManifest`, which is Steam/depot-specific.
- **Launch**: reuses the same renderer auto-detection as everything else (`GameActions.bestPlay`, D3DMetal → bundled DXVK fallback) — a custom game gets the same "how this runs" chip, not a second-class launch path.
- **No achievements section** on a custom entry's detail page (nothing to show) — the layout degrades gracefully rather than showing an empty trophy case.
- **Removal is non-destructive by default**: labeled **"Remove from Mist"**, not "Uninstall" — it only forgets the library entry. Mist never deletes a file it didn't install itself, unless that file happens to live inside Mist's own managed directories (rare for a custom add, checked defensively).
- **Missing-file handling**: if the exe has moved/been deleted, the card shows a broken state with a "Locate…" action instead of silently failing to launch.
- **Dedup**: adding the same path twice updates the existing entry rather than creating a duplicate.
- **Cover art**: no store art exists. Default is a Foglight-styled placeholder card (monogram + tint); extracting the real .exe icon (PE resource parsing) is a nice-to-have, not required for v1 — flagged as a stretch goal within the phase, cut first if time-constrained.

## Phase 3 — Downloads — shipped

Real queue view (speed/ETA/pause/resume/reorder), cover-art fill-as-it-installs, sidebar download meter, Play button on the install-finished toast.

## Phase 4 — Discovery (expanded)

- **Store page has real content before you search** *(new)* — Steam's public, keyless `featuredcategories` endpoint (verified: Specials, Top Sellers, New Releases, Coming Soon, real cover art) populates the page by default; search narrows within/beyond it. No more a dead search bar as the entire page.
- **In-app browser for store/community links** *(new)* — a `WKWebView`-backed sheet/window inside Mist, so clicking "View on Steam", a store listing, or a free-game claim link never bounces you to Safari.
  - **Best-effort SSO**: Steam's QR/client-protocol login can, in principle, be bridged to a web session via the same `finalizelogin` cookie-transfer flow Steam's own clients use — this needs a feasibility spike at implementation time (untested so far; not guaranteed, since an earlier attempt to mint a Web-API access token from the same refresh token came back empty, which may or may not affect this different flow). If it works, links open already signed in; if not, they open logged-out inside the embedded browser — still strictly better than today's external-browser hop, and a documented fallback either way.
  - Epic SSO is even less likely (legendary's stored tokens are launcher-API tokens, not storefront web cookies) — treat as logged-out-by-default for Epic links, revisit only if Steam's approach reveals a general pattern worth reapplying.
  - Applied wherever the app currently opens a Steam/Epic URL externally (Store, Free Games, a game's "View store page", achievement pages).
- Free-games countdown + claimed state, actionable wishlist, curated "runs great here" shelves (grounded in Mist's own renderer detection).

## Phase 5 — Navigation & presence

⌘K global search (library + store), Steam avatar/persona in the sidebar footer, collapsible sidebar sections, card-expands-into-page transitions.

## Phase 6 — Settings & transparency

Graphics-detected panel (trivial now — `D3DMetalProvider`/`DXVKManager` already exist, this is just surfacing them), inline re-sign-in on token expiry, storage & reclaim, System-Settings-shaped layout.

## Phase 7 — Atmosphere & delights

Ambient fog behind the library, matched-geometry transitions, trophy-case view, living app icon, optional unlock chime, genre-aware tints, characterful empty states.

---

**Working agreement:** one phase per branch/PR/release. After each merges and tags, the user updates via the in-app updater and reviews before the next phase starts.

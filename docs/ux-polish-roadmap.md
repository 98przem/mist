# Mist UX polish — roadmap

Working backlog for the post-Foglight polish pass. Phases ship one at a time: branch → PR → merge → tag release → tell the user, so each can be reviewed and installed via the in-app updater before the next starts.

Shipped already (pre-dates this file): Phase 0 (data foundations: playtime/last-played/screenshots), library cards/covers/badges, game pages, the running-state card, the sign-out empty-state fix, and the Foglight app icon. Also landed early, ahead of their numbered phase below: the Settings Graphics-detected panel (idea 42, part of Phase 6) and the ambient `FogAtmosphere` behind the library grid (idea 46, part of Phase 7) — both already live, so Phases 6/7 start partially done.

**Phase 1 — shipped.** Guided Engine → Sign in → Play rail, Steam (QR) and Epic (browser) as independent tiles, skip-and-remember.

**Phase 2 — shipped.** Custom apps: "My Apps" sidebar row, Add/Locate via native file picker, non-destructive "Remove from Mist", broken-file state, dedup, no achievements section on custom entries.

**Phase 3 — shipped.** Real download queue (sequential, with speed/ETA sampled from on-disk growth, pause/resume/cancel/reorder), cover-art fill-as-it-installs on the grid card, a sidebar download meter opening the full queue sheet, and a "Play" toast when a Steam install finishes.

## Graphics stack — DONE, not backlog

Both arms are implemented and verified (see memory `mist-graphics-stack`): D3DMetal via GPTK/CrossOver when present, bundled DXVK-macOS otherwise. No phase needed. Only optional follow-up: spot-test the bundled DXVK path on a couple more games beyond Easy Delivery Co, opportunistically, not as scheduled work.

## Known bugs to fix (found in Phase 1 review, 2026-07-12 — not yet scheduled to a phase)

1. **Epic sign-in doesn't work out of the box.** `LegendaryLocator` only *searches* a fixed list of paths (Homebrew, pip user-installs, etc.) for a `legendary` binary already on the system — Mist never bundles or auto-downloads it, unlike DepotDownloader/AchievementRelay/gbe_fork, which all fetch themselves via `tools/build-tools.sh`. Real fix: bundle `legendary` the same way — confirmed 2026-07-13 that `legendary-gl/legendary` (the community fork; matches the `legendary.gl/epiclogin` domain already used for browser sign-in) publishes a prebuilt `legendary_macOS.zip` on every GitHub release, same shape as the gbe_fork/DXVK pins in `tools/build-tools.sh`. **Not done this round** — wiring up a new `.pin` + build-tools.sh fetch step is straightforward, but verifying the actual Epic OAuth + legendary auth flow end-to-end needs a real Epic account and isn't something to rush through unverified; do this as its own focused pass.
2. ~~**The Steam QR code doesn't refresh when it expires.**~~ — the first fix (auto-restart on a "expired" error from `pollUntilConfirmed`) turned out to be a dead end: user-tested 2026-07-13, still stale. Root cause was the detection itself — `PollAuthSessionStatus` doesn't reliably surface Steam's real (short) QR TTL as an error at all, it just quietly keeps returning "still pending," so the reactive check only would have ever fired after the full ~900s poll ceiling, long after the code was visibly dead. Real fix: `pollUntilConfirmedOrQRExpiry` races the poll against a client-side 110s timer and treats the timer firing as expiry itself — proactive instead of reactive.
3. ~~**"Add App…" in My Apps (Phase 2) does nothing.**~~ — the first fix (`NSApp.activate` before presenting, on a theory that the panel was opening invisibly behind Mist's own window) also turned out to be a dead end: user-tested 2026-07-13, still nothing happened. Debug instrumentation showed the `showingAddCustomApp` binding truly did flip to `true` all the way through to `.fileImporter`'s own `isPresented` parameter, yet no panel — not even hidden — was ever created (no XPC activity to the system's open/save panel service at all). With this many `.sheet`/`.fileImporter` modifiers stacked on `ContentView`, `.fileImporter(isPresented:)` had just stopped reliably presenting. Real fix: drive `NSOpenPanel` directly and imperatively (`presentExePicker`) from the button actions instead of through a declarative `.fileImporter`, which sidesteps whatever was going wrong with the modifier entirely.

## Small UX asks for later (not bugs, filed 2026-07-13)

4. ~~**A "My Library" (or similar) filter chip**~~ — fixed. `LibraryFilter.myLibrary` sits between Not Installed and Family Shared, filtering out family-shared titles the same way the Family Shared chip isolates them.
5. ~~**CI release runner keeps running out of disk space during DMG creation**~~ — fixed in the v0.8.0 release (freed Android SDK/simulator runtimes/GHC before the `hdiutil create` step); the underlying `hdiutil` flakiness (confirmed via `df` to NOT be a real space issue) got a retry loop in v0.10.0 after it recurred once more with 110GB genuinely free.
6. ~~**App icon glows in Launchpad/Finder/Dock, not just inside the app.**~~ — fixed. `tools/make_icon.swift` no longer draws the shadow-based outer halo or the glyph's glow shadow — both were bleeding past the squircle's own bounds into every context the icon renders (Dock, Finder, Launchpad, Spotlight). The inner bloom gradient (contained within the squircle, doesn't bleed) stays, so it isn't flat-flat, just no longer glowing outside itself.
7. ~~**⌘K command palette has no keyboard navigation**~~ — fixed. Up/down arrows move a focused index across a single flat list spanning both the Your Library and Steam Store sections; Return activates whatever's focused. Uses `.onKeyPress`, which needed the macOS-14 deployment-target pin from the v0.9.1 fix to be available.
8. ~~**No way to sign into Steam without the Mobile app to scan a QR code.**~~ — fixed (user-requested 2026-07-13). Added username/password sign-in as an alternative on both the onboarding tile and Settings: `SteamAuthManager.startCredentialsLogin` fetches the account's RSA key (`GetPasswordRSAPublicKey`), encrypts the password (PKCS#1 v1.5, built the DER key by hand since Steam hands back a raw modulus/exponent, not a certificate), submits via `BeginAuthSessionViaCredentials`, and if Steam asks for a Guard code (email or mobile-authenticator TOTP) collects one via `UpdateAuthSessionWithSteamGuardCode` — then falls into the same `pollUntilConfirmed` the QR flow already used, so both paths converge on identical session handling.
9. **No in-app "clean slate" reset.** Filed 2026-07-13. The only way to fully reset Mist today is `make reset-all`/`make reset-steam` from a git clone in Terminal — not something a normal (non-dev) user installed via Homebrew can reach at all. Add a real Settings action ("Reset Mist…" under Storage & Engine, destructive-styled with a confirmation alert spelling out exactly what goes) that does what `reset-all` does: wipe the Wine prefix (`~/Library/Application Support/Mist`, so all installed games, the downloaded engine, custom_apps.json, login/session files, per-game settings) and relevant `UserDefaults` keys, quitting and requiring a relaunch afterward (mirroring the auto-updater's own quit-and-relaunch pattern). Worth two tiers, matching the Makefile split: a lighter "Sign out & reset settings" (keeps the downloaded Wine engine, just clears logins/prefs — fast to recover from) alongside the full wipe.

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

## Phase 4 — Discovery (expanded) — shipped (partial)

- **Store page has real content before you search** — shipped. Steam's public, keyless `featuredcategories` endpoint populates Specials/Top Sellers/New Releases/Coming Soon shelves by default; search narrows within/beyond it.
- **In-app browser for store/community links** — shipped. A `WKWebView`-backed sheet (`InAppBrowserView`) with back/forward/reload/"Open in Safari", applied to Store results, featured-shelf items, and Epic free-game claim links. Logged-out by default — the SSO cookie-bridging spike wasn't attempted (unverified feasibility, not worth the risk this round); still strictly better than the old external-browser hop.
- **Free-games countdown** — already existed (relative-date label). **Claimed state** — shipped, a local-only "already claimed" marker (`ClaimedEpicPromos`, UserDefaults) so a claimed promo stops nagging you.
- **Not done, deferred**: actionable wishlist and curated "runs great here" shelves — both need data Mist doesn't currently have (an authenticated wishlist scope; a track record of verified-working titles) and didn't fit this pass. Revisit if there's a cheap way to source either.

## Phase 5 — Navigation & presence — shipped (partial)

- **⌘K global search** — shipped. `CommandPaletteView` searches your library (local, instant) and the Steam store (live) at once; picking a library result opens its detail page, a store result opens in the Phase 4 in-app browser.
- **Sidebar footer identity** — shipped, scoped down from "avatar" to account name + initials circle: Mist has no Steam Web API key to fetch a real profile photo, so it's a tinted-initial placeholder, not a fetched image. Revisit if a cheap way to get a real avatar shows up (the client-protocol relay could plausibly be extended to return persona+avatar, unverified).
- **Collapsible sidebar sections** — shipped, state persisted in UserDefaults across launches.
- **Not done, deferred**: card-expands-into-page transition (matchedGeometryEffect from grid card to detail sheet) — didn't fit this pass; the detail view is a `.sheet` today rather than a push, which would need restructuring to support a shared-geometry animation.
- **Bug found 2026-07-13**: `CommandPaletteView` (⌘K) has no keyboard navigation — up/down arrows and Return don't move through or select results, mouse-only right now. Needs a focused-index state + arrow-key handling + Return-to-select, matching the gamepad grid's existing focus-index pattern.

## Phase 6 — Settings & transparency — shipped (partial)

- **System-Settings-shaped layout** — shipped. `SettingsView` is now a left category list (Accounts/Graphics/Updates/Storage & Engine) + right detail pane, matching macOS's own Settings app, instead of every card stacked in one long scroll.
- **Graphics-detected panel** — already existed (idea 42), unchanged.
- **Inline re-sign-in on token expiry** — shipped. When `mintAccessToken` hard-fails with an "expired"/"log in again" error (not just a network hiccup), Mist now signs the Steam session out itself so the Accounts card falls back to its normal QR sign-in flow right there, with an explanatory message, instead of leaving `isLoggedIn` stuck true against a dead session.
- **Storage & reclaim** — partial. The Storage & Engine card now shows real numbers (installed games' total size, Wine engine size measured off the main thread) instead of just paths. **Not done**: no bulk-reclaim actions (e.g. clearing DepotDownloader's cache from the UI) — scoped down to transparency only this round; reclaim actions still go through each game's own Uninstall today.

## Phase 7 — Atmosphere & delights — shipped (partial)

- **Ambient fog behind the library** — already existed (idea 46), unchanged.
- **Genre-aware tints** — shipped. Each genre tag on a game's detail page now gets its own hand-picked tint (`Fog.genreTint`) instead of every tag being the same flat gray chip.
- **Optional unlock chime** — shipped. `SteamAchievement.isRecentlyUnlocked` infers "unlocked in the last 10 minutes" (no persisted "last seen" store exists, so this is the practical proxy) — plays a system chime and shows a "NEW" badge on the achievement row. Toggle lives in Settings → Accounts, on by default.
- **Characterful empty states** — light touch: punched up the flattest "no games match any filter" copy; the rest already had personality from earlier phases.
- **Not done, deferred**: card-expands-into-page transition (already deferred from Phase 5, same underlying blocker — detail is a `.sheet`, not a push). **Trophy-case view** (a dedicated cross-game achievement browser) — needs per-game achievement fetches for the whole library, which is expensive without a caching layer that doesn't exist yet. **Living app icon** — skipped outright: it would conflict with the just-fixed "icon shouldn't glow outside the app" bug (item 6 above); revisit only with a design that's animated/alive without adding a glow back to the static Dock/Finder icon.

---

**Working agreement:** one phase per branch/PR/release. After each merges and tags, the user updates via the in-app updater and reviews before the next phase starts.

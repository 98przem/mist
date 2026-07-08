# Helper tools (Steam client-protocol, powered by Mist's single QR login)

Two small .NET/SteamKit2 helpers Mist shells out to. Both are self-contained
single-file binaries (published like DepotDownloader) and use Mist's own
persistent session token (`steam_session.json`) — no Steam Web API key, no
Steam client, no extra login.

## AchievementRelay/
Reads a game's achievement schema + the user's unlock state over Steam's client
protocol (`CMsgClientGetUserStats`), and unlocks achievements on the real profile
(`CMsgClientStoreUserStats2`). Mist's `RelayManager` calls it.

Build: `dotnet publish -c Release -r osx-arm64 --self-contained true \
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true \
  -o out`  → `out/AchievementRelay` → install to `~/Library/Application Support/Mist/tools/`.

## depotdownloader-patch/
A one-hunk patch to SteamRE/DepotDownloader's Program.cs: if `MIST_REFRESH_TOKEN`
is set, seed it into the login-token store so `-username <acct> -remember-password`
reuses Mist's session — eliminating DepotDownloader's own separate QR scan.
Apply to a DepotDownloader checkout, publish self-contained, install to tools/.

NOTE: both binaries are currently placed in tools/ manually. A download-on-first-
use step (like DepotDownloaderManager's) is still needed for distribution.

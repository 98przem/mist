using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using SteamKit2;
using SteamKit2.Internal;

// Mist Steam-stats relay. Uses Mist's single persistent session token to talk to
// Steam's client protocol (no Steam client, no Web API key) for achievements and
// Steam Family library sharing.
//
//   relay <session.json> <appid>                 → print achievements as JSON (viewing)
//   relay <session.json> <appid> --unlock <name> → unlock one achievement
//   relay <session.json> <appid> --unlock-auto   → unlock first currently-locked one
//   relay <session.json> --family                → print Family-shared library as JSON
//   relay <session.json> --persona                → print {personaName, avatarHash} as JSON
//
// session.json is Mist's steam_session.json (accountName, steamID, refreshToken).
// Exit 0 = success. All human status goes to stderr; stdout is JSON only.

class Program
{
    static SteamClient steamClient = null!;
    static CallbackManager manager = null!;
    static SteamUser steamUser = null!;
    static SteamFriends steamFriends = null!;

    static string accountName = "", refreshToken = "";
    static ulong steamId = 0;
    static uint appId = 0;
    static uint cellId = 0;
    static string mode = "view";      // view | unlock | schema | family | owned | persona | cloud-*
    static string? unlockName = null;  // specific name, or null for --unlock-auto
    static string cloudFilename = "", cloudLocalPath = "";
    static bool running = true;
    static int exitCode = 1;
    static SteamUnifiedMessages unifiedMessages = null!;

    static int Main(string[] args)
    {
        if (args.Length < 2) { Err("usage: <session.json> <appid|--family> [--unlock <name> | --unlock-auto]"); return 2; }
        var json = File.ReadAllText(args[0]);
        accountName = Extract(json, "accountName");
        refreshToken = Extract(json, "refreshToken");
        steamId = ulong.TryParse(Extract(json, "steamID"), out var s) ? s : 0;
        if (args[1] == "--family") { mode = "family"; }
        else if (args[1] == "--owned") { mode = "owned"; }
        else if (args[1] == "--persona") { mode = "persona"; }
        else if (args[1] == "--cloud-list") { mode = "cloud-list"; appId = uint.Parse(args[2]); }
        else if (args[1] == "--cloud-quota") { mode = "cloud-quota"; appId = uint.Parse(args[2]); }
        else if (args[1] == "--cloud-resume") { mode = "cloud-resume"; appId = uint.Parse(args[2]); }
        else if (args[1] == "--cloud-download") { mode = "cloud-download"; appId = uint.Parse(args[2]); cloudFilename = args[3]; cloudLocalPath = args[4]; }
        else if (args[1] == "--cloud-upload") { mode = "cloud-upload"; appId = uint.Parse(args[2]); cloudFilename = args[3]; cloudLocalPath = args[4]; }
        else if (args[1] == "--cloud-delete") { mode = "cloud-delete"; appId = uint.Parse(args[2]); cloudFilename = args[3]; }
        else
        {
            appId = uint.Parse(args[1]);
            if (args.Length >= 3 && args[2] == "--unlock") { mode = "unlock"; unlockName = args.Length >= 4 ? args[3] : null; }
            else if (args.Length >= 3 && args[2] == "--unlock-auto") { mode = "unlock"; unlockName = null; }
            else if (args.Length >= 3 && args[2] == "--schema") { mode = "schema"; }
        }

        if (string.IsNullOrEmpty(refreshToken)) { Err("no refreshToken in session"); return 2; }

        // Real clients have used WebSocket-only since ~2018; SteamKit2 defaults to
        // allowing TCP too. Experiment: does Cloud storage-backend assignment
        // (GCS vs Azure) key off which transport this connection actually used?
        var config = SteamConfiguration.Create(b => b.WithProtocolTypes(ProtocolTypes.WebSocket));
        steamClient = new SteamClient(config);
        manager = new CallbackManager(steamClient);
        steamUser = steamClient.GetHandler<SteamUser>()!;
        steamFriends = steamClient.GetHandler<SteamFriends>()!;
        unifiedMessages = steamClient.GetHandler<SteamUnifiedMessages>()!;
        unifiedMessages.CreateService<CloudService>();
        steamClient.AddHandler(new StatsHandler());

        manager.Subscribe<SteamClient.ConnectedCallback>(OnConnected);
        manager.Subscribe<SteamClient.DisconnectedCallback>(_ => { running = false; });
        manager.Subscribe<SteamUser.LoggedOnCallback>(cb =>
        {
            if (mode == "family") _ = OnLoggedOnFamily(cb);
            else if (mode == "owned") _ = OnLoggedOnOwned(cb);
            else if (mode == "persona") OnLoggedOnPersona(cb);
            else if (mode.StartsWith("cloud-")) _ = OnLoggedOnCloud(cb);
            else OnLoggedOn(cb);
        });
        manager.Subscribe<SteamFriends.PersonaStateCallback>(OnPersonaState);

        Err($"connecting as {accountName} ({mode})…");
        steamClient.Connect();
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (running && DateTime.UtcNow < deadline)
            manager.RunWaitCallbacks(TimeSpan.FromMilliseconds(200));
        try { steamUser.LogOff(); } catch { }
        return exitCode;
    }

    // Steam Family library sharing: this account's shared appids that are
    // actually available to play/install right now (exclude_reason names
    // containing "Excluded" mean genuinely unavailable — e.g. the lending
    // account is currently playing it, or licensing rules block it).
    static async Task OnLoggedOnFamily(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result != EResult.OK) { Err($"logon failed: {cb.Result}/{cb.ExtendedResult}"); exitCode = 1; running = false; return; }
        try
        {
            var unified = steamClient.GetHandler<SteamUnifiedMessages>()!;
            var family = unified.CreateService<FamilyGroups>();

            var groupResp = await family.GetFamilyGroupForUser(
                new CFamilyGroups_GetFamilyGroupForUser_Request { steamid = steamId, include_family_group_response = false });
            var group = groupResp.Body;
            if (groupResp.Result != EResult.OK || group.is_not_member_of_any_group || group.family_groupid == 0)
            {
                Console.Out.Write("[]");
                exitCode = 0; running = false; return;
            }

            var appsResp = await family.GetSharedLibraryApps(new CFamilyGroups_GetSharedLibraryApps_Request
            {
                family_groupid = group.family_groupid,
                steamid = steamId,
                include_own = false,
                include_excluded = false,
                max_apps = 5000,
            });

            // The same appid can appear more than once (e.g. shared by more than one
            // family member, or listed under more than one package) — keep one. Steam
            // also has genuinely distinct appids for the same title (e.g. GTA III is
            // both appid 12100 and 12230 in this account's shared library) — dedupe
            // by name too, keeping whichever copy is listed first.
            var seenAppIds = new HashSet<uint>();
            var seenNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var sb = new StringBuilder("[");
            bool first = true;
            foreach (var a in appsResp.Body.apps)
            {
                if (a.exclude_reason.ToString().Contains("Excluded")) continue;
                // include_own=false only drops apps owned *solely* by this account.
                // A game both you and a family member own still comes back (your id
                // buried in owner_steamids) — that's YOUR game, not a borrowed one.
                if (a.owner_steamids.Contains(steamId)) continue;
                if (!seenAppIds.Add(a.appid)) continue;
                if (!seenNames.Add(a.name)) continue;
                if (!first) sb.Append(','); first = false;
                sb.Append('{')
                  .Append("\"appid\":").Append(a.appid).Append(',')
                  .Append("\"name\":").Append(JStr(a.name)).Append(',')
                  .Append("\"ownerSteamID\":").Append(a.owner_steamids.FirstOrDefault())
                  .Append('}');
            }
            sb.Append(']');
            Console.Out.Write(sb.ToString());
            exitCode = 0;
        }
        catch (Exception ex)
        {
            Err("family query failed: " + ex.Message);
            exitCode = 1;
        }
        finally
        {
            running = false;
        }
    }

    // The account's own owned games over the client protocol (IPlayerService),
    // so Mist never needs a Steam Web API key or a separately-minted web token —
    // just the same session everything else uses. Emitted as [{appid,name}].
    static async Task OnLoggedOnOwned(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result != EResult.OK) { Err($"logon failed: {cb.Result}/{cb.ExtendedResult}"); exitCode = 1; running = false; return; }
        try
        {
            var unified = steamClient.GetHandler<SteamUnifiedMessages>()!;
            var player = unified.CreateService<Player>();
            var resp = await player.GetOwnedGames(new CPlayer_GetOwnedGames_Request
            {
                steamid = steamId,
                include_appinfo = true,
                include_played_free_games = true,
                include_free_sub = false,
            });

            var sb = new StringBuilder("[");
            bool first = true;
            foreach (var g in resp.Body.games)
            {
                if (!first) sb.Append(','); first = false;
                sb.Append('{')
                  .Append("\"appid\":").Append(g.appid).Append(',')
                  .Append("\"name\":").Append(JStr(g.name ?? "")).Append(',')
                  .Append("\"playtimeForever\":").Append(g.playtime_forever).Append(',')
                  .Append("\"lastPlayed\":").Append(g.rtime_last_played)
                  .Append('}');
            }
            sb.Append(']');
            Console.Out.Write(sb.ToString());
            exitCode = 0;
        }
        catch (Exception ex)
        {
            Err("owned-games query failed: " + ex.Message);
            exitCode = 1;
        }
        finally
        {
            running = false;
        }
    }

    // Persona name + avatar for the SIGNED-IN account's own sidebar footer —
    // over the same client-protocol session as everything else, so Mist never
    // needs a separate Steam Web API key just to show who's logged in.
    // RequestFriendInfo works for your own SteamID too, not just friends; the
    // response comes back as an ordinary PersonaStateCallback.
    static void OnLoggedOnPersona(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result != EResult.OK) { Err($"logon failed: {cb.Result}/{cb.ExtendedResult}"); exitCode = 1; running = false; return; }
        steamFriends.RequestFriendInfo(new SteamID(steamId),
            EClientPersonaStateFlag.PlayerName | EClientPersonaStateFlag.Presence);
    }

    static void OnPersonaState(SteamFriends.PersonaStateCallback cb)
    {
        if (mode != "persona" || cb.FriendID.ConvertToUInt64() != steamId) return;
        var hashHex = cb.AvatarHash != null && cb.AvatarHash.Length > 0
            ? string.Concat(cb.AvatarHash.Select(b => b.ToString("x2")))
            : "";
        var sb = new StringBuilder("{");
        sb.Append("\"personaName\":").Append(JStr(cb.Name ?? "")).Append(',');
        sb.Append("\"avatarHash\":").Append(JStr(hashHex));
        sb.Append('}');
        Console.Out.Write(sb.ToString());
        exitCode = 0;
        running = false;
    }

    // Steam Cloud (the "Cloud" unified service) — message bodies for this
    // aren't included in SteamKit2 itself (only the message IDs are), so the
    // request/response classes live in SteamCloud.g.cs, generated straight
    // from SteamDatabase's reverse-engineered steammessages_cloud.steamclient.proto
    // via protobuf-net's protogen — not hand-transcribed, since this touches
    // real save-file data and a hand-typed field-number mistake would be the
    // kind of bug that corrupts something irreplaceable rather than just
    // failing loudly.
    static async Task OnLoggedOnCloud(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result != EResult.OK) { Err($"logon failed: {cb.Result}/{cb.ExtendedResult}"); exitCode = 1; running = false; return; }
        cellId = cb.CellID;
        try
        {
            // The achievements path announces "playing this app" via
            // ClientGamesPlayed before Steam will answer stats queries for it —
            // Cloud service calls may need the same context to route at all
            // (untested theory: quota/changelist calls timed out with zero
            // response until this was added).
            var gp = new ClientMsgProtobuf<CMsgClientGamesPlayed>(EMsg.ClientGamesPlayed);
            gp.Body.games_played.Add(new CMsgClientGamesPlayed.GamePlayed { game_id = appId });
            steamClient.Send(gp);
            await Task.Delay(1200);

            switch (mode)
            {
                case "cloud-list": await CloudList(); break;
                case "cloud-quota": await CloudQuota(); break;
                case "cloud-resume": await CloudResume(); break;
                case "cloud-download": await CloudDownload(); break;
                case "cloud-upload":
                    // Sequence confirmed by capturing a real Steam client's own
                    // traffic (NetHook2) during a real cloud sync: LaunchIntent,
                    // then a batch is opened before any file touches the CDN, and
                    // closed again after every file in it commits.
                    await CloudLaunchIntent();
                    await CloudUpload();
                    break;
                case "cloud-delete": await CloudDelete(); break;
            }
        }
        catch (Exception ex)
        {
            Err("cloud operation failed: " + ex.GetType().FullName + ": " + ex.Message
                + (ex.InnerException != null ? " | inner: " + ex.InnerException.GetType().FullName + ": " + ex.InnerException.Message : ""));
            exitCode = 1;
        }
        finally
        {
            running = false;
        }
    }

    // client_id identifies this "machine" to Steam's cloud-session tracking
    // (conflict resolution across machines) — derived from the account so
    // it's stable across runs, not random.
    static ulong CloudClientId => steamId ^ 0x4D697374;

    static async Task CloudList()
    {
        var req = new CCloud_GetAppFileChangelist_Request { appid = appId };
        var resp = await unifiedMessages.SendMessage<CCloud_GetAppFileChangelist_Request, CCloud_GetAppFileChangelist_Response>(
            "Cloud.GetAppFileChangelist#1", req);
        if (resp.Result != EResult.OK) { Err($"GetAppFileChangelist: {resp.Result}"); exitCode = 1; return; }
        // Files are named relative to one of path_prefixes (which index a file uses
        // is path_prefix_index) — Cloud.ClientFileDownload/#Upload/#DeleteFile all
        // need that full prefixed string as "filename", not the bare file_name, or
        // they come back FileNotFound. Resolve it here so callers never need to
        // know this indirection exists.
        var prefixes = resp.Body.path_prefixes;
        var sb = new StringBuilder("[");
        bool first = true;
        foreach (var f in resp.Body.files)
        {
            if (!first) sb.Append(','); first = false;
            var sha = f.sha_file is { Length: > 0 } ? Convert.ToHexString(f.sha_file).ToLowerInvariant() : "";
            var prefix = f.path_prefix_index < prefixes.Count ? prefixes[(int)f.path_prefix_index] : "";
            var path = prefix + (f.file_name ?? "");
            sb.Append('{')
              .Append("\"fileName\":").Append(JStr(f.file_name ?? "")).Append(',')
              .Append("\"path\":").Append(JStr(path)).Append(',')
              .Append("\"sha\":").Append(JStr(sha)).Append(',')
              .Append("\"timeStamp\":").Append(f.time_stamp).Append(',')
              .Append("\"rawFileSize\":").Append(f.raw_file_size).Append(',')
              .Append("\"persistState\":").Append((int)f.persist_state)
              .Append('}');
        }
        sb.Append(']');
        Console.Out.Write(sb.ToString());
        exitCode = 0;
    }

    static async Task CloudQuota()
    {
        var req = new CCloud_ClientGetAppQuotaUsage_Request { appid = appId };
        var resp = await unifiedMessages.SendMessage<CCloud_ClientGetAppQuotaUsage_Request, CCloud_ClientGetAppQuotaUsage_Response>(
            "Cloud.ClientGetAppQuotaUsage#1", req);
        if (resp.Result != EResult.OK) { Err($"ClientGetAppQuotaUsage: {resp.Result}"); exitCode = 1; return; }
        var b = resp.Body;
        Console.Out.Write("{\"existingFiles\":" + b.existing_files + ",\"existingBytes\":" + b.existing_bytes +
                           ",\"maxNumFiles\":" + b.max_num_files + ",\"maxNumBytes\":" + b.max_num_bytes + "}");
        exitCode = 0;
    }

    // A real client announces "about to play this app" before touching any
    // cloud files. Confirmed via a real client's own captured traffic that the
    // RPC is named "SignalAppLaunchIntent" — the CCloud_AppLaunchIntent_Request
    // message type name is misleading; a bare "Cloud.AppLaunchIntent#1" isn't a
    // real method and every call using that name failed outright.
    static async Task CloudLaunchIntent()
    {
        var req = new CCloud_AppLaunchIntent_Request
        {
            appid = appId,
            client_id = CloudClientId,
            os_type = (int)EOSType.Windows10,
            device_type = 1, // EGamingDeviceType.StandardPC
        };
        var resp = await unifiedMessages.SendMessage<CCloud_AppLaunchIntent_Request, CCloud_AppLaunchIntent_Response>(
            "Cloud.SignalAppLaunchIntent#1", req);
        if (resp.Result != EResult.OK) Err($"SignalAppLaunchIntent: {resp.Result}");
    }

    static async Task CloudResume(bool quiet = false)
    {
        var req = new CCloud_AppSessionResume_Request { appid = appId, client_id = CloudClientId };
        var resp = await unifiedMessages.SendMessage<CCloud_AppSessionResume_Request, CCloud_AppSessionResume_Response>(
            "Cloud.ResumeAppSession#1", req);
        if (quiet) { Err($"ResumeAppSession (pre-upload): {resp.Result}"); return; }
        Console.Out.Write("{\"result\":\"" + resp.Result + "\"}");
        exitCode = resp.Result == EResult.OK ? 0 : 1;
    }

    // A real client wraps every batch of file changes (uploads and/or deletes)
    // for an app in a Begin/CompleteAppUploadBatch pair — the batch_id this
    // hands back must be threaded into every ClientBeginFileUpload call in the
    // batch (upload_batch_id) or Steam issues CDN URLs whose signature never
    // validates.
    // A real client always knows its own installed build id and sends it here;
    // ours doesn't track depot state at all, so best-effort look it up via PICS
    // (the app's current public-branch build) rather than sending 0.
    static async Task<ulong> CloudCurrentBuildId()
    {
        try
        {
            var steamApps = steamClient.GetHandler<SteamApps>()!;
            var job = steamApps.PICSGetProductInfo(new SteamApps.PICSRequest(appId), null);
            job.Timeout = TimeSpan.FromSeconds(15);
            var result = await job;
            var app = result.Results?.SelectMany(r => r.Apps.Values).FirstOrDefault(a => a.ID == appId);
            var buildIdStr = app?.KeyValues["depots"]["branches"]["public"]["buildid"].Value;
            return buildIdStr != null && ulong.TryParse(buildIdStr, out var id) ? id : 0;
        }
        catch (Exception ex)
        {
            Err($"PICSGetProductInfo lookup failed (non-fatal): {ex.Message}");
            return 0;
        }
    }

    static async Task<ulong> CloudBeginUploadBatch(string filename)
    {
        var req = new CCloud_BeginAppUploadBatch_Request
        {
            appid = appId,
            client_id = CloudClientId,
            app_build_id = await CloudCurrentBuildId(),
        };
        req.files_to_upload.Add(filename);
        var resp = await unifiedMessages.SendMessage<CCloud_BeginAppUploadBatch_Request, CCloud_BeginAppUploadBatch_Response>(
            "Cloud.BeginAppUploadBatch#1", req);
        if (resp.Result != EResult.OK) { Err($"BeginAppUploadBatch: {resp.Result}"); return 0; }
        return resp.Body.batch_id;
    }

    static async Task CloudCompleteUploadBatch(ulong batchId, bool ok)
    {
        var req = new CCloud_CompleteAppUploadBatch_Request
        {
            appid = appId,
            batch_id = batchId,
            batch_eresult = (uint)(ok ? EResult.OK : EResult.Fail),
        };
        var resp = await unifiedMessages.SendMessage<CCloud_CompleteAppUploadBatch_Request, CCloud_CompleteAppUploadBatch_Response>(
            "Cloud.CompleteAppUploadBatchBlocking#1", req);
        if (resp.Result != EResult.OK) Err($"CompleteAppUploadBatchBlocking: {resp.Result}");
    }

    // Download is a two-step handshake: the unified-message call only hands
    // back a signed CDN URL (+headers); the actual file bytes come from a
    // plain HTTP GET against that URL. The size check before writing is not
    // optional — a truncated/wrong response must never silently overwrite
    // whatever local save already exists at the destination path.
    static async Task CloudDownload()
    {
        var req = new CCloud_ClientFileDownload_Request { appid = appId, filename = cloudFilename };
        var resp = await unifiedMessages.SendMessage<CCloud_ClientFileDownload_Request, CCloud_ClientFileDownload_Response>(
            "Cloud.ClientFileDownload#1", req);
        if (resp.Result != EResult.OK) { Err($"ClientFileDownload: {resp.Result}"); exitCode = 1; return; }
        var b = resp.Body;
        if (string.IsNullOrEmpty(b.url_host)) { Err("no download URL returned — file may not exist in the cloud"); exitCode = 1; return; }

        var url = $"{(b.use_https ? "https" : "http")}://{b.url_host}{b.url_path}";
        using var http = new HttpClient();
        using var httpResp = await http.GetAsync(url);
        if (!httpResp.IsSuccessStatusCode) { Err($"download HTTP {(int)httpResp.StatusCode}"); exitCode = 1; return; }
        var bytes = await httpResp.Content.ReadAsByteArrayAsync();
        // The CDN stores files zipped whenever that's smaller than the raw
        // file (file_size < raw_file_size); small/incompressible files come
        // back as-is. A real client unzips transparently, so we must too —
        // detected by the standard local-file-header magic rather than just
        // comparing sizes, since a raw file can coincidentally be zip-sized.
        if (bytes.Length >= 4 && bytes[0] == 0x50 && bytes[1] == 0x4B && bytes[2] == 0x03 && bytes[3] == 0x04)
        {
            using var zipStream = new MemoryStream(bytes);
            using var archive = new System.IO.Compression.ZipArchive(zipStream, System.IO.Compression.ZipArchiveMode.Read);
            if (archive.Entries.Count != 1) { Err($"expected 1 zip entry, found {archive.Entries.Count}"); exitCode = 1; return; }
            using var entryStream = archive.Entries[0].Open();
            using var outStream = new MemoryStream();
            await entryStream.CopyToAsync(outStream);
            bytes = outStream.ToArray();
        }

        if (b.raw_file_size > 0 && bytes.Length != b.raw_file_size)
        {
            Err($"downloaded {bytes.Length} bytes, expected {b.raw_file_size} — refusing to write");
            exitCode = 1; return;
        }
        await File.WriteAllBytesAsync(cloudLocalPath, bytes);
        Console.Out.Write("{\"bytes\":" + bytes.Length + ",\"timeStamp\":" + b.time_stamp + "}");
        exitCode = 0;
    }

    // Upload is the risky direction — this writes to the account's real cloud
    // save. Sequence confirmed against a real Steam client's own captured
    // traffic: BeginAppUploadBatch opens a batch for this file before anything
    // else, its batch_id must be threaded into ClientBeginFileUpload (or the
    // CDN URL it hands back is issued but never validates), then per file:
    // PUT bytes → ExternalStorageTransferReport (telemetry, best-effort) →
    // ClientCommitFileUpload → and finally CompleteAppUploadBatchBlocking
    // closes the batch.
    static async Task CloudUpload()
    {
        if (!File.Exists(cloudLocalPath)) { Err("local file not found: " + cloudLocalPath); exitCode = 1; return; }
        var bytes = await File.ReadAllBytesAsync(cloudLocalPath);
        var sha = SHA1.HashData(bytes);
        var timeStamp = (ulong)DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        var batchId = await CloudBeginUploadBatch(cloudFilename);
        if (batchId == 0) { exitCode = 1; return; }

        var beginReq = new CCloud_ClientBeginFileUpload_Request
        {
            appid = appId,
            file_size = (uint)bytes.Length,
            raw_file_size = (uint)bytes.Length,
            file_sha = sha,
            time_stamp = timeStamp,
            filename = cloudFilename,
            can_encrypt = false,
            cell_id = cellId,
            upload_batch_id = batchId,
        };
        var beginResp = await unifiedMessages.SendMessage<CCloud_ClientBeginFileUpload_Request, CCloud_ClientBeginFileUpload_Response>(
            "Cloud.ClientBeginFileUpload#1", beginReq);
        if (beginResp.Result != EResult.OK)
        {
            Err($"ClientBeginFileUpload: {beginResp.Result}");
            await CloudCompleteUploadBatch(batchId, ok: false);
            exitCode = 1; return;
        }

        bool ok = true;
        using (var http = new HttpClient())
        {
            foreach (var block in beginResp.Body.block_requests)
            {
                var url = $"{(block.use_https ? "https" : "http")}://{block.url_host}{block.url_path}";
                var body = block.explicit_body_data is { Length: > 0 }
                    ? block.explicit_body_data
                    : bytes.Skip((int)block.block_offset).Take((int)block.block_length).ToArray();
                // http_method uses ISteamHTTP's public HTTPMethod_t ordinals
                // (Steamworks SDK isteamhttp.h) — 4 is PUT.
                var httpMethod = block.http_method == 4 ? HttpMethod.Put : HttpMethod.Post;
                var httpReq = new HttpRequestMessage(httpMethod, url) { Content = new ByteArrayContent(body) };
                // The signed CDN URL is signed against an empty Content-Type;
                // Steam's own request_headers nonetheless list one — sending it
                // here makes the CDN recompute a different signature and reject
                // the request, so it's deliberately dropped.
                foreach (var h in block.request_headers)
                    if (!h.name.Equals("Content-Type", StringComparison.OrdinalIgnoreCase))
                        httpReq.Headers.TryAddWithoutValidation(h.name, h.value);
                var started = DateTime.UtcNow;
                HttpResponseMessage? blockResp = null;
                string? httpError = null;
                try { blockResp = await http.SendAsync(httpReq); }
                catch (Exception ex) { httpError = ex.Message; }
                var durationMs = (uint)(DateTime.UtcNow - started).TotalMilliseconds;

                var success = blockResp?.IsSuccessStatusCode == true;
                unifiedMessages.SendNotification("Cloud.ExternalStorageTransferReport#1", new CCloud_ExternalStorageTransferReport_Notification
                {
                    host = block.url_host,
                    path = block.url_path,
                    is_upload = true,
                    success = success,
                    http_status_code = blockResp != null ? (uint)blockResp.StatusCode : 0,
                    bytes_expected = (ulong)body.Length,
                    bytes_actual = success ? (ulong)body.Length : 0,
                    duration_ms = durationMs,
                    cellid = cellId,
                });

                if (!success)
                {
                    var errBody = blockResp != null ? await blockResp.Content.ReadAsStringAsync() : httpError;
                    Err($"upload block HTTP {(blockResp != null ? (int)blockResp.StatusCode : -1)}: {errBody}");
                    ok = false;
                    break;
                }
            }
        }

        var commitReq = new CCloud_ClientCommitFileUpload_Request
        {
            transfer_succeeded = ok,
            appid = appId,
            file_sha = sha,
            filename = cloudFilename,
        };
        var commitResp = await unifiedMessages.SendMessage<CCloud_ClientCommitFileUpload_Request, CCloud_ClientCommitFileUpload_Response>(
            "Cloud.ClientCommitFileUpload#1", commitReq);
        var committed = ok && commitResp.Result == EResult.OK && commitResp.Body.file_committed;

        await CloudCompleteUploadBatch(batchId, ok: committed);
        unifiedMessages.SendNotification("Cloud.SignalAppExitSyncDone#1", new CCloud_AppExitSyncDone_Notification
        {
            appid = appId,
            client_id = CloudClientId,
            uploads_completed = committed,
            uploads_required = true,
        });

        if (!committed)
        {
            Err($"upload not committed (transferOk={ok} result={commitResp.Result} committed={commitResp.Body?.file_committed})");
            exitCode = 1;
            return;
        }
        Console.Out.Write("{\"committed\":true,\"bytes\":" + bytes.Length + "}");
        exitCode = 0;
    }

    static async Task CloudDelete()
    {
        var req = new CCloud_ClientDeleteFile_Request { appid = appId, filename = cloudFilename, is_explicit_delete = true };
        var resp = await unifiedMessages.SendMessage<CCloud_ClientDeleteFile_Request, CCloud_ClientDeleteFile_Response>(
            "Cloud.ClientDeleteFile#1", req);
        if (resp.Result != EResult.OK) { Err($"ClientDeleteFile: {resp.Result}"); exitCode = 1; return; }
        Console.Out.Write("{\"deleted\":true}");
        exitCode = 0;
    }

    static void OnConnected(SteamClient.ConnectedCallback cb)
    {
        var details = new SteamUser.LogOnDetails
        {
            Username = accountName,
            AccessToken = refreshToken,
            ShouldRememberPassword = true,
        };
        // Experiment: does Steam's Cloud bucket/provider assignment (GCS vs
        // Azure) key off the session's declared client OS rather than anything
        // per-call? A real Windows client got Azure; our default (macOS, since
        // SteamKit2 auto-detects the actual host) gets GCS with signatures that
        // never validate. Only overridden for cloud-* modes pending that test.
        if (mode.StartsWith("cloud-", StringComparison.Ordinal)) details.ClientOSType = EOSType.Windows10;
        steamUser.LogOn(details);
    }

    static void OnLoggedOn(SteamUser.LoggedOnCallback cb)
    {
        if (cb.Result != EResult.OK) { Err($"logon failed: {cb.Result}/{cb.ExtendedResult}"); running = false; return; }
        // Register as playing the game — required before Steam accepts stat stores.
        var gp = new ClientMsgProtobuf<CMsgClientGamesPlayed>(EMsg.ClientGamesPlayed);
        gp.Body.games_played.Add(new CMsgClientGamesPlayed.GamePlayed { game_id = appId });
        steamClient.Send(gp);
        Thread.Sleep(1200);
        var get = new ClientMsgProtobuf<CMsgClientGetUserStats>(EMsg.ClientGetUserStats);
        get.Body.game_id = appId;
        get.Body.steam_id_for_user = steamId;
        get.Body.schema_local_version = -1;
        get.Body.crc_stats = 0;
        steamClient.Send(get);
    }

    class StatsHandler : ClientMsgHandler
    {
        public override void HandleMsg(IPacketMsg p)
        {
            if (p.MsgType == EMsg.ClientGetUserStatsResponse) OnGetStats(p);
            else if (p.MsgType == EMsg.ClientStoreUserStatsResponse) OnStoreStats(p);
        }
    }

    static void OnGetStats(IPacketMsg packetMsg)
    {
        var resp = new ClientMsgProtobuf<CMsgClientGetUserStatsResponse>(packetMsg);
        var statValues = resp.Body.stats.ToDictionary(s => s.stat_id, s => s.stat_value);
        var achs = ParseSchema(resp.Body.schema);
        foreach (var a in achs)
        {
            uint cur = statValues.TryGetValue(a.Stat, out var v) ? v : 0;
            a.Unlocked = (cur & (1u << a.Bit)) != 0;
        }

        if (mode == "view")
        {
            Console.Out.Write(ToJson(achs));
            exitCode = 0; running = false; return;
        }

        if (mode == "schema")
        {
            // gbe_fork's steam_settings/achievements.json format — WITHOUT this the
            // emulator doesn't know these achievements exist and silently ignores
            // the game's SetAchievement() calls, so nothing ever gets recorded.
            Console.Out.Write(ToGbeSchema(achs));
            exitCode = 0; running = false; return;
        }

        // unlock mode
        var target = unlockName != null
            ? achs.FirstOrDefault(a => a.Name == unlockName)
            : achs.OrderBy(a => a.Stat).ThenBy(a => a.Bit).FirstOrDefault(a => !a.Unlocked);
        if (target == null) { Err(unlockName != null ? $"'{unlockName}' not found" : "no locked achievements"); exitCode = 3; running = false; return; }
        if (target.Unlocked) { Err($"'{target.Name}' already unlocked"); Console.Out.Write("{\"unlocked\":\"" + target.Name + "\",\"alreadyUnlocked\":true}"); exitCode = 0; running = false; return; }

        uint curVal = statValues.TryGetValue(target.Stat, out var cv) ? cv : 0;
        var store = new ClientMsgProtobuf<CMsgClientStoreUserStats2>(EMsg.ClientStoreUserStats2);
        store.Body.game_id = appId;
        store.Body.settor_steam_id = steamId;
        store.Body.settee_steam_id = steamId;
        store.Body.crc_stats = resp.Body.crc_stats;
        store.Body.explicit_reset = false;
        store.Body.stats.Add(new CMsgClientStoreUserStats2.Stats { stat_id = target.Stat, stat_value = curVal | (1u << target.Bit) });
        unlockName = target.Name; // for the response line
        Err($"unlocking {target.Name} (stat {target.Stat} bit {target.Bit})…");
        steamClient.Send(store);
    }

    static void OnStoreStats(IPacketMsg packetMsg)
    {
        var resp = new ClientMsgProtobuf<CMsgClientStoreUserStatsResponse>(packetMsg);
        bool ok = resp.Body.eresult == (int)EResult.OK;
        Console.Out.Write("{\"unlocked\":\"" + unlockName + "\",\"result\":\"" + (EResult)resp.Body.eresult + "\",\"ok\":" + (ok ? "true" : "false") + "}");
        exitCode = ok ? 0 : 1;
        running = false;
    }

    // ── achievement model + schema parse ───────────────────────────────
    class Ach { public string Name=""; public uint Stat; public int Bit; public string Display=""; public string Desc=""; public bool Hidden; public bool Unlocked; }

    static List<Ach> ParseSchema(byte[] schema)
    {
        var list = new List<Ach>();
        if (schema == null || schema.Length == 0) return list;
        int pos = 0;
        var root = ReadKV(schema, ref pos);
        foreach (var app in root.Map.Values.OfType<KV>())
        {
            if (app.Map.GetValueOrDefault("stats") is not KV stats) continue;
            foreach (var (statKey, statV) in stats.Map)
            {
                if (statV is not KV statObj || !uint.TryParse(statKey, out var statId)) continue;
                if (statObj.Map.GetValueOrDefault("bits") is not KV bits) continue;
                foreach (var (bitKey, bitV) in bits.Map)
                {
                    if (bitV is not KV bo || !int.TryParse(bitKey, out var bitIdx)) continue;
                    var a = new Ach { Stat = statId, Bit = bitIdx };
                    a.Name = bo.Map.GetValueOrDefault("name") as string ?? "";
                    if (bo.Map.GetValueOrDefault("display") is KV disp)
                    {
                        if (disp.Map.GetValueOrDefault("name") is KV dn) a.Display = dn.Map.GetValueOrDefault("english") as string ?? "";
                        if (disp.Map.GetValueOrDefault("desc") is KV dd) a.Desc = dd.Map.GetValueOrDefault("english") as string ?? "";
                        a.Hidden = (disp.Map.GetValueOrDefault("hidden") as string) == "1";
                    }
                    if (!string.IsNullOrEmpty(a.Name)) list.Add(a);
                }
            }
        }
        return list;
    }

    static string ToJson(List<Ach> achs)
    {
        var sb = new StringBuilder("[");
        for (int i = 0; i < achs.Count; i++)
        {
            var a = achs[i];
            if (i > 0) sb.Append(',');
            sb.Append('{')
              .Append("\"apiname\":").Append(JStr(a.Name)).Append(',')
              .Append("\"name\":").Append(JStr(a.Display)).Append(',')
              .Append("\"description\":").Append(JStr(a.Desc)).Append(',')
              .Append("\"hidden\":").Append(a.Hidden ? "true" : "false").Append(',')
              .Append("\"achieved\":").Append(a.Unlocked ? "1" : "0")
              .Append('}');
        }
        return sb.Append(']').ToString();
    }

    // Emit the achievement schema in gbe_fork's expected steam_settings format.
    static string ToGbeSchema(List<Ach> achs)
    {
        var sb = new StringBuilder("[");
        for (int i = 0; i < achs.Count; i++)
        {
            var a = achs[i];
            if (i > 0) sb.Append(',');
            sb.Append('{')
              .Append("\"name\":").Append(JStr(a.Name)).Append(',')
              .Append("\"displayName\":").Append(JStr(a.Display)).Append(',')
              .Append("\"description\":").Append(JStr(a.Desc)).Append(',')
              .Append("\"hidden\":").Append(JStr(a.Hidden ? "1" : "0"))
              .Append('}');
        }
        return sb.Append(']').ToString();
    }

    static string JStr(string s)
    {
        var sb = new StringBuilder("\"");
        foreach (var c in s)
            sb.Append(c switch { '"' => "\\\"", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t", _ => c.ToString() });
        return sb.Append('"').ToString();
    }

    class KV { public Dictionary<string, object> Map = new(); }

    static KV ReadKV(byte[] b, ref int pos)
    {
        var node = new KV();
        while (pos < b.Length)
        {
            byte type = b[pos++];
            if (type == 0x08) break;
            string key = ReadCStr(b, ref pos);
            switch (type)
            {
                case 0x00: node.Map[key] = ReadKV(b, ref pos); break;
                case 0x01: node.Map[key] = ReadCStr(b, ref pos); break;
                case 0x02: case 0x03: pos += 4; break;
                case 0x07: case 0x0B: pos += 8; break;
                default: pos += 4; break;
            }
        }
        return node;
    }

    static string ReadCStr(byte[] b, ref int pos)
    {
        int start = pos;
        while (pos < b.Length && b[pos] != 0) pos++;
        string s = Encoding.UTF8.GetString(b, start, pos - start);
        pos++;
        return s;
    }

    static void Err(string m) => Console.Error.WriteLine("[relay] " + m);

    static string Extract(string json, string key)
    {
        var n = "\"" + key + "\"";
        var i = json.IndexOf(n); if (i < 0) return "";
        i = json.IndexOf(':', i + n.Length); if (i < 0) return "";
        i++;
        while (i < json.Length && (json[i] == ' ' || json[i] == '"')) i++;
        var e = i;
        while (e < json.Length && json[e] != '"' && json[e] != ',' && json[e] != '}') e++;
        return json.Substring(i, e - i).Trim();
    }
}

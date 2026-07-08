using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using System.Threading;
using SteamKit2;
using SteamKit2.Internal;

// Mist Steam-stats relay. Uses Mist's single persistent session token to talk to
// Steam's client protocol (no Steam client, no Web API key) for achievements.
//
//   relay <session.json> <appid>                 → print achievements as JSON (viewing)
//   relay <session.json> <appid> --unlock <name> → unlock one achievement
//   relay <session.json> <appid> --unlock-auto   → unlock first currently-locked one
//
// session.json is Mist's steam_session.json (accountName, steamID, refreshToken).
// Exit 0 = success. All human status goes to stderr; stdout is JSON only.

class Program
{
    static SteamClient steamClient = null!;
    static CallbackManager manager = null!;
    static SteamUser steamUser = null!;

    static string accountName = "", refreshToken = "";
    static ulong steamId = 0;
    static uint appId = 0;
    static string mode = "view";      // view | unlock
    static string? unlockName = null;  // specific name, or null for --unlock-auto
    static bool running = true;
    static int exitCode = 1;

    static int Main(string[] args)
    {
        if (args.Length < 2) { Err("usage: <session.json> <appid> [--unlock <name> | --unlock-auto]"); return 2; }
        var json = File.ReadAllText(args[0]);
        accountName = Extract(json, "accountName");
        refreshToken = Extract(json, "refreshToken");
        steamId = ulong.TryParse(Extract(json, "steamID"), out var s) ? s : 0;
        appId = uint.Parse(args[1]);
        if (args.Length >= 3 && args[2] == "--unlock") { mode = "unlock"; unlockName = args.Length >= 4 ? args[3] : null; }
        else if (args.Length >= 3 && args[2] == "--unlock-auto") { mode = "unlock"; unlockName = null; }
        else if (args.Length >= 3 && args[2] == "--schema") { mode = "schema"; }

        if (string.IsNullOrEmpty(refreshToken)) { Err("no refreshToken in session"); return 2; }

        steamClient = new SteamClient();
        manager = new CallbackManager(steamClient);
        steamUser = steamClient.GetHandler<SteamUser>()!;
        steamClient.AddHandler(new StatsHandler());

        manager.Subscribe<SteamClient.ConnectedCallback>(OnConnected);
        manager.Subscribe<SteamClient.DisconnectedCallback>(_ => running = false);
        manager.Subscribe<SteamUser.LoggedOnCallback>(OnLoggedOn);

        Err($"connecting as {accountName} for app {appId} ({mode})…");
        steamClient.Connect();
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (running && DateTime.UtcNow < deadline)
            manager.RunWaitCallbacks(TimeSpan.FromMilliseconds(200));
        try { steamUser.LogOff(); } catch { }
        return exitCode;
    }

    static void OnConnected(SteamClient.ConnectedCallback cb) =>
        steamUser.LogOn(new SteamUser.LogOnDetails
        {
            Username = accountName,
            AccessToken = refreshToken,
            ShouldRememberPassword = true,
        });

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

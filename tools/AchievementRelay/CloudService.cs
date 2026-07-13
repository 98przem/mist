using SteamKit2;
using SteamKit2.Internal;

// SteamKit2 ships generated UnifiedService proxies for services it officially
// supports (Player, FamilyGroups, ...) — Cloud isn't one of them, so calling
// SteamUnifiedMessages.SendMessage("Cloud.X#1", ...) directly sends the
// request fine, but the reply gets silently dropped: SteamUnifiedMessages.
// HandleMsg looks up the service name in a dictionary populated only by
// CreateService<T>(), and drops anything unregistered before it ever reaches
// an AsyncJob. This is that missing registration — a minimal hand-written
// version of what a generated proxy class looks like (see SteamKit2's own
// SteamMsgPlayer.cs for the pattern this mirrors), routing only the methods
// this relay actually calls.
public class CloudService : SteamUnifiedMessages.UnifiedService
{
    public override string ServiceName { get; } = "Cloud";

    public override void HandleResponseMsg(string methodName, PacketClientMsgProtobuf packetMsg)
    {
        // SteamUnifiedMessages.ServiceMethodResponse<T> only surfaces eresult,
        // discarding the header's free-text error_message — read it here while
        // we still have the raw packet, to see *why* a call is rejected.
        // Body type here is irrelevant — CCloud_AppSessionResume_Response has no
        // fields, so it parses trivially regardless of the actual response
        // shape; we only want the header this constructor extracts alongside it.
        var proto = new ClientMsgProtobuf<CCloud_AppSessionResume_Response>(packetMsg).ProtoHeader;
        if (proto.eresult != (int)EResult.OK && !string.IsNullOrEmpty(proto.error_message))
            System.Console.Error.WriteLine($"[relay] {ServiceName}.{methodName} eresult={proto.eresult} error_message=\"{proto.error_message}\"");

        switch (methodName)
        {
            case "GetAppFileChangelist":
                PostResponseMsg<CCloud_GetAppFileChangelist_Response>(packetMsg);
                break;
            case "ClientGetAppQuotaUsage":
                PostResponseMsg<CCloud_ClientGetAppQuotaUsage_Response>(packetMsg);
                break;
            case "ClientBeginFileUpload":
                PostResponseMsg<CCloud_ClientBeginFileUpload_Response>(packetMsg);
                break;
            case "ClientCommitFileUpload":
                PostResponseMsg<CCloud_ClientCommitFileUpload_Response>(packetMsg);
                break;
            case "ClientFileDownload":
                PostResponseMsg<CCloud_ClientFileDownload_Response>(packetMsg);
                break;
            case "ClientDeleteFile":
                PostResponseMsg<CCloud_ClientDeleteFile_Response>(packetMsg);
                break;
            case "SuspendAppSession":
                PostResponseMsg<CCloud_AppSessionSuspend_Response>(packetMsg);
                break;
            case "ResumeAppSession":
                PostResponseMsg<CCloud_AppSessionResume_Response>(packetMsg);
                break;
            case "SignalAppLaunchIntent":
                PostResponseMsg<CCloud_AppLaunchIntent_Response>(packetMsg);
                break;
            case "BeginAppUploadBatch":
                PostResponseMsg<CCloud_BeginAppUploadBatch_Response>(packetMsg);
                break;
            case "CompleteAppUploadBatchBlocking":
                PostResponseMsg<CCloud_CompleteAppUploadBatch_Response>(packetMsg);
                break;
        }
    }

    public override void HandleNotificationMsg(string methodName, PacketClientMsgProtobuf packetMsg) { }
}

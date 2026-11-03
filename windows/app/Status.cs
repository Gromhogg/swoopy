using System.Text.Json;

namespace PitchShift;

// An app that has sound right now (from the engine's list).
public sealed record SoundSource(string Exe, string Name, int Pid, bool Playing);

// A microphone (from the engine's list). Id "" = none.
public sealed record Mic(string Id, string Name, bool IsDefault)
{
    public override string ToString() => Name;
}

// One ticked app as the engine sees it.
public sealed record WatchedApp(string Exe, bool Running);

// What the engine is doing (read from ps_status_json about 4 times a second).
public sealed record EngineStatus
{
    public string MusicState { get; init; } = "off";   // off, waiting, running, error
    public string MusicError { get; init; } = "";
    public IReadOnlyList<WatchedApp> MusicApps { get; init; } = Array.Empty<WatchedApp>();
    public string MusicSpeaker { get; init; } = "";    // the speakers the shifted sound plays to
    public string VoiceState { get; init; } = "off";   // off, idle, running, no_mic, mic_denied, cable_missing, restart_needed, error
    public string VoiceError { get; init; } = "";
    public bool? CablePresent { get; init; }            // null = not known yet
    public bool CableRestartNeeded { get; init; }       // setup put VB-CABLE in, but Windows needs a restart
                                                        // (false when VB-Audio's window was closed without installing)
    public bool InUse { get; init; }                    // a call app is using Swoopy Mic
    public string TestState { get; init; } = "idle";    // idle, recording, playing
    public int TestSecondsLeft { get; init; }

    public static readonly EngineStatus Empty = new();
}

// The state button at the bottom of "Your voice" (only one at a time, only when needed).
public enum VoiceAction { None, Restart, Repair, AllowMic }

public static class EngineJson
{
    public static EngineStatus Status(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return EngineStatus.Empty;
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            var status = new EngineStatus();
            if (root.ValueKind != JsonValueKind.Object) return status;
            if (root.TryGetProperty("music", out var music) && music.ValueKind == JsonValueKind.Object)
            {
                var apps = new List<WatchedApp>();
                if (music.TryGetProperty("apps", out var list) && list.ValueKind == JsonValueKind.Array)
                    foreach (var a in list.EnumerateArray())
                        apps.Add(new WatchedApp(Text(a, "exe"), Bool(a, "running")));
                status = status with
                {
                    MusicState = Text(music, "state", "off"),
                    MusicError = Text(music, "error"),
                    MusicApps = apps,
                    MusicSpeaker = Text(music, "speaker"),
                };
            }
            if (root.TryGetProperty("voice", out var voice) && voice.ValueKind == JsonValueKind.Object)
            {
                bool? cable = null;
                var restart = false;
                if (voice.TryGetProperty("cable", out var c) && c.ValueKind == JsonValueKind.Object)
                {
                    cable = Bool(c, "present");
                    restart = Bool(c, "restart_needed");
                }
                var testState = "idle";
                var left = 0;
                if (voice.TryGetProperty("test", out var t) && t.ValueKind == JsonValueKind.Object)
                {
                    testState = Text(t, "state", "idle");
                    if (t.TryGetProperty("seconds_left", out var s) && s.ValueKind == JsonValueKind.Number) left = s.GetInt32();
                }
                status = status with
                {
                    VoiceState = Text(voice, "state", "off"),
                    VoiceError = Text(voice, "error"),
                    CablePresent = cable,
                    CableRestartNeeded = restart,
                    InUse = Bool(voice, "in_use"),
                    TestState = testState,
                    TestSecondsLeft = left,
                };
            }
            return status;
        }
        catch (JsonException)
        {
            return EngineStatus.Empty;
        }
    }

    public static List<SoundSource> Sources(string? json)
    {
        var list = new List<SoundSource>();
        foreach (var e in Array(json))
        {
            var exe = Text(e, "exe");
            if (exe.Length == 0) continue;
            var name = Text(e, "name");
            var pid = e.TryGetProperty("pid", out var p) && p.ValueKind == JsonValueKind.Number ? p.GetInt32() : 0;
            list.Add(new SoundSource(exe, name.Length > 0 ? name : Settings.NameFromPath(exe), pid, Bool(e, "playing")));
        }
        return list;
    }

    public static List<Mic> Mics(string? json)
    {
        var list = new List<Mic>();
        foreach (var e in Array(json))
        {
            var id = Text(e, "id");
            if (id.Length > 0) list.Add(new Mic(id, Text(e, "name", "Microphone"), Bool(e, "default")));
        }
        return list;
    }

    static List<JsonElement> Array(string? json)
    {
        var items = new List<JsonElement>();
        if (string.IsNullOrWhiteSpace(json)) return items;
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return items;
            foreach (var e in doc.RootElement.EnumerateArray())
                if (e.ValueKind == JsonValueKind.Object) items.Add(e.Clone());
        }
        catch (JsonException)
        {
        }
        return items;
    }

    static string Text(JsonElement e, string name, string fallback = "") =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? fallback : fallback;

    static bool Bool(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.True;
}

public static class PickerText
{
    // What the "What you hear" button shows.
    public static string HearTitle(bool all, IReadOnlyList<string> names) =>
        all ? "All sound" : names.Count == 0 ? "Choose apps" : string.Join(", ", names);

    // Which mic the picker shows as chosen: the saved one if it's there, else Windows' default, else the first.
    public static Mic? ChosenMic(IReadOnlyList<Mic> mics, string? savedId)
    {
        if (mics.Count == 0) return null;
        return mics.FirstOrDefault(m => m.Id == savedId)
            ?? mics.FirstOrDefault(m => m.IsDefault)
            ?? mics[0];
    }

    // The one state button "Your voice" may need.
    public static VoiceAction Action(EngineStatus status, bool restartNeeded)
    {
        if (status.CablePresent == false)
            return restartNeeded || status.CableRestartNeeded ? VoiceAction.Restart : VoiceAction.Repair;
        if (status.VoiceState == "restart_needed") return VoiceAction.Restart;
        if (status.VoiceState == "cable_missing") return VoiceAction.Repair;
        if (status.VoiceState == "mic_denied") return VoiceAction.AllowMic;
        return VoiceAction.None;
    }

    public static string ActionTitle(VoiceAction action) => action switch
    {
        VoiceAction.Restart => "Restart to finish setup",
        VoiceAction.Repair => "Repair Swoopy Mic",
        VoiceAction.AllowMic => "Allow microphone",
        _ => "",
    };

    // The Test button: "Test", then a red "● 5…1" while recording, then "■ Stop" while playing back.
    public static string TestTitle(string testState, int secondsLeft) => testState switch
    {
        "recording" => $"● {Math.Max(1, secondsLeft)}",
        "playing" => "■ Stop",
        _ => "Test",
    };
}

using Xunit;

namespace PitchShift.Tests;

public class PickerTests
{
    [Fact]
    public void HearTitle()
    {
        Assert.Equal("All sound", PickerText.HearTitle(true, new[] { "Spotify" }));
        Assert.Equal("Choose apps", PickerText.HearTitle(false, Array.Empty<string>()));
        Assert.Equal("Spotify", PickerText.HearTitle(false, new[] { "Spotify" }));
        Assert.Equal("Spotify, Google Chrome", PickerText.HearTitle(false, new[] { "Spotify", "Google Chrome" }));
    }

    static readonly List<Mic> Mics = new()
    {
        new("a", "Microphone (Realtek)", false),
        new("b", "Headset Microphone", true),
        new("c", "USB Mic", false),
    };

    [Fact]
    public void ChosenMic()
    {
        Assert.Equal("c", PickerText.ChosenMic(Mics, "c")!.Id);       // the saved one
        Assert.Equal("b", PickerText.ChosenMic(Mics, "")!.Id);        // Windows' default
        Assert.Equal("b", PickerText.ChosenMic(Mics, "gone")!.Id);    // unplugged: the default
        Assert.Equal("a", PickerText.ChosenMic(Mics.Where(m => !m.IsDefault).ToList(), "gone")!.Id);
        Assert.Null(PickerText.ChosenMic(new List<Mic>(), "a"));
    }

    [Fact]
    public void VoiceActionButton()
    {
        var fine = new EngineStatus { CablePresent = true, VoiceState = "running" };
        Assert.Equal(VoiceAction.None, PickerText.Action(fine, restartNeeded: false));
        Assert.Equal(VoiceAction.None, PickerText.Action(EngineStatus.Empty, restartNeeded: true));  // not known yet
        Assert.Equal(VoiceAction.Repair, PickerText.Action(fine with { CablePresent = false }, false));
        Assert.Equal(VoiceAction.Restart, PickerText.Action(fine with { CablePresent = false }, true));
        // Setup put VB-CABLE in and Windows needs a restart (the engine says so) ...
        Assert.Equal(VoiceAction.Restart, PickerText.Action(fine with { CablePresent = false, CableRestartNeeded = true }, false));
        // ... but VB-Audio's window was closed without installing: Repair, not Restart.
        Assert.Equal(VoiceAction.Repair, PickerText.Action(fine with { CablePresent = false, CableRestartNeeded = false }, false));
        Assert.Equal(VoiceAction.Restart, PickerText.Action(fine with { VoiceState = "restart_needed" }, false));
        Assert.Equal(VoiceAction.Repair, PickerText.Action(fine with { VoiceState = "cable_missing" }, false));
        Assert.Equal(VoiceAction.AllowMic, PickerText.Action(fine with { VoiceState = "mic_denied" }, false));
        Assert.Equal("Repair Swoopy Mic", PickerText.ActionTitle(VoiceAction.Repair));
        Assert.Equal("Restart to finish setup", PickerText.ActionTitle(VoiceAction.Restart));
        Assert.Equal("Allow microphone", PickerText.ActionTitle(VoiceAction.AllowMic));
    }

    [Fact]
    public void TestButtonTitle()
    {
        Assert.Equal("Test", PickerText.TestTitle("idle", 0));
        Assert.Equal("\u25CF 5", PickerText.TestTitle("recording", 5));
        Assert.Equal("\u25CF 1", PickerText.TestTitle("recording", 0));
        Assert.Equal("\u25A0 Stop", PickerText.TestTitle("playing", 2));
    }
}

public class EngineJsonTests
{
    // The shape ps_status_json gives (see engine/api/engine_api.cpp, music.cpp, voice.cpp).
    const string Status = """
        {"version":"2.0.0-beta","started":true,"arch":"x64",
         "music":{"state":"waiting","error":"","mode":"apps",
                  "apps":[{"exe":"C:\\x\\Spotify.exe","running":false,"pid":0},{"exe":"C:\\x\\chrome.exe","running":true,"pid":42}],
                  "speaker":"Speakers (Realtek(R) Audio)","semitones":2.0,"quieted":0},
         "voice":{"state":"running","error":"","in_use":true,"mic":{"id":"m1","name":"Mic"},
                  "cable":{"present":true,"mic_name":"Swoopy Mic","feed_name":"Swoopy Mic Feed"},
                  "semitones":3.0,"natural":true,"test":{"state":"recording","seconds_left":4}}}
        """;

    [Fact]
    public void ReadsStatus()
    {
        var s = EngineJson.Status(Status);
        Assert.Equal("waiting", s.MusicState);
        Assert.Equal(2, s.MusicApps.Count);
        Assert.False(s.MusicApps[0].Running);
        Assert.True(s.MusicApps[1].Running);
        Assert.Equal("Speakers (Realtek(R) Audio)", s.MusicSpeaker);
        Assert.Equal("running", s.VoiceState);
        Assert.True(s.CablePresent);
        Assert.True(s.InUse);
        Assert.Equal("recording", s.TestState);
        Assert.Equal(4, s.TestSecondsLeft);
    }

    [Fact]
    public void StatusBeforeTheVoiceStarts()
    {
        var s = EngineJson.Status("""{"started":true,"music":{"state":"off"},"voice":{"state":"off"}}""");
        Assert.Equal("off", s.MusicState);
        Assert.Null(s.CablePresent);
        Assert.Equal("idle", s.TestState);
    }

    [Theory]
    [InlineData("")]
    [InlineData("{")]
    [InlineData("[]")]
    [InlineData("{\"started\":false}")]
    public void BrokenStatusIsEmpty(string json)
    {
        var s = EngineJson.Status(json);
        Assert.Equal("off", s.MusicState);
        Assert.Equal("off", s.VoiceState);
    }

    [Fact]
    public void ReadsSources()
    {
        var list = EngineJson.Sources("""
            [{"exe":"C:\\x\\Spotify.exe","name":"Spotify","pid":12,"playing":true},
             {"exe":"C:\\y\\game.exe","name":"","pid":13,"playing":false},
             {"name":"no exe"}]
            """);
        Assert.Equal(2, list.Count);
        Assert.Equal(new SoundSource(@"C:\x\Spotify.exe", "Spotify", 12, true), list[0]);
        Assert.Equal("game", list[1].Name);
        Assert.Empty(EngineJson.Sources("oops"));
    }

    [Fact]
    public void ReadsMics()
    {
        var list = EngineJson.Mics("""
            [{"id":"a","name":"Microphone (Realtek)","default":false},{"id":"b","name":"Headset","default":true},{"id":""}]
            """);
        Assert.Equal(2, list.Count);
        Assert.True(list[1].IsDefault);
        Assert.Equal("Headset", list[1].ToString());
        Assert.Empty(EngineJson.Mics(null));
    }
}

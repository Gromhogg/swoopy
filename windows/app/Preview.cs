using System.IO;

namespace PitchShift;

// For pictures of the window (used by the GitHub checks): shows a made-up state and makes no sound.
//   Swoopy.exe --preview hear-on,voice-on,cartoon --screenshot shot.png [--theme dark] [--scale 2] [--size 900x450]
// States: hear-on, voice-on, all, two-apps, waiting, cartoon, typing, hover, recording, playing, listening (in-use),
//         repair, restart, allow-mic, no-mic, menu, advanced (the "Advanced processing" switch on),
//         advanced-alert (the alert shown when turning it on).
sealed class Preview
{
    readonly HashSet<string> states;

    public Preview(string? list)
    {
        states = new HashSet<string>(
            (list ?? "").Split(new[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries),
            StringComparer.OrdinalIgnoreCase);
    }

    public bool Has(string state) => states.Contains(state);

    // Real programs on every Windows PC, so their icons show.
    static readonly (string Exe, string Name)[] SampleApps =
    {
        (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), @"Microsoft\Edge\Application\msedge.exe"), "Microsoft Edge"),
        (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe"), "Windows Explorer"),
        (Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "SndVol.exe"), "Volume Mixer"),
    };

    public Settings Settings()
    {
        var s = new Settings
        {
            HearOn = Has("hear-on"),
            VoiceOn = Has("voice-on"),
            HearSteps = 1,
            VoiceSteps = 15,
            VoiceNatural = !Has("cartoon"),
            HearAll = Has("all"),
            HearAdvanced = Has("advanced"),
        };
        if (!s.HearAll)
        {
            var count = Has("two-apps") ? 2 : 1;
            foreach (var (exe, name) in SampleApps.Take(count)) s.HearApps.Add(new HearApp { Exe = exe, Name = name });
        }
        return s;
    }

    public EngineStatus Status() => new()
    {
        MusicState = Has("hear-on") ? (Has("waiting") ? "waiting" : "running") : "off",
        VoiceState = Has("allow-mic") ? "mic_denied" : Has("voice-on") ? "running" : "off",
        CablePresent = !(Has("repair") || Has("restart")),
        InUse = Has("in-use") || Has("listening"),
        TestState = Has("recording") ? "recording" : Has("playing") ? "playing" : "idle",
        TestSecondsLeft = 3,
    };

    public bool RestartNeeded => Has("restart");

    public List<Mic> Mics() => Has("no-mic")
        ? new List<Mic>()
        : new List<Mic>
        {
            new("mic-1", "Microphone (Realtek(R) Audio)", true),
            new("mic-2", "Headset Microphone (G522 LIGHTSPEED)", false),
        };

    public List<SoundSource> Sources() =>
        SampleApps.Select((a, i) => new SoundSource(a.Exe, a.Name, 100 + i, i == 0)).ToList();
}

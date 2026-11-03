using System.Runtime.InteropServices;
using System.Text.Json;

namespace PitchShift;

// Calls into the sound engine (SwoopyEngine.dll, written in C++). See engine/api/pitchshift_engine.h.
// If the engine can't be loaded, the window still works; it just makes no sound.
static class Engine
{
    const string Dll = "SwoopyEngine.dll";

    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_version();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_init();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern void ps_shutdown();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_restore_all();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_list_sources_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_list_mics_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern IntPtr ps_status_json();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_music_start_all();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_music_set_apps([MarshalAs(UnmanagedType.LPUTF8Str)] string exePathsJson);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_music_stop();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_music_set_semitones(double halfSteps);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_music_set_advanced(int on);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_start([MarshalAs(UnmanagedType.LPUTF8Str)] string endpointId);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_stop();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_set_semitones(double halfSteps);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_set_formant(int natural);
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_test_start();
    [DllImport(Dll, CallingConvention = CallingConvention.Cdecl)] static extern int ps_voice_test_stop();

    static string Text(IntPtr p) => Marshal.PtrToStringUTF8(p) ?? "";

    // True once ps_init worked. Everything below does nothing until then.
    public static bool Ready { get; private set; }
    public static string Problem { get; private set; } = "";

    public static string Version
    {
        get
        {
            try { return Text(ps_version()); }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException) { return "missing"; }
        }
    }

    // Starts the engine. It also puts back app volumes and the default microphone left by a crash.
    public static bool Init()
    {
        try
        {
            Ready = ps_init() == 0;
            if (!Ready) Problem = "The sound engine didn't start.";
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            Problem = "The sound engine is missing: " + e.Message;
            Ready = false;
        }
        return Ready;
    }

    // Stops all sound and puts every app volume and the default microphone back.
    public static void Shutdown()
    {
        if (!Ready) return;
        Ready = false;
        ps_shutdown();
    }

    static void Call(Func<int> f)
    {
        if (Ready) f();
    }

    public static string StatusJson() => Ready ? Text(ps_status_json()) : "";
    public static string SourcesJson() => Ready ? Text(ps_list_sources_json()) : "[]";
    public static string MicsJson() => Ready ? Text(ps_list_mics_json()) : "[]";

    public static void HearAll() => Call(ps_music_start_all);
    public static void HearApps(IEnumerable<string> exePaths) => Call(() => ps_music_set_apps(JsonSerializer.Serialize(exePaths.ToArray())));
    public static void HearStop() => Call(ps_music_stop);
    public static void HearSteps(double halfSteps) => Call(() => ps_music_set_semitones(halfSteps));
    // "Advanced processing" (made for music): keeps the bass deep going up and the top bright going down.
    public static void HearAdvanced(bool on) => Call(() => ps_music_set_advanced(on ? 1 : 0));

    public static void VoiceStart(string micId) => Call(() => ps_voice_start(micId ?? ""));
    public static void VoiceStop() => Call(ps_voice_stop);
    public static void VoiceSteps(double halfSteps) => Call(() => ps_voice_set_semitones(halfSteps));
    public static void VoiceNatural(bool natural) => Call(() => ps_voice_set_formant(natural ? 1 : 0));
    public static void TestStart() => Call(ps_voice_test_start);
    public static void TestStop() => Call(ps_voice_test_stop);
}

/* Swoopy sound engine: the small C interface the window app (C#) calls.
   All text is UTF-8. Functions that return text return a pointer that stays valid until the
   next call of the same function on the same thread. Functions that return int give 0 for
   "worked" and a negative number for "didn't work". */
#ifndef PITCHSHIFT_ENGINE_H
#define PITCHSHIFT_ENGINE_H

#ifdef __cplusplus
extern "C" {
#endif

#if defined(PS_ENGINE_BUILD)
#define PS_API __declspec(dllexport)
#elif defined(PS_ENGINE_STATIC)
#define PS_API
#else
#define PS_API __declspec(dllimport)
#endif

PS_API const char* ps_version(void);

/* Call once at start. Puts back any app volumes left quiet by an earlier crash, and starts a
   small watchdog that puts them back if this program ends unexpectedly. */
PS_API int ps_init(void);
/* Stops everything and puts every app volume back. */
PS_API void ps_shutdown(void);
/* Puts back every app volume Swoopy lowered. Returns how many were fixed. */
PS_API int ps_restore_all(void);

/* JSON list of apps playing sound: [{"exe":..,"name":..,"pid":..,"playing":true}, ...] */
PS_API const char* ps_list_sources_json(void);
/* JSON list of microphones (not the virtual cable): [{"id":..,"name":..,"default":true}, ...] */
PS_API const char* ps_list_mics_json(void);
/* JSON with what the engine is doing right now: "music" (state, apps, speaker = the speakers it plays to,
   advanced = Advanced processing on, counts) and "voice" (state, in_use, mic, cable {present, restart_needed,
   mic_name}, test, counts). */
PS_API const char* ps_status_json(void);

/* What you hear. mode 0 = process `pid` and everything it started, mode 1 = all sound. */
PS_API int ps_music_start(int mode, int pid);
/* What you hear: all sound (everything except Swoopy). */
PS_API int ps_music_start_all(void);
/* What you hear: the ticked apps, as a JSON list of program files ["C:\\...\\Spotify.exe", ...].
   Apps that aren't open join as soon as they start (and again after they restart). */
PS_API int ps_music_set_apps(const char* exe_paths_json);
PS_API int ps_music_stop(void);
PS_API int ps_music_set_semitones(double half_steps);
/* What you hear: "Advanced processing" on (1) or off (0). Made for music: going up, the bass stays deep;
   going down, the top stays bright. Switching makes a new player (a short pause). The status shows it as
   music.advanced (and music.advanced_engine while it plays: range, latency_ms, heard, underruns, ...). */
PS_API int ps_music_set_advanced(int on);

/* Your voice. endpoint_id = a microphone id from ps_list_mics_json, or "" for the default.
   While it's on, Swoopy Mic is the Windows default microphone (given back when it's off). */
PS_API int ps_voice_start(const char* endpoint_id);
PS_API int ps_voice_stop(void);
PS_API int ps_voice_set_semitones(double half_steps);
PS_API int ps_voice_set_formant(int natural); /* 1 = Natural, 0 = Cartoon */
PS_API int ps_voice_test_start(void);
PS_API int ps_voice_test_stop(void);

#ifdef __cplusplus
}
#endif

#endif

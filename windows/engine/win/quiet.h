// Makes an app's own sound very quiet (so only the shifted copy is heard) and, above all,
// always puts it back.
//
// How it stays safe:
//   - Before any change, the original volumes go into a restore list
//     (%LOCALAPPDATA%\Pitch Shift\restore.json), so a later start can fix things after a crash.
//   - Windows remembers an app's volume when the app quits, so an app that quit while quiet would
//     start quiet next time. Apps on the list are fixed as soon as they play again, and their
//     remembered volume in the registry is put back too.
//   - While anything is quiet, a "RunOnce" entry runs "SwoopyTool restore" at the next sign-in.
#pragma once
#include "win/sessions.h"

#include <chrono>
#include <functional>
#include <map>
#include <mutex>
#include <nlohmann/json.hpp>
#include <set>
#include <string>
#include <vector>

namespace ps {

constexpr float kQuietLevel = 0.001f;  // -60 dB; the captured sound is boosted by 1000 to match
constexpr float kNudgeLevel = 0.000999f;  // written for a moment to make Windows apply the quiet volume (see nudge)

struct QuietEntry {
    std::wstring exe;             // program path; new sessions of the same program are fixed too
    std::wstring native_exe;      // the same path as Windows' sound settings store it (\Device\...)
    DWORD pid = 0;
    std::wstring instance_id;
    std::vector<float> original;  // channel volumes before we changed them
    float quiet_level = kQuietLevel;
};

std::wstring restore_file_path();  // %LOCALAPPDATA%\Pitch Shift\restore.json

bool save_restore_list(const std::wstring& path, const std::vector<QuietEntry>& entries);
std::vector<QuietEntry> load_restore_list(const std::wstring& path);

// Writes the session's current volumes to the restore list, then lowers every channel to `level`.
HRESULT quiet_session(const Session& session, float level, const std::wstring& path);

// Puts back the volume Windows remembered for a program that quit while quiet (in the registry).
// Returns how many remembered volumes were fixed.
int fix_remembered_volume(const QuietEntry& entry);

struct RestoreResult {
    int restored = 0;   // running sessions put back
    int remembered = 0; // remembered (registry) volumes put back
    int failed = 0;
    int pending = 0;    // listed apps not playing now, kept on the list
    nlohmann::json log = nlohmann::json::array();
};

// Puts back every listed app that is still quiet (running or remembered), then deletes the list
// if nothing is left to do.
RestoreResult restore_all(const std::wstring& path);

// The RunOnce safety net: runs `command` at the next sign-in. Empty command removes it.
void set_restore_at_sign_in(const std::wstring& command);
// Sets the safety net while anything needs putting back (quiet apps or the default microphone),
// and removes it when nothing does.
void update_sign_in_safety_net(const std::wstring& command, bool busy = false);

// Keeps a set of sessions quiet while Swoopy runs.
class QuietKeeper {
public:
    explicit QuietKeeper(std::wstring list_path, std::wstring restore_command = L"");
    ~QuietKeeper();

    // Quiets every session `wanted` says yes to, and puts back every session we quieted that
    // isn't wanted any more. Also fixes listed apps that came back quiet from an earlier run.
    void update(const std::vector<Session>& sessions, const std::function<bool(const Session&)>& wanted);
    // Puts everything back.
    void restore_everything();

    int quieted() const;
    const std::wstring& list_path() const { return path_; }
    // How often an app that should be quiet could not be made quiet, and why the last time (empty: never).
    int failures() const;
    std::string last_failure() const;

    // Call when sound that wasn't quieted still arrives. Windows sometimes misses a volume change made just as an
    // app starts playing: the session then says 0.001, but the app plays on at full volume. So the sessions quieted
    // in the last few seconds get a slightly different quiet volume, which Windows does apply, and the next update()
    // writes the exact one back.
    void nudge();
    int nudges() const;  // how often a session was nudged

private:
    void sync_sign_in_entry();

    std::wstring path_, restore_command_;
    mutable std::mutex lock_;
    std::map<std::wstring, Session> ours_;  // by session instance id
    std::map<std::wstring, std::chrono::steady_clock::time_point> gone_;  // quieted, then the app quit
    int failures_ = 0;
    std::string last_failure_;
    std::map<std::wstring, std::chrono::steady_clock::time_point> quieted_at_;  // when we quieted each session
    std::set<std::wstring> nudged_;  // at kNudgeLevel now; back to kQuietLevel on the next update()
    int nudges_ = 0;
};

}  // namespace ps

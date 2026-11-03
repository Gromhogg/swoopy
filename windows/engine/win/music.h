// "What you hear": records the chosen apps (each with its helper processes) or all sound,
// changes the pitch, and plays it to the default speakers. The apps' own sound is made very quiet
// (see quiet.h) and the recording is boosted back up, so only the shifted copy is heard.
// Several apps can be chosen: each is recorded on its own and the recordings are mixed.
// "Advanced processing" (set_advanced) swaps Rubber Band alone for the Mac app's Advanced engine (made for music:
// keeps the bass deep going up and the top bright going down). It runs on its own thread (like on the Mac), so the
// recording threads only hand the sound over.
#pragma once
#include "dsp/advanced_shifter.h"
#include "dsp/booster.h"
#include "dsp/cushion.h"
#include "dsp/music_shifter.h"
#include "dsp/ring.h"
#include "win/capture.h"
#include "win/quiet.h"
#include "win/render.h"

#include <atomic>
#include <chrono>
#include <map>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <string>
#include <thread>
#include <vector>

namespace ps {

class MusicPath {
public:
    MusicPath(std::wstring restore_list, std::wstring restore_command);
    ~MusicPath();
    MusicPath(const MusicPath&) = delete;
    MusicPath& operator=(const MusicPath&) = delete;

    void start_all();                                     // everything except Swoopy itself
    void start_apps(const std::vector<std::wstring>& exe_paths);  // apps by program file; each joins when it opens
    void start_pids(const std::vector<DWORD>& pids);      // processes and everything they started
    void start_pid(DWORD pid) { start_pids({pid}); }
    void stop();
    void set_semitones(double value);
    double semitones() const { return semitones_; }
    // Advanced processing on or off. Switching makes a new player (the sound pauses for a moment, as on the Mac).
    // Like the Mac: it's made for -12..+12 (less delay); going past that makes a new one with more delay.
    void set_advanced(bool on);
    bool advanced() const { return advanced_; }

    nlohmann::json status() const;
    void reset_counts();
    // Checks only: turn off writing the quiet volume again when loud sound still arrives (see tick), to see how
    // often it is needed.
    void set_nudging(bool on) { nudging_ = on; }

    // Cushion sizes (same as the Mac app): start at 50 ms, never more than 150 ms.
    static constexpr double kStartMs = 50;
    static constexpr double kMaxMs = 150;

private:
    enum class Mode { off, all, pids, apps };

    // One recording (one app with its helpers, or "everything except us").
    struct Stream {
        explicit Stream(DWORD root) : root(root), ring(size_t(kRate) * kChannels) {}
        DWORD root;
        std::unique_ptr<Capture> capture;
        SampleRing ring;  // filled by the stream's recording thread, emptied by mix()
    };

    void run();
    void tick();
    void add_stream(DWORD root, bool include_tree);
    void remove_stream(DWORD root);
    void remove_all_streams();
    void on_sound();
    void mix();
    void process_mixed(float* data, size_t frames);
    void make_player_locked();
    void update_player();
    void player_changed_locked();
    void advanced_loop();

    // Settings (set by the caller, read by the manager thread).
    mutable std::mutex settings_lock_;
    Mode mode_ = Mode::off;
    std::vector<DWORD> target_pids_;
    std::vector<std::wstring> target_exes_;
    std::atomic<double> semitones_{0.0};
    std::atomic<bool> advanced_{false};

    // Manager thread.
    HANDLE wake_;
    std::thread thread_;
    std::atomic<bool> quit_{false};
    QuietKeeper keeper_;
    std::map<DWORD, std::chrono::steady_clock::time_point> retry_after_;
    uint64_t guarded_seen_ = 0;  // the booster's count at the last look (it steps in when sound wasn't quieted)
    std::atomic<bool> nudging_{true};
    std::chrono::steady_clock::time_point nudged_at_{};

    // The sound chain. mix_lock_ guards streams_ and everything mix() uses.
    std::mutex mix_lock_;
    std::map<DWORD, std::shared_ptr<Stream>> streams_;
    bool include_tree_ = true;
    std::unique_ptr<Renderer> renderer_;
    std::unique_ptr<MusicShifter> shifter_;            // normal mode
    std::unique_ptr<AdvancedShifter> advanced_shifter_;  // Advanced processing (only one of the two is there)
    Booster booster_;
    Cushion cushion_;
    std::vector<float> mixed_, piece_, shifted_;  // room is made at the start, so mixing makes no memory

    // Advanced processing runs on its own thread: the recording threads wake it (on_sound) and it mixes.
    HANDLE advanced_wake_;
    std::thread advanced_thread_;
    std::atomic<bool> advanced_quit_{false}, advanced_mixes_{false};

    // What the Advanced engine is doing (written by the sound side, read by status()).
    std::atomic<bool> adv_on_{false}, adv_full_range_{false}, adv_changing_{false};
    std::atomic<double> adv_latency_ms_{0}, adv_heard_{0};
    std::atomic<int64_t> adv_underruns_{0}, adv_switches_{0};
    std::atomic<int> adv_shifters_{0};
    std::atomic<uint64_t> player_rebuilds_{0};

    // Status (read from any thread).
    mutable std::mutex status_lock_;
    std::string state_ = "off", error_;
    nlohmann::json apps_ = nlohmann::json::array();
    int quieted_ = 0;
    int quiet_failures_ = 0;   // apps that could not be made quiet (see QuietKeeper::failures)
    int quiet_nudges_ = 0;     // quiet volumes written again because loud sound still arrived (QuietKeeper::nudge)
    std::string quiet_error_;  // why, the last time
    std::atomic<uint64_t> clipped_{0}, gaps_{0};
    // How often the speaker stream ran empty (the playing thread came back too late): players already closed, the
    // current one (as of the last look), and the total at the last reset_counts().
    std::atomic<uint64_t> starved_gone_{0}, starved_now_{0}, starved_reset_{0};
    std::atomic<double> slowest_tick_ms_{0};  // the manager's slowest look (quieting new apps waits for it)
    double output_ms_ = 0;
    uint64_t current_gaps_ = 0;
    std::wstring speaker_;
    std::chrono::steady_clock::time_point speaker_checked_{};
};

}  // namespace ps

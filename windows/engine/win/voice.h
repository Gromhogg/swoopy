// "Your voice": takes the chosen microphone, changes its pitch, and plays it into the virtual cable,
// so call apps that use "Swoopy Mic" hear the shifted voice.
// While it's on, Swoopy Mic is also the Windows default microphone (see mic_default.h), so
// apps set to "Default" use it; the real microphone keeps being read for the voice.
// Like the Mac app, it only runs while some app is actually using Swoopy Mic (or during Test),
// so the microphone isn't held open when nobody listens.
#pragma once
#include "dsp/drift_buffer.h"
#include "dsp/voice_shifter.h"
#include "win/cable.h"
#include "win/capture.h"
#include "win/render.h"

#include <atomic>
#include <chrono>
#include <functional>
#include <memory>
#include <mutex>
#include <nlohmann/json.hpp>
#include <string>
#include <thread>

namespace ps {

class VoicePath {
public:
    explicit VoicePath(std::wstring restore_command = L"");
    ~VoicePath();
    VoicePath(const VoicePath&) = delete;
    VoicePath& operator=(const VoicePath&) = delete;

    void start(const std::wstring& mic_id);  // empty = Windows' default microphone for calls
    void stop();
    void set_semitones(double value) { semitones_ = value; }
    void set_natural(bool natural) { natural_ = natural; }

    // Test: record 5 s of what call apps would hear, then play it back on the speakers.
    void test_start();
    void test_stop();

    // For the checks: use this instead of a microphone (fills one 10 ms piece at a time),
    // and run even when no call app is listening.
    void set_test_input(std::function<void(float* out, size_t n)> source);
    void set_always_run(bool on) { always_run_ = on; }

    nlohmann::json status() const;
    void reset_counts();

    // The microphone to read when none was picked: the default from before Swoopy Mic
    // became the default, else Windows' default, else any real microphone.
    static std::wstring default_mic_id();
    static constexpr double kTestSeconds = 5.0;

private:
    void run();
    void tick();
    void start_chain(const std::wstring& mic_id, const std::wstring& feed_id);
    void stop_chain();
    void on_mic(const float* data, size_t n);
    bool cable_in_use(const std::wstring& mic_id) const;

    std::wstring restore_command_;
    bool took_default_ = false;

    // Settings.
    mutable std::mutex settings_lock_;
    bool on_ = false;
    std::wstring mic_choice_;
    std::function<void(float*, size_t)> test_input_;
    std::atomic<bool> always_run_{false};
    std::atomic<double> semitones_{0.0};
    std::atomic<bool> natural_{true};
    std::atomic<int> test_request_{0};  // 1 = start, 2 = stop

    // Manager thread.
    HANDLE wake_;
    std::thread thread_;
    std::atomic<bool> quit_{false};

    // The chain.
    std::unique_ptr<Capture> capture_;
    std::unique_ptr<Renderer> feed_;
    std::unique_ptr<VoiceShifter> shifter_;
    std::unique_ptr<DriftBuffer> drift_;
    std::thread synth_;
    std::atomic<bool> synth_stop_{false};
    std::vector<float> shifted_, mono_;
    std::atomic<bool> muted_{false};
    std::wstring chain_mic_, chain_feed_;
    std::chrono::steady_clock::time_point retry_after_{}, last_in_use_{}, last_check_{};
    bool in_use_ = false;
    std::wstring mic_resolved_, mic_name_, mic_choice_seen_;
    std::chrono::steady_clock::time_point mic_checked_{};
    CableInfo cable_;
    bool restart_needed_ = false;
    std::chrono::steady_clock::time_point cable_checked_{};

    // Test.
    enum class TestPhase { idle, recording, playing };
    TestPhase test_phase_ = TestPhase::idle;
    std::chrono::steady_clock::time_point test_end_{};
    std::unique_ptr<Capture> test_recorder_;
    std::unique_ptr<Renderer> test_player_;
    std::mutex test_lock_;
    std::vector<float> test_buf_;
    std::atomic<size_t> test_play_pos_{0};

    // Status.
    mutable std::mutex status_lock_;
    nlohmann::json status_;
    std::atomic<uint64_t> clipped_{0};
};

}  // namespace ps

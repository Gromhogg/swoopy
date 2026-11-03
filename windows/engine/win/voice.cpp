#include "win/voice.h"

#include "dsp/booster.h"
#include "win/devices.h"
#include "win/mic_default.h"
#include "win/quiet.h"
#include "win/sessions.h"

#include <audiopolicy.h>
#include <avrt.h>

#include <algorithm>
#include <cmath>

namespace ps {

namespace {
bool is_cable_mic(const Endpoint& e, const std::wstring& cable_mic) {
    return e.id == cable_mic || (cable_mic.empty() && lower(e.adapter) == L"vb-audio virtual cable");
}

std::wstring endpoint_name(EDataFlow flow, const std::wstring& id) {
    try {
        for (const auto& e : list_endpoints(flow, DEVICE_STATE_ACTIVE))
            if (e.id == id) return e.name;
    } catch (const std::exception&) {
    }
    return {};
}

bool is_access_denied(HRESULT hr) { return hr == E_ACCESSDENIED || hr == HRESULT_FROM_WIN32(ERROR_ACCESS_DENIED); }
}  // namespace

VoicePath::VoicePath(std::wstring restore_command) : restore_command_(std::move(restore_command)) {
    wake_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    status_ = {{"state", "off"}};
    thread_ = std::thread([this] { run(); });
}

VoicePath::~VoicePath() {
    quit_ = true;
    SetEvent(wake_);
    if (thread_.joinable()) thread_.join();
    CloseHandle(wake_);
}

void VoicePath::start(const std::wstring& mic_id) {
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        on_ = true;
        mic_choice_ = mic_id;
    }
    SetEvent(wake_);
}

void VoicePath::stop() {
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        on_ = false;
    }
    SetEvent(wake_);
}

void VoicePath::test_start() {
    test_request_ = 1;
    SetEvent(wake_);
}

void VoicePath::test_stop() {
    test_request_ = 2;
    SetEvent(wake_);
}

void VoicePath::set_test_input(std::function<void(float*, size_t)> source) {
    std::lock_guard<std::mutex> lock(settings_lock_);
    test_input_ = std::move(source);
}

std::wstring VoicePath::default_mic_id() {
    try {
        const std::wstring cable_mic = find_cable().mic_id;
        const auto mics = list_endpoints(eCapture, DEVICE_STATE_ACTIVE);
        auto usable = [&](const std::wstring& id) {
            for (const auto& e : mics)
                if (e.id == id && !is_cable_mic(e, cable_mic)) return true;
            return false;
        };
        const std::wstring before = remembered_mic();
        if (usable(before)) return before;
        for (ERole role : {eCommunications, eConsole}) {
            const std::wstring id = default_endpoint_id(eCapture, role);
            if (usable(id)) return id;
        }
        for (const auto& e : mics)
            if (!is_cable_mic(e, cable_mic)) return e.id;
    } catch (const std::exception&) {
    }
    return {};
}

bool VoicePath::cable_in_use(const std::wstring& mic_id) const {
    // Is any other program recording from Swoopy Mic right now (a call app)?
    try {
        auto device = device_by_id(mic_id);
        ComPtr<IAudioSessionManager2> manager;
        if (FAILED(device->Activate(__uuidof(IAudioSessionManager2), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void**>(manager.GetAddressOf()))))
            return false;
        ComPtr<IAudioSessionEnumerator> sessions;
        if (FAILED(manager->GetSessionEnumerator(&sessions))) return false;
        int count = 0;
        sessions->GetCount(&count);
        const DWORD self = GetCurrentProcessId();
        for (int i = 0; i < count; ++i) {
            ComPtr<IAudioSessionControl> control;
            ComPtr<IAudioSessionControl2> control2;
            if (FAILED(sessions->GetSession(i, &control)) || FAILED(control.As(&control2))) continue;
            AudioSessionState state = AudioSessionStateInactive;
            DWORD pid = 0;
            control2->GetState(&state);
            control2->GetProcessId(&pid);
            if (state == AudioSessionStateActive && pid != self) return true;
        }
    } catch (const std::exception&) {
    }
    return false;
}

void VoicePath::run() {
    ComScope com;
    while (!quit_) {
        try {
            tick();
        } catch (const std::exception& e) {
            stop_chain();
            retry_after_ = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            std::lock_guard<std::mutex> lock(status_lock_);
            status_["state"] = "error";
            status_["error"] = e.what();
        }
        WaitForSingleObject(wake_, 100);
    }
    test_recorder_.reset();
    test_player_.reset();
    stop_chain();
    if (took_default_ || default_mic_taken()) give_back_default_mic();
    update_sign_in_safety_net(restore_command_);
}

void VoicePath::start_chain(const std::wstring& mic_id, const std::wstring& feed_id) {
    std::function<void(float*, size_t)> input;
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        input = test_input_;
    }
    shifter_ = std::make_unique<VoiceShifter>(kRate, semitones_.load(), natural_.load());
    drift_ = std::make_unique<DriftBuffer>(kRate);
    shifted_.reserve(8192);
    mono_.assign(8192, 0.0f);
    feed_ = Renderer::to_endpoint(
        feed_id,
        [this](float* out, size_t frames) {
            if (mono_.size() < frames) mono_.resize(frames);
            drift_->pull(mono_.data(), frames);
            const bool mute = muted_;
            for (size_t i = 0; i < frames; ++i) out[2 * i] = out[2 * i + 1] = mute ? 0.0f : mono_[i];
        },
        2);
    try {
        if (input) {
            // A made-up voice instead of a microphone, delivered in real time on its own clock.
            synth_stop_ = false;
            synth_ = std::thread([this, input] {
                // Same priority a real microphone's recording thread gets.
                DWORD task_index = 0;
                HANDLE task = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task_index);
                std::vector<float> piece(480);
                auto next = std::chrono::steady_clock::now();
                while (!synth_stop_) {
                    input(piece.data(), piece.size());
                    on_mic(piece.data(), piece.size());
                    next += std::chrono::milliseconds(10);
                    std::this_thread::sleep_until(next);
                }
                if (task) AvRevertMmThreadCharacteristics(task);
            });
        } else {
            capture_ = Capture::from_endpoint(mic_id, [this](const float* d, size_t n) { on_mic(d, n); }, 1);
        }
    } catch (...) {
        feed_.reset();
        throw;
    }
    chain_mic_ = mic_id;
    chain_feed_ = feed_id;
}

void VoicePath::stop_chain() {
    synth_stop_ = true;
    if (synth_.joinable()) synth_.join();
    capture_.reset();
    feed_.reset();
    shifter_.reset();
    drift_.reset();
    chain_mic_.clear();
    chain_feed_.clear();
}

// Runs on the microphone thread for every packet.
void VoicePath::on_mic(const float* data, size_t n) {
    const double want = semitones_.load();
    if (want != shifter_->half_steps()) shifter_->set_half_steps(want);
    shifter_->set_natural(natural_.load());
    shifted_.clear();
    shifter_->process(data, n, shifted_);
    clipped_ += limit(shifted_.data(), shifted_.size());
    drift_->push(shifted_.data(), shifted_.size());
}

void VoicePath::tick() {
    bool on;
    std::wstring choice;
    {
        std::lock_guard<std::mutex> lock(settings_lock_);
        on = on_;
        choice = mic_choice_;
    }
    const auto now = std::chrono::steady_clock::now();
    if (now - cable_checked_ > std::chrono::seconds(cable_.present ? 5 : 2)) {
        cable_ = find_cable();
        restart_needed_ = !cable_.present && cable_restart_needed();
        cable_checked_ = now;
    }

    // Test button.
    const int request = test_request_.exchange(0);
    if (request == 2 || !on || !cable_.present) {
        if (test_phase_ != TestPhase::idle) {
            test_recorder_.reset();
            test_player_.reset();
            muted_ = false;
            test_phase_ = TestPhase::idle;
        }
    }
    if (request == 1 && on && cable_.present && test_phase_ == TestPhase::idle) {
        {
            std::lock_guard<std::mutex> lock(test_lock_);
            test_buf_.clear();
            test_buf_.reserve(size_t(kRate * kTestSeconds) + kRate);
        }
        // Record what call apps hear: the recording side of the cable.
        test_recorder_ = Capture::from_endpoint(
            cable_.mic_id,
            [this](const float* d, size_t n) {
                std::lock_guard<std::mutex> lock(test_lock_);
                test_buf_.insert(test_buf_.end(), d, d + n);
            },
            1);
        test_phase_ = TestPhase::recording;
        test_end_ = now + std::chrono::milliseconds(int(kTestSeconds * 1000));
    }
    if (test_phase_ == TestPhase::recording && now >= test_end_) {
        test_recorder_.reset();
        // Play it back on the speakers. Meanwhile the shifted voice going into calls is silenced.
        muted_ = true;
        test_play_pos_ = 0;
        test_player_ = Renderer::to_default([this](float* out, size_t frames) {
            std::lock_guard<std::mutex> lock(test_lock_);
            size_t pos = test_play_pos_;
            for (size_t i = 0; i < frames; ++i, ++pos) {
                const float v = pos < test_buf_.size() ? test_buf_[pos] : 0.0f;
                out[2 * i] = out[2 * i + 1] = v;
            }
            test_play_pos_ = pos;
        });
        size_t length = 0;
        {
            std::lock_guard<std::mutex> lock(test_lock_);
            length = test_buf_.size();
        }
        test_phase_ = TestPhase::playing;
        test_end_ = now + std::chrono::milliseconds(int(length * 1000 / kRate) + 300);
    }
    if (test_phase_ == TestPhase::playing && now >= test_end_) {
        test_player_.reset();
        muted_ = false;
        test_phase_ = TestPhase::idle;
    }

    std::string state;
    std::string error;
    std::wstring mic_id;
    if (!on) {
        stop_chain();
        state = "off";
        if (took_default_ || default_mic_taken()) {
            give_back_default_mic();
            took_default_ = false;
            update_sign_in_safety_net(restore_command_);
        }
    } else if (!cable_.present) {
        stop_chain();
        state = restart_needed_ ? "restart_needed" : "cable_missing";
    } else {
        if (!took_default_) {
            // Swoopy Mic becomes the default microphone (the old defaults are written down first).
            took_default_ = true;
            take_default_mic(cable_.mic_id);
            update_sign_in_safety_net(restore_command_);
        }
        if (now - last_check_ > std::chrono::milliseconds(300)) {
            in_use_ = cable_in_use(cable_.mic_id);
            last_check_ = now;
            if (in_use_) last_in_use_ = now;
        }
        // Keep running 2 s after the last call app stops, so short gaps don't restart it.
        const bool want = always_run_ || test_phase_ == TestPhase::recording || in_use_ ||
                          now - last_in_use_ < std::chrono::seconds(2);
        // Which microphone to read (checked once a second; looking at devices isn't free). The
        // chain is only rebuilt when this really changes, never because of our own streams.
        if (now - mic_checked_ > std::chrono::seconds(1) || choice != mic_choice_seen_) {
            std::wstring id = choice;
            if (!id.empty() && endpoint_name(eCapture, id).empty()) id.clear();  // unplugged
            if (id.empty()) id = default_mic_id();
            mic_resolved_ = id;
            mic_name_ = endpoint_name(eCapture, id);
            mic_checked_ = now;
            mic_choice_seen_ = choice;
        }
        mic_id = mic_resolved_;
        bool has_input;
        {
            std::lock_guard<std::mutex> lock(settings_lock_);
            has_input = bool(test_input_);
        }
        if ((capture_ || feed_) && (mic_id != chain_mic_ || cable_.feed_id != chain_feed_)) stop_chain();
        if (capture_ && FAILED(capture_->stats().error)) {
            error = "microphone stopped: " + hr_text(capture_->stats().error);
            stop_chain();
            retry_after_ = now + std::chrono::milliseconds(500);
        }
        if (feed_ && FAILED(feed_->error())) {
            error = "Swoopy Mic stopped: " + hr_text(feed_->error());
            stop_chain();
            retry_after_ = now + std::chrono::milliseconds(500);
        }
        state = want ? "running" : "idle";
        if (want && !feed_ && now >= retry_after_) {
            if (mic_id.empty() && !has_input) {
                state = "no_mic";
            } else {
                try {
                    start_chain(mic_id, cable_.feed_id);
                } catch (const WinError& e) {
                    stop_chain();
                    retry_after_ = now + std::chrono::seconds(3);
                    state = is_access_denied(e.hr) ? "mic_denied" : "error";
                    error = e.what();
                }
            }
        }
        if (!want && feed_) stop_chain();
        if (want && !feed_ && state == "running") state = "error";
    }

    const char* test_state = test_phase_ == TestPhase::recording ? "recording"
                             : test_phase_ == TestPhase::playing ? "playing"
                                                                   : "idle";
    const double left_s = test_phase_ == TestPhase::idle
                              ? 0
                              : std::max(0.0, std::chrono::duration<double>(test_end_ - now).count());
    nlohmann::json s = {{"state", state},
                        {"error", error},
                        {"in_use", in_use_},
                        {"mic", {{"id", utf8(mic_id)}, {"name", utf8(mic_id.empty() ? L"" : mic_name_)}}},
                        {"cable", {{"present", cable_.present}, {"restart_needed", restart_needed_}, {"mic_name", utf8(cable_.mic_name)}, {"feed_name", utf8(cable_.feed_name)}}},
                        {"semitones", semitones_.load()},
                        {"natural", natural_.load()},
                        {"test", {{"state", test_state}, {"seconds_left", int(std::ceil(left_s))}}},
                        {"dropouts", drift_ ? drift_->dropouts() : 0},
                        {"trims", drift_ ? drift_->trims() : 0},
                        {"repeats", drift_ ? drift_->repeats() : 0},
                        {"queued_ms", drift_ ? drift_->queued_ms() : 0.0},
                        // Rubber Band (about 60 ms, measured in the sound math tests) + the cushion + the cable's buffer.
                        {"delay_estimate_ms",
                         feed_ && drift_ ? 60 + drift_->queued_ms() + feed_->buffer_ms() + feed_->latency_ms() : 0.0},
                        {"gaps", capture_ ? capture_->stats().gaps : 0},
                        {"clipped", clipped_.load()}};
    std::lock_guard<std::mutex> lock(status_lock_);
    status_ = std::move(s);
}

nlohmann::json VoicePath::status() const {
    std::lock_guard<std::mutex> lock(status_lock_);
    return status_;
}

void VoicePath::reset_counts() {
    clipped_ = 0;
    if (drift_) drift_->reset_counts();
}

}  // namespace ps

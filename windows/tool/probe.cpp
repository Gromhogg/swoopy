// probe: decides how Swoopy should keep an app's original sound out of the speakers on Windows.
//
// On the Mac, grabbing an app's sound also mutes the original. On Windows it doesn't, and turning the
// app's volume down also turns down what we grab. The plan ("quiet and boost") is to set the app's
// hidden per-channel volume to 0.001 (-60 dB), multiply what we grab by 1000, shift it, and play it.
// This checks, on a real Windows audio system with a virtual cable standing in for the speakers:
//   - grabbing one app's sound works (not silent)
//   - the hidden per-channel volume of another program's session can be changed
//   - 0.001 lowers the grabbed sound by exactly 60 dB, and the boosted copy is clean
//   - the speakers (the cable) get at least 55 dB less of the original
//   - putting the volume back works, also from a separate process, and what Windows remembers
//     when the app restarts
//   - the app's normal volume slider still changes the grabbed sound
//   - whether a plain mute silences the grabbed sound too
// Writes probe.json and WAV recordings to the --out folder.
#include "tool/tool.h"

#include "tool/recorder.h"

#include "dsp/analysis.h"
#include "dsp/wav.h"
#include "win/apps.h"
#include "win/capture.h"
#include "win/devices.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"

#include <endpointvolume.h>

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <thread>

namespace ps::tool {

namespace fs = std::filesystem;
using json = nlohmann::json;

namespace {

constexpr double kToneHz = 440.0;
constexpr double kToneAmp = 0.25;  // -12 dB
constexpr float kQuiet = 0.001f;   // -60 dB

void sleep_s(double seconds) { std::this_thread::sleep_for(std::chrono::duration<double>(seconds)); }

json tone_json(const ToneMeasure& m) {
    auto r = [](double v) { return std::round(v * 1000) / 1000; };
    return {{"frequency", r(m.frequency)}, {"level_db", r(m.level_db)}, {"rms_db", r(m.rms_db)},
            {"thdn_db", r(m.thdn_db)},     {"peak", m.peak},           {"frames", m.frames}};
}

ToneMeasure measure_left(const std::vector<float>& interleaved, float gain = 1.0f) {
    auto left = take_channel(interleaved, kChannels, 0);
    if (gain != 1.0f)
        for (auto& v : left) v *= gain;
    return measure_tone(left.data(), left.size(), kRate, kToneHz);
}

bool silent(const ToneMeasure& m) { return m.frames == 0 || m.level_db < -140; }

class Probe {
public:
    explicit Probe(fs::path out) : out_(std::move(out)) {
        restore_file_ = (out_ / L"restore.json").wstring();
        report_["checks"] = json::object();
        report_["steps"] = json::array();
        report_["notes"] = json::array();
    }

    int run();
    void finish();  // puts every volume back and stops the test tone (also after an error)
    void write_report();

private:
    struct Result {
        ToneMeasure app, cable;
        std::vector<float> app_raw, cable_raw;
    };

    void note(const std::string& text) {
        say("  note: " + text);
        report_["notes"].push_back(text);
    }
    void check(const std::string& name, bool pass, json value, const std::string& meaning) {
        say(std::string(pass ? "  PASS " : "  FAIL ") + name + " = " + value.dump() + "  (" + meaning + ")");
        report_["checks"][name] = {{"pass", pass}, {"value", value}, {"meaning", meaning}};
    }
    void info(const std::string& name, json value, const std::string& meaning) {
        say("  INFO " + name + " = " + value.dump() + "  (" + meaning + ")");
        report_["checks"][name] = {{"pass", nullptr}, {"value", value}, {"meaning", meaning}};
    }

    std::unique_ptr<ChildProcess> start_tone();
    std::optional<Session> wait_for_session(DWORD pid, double seconds = 15);
    std::optional<Session> session_now(DWORD pid);
    void record_app(DWORD pid);
    Result measure(const std::string& name, const std::string& wav_prefix = "", double settle = 0.8,
                   double seconds = 2.0);
    void save_wav(const std::string& name, const std::vector<float>& data, float gain = 1.0f);
    void put_everything_back();

    fs::path out_;
    std::wstring restore_file_;
    json report_;
    Recorder app_, cable_;
    std::unique_ptr<Capture> app_rec_, cable_rec_;
    std::unique_ptr<ChildProcess> tone_;
    ComPtr<IAudioEndpointVolume> cable_volume_;
    float cable_volume_before_ = 0;
    bool cable_volume_changed_ = false;
};

std::unique_ptr<ChildProcess> Probe::start_tone() {
    auto child = start_process(self_path(), L"tonegen --freq 440 --amp 0.25 --seconds 900");
    say("  started tonegen, pid " + std::to_string(child->pid()));
    return child;
}

std::optional<Session> Probe::session_now(DWORD pid) {
    for (auto& s : sessions_of(pid))
        if (s.state == AudioSessionStateActive) return s;
    return std::nullopt;
}

std::optional<Session> Probe::wait_for_session(DWORD pid, double seconds) {
    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    while (std::chrono::steady_clock::now() < end) {
        if (auto s = session_now(pid)) return s;
        sleep_s(0.1);
    }
    return std::nullopt;
}

void Probe::record_app(DWORD pid) {
    if (app_rec_) app_rec_->stop();
    app_rec_.reset();
    app_.clear();
    app_rec_ = Capture::from_process(pid, true, [this](const float* d, size_t n) { app_.add(d, n); });
}

void Probe::save_wav(const std::string& name, const std::vector<float>& data, float gain) {
    std::vector<float> copy = data;
    if (gain != 1.0f)
        for (auto& v : copy) v *= gain;
    write_wav((out_ / (name + ".wav")).string(), copy, kChannels, kRate);
}

Probe::Result Probe::measure(const std::string& name, const std::string& wav_prefix, double settle, double seconds) {
    sleep_s(settle);  // let volume changes finish fading
    app_.clear();
    cable_.clear();
    sleep_s(seconds);
    Result r;
    r.app_raw = app_.take();
    r.cable_raw = cable_.take();
    r.app = measure_left(r.app_raw);
    r.cable = measure_left(r.cable_raw);
    json step = {{"name", name}, {"app_recording", tone_json(r.app)}, {"cable_output", tone_json(r.cable)}};
    if (app_rec_) {
        const auto st = app_rec_->stats();
        step["app_recording_stats"] = {{"frames", st.frames}, {"packets", st.packets},
                                       {"silent_packets", st.silent_packets}, {"gaps", st.gaps},
                                       {"error", hr_text(st.error)}};
    }
    report_["steps"].push_back(step);
    char line[256];
    std::snprintf(line, sizeof line, "  %-34s app %8.2f dB (%7.2f Hz)   cable %8.2f dB", name.c_str(), r.app.level_db,
                  r.app.frequency, r.cable.level_db);
    say(line);
    if (!wav_prefix.empty()) {
        save_wav("app_" + wav_prefix, r.app_raw);
        save_wav("cable_" + wav_prefix, r.cable_raw);
    }
    return r;
}

void Probe::put_everything_back() {
    // Whatever happened above, leave every test session at full volume and unmuted.
    try {
        for (auto& s : list_sessions()) {
            if (lower(s.exe) != lower(self_path())) continue;
            if (auto v = s.channel_volume()) set_all_channels(v.Get(), 1.0f);
            if (auto v = s.simple_volume()) {
                v->SetMasterVolume(1.0f, &kPitchShiftEventContext);
                v->SetMute(FALSE, &kPitchShiftEventContext);
            }
        }
        if (cable_volume_ && cable_volume_changed_)
            cable_volume_->SetMasterVolumeLevel(cable_volume_before_, &kPitchShiftEventContext);
    } catch (const std::exception& e) {
        note(std::string("cleanup problem: ") + e.what());
    }
}

void Probe::finish() {
    put_everything_back();
    if (tone_) tone_->kill();
    tone_.reset();
    if (app_rec_) app_rec_->stop();
    if (cable_rec_) cable_rec_->stop();
    try {
        const auto left = restore_all(restore_file_);
        if (left.restored > 0) note("cleanup restored " + std::to_string(left.restored) + " session(s)");
    } catch (const std::exception&) {
    }
}

void Probe::write_report() {
    std::ofstream f(out_ / "probe.json", std::ios::binary);
    f << report_.dump(2);
}

int Probe::run() {
    report_["os"] = os_text();
    report_["machine"] = machine_arch();
    report_["build"] = process_arch();

    // ---- The virtual cable stands in for the speakers.
    const auto cable_in = find_endpoint(eRender, L"CABLE Input");
    const auto cable_out = find_endpoint(eCapture, L"CABLE Output");
    report_["endpoints"] = endpoints_json();
    if (!cable_in || !cable_out) {
        note("VB-CABLE is not installed or not active, so there is nothing to measure.");
        return 2;
    }
    if (default_endpoint_id(eRender, eConsole) != cable_in->id) {
        const HRESULT hr = set_default_endpoint_all(cable_in->id);
        note("made CABLE Input the default playback device: " + hr_text(hr));
    }
    report_["cable_input_format"] = mix_format_text(device_by_id(cable_in->id).Get());
    report_["cable_output_format"] = mix_format_text(device_by_id(cable_out->id).Get());
    {
        auto dev = device_by_id(cable_in->id);
        if (SUCCEEDED(dev->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                                    reinterpret_cast<void**>(cable_volume_.GetAddressOf()))))
            cable_volume_->GetMasterVolumeLevel(&cable_volume_before_);
    }

    cable_rec_ = Capture::from_endpoint(cable_out->id, [this](const float* d, size_t n) { cable_.add(d, n); });

    // ---- 1. Start the test tone and grab its sound.
    say("1. baseline");
    tone_ = start_tone();
    auto session = wait_for_session(tone_->pid());
    if (!session) {
        note("tonegen's sound session never showed up.");
        return 2;
    }
    report_["tone_session"] = session_json(*session);
    record_app(tone_->pid());
    const auto base = measure("baseline", "baseline");
    check("app_recording_not_silent", !silent(base.app) && base.app.level_db > -20, base.app.level_db,
          "grabbing tonegen's sound works (expect about -12 dB)");
    check("app_recording_pitch", std::fabs(base.app.frequency - kToneHz) < 0.5, base.app.frequency,
          "the grabbed tone is 440 Hz");
    check("cable_not_silent", !silent(base.cable) && base.cable.level_db > -20, base.cable.level_db,
          "the tone reaches the cable (the stand-in speakers)");
    if (silent(base.app)) {
        note("App recording is silent, so the rest can't be measured.");
        return 3;
    }

    auto channel = session->channel_volume();
    auto simple = session->simple_volume();
    info("channel_count", channel_volumes(channel.Get()).size(), "channels in the hidden per-channel volume");

    // ---- 2. Quiet-and-boost: hidden per-channel volume to 0.001.
    say("2. per-channel volume 0.001 (quiet-and-boost)");
    const HRESULT set_hr = set_all_channels(channel.Get(), kQuiet);
    check("channel_volume_set", SUCCEEDED(set_hr), hr_text(set_hr),
          "IChannelAudioVolume::SetAllVolumes works on another program's session");
    const auto read_back = channel_volumes(channel.Get());
    info("channel_volume_read_back", read_back, "what Windows reports after setting 0.001");
    float slider = -1;
    if (simple) simple->GetMasterVolume(&slider);
    info("app_slider_while_quiet", slider, "the app's volume-mixer slider stays where the user left it (1.0)");
    const auto quiet = measure("channel 0.001", "channel_quiet");
    save_wav("app_channel_quiet_boosted", quiet.app_raw, 1000.0f);
    const auto boosted = measure_left(quiet.app_raw, 1000.0f);
    const double drop = quiet.app.level_db - base.app.level_db;
    const double cable_drop = quiet.cable.level_db - base.cable.level_db;
    check("quiet_drop_db", std::fabs(drop + 60.0) <= 0.2, drop, "grabbed sound drops by 60.0 +/- 0.2 dB");
    check("boosted_level_error_db", std::fabs(boosted.level_db - base.app.level_db) <= 0.2,
          boosted.level_db - base.app.level_db, "boosted x1000 copy matches the original level");
    check("boosted_thdn_db", boosted.thdn_db <= -60, boosted.thdn_db,
          "boosted copy is clean (baseline THD+N " + std::to_string(base.app.thdn_db) + " dB)");
    check("cable_drop_db", cable_drop <= -55, cable_drop, "speakers get at least 55 dB less of the original");
    report_["boosted"] = tone_json(boosted);

    // ---- 3. Put it back.
    say("3. per-channel volume back to 1.0");
    const HRESULT back_hr = set_all_channels(channel.Get(), 1.0f);
    const auto back = measure("channel back to 1.0");
    check("restore_ok", SUCCEEDED(back_hr) && std::fabs(back.app.level_db - base.app.level_db) < 0.2 &&
                            std::fabs(back.cable.level_db - base.cable.level_db) < 0.5,
          back.app.level_db - base.app.level_db, "volume comes back to where it was");

    // ---- 4. The user's own app slider (ISimpleAudioVolume) at 0.5.
    say("4. app slider 0.5");
    if (simple) {
        simple->SetMasterVolume(0.5f, &kPitchShiftEventContext);
        const auto half = measure("app slider 0.5");
        const double d = half.app.level_db - base.app.level_db;
        check("app_slider_changes_recording", std::fabs(d + 6.02) < 0.3, d,
              "moving the app's mixer slider still changes the shifted sound (expect -6.02 dB)");
        info("app_slider_cable_db", half.cable.level_db - base.cable.level_db, "cable change with slider at 0.5");
        // Slider 0.5 together with the hidden volume 0.001.
        set_all_channels(channel.Get(), kQuiet);
        const auto both = measure("app slider 0.5 + channel 0.001");
        info("slider_plus_quiet_db", both.app.level_db - base.app.level_db, "expect -66.02 dB");
        set_all_channels(channel.Get(), 1.0f);
        simple->SetMasterVolume(1.0f, &kPitchShiftEventContext);
    }

    // ---- 5. Plain mute.
    say("5. session mute");
    if (simple) {
        simple->SetMute(TRUE, &kPitchShiftEventContext);
        const auto muted = measure("session muted", "muted");
        info("mute_app_recording_db", muted.app.level_db - base.app.level_db,
             "change in the grabbed sound when the app is muted (very low = mute silences it)");
        info("mute_cable_db", muted.cable.level_db - base.cable.level_db, "change at the cable when muted");
        report_["mute_silences_recording"] = silent(muted.app) || muted.app.level_db - base.app.level_db < -40;
        report_["mute_keeps_recording"] = std::fabs(muted.app.level_db - base.app.level_db) < 1.0;
        report_["mute_silences_cable"] = silent(muted.cable) || muted.cable.level_db - base.cable.level_db < -55;
        simple->SetMute(FALSE, &kPitchShiftEventContext);
    }

    // ---- 6. The app slider itself at 0.001 (a fallback).
    say("6. app slider 0.001");
    if (simple) {
        simple->SetMasterVolume(kQuiet, &kPitchShiftEventContext);
        const auto low = measure("app slider 0.001");
        const auto low_boosted = measure_left(low.app_raw, 1000.0f);
        info("slider_quiet_drop_db", low.app.level_db - base.app.level_db, "expect -60 dB if the slider is linear");
        info("slider_quiet_boosted_thdn_db", low_boosted.thdn_db, "cleanliness of that boosted copy");
        info("slider_quiet_cable_db", low.cable.level_db - base.cable.level_db, "cable change");
        simple->SetMasterVolume(1.0f, &kPitchShiftEventContext);
    }

    // ---- 7. The speakers' (cable's) own volume.
    say("7. speaker volume -6 dB");
    if (cable_volume_) {
        cable_volume_changed_ = true;
        float lo = 0, hi = 0, step = 0, now = 0;
        DWORD hardware = 0;
        cable_volume_->GetVolumeRange(&lo, &hi, &step);
        cable_volume_->QueryHardwareSupport(&hardware);
        const HRESULT hr = cable_volume_->SetMasterVolumeLevel(cable_volume_before_ - 6.0f, &kPitchShiftEventContext);
        cable_volume_->GetMasterVolumeLevel(&now);
        info("speaker_volume_details",
             {{"set_result", hr_text(hr)}, {"before_db", cable_volume_before_}, {"now_db", now}, {"range_db", {lo, hi}},
              {"driver_handles_volume", (hardware & ENDPOINT_HARDWARE_SUPPORT_VOLUME) != 0}},
             "the cable's own volume control");
        const auto quieter = measure("speaker volume -6 dB");
        info("speaker_volume_recording_db", quieter.app.level_db - base.app.level_db,
             "0 = grabbed sound is taken before the speaker volume (good: no double volume)");
        info("speaker_volume_cable_db", quieter.cable.level_db - base.cable.level_db, "cable change");
        cable_volume_->SetMasterVolumeLevel(cable_volume_before_, &kPitchShiftEventContext);
        cable_volume_changed_ = false;
    }

    // ---- 8. Everything except our own processes ("All sound"). tonegen is our child, so it's left out.
    say("8. all sound except our own process tree");
    {
        Recorder others;
        auto rec = Capture::from_process(GetCurrentProcessId(), false,
                                         [&](const float* d, size_t n) { others.add(d, n); });
        sleep_s(1.5);
        others.clear();
        sleep_s(1.5);
        const auto m = measure_left(others.take());
        rec->stop();
        info("all_sound_excludes_own_child_db", m.level_db,
             "all-sound recording leaves out our own child processes (expect silence)");
    }

    // ---- 9. Restore from a separate process, using the restore list (like after a crash).
    say("9. restore from another process");
    {
        session = session_now(tone_->pid());
        const HRESULT hr = session ? quiet_session(*session, kQuiet, restore_file_) : E_FAIL;
        const bool listed = fs::exists(restore_file_);
        const auto q = measure("quiet (via restore list)");
        auto fixer = start_process(self_path(), L"restore --file \"" + restore_file_ + L"\"");
        const bool done = fixer->wait(20000);
        const auto after = measure("after 'SwoopyTool restore'", "after_restore");
        check("restore_by_other_process",
              SUCCEEDED(hr) && listed && q.app.level_db - base.app.level_db < -55 && done &&
                  fixer->exit_code() == 0 && std::fabs(after.app.level_db - base.app.level_db) < 0.2,
              after.app.level_db - base.app.level_db,
              "a separate 'SwoopyTool restore' puts the volume back from the list");
        info("restore_list_removed", !fs::exists(restore_file_), "the list is deleted after a full restore");
    }

    // ---- 10. Quiet, then the app quits and starts again: does Windows bring back the quiet volume?
    say("10. app restart while quiet");
    {
        session = session_now(tone_->pid());
        if (session) quiet_session(*session, kQuiet, restore_file_);
        sleep_s(1.0);
        _wsystem((L"reg query \"HKCU\\Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\"
                  L"PropertyStore\" /s > \"" +
                  (out_ / L"registry_while_quiet.txt").wstring() + L"\" 2>&1")
                     .c_str());
        tone_->kill();
        tone_ = start_tone();
        auto fresh = wait_for_session(tone_->pid());
        if (fresh) {
            const auto fresh_levels = channel_volumes(fresh->channel_volume().Get());
            info("new_session_channel_volumes", fresh_levels, "volumes of the restarted app's new session");
            record_app(tone_->pid());
            const auto m = measure("restarted while quiet", "restarted_while_quiet");
            const bool persists = m.app.level_db - base.app.level_db < -40;
            info("quiet_persists_after_app_restart", persists,
                 "true = Windows remembers the quiet volume for the app's next run (restore must handle it)");
            report_["quiet_persists_after_app_restart"] = persists;
            auto fixer = start_process(self_path(), L"restore --file \"" + restore_file_ + L"\"");
            fixer->wait(20000);
            const auto fixed = measure("restarted, after restore");
            check("restore_after_app_restart", std::fabs(fixed.app.level_db - base.app.level_db) < 0.2,
                  fixed.app.level_db - base.app.level_db, "restore also fixes the restarted app");
        } else {
            note("restarted tonegen's session never showed up");
        }
    }

    // ---- 11. After restoring, the app restarts again: it must come back at full volume.
    say("11. app restart after restore");
    {
        tone_->kill();
        tone_ = start_tone();
        auto fresh = wait_for_session(tone_->pid());
        if (fresh) {
            info("final_session_channel_volumes", channel_volumes(fresh->channel_volume().Get()),
                 "volumes after another restart");
            record_app(tone_->pid());
            const auto m = measure("restarted after restore");
            check("restored_persists_after_app_restart", std::fabs(m.app.level_db - base.app.level_db) < 0.2,
                  m.app.level_db - base.app.level_db, "the app starts at full volume next time");
        }
    }

    // ---- 12. Quiet, the app quits, and we put the volume back on its closed session before it starts
    // again (what Swoopy would do when it sees a quieted app close). Does the next run start at full?
    say("12. restore after the app quit");
    {
        session = session_now(tone_->pid());
        if (session) {
            const Session old = *session;
            quiet_session(old, kQuiet, restore_file_);
            sleep_s(0.5);
            tone_->kill();
            sleep_s(1.0);
            AudioSessionState state = AudioSessionStateActive;
            old.control->GetState(&state);
            info("closed_session_state", state == AudioSessionStateExpired    ? "expired"
                                         : state == AudioSessionStateInactive ? "inactive"
                                                                              : "active",
                 "state of the quieted session after its app quit");
            const HRESULT hr = set_all_channels(old.channel_volume().Get(), 1.0f);
            info("restore_closed_session_result", hr_text(hr), "setting volume on the closed session");
            info("restore_closed_session_read_back", channel_volumes(old.channel_volume().Get()),
                 "what the closed session reports afterwards");
            _wsystem((L"reg query \"HKCU\\Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\"
                      L"PropertyStore\" /s > \"" +
                      (out_ / L"registry_after_quit.txt").wstring() + L"\" 2>&1")
                         .c_str());
            tone_ = start_tone();
            auto fresh = wait_for_session(tone_->pid());
            if (fresh) {
                info("after_quit_new_session_channel_volumes", channel_volumes(fresh->channel_volume().Get()),
                     "volumes of the next run");
                record_app(tone_->pid());
                const auto m = measure("next run after closed-session restore", "after_quit_restore");
                info("restore_after_quit_works", std::fabs(m.app.level_db - base.app.level_db) < 0.2,
                     "true = putting the volume back on the closed session is enough");
            }
            restore_all(restore_file_);  // in case it didn't work
        }
    }

    // ---- 13. The app quit while quiet; we rewrite the volume Windows remembered for it in the
    // registry (no session to fix). Does the next run really start at full volume?
    say("13. fix the remembered volume in the registry");
    {
        session = session_now(tone_->pid());
        if (session) {
            const Session old = *session;
            QuietEntry entry;
            entry.exe = old.exe;
            entry.native_exe = native_process_path(old.pid);
            entry.original = {1.0f, 1.0f};
            quiet_session(old, kQuiet, restore_file_);
            sleep_s(0.5);
            tone_->kill();
            sleep_s(2.0);  // Windows writes the remembered volume when the session ends
            const int fixed = fix_remembered_volume(entry);
            info("registry_values_fixed", fixed, "remembered quiet volumes rewritten to full");
            _wsystem((L"reg query \"HKCU\\Software\\Microsoft\\Internet Explorer\\LowRegistry\\Audio\\PolicyConfig\\"
                      L"PropertyStore\" /s > \"" +
                      (out_ / L"registry_after_fix.txt").wstring() + L"\" 2>&1")
                         .c_str());
            tone_ = start_tone();
            auto fresh = wait_for_session(tone_->pid());
            if (fresh) {
                const auto levels = channel_volumes(fresh->channel_volume().Get());
                info("after_registry_fix_channel_volumes", levels, "volumes of the next run");
                record_app(tone_->pid());
                const auto m = measure("next run after registry fix", "after_registry_fix");
                check("registry_fix_works", fixed > 0 && std::fabs(m.app.level_db - base.app.level_db) < 0.2,
                      m.app.level_db - base.app.level_db,
                      "rewriting the remembered volume makes the app start at full volume");
            }
            restore_all(restore_file_);
        }
    }

    // ---- Verdict.
    auto pass = [&](const char* name) {
        const auto& c = report_["checks"];
        return c.contains(name) && c[name]["pass"].is_boolean() && c[name]["pass"].get<bool>();
    };
    const bool quiet_and_boost = pass("channel_volume_set") && pass("quiet_drop_db") &&
                                 pass("boosted_level_error_db") && pass("boosted_thdn_db") &&
                                 pass("cable_drop_db") && pass("restore_ok") && pass("restore_by_other_process");
    std::string mode;
    if (quiet_and_boost)
        mode = "channel-quiet-and-boost";
    else if (report_.value("mute_keeps_recording", false) && report_.value("mute_silences_cable", false))
        mode = "session-mute";
    else
        mode = "route-to-silent-device";
    report_["recommended_mode"] = mode;
    say("Recommended quieting mode: " + mode);
    return 0;
}

}  // namespace

int probe(const Args& args) {
    ComScope com;
    const fs::path out = args.get(L"--out", L"probe-out");
    std::error_code ec;
    fs::create_directories(out, ec);
    Probe p(out);
    int code = 2;
    try {
        code = p.run();
    } catch (const std::exception& e) {
        say(std::string("probe stopped: ") + e.what());
    }
    p.finish();
    p.write_report();
    return code;
}

}  // namespace ps::tool

// The engine's C interface (used by the window app through SwoopyEngine.dll, and by
// SwoopyTool's checks, which build the same code in).
#include "api/pitchshift_engine.h"

#include "win/apps.h"
#include "win/cable.h"
#include "win/devices.h"
#include "win/mic_default.h"
#include "win/music.h"
#include "win/process.h"
#include "win/quiet.h"
#include "win/sessions.h"
#include "win/voice.h"

#include <algorithm>
#include <filesystem>
#include <map>
#include <memory>
#include <mutex>
#include <string>

using namespace ps;

namespace {
std::mutex g_lock;
std::unique_ptr<MusicPath> g_music;
std::unique_ptr<VoicePath> g_voice;

const char* hand_back(std::string text) {
    thread_local std::string kept;
    kept = std::move(text);
    return kept.c_str();
}

std::wstring restore_command() {
    const std::wstring tool = tool_path();
    std::error_code ec;
    if (!std::filesystem::exists(tool, ec)) return {};
    return L"\"" + tool + L"\" restore";
}

// COM for calls from the app's threads (it may already be set up; that's fine).
struct ComForCall {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    ~ComForCall() {
        if (SUCCEEDED(hr)) CoUninitialize();
    }
};
}  // namespace

extern "C" {

PS_API const char* ps_version(void) { return "2.0.0-beta"; }

PS_API int ps_init(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (g_music) return 0;
    ComForCall com;
    try {
        // Left over from a crash: put back app volumes and the default microphone.
        restore_all(restore_file_path());
        give_back_default_mic();
    } catch (const std::exception&) {
    }
    // The watchdog puts volumes back if this program ends without cleaning up (a crash).
    const std::wstring tool = tool_path();
    std::error_code ec;
    if (std::filesystem::exists(tool, ec)) start_helper(tool, L"watch " + std::to_wstring(GetCurrentProcessId()));
    g_music = std::make_unique<MusicPath>(restore_file_path(), restore_command());
    g_voice = std::make_unique<VoicePath>(restore_command());
    return 0;
}

PS_API void ps_shutdown(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    g_music.reset();  // stops and puts every app volume back
    g_voice.reset();  // stops and gives the default microphone back
    ComForCall com;
    try {
        restore_all(restore_file_path());
        give_back_default_mic();
        update_sign_in_safety_net(restore_command());
    } catch (const std::exception&) {
    }
}

PS_API int ps_restore_all(void) {
    ComForCall com;
    try {
        const auto r = restore_all(restore_file_path());
        return r.restored + r.remembered;
    } catch (const std::exception&) {
        return -1;
    }
}

PS_API const char* ps_list_sources_json(void) {
    ComForCall com;
    nlohmann::json list = nlohmann::json::array();
    try {
        const ProcessSnapshot snap;
        const auto own = snap.tree(GetCurrentProcessId());
        std::map<std::wstring, nlohmann::json> apps;
        for (const auto& s : list_sessions()) {
            if (s.pid == 0 || s.system_sounds || own.count(s.pid) || s.state == AudioSessionStateExpired) continue;
            const DWORD root = snap.app_root(s.pid);
            std::wstring exe = process_path(root);
            if (exe.empty()) exe = s.exe;
            if (exe.empty()) continue;
            auto& app = apps[lower(exe)];
            if (app.is_null()) {
                app = {{"exe", utf8(exe)}, {"name", utf8(app_display_name(exe))}, {"pid", root}, {"playing", false}};
            }
            if (s.state == AudioSessionStateActive) app["playing"] = true;
        }
        for (auto& [key, app] : apps) list.push_back(app);
        std::sort(list.begin(), list.end(), [](const nlohmann::json& a, const nlohmann::json& b) {
            return a["name"].get<std::string>() < b["name"].get<std::string>();
        });
    } catch (const std::exception&) {
    }
    return hand_back(list.dump());
}

PS_API const char* ps_list_mics_json(void) {
    ComForCall com;
    nlohmann::json list = nlohmann::json::array();
    try {
        const std::wstring default_id = VoicePath::default_mic_id();
        const std::wstring cable_mic = find_cable().mic_id;
        for (const auto& e : list_endpoints(eCapture, DEVICE_STATE_ACTIVE)) {
            // Swoopy Mic is where the shifted voice goes, so it can't be a source.
            if (e.id == cable_mic || (cable_mic.empty() && lower(e.adapter) == L"vb-audio virtual cable")) continue;
            list.push_back({{"id", utf8(e.id)}, {"name", utf8(e.name)}, {"default", e.id == default_id}});
        }
    } catch (const std::exception&) {
    }
    return hand_back(list.dump());
}

PS_API const char* ps_status_json(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    nlohmann::json j = {{"version", ps_version()}, {"started", bool(g_music)}, {"arch", process_arch()}};
    if (g_music) j["music"] = g_music->status();
    if (g_voice) j["voice"] = g_voice->status();
    return hand_back(j.dump());
}

PS_API int ps_music_start(int mode, int pid) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music) return -1;
    if (mode == 1) g_music->start_all();
    else g_music->start_pid(DWORD(pid));
    return 0;
}

PS_API int ps_music_start_all(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music) return -1;
    g_music->start_all();
    return 0;
}

PS_API int ps_music_set_apps(const char* exe_paths_json) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music || !exe_paths_json) return -1;
    std::vector<std::wstring> exes;
    try {
        for (const auto& item : nlohmann::json::parse(exe_paths_json)) exes.push_back(wide(item.get<std::string>()));
    } catch (const std::exception&) {
        return -2;
    }
    g_music->start_apps(exes);
    return 0;
}

PS_API int ps_music_stop(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music) return -1;
    g_music->stop();
    return 0;
}

PS_API int ps_music_set_semitones(double half_steps) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music) return -1;
    g_music->set_semitones(std::clamp(half_steps, -24.0, 24.0));
    return 0;
}

PS_API int ps_music_set_advanced(int on) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_music) return -1;
    g_music->set_advanced(on != 0);
    return 0;
}

PS_API int ps_voice_start(const char* endpoint_id) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->start(endpoint_id ? wide(endpoint_id) : L"");
    return 0;
}

PS_API int ps_voice_stop(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->stop();
    return 0;
}

PS_API int ps_voice_set_semitones(double half_steps) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->set_semitones(std::clamp(half_steps, -24.0, 24.0));
    return 0;
}

PS_API int ps_voice_set_formant(int natural) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->set_natural(natural != 0);
    return 0;
}

PS_API int ps_voice_test_start(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->test_start();
    return 0;
}

PS_API int ps_voice_test_stop(void) {
    std::lock_guard<std::mutex> lock(g_lock);
    if (!g_voice) return -1;
    g_voice->test_stop();
    return 0;
}

}  // extern "C"

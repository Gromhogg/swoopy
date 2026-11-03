// Everyday commands: setting up the virtual mic, putting volumes back, the watchdog.
#include "tool/tool.h"

#include "win/cable.h"
#include "win/devices.h"
#include "win/mic_default.h"
#include "win/music.h"
#include "win/voice.h"
#include "win/process.h"
#include "win/quiet.h"

#include <algorithm>
#include <chrono>
#include <filesystem>
#include <thread>

namespace ps::tool {

int setup_mic(const Args& args) {
    ComScope com;
    SetupOptions options;
    options.silent = args.has(L"--silent");
    options.pack_zip = args.get(L"--pack");
    options.work_dir = args.get(L"--work");
    options.skip_installer = args.has(L"--skip-vb-setup");  // checks only
    nlohmann::json log = nlohmann::json::array();
    const int code = ps::setup_mic(options, log);
    const auto cable = find_cable();
    say(nlohmann::json{{"result", code},
                       {"cable", cable.present},
                       {"mic", utf8(cable.mic_name)},
                       {"feed", utf8(cable.feed_name)},
                       {"log", log}}
            .dump(2));
    return code;
}

int restore(const Args& args) {
    ComScope com;
    const std::wstring default_file = restore_file_path();
    const std::wstring file = args.get(L"--file", default_file);
    const auto result = restore_all(file);
    const int mic = give_back_default_mic();
    // The sign-in safety net is only for the normal list.
    std::error_code ec;
    if (file == default_file && !std::filesystem::exists(file, ec) && !default_mic_taken()) set_restore_at_sign_in(L"");
    say(nlohmann::json{{"restored", result.restored},
                       {"remembered", result.remembered},
                       {"failed", result.failed},
                       {"pending", result.pending},
                       {"default_mic_given_back", mic},
                       {"log", result.log}}
            .dump());
    return result.failed == 0 ? 0 : 1;
}

int restore_names(const Args&) {
    ComScope com;
    nlohmann::json log = nlohmann::json::array();
    const int code = restore_cable_names(log);
    say(log.dump());
    return code;
}

int remove_cable(const Args&) {
    ComScope com;
    nlohmann::json log = nlohmann::json::array();
    const int code = ps::remove_cable(log);
    say(log.dump());
    return code;
}

// Waits for Swoopy (process `pid`) to end, then puts every app volume back. Started by the app,
// so volumes come back even if the app crashes or is ended from Task Manager.
int watch(const Args& args) {
    const DWORD pid = DWORD(std::stoul(args.positional(0, L"0")));
    const std::wstring default_file = restore_file_path();
    const std::wstring file = args.get(L"--file", default_file);
    if (HANDLE process = OpenProcess(SYNCHRONIZE, FALSE, pid)) {
        WaitForSingleObject(process, INFINITE);
        CloseHandle(process);
    }
    ComScope com;
    // Twice: right away, and again a moment later for apps that quit at the same time
    // (Windows remembers their volume a little after they close).
    for (int pass = 0; pass < 2; ++pass) {
        try {
            restore_all(file);
            give_back_default_mic();
        } catch (const std::exception&) {
        }
        if (pass == 0) std::this_thread::sleep_for(std::chrono::seconds(4));
    }
    std::error_code ec;
    if (file == default_file && !std::filesystem::exists(file, ec) && !default_mic_taken()) set_restore_at_sign_in(L"");
    return 0;
}

// For the crash check: runs the "What you hear" path for one process (--pid) and/or the voice
// path (--voice, with a made-up voice) until it's ended.
int host(const Args& args) {
    ComScope com;
    const DWORD pid = DWORD(args.number(L"--pid", 0));
    const std::wstring file = args.get(L"--file", restore_file_path());
    start_helper(self_path(), L"watch " + std::to_wstring(GetCurrentProcessId()) + L" --file \"" + file + L"\"");
    MusicPath music(file, L"");
    if (pid) {
        music.set_semitones(args.number(L"--semitones", 2));
        music.start_pid(pid);
    }
    VoicePath voice;
    if (args.has(L"--voice")) {
        voice.set_test_input([](float* out, size_t n) { std::fill(out, out + n, 0.0f); });
        voice.start(L"");
    }
    say("host: running");
    const double seconds = args.number(L"--seconds", 600);
    std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
    return 0;
}

}  // namespace ps::tool


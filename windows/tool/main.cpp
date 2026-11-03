// SwoopyTool.exe <command> [options]
//
// Everyday (the installer and the app use these):
//   setup-mic [--silent] [--pack file.zip]   install VB-CABLE if needed and name it "Swoopy Mic" (admin)
//                                            exit code: 0 ready, 3010 restart needed, 1223 not installed
//   restore [--file path]                    put back app volumes that Swoopy lowered
//   restore-names                            give VB-CABLE its own names back (admin)
//   remove-cable                             remove VB-CABLE (admin)
//   watch <pid> [--file path]                wait for Swoopy to end, then put volumes back
// Information:
//   diag                                     sound devices, app sessions, restore list (JSON)
// Checks (used on GitHub):
//   tonegen [--freq 440] [--amp 0.25] [--seconds 600] [--device "name"] [--pulse] [--spawn-child] [--log file]
//   record --device "name" --seconds 5 --out file.wav [--channels 1]
//   probe [--out folder]                     how app volume affects app recording
//   e2e-music | e2e-advanced | e2e-voice | e2e-crash [--out folder]
//   e2e-music --only-later N [--no-nudge]    only "a ticked app opens later", N times (to look for rare failures)
//   make-song --out song.wav [--seconds 20]  a made-up song for checks (no sound devices needed)
//   render-file IN OUT [--steps 8] [--advanced] [--steps-at "4:8,8:-5"]   shift a WAV file offline
//   set-default <playback|recording> "name"   ("pitch-shift-feed" / "pitch-shift-mic" = our cable)
//   selftest                                 shift a made-up tone with Rubber Band and check the pitch
#include "tool/tool.h"

#include "dsp/analysis.h"
#include "dsp/music_shifter.h"
#include "win/com.h"
#include "win/cable.h"
#include "win/devices.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <nlohmann/json.hpp>

namespace ps::tool {

bool Args::has(const wchar_t* flag) const {
    for (const auto& a : items)
        if (a == flag) return true;
    return false;
}

std::wstring Args::get(const wchar_t* flag, const std::wstring& fallback) const {
    for (size_t i = 0; i + 1 < items.size(); ++i)
        if (items[i] == flag) return items[i + 1];
    return fallback;
}

double Args::number(const wchar_t* flag, double fallback) const {
    const auto text = get(flag);
    if (text.empty()) return fallback;
    try {
        return std::stod(text);
    } catch (...) {
        return fallback;
    }
}

std::wstring Args::positional(size_t index, const std::wstring& fallback) const {
    // Flags that stand alone (no value after them).
    static const std::vector<std::wstring> switches = {L"--silent", L"--pulse", L"--spawn-child", L"--quick", L"--voice", L"--skip-vb-setup", L"--advanced", L"--no-nudge"};
    size_t seen = 0;
    for (size_t i = 1; i < items.size(); ++i) {
        if (items[i].rfind(L"--", 0) == 0) {
            if (std::find(switches.begin(), switches.end(), items[i]) == switches.end()) ++i;  // skip its value
            continue;
        }
        if (seen++ == index) return items[i];
    }
    return fallback;
}

void say(const std::string& line) {
    std::fwrite(line.data(), 1, line.size(), stdout);
    std::fputc('\n', stdout);
    std::fflush(stdout);
}

int set_default(const Args& args) {
    ComScope com;
    const std::wstring direction = args.positional(0);
    const std::wstring name = args.positional(1);
    const EDataFlow flow = direction == L"recording" ? eCapture : eRender;
    // "pitch-shift-feed" / "pitch-shift-mic": our cable, even when there are two cables.
    std::wstring id;
    if (name == L"pitch-shift-feed") id = find_cable().feed_id;
    else if (name == L"pitch-shift-mic") id = find_cable().mic_id;
    else if (const auto endpoint = find_endpoint(flow, name)) id = endpoint->id;
    if (id.empty()) {
        say("No active device named like \"" + utf8(name) + "\".");
        return 1;
    }
    const HRESULT hr = set_default_endpoint_all(id);
    say("Default " + utf8(direction) + " device -> " + utf8(name) + ": " + hr_text(hr));
    return SUCCEEDED(hr) ? 0 : 1;
}

int selftest(const Args&) {
    const int rate = 48000;
    MusicShifter shifter(rate, 2, 2.0);
    const auto in = make_tone(440.0, 0.25, rate, 2, 4.0);
    std::vector<float> out;
    for (size_t i = 0; i < in.size() / 2; i += 480) shifter.process(in.data() + i * 2, 480, out);
    const auto left = take_channel(out, 2, 0);
    const size_t n = size_t(rate * 1.5);
    if (left.size() < n) {
        say("selftest: Rubber Band gave too little sound");
        return 1;
    }
    const auto m = measure_tone(left.data() + left.size() - n, n, rate, 493.88);
    const double expected = 440.0 * std::pow(2.0, 2.0 / 12);
    const bool ok = std::fabs(m.frequency - expected) < 0.5 && std::fabs(m.level_db - to_db(0.25)) < 1.0;
    say(nlohmann::json{{"selftest", ok ? "pass" : "fail"}, {"frequency", m.frequency}, {"expected", expected},
                       {"level_db", m.level_db}, {"thdn_db", m.thdn_db}}
            .dump());
    return ok ? 0 : 1;
}

}  // namespace ps::tool

int wmain(int argc, wchar_t** argv) {
    using namespace ps::tool;
    Args args;
    for (int i = 1; i < argc; ++i) args.items.emplace_back(argv[i]);
    const std::wstring command = args.items.empty() ? L"" : args.items[0];
    try {
        if (command == L"setup-mic") return setup_mic(args);
        if (command == L"restore") return restore(args);
        if (command == L"restore-names") return restore_names(args);
        if (command == L"remove-cable") return remove_cable(args);
        if (command == L"watch") return watch(args);
        if (command == L"diag") return diag(args);
        if (command == L"tonegen") return tonegen(args);
        if (command == L"record") return record(args);
        if (command == L"probe") return probe(args);
        if (command == L"e2e-music") return e2e_music(args);
        if (command == L"e2e-advanced") return e2e_advanced(args);
        if (command == L"make-song") return make_song(args);
        if (command == L"render-file") return render_file(args);
        if (command == L"e2e-voice") return e2e_voice(args);
        if (command == L"e2e-crash") return e2e_crash(args);
        if (command == L"host") return host(args);
        if (command == L"set-default") return set_default(args);
        if (command == L"selftest") return selftest(args);
    } catch (const std::exception& e) {
        say(std::string("Error: ") + e.what());
        return 2;
    }
    say("Usage: SwoopyTool <setup-mic|restore|restore-names|remove-cable|watch|diag|tonegen|record|probe|"
        "e2e-music|e2e-advanced|e2e-voice|e2e-crash|make-song|render-file|set-default|selftest> [options]");
    return command.empty() ? 0 : 1;
}

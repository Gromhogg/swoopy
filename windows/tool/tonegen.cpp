// tonegen: plays a steady test tone, like a music app would. The checks record it and measure it.
//   --pulse        tone for 0.3 s, then quiet for 0.7 s, over and over (for timing checks)
//   --spawn-child  stay silent and start a second tonegen that plays (like a browser's sound helper)
//   --log FILE     write a line "<time in ms> <count>" each time its own sound ran empty (a short gap the checks
//                  would hear that has nothing to do with Swoopy)
#include "tool/tool.h"

#include "win/devices.h"
#include "win/process.h"
#include "win/render.h"

#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <thread>

namespace ps::tool {

int tonegen(const Args& args) {
    ComScope com;
    const double freq = args.number(L"--freq", 440.0);
    const double amp = args.number(L"--amp", 0.25);
    const double seconds = args.number(L"--seconds", 600.0);
    const bool pulse = args.has(L"--pulse");
    const std::wstring device_name = args.get(L"--device");
    const std::wstring log = args.get(L"--log");

    if (args.has(L"--spawn-child")) {
        // The parent stays silent; its child makes the sound.
        auto child = start_process(self_path(), L"tonegen --freq " + std::to_wstring(freq) + L" --amp " +
                                                    std::to_wstring(amp) + L" --seconds " + std::to_wstring(seconds) +
                                                    (log.empty() ? L"" : L" --log \"" + log + L"\""));
        say("tonegen: pid " + std::to_string(GetCurrentProcessId()) + ", child " + std::to_string(child->pid()));
        child->wait(DWORD(seconds * 1000) + 5000);
        return 0;
    }

    std::wstring endpoint_id;
    if (!device_name.empty()) {
        const auto e = find_endpoint(eRender, device_name);
        if (!e) {
            say("tonegen: no playback device named like \"" + utf8(device_name) + "\"");
            return 1;
        }
        endpoint_id = e->id;
    }

    const double two_pi = 2 * 3.14159265358979323846;
    double phase = 0;
    uint64_t n = 0;
    const double step = two_pi * freq / kRate;
    auto renderer = Renderer::to_endpoint(endpoint_id, [&](float* out, size_t frames) {
        for (size_t i = 0; i < frames; ++i, ++n) {
            float v = float(amp * std::sin(phase));
            phase += step;
            if (phase > two_pi) phase -= two_pi;
            if (pulse) {
                const uint64_t in_cycle = n % uint64_t(kRate);  // 1 s cycle
                if (in_cycle >= uint64_t(kRate * 0.3)) v = 0;
                if (in_cycle == 0) phase = 0;  // each pulse starts the same way
            }
            for (int c = 0; c < kChannels; ++c) out[i * kChannels + size_t(c)] = v;
        }
    });
    say("tonegen: pid " + std::to_string(GetCurrentProcessId()) + ", " + std::to_string(freq) + " Hz");

    const auto end = std::chrono::steady_clock::now() + std::chrono::duration<double>(seconds);
    uint64_t starved = 0;
    while (std::chrono::steady_clock::now() < end) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        if (!log.empty() && renderer->starved() != starved) {
            starved = renderer->starved();
            const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch());
            std::ofstream(std::filesystem::path(log), std::ios::app) << ms.count() << ' ' << starved << '\n';
        }
        if (FAILED(renderer->error())) {
            say("tonegen: playing stopped: " + hr_text(renderer->error()));
            return 3;
        }
    }
    renderer->stop();
    return 0;
}

}  // namespace ps::tool

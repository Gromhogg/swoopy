// SwoopyTool.exe: setup, repair and test commands that run without the window.
#pragma once
#include <string>
#include <vector>

namespace ps::tool {

struct Args {
    std::vector<std::wstring> items;
    bool has(const wchar_t* flag) const;
    std::wstring get(const wchar_t* flag, const std::wstring& fallback = L"") const;
    double number(const wchar_t* flag, double fallback) const;
    std::wstring positional(size_t index, const std::wstring& fallback = L"") const;  // after the command
};

// Everyday commands (setup.cpp)
int setup_mic(const Args& args);
int restore(const Args& args);
int restore_names(const Args& args);
int remove_cable(const Args& args);
int watch(const Args& args);

// Information (diag.cpp)
int diag(const Args& args);

// Checks (tonegen.cpp, record.cpp, probe.cpp, e2e.cpp)
int tonegen(const Args& args);
int record(const Args& args);
int probe(const Args& args);
int e2e_music(const Args& args);
int e2e_advanced(const Args& args);
int e2e_voice(const Args& args);

// Offline (render.cpp)
int make_song(const Args& args);
int render_file(const Args& args);
int e2e_crash(const Args& args);
int host(const Args& args);
int set_default(const Args& args);
int selftest(const Args& args);

// Prints a line to the console (UTF-8) and flushes it, so logs on GitHub show it right away.
void say(const std::string& line);

}  // namespace ps::tool

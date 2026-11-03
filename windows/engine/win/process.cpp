#include "win/process.h"

#include <tlhelp32.h>

#include <cstdio>
#include <vector>

namespace ps {

ChildProcess::~ChildProcess() {
    if (process_) CloseHandle(process_);
}

bool ChildProcess::running() const { return WaitForSingleObject(process_, 0) == WAIT_TIMEOUT; }

bool ChildProcess::wait(DWORD ms) const { return WaitForSingleObject(process_, ms) == WAIT_OBJECT_0; }

DWORD ChildProcess::exit_code() const {
    DWORD code = 0;
    GetExitCodeProcess(process_, &code);
    return code;
}

void ChildProcess::kill() {
    if (running()) {
        TerminateProcess(process_, 9);
        WaitForSingleObject(process_, 5000);
    }
}

std::wstring self_path() {
    std::vector<wchar_t> buf(MAX_PATH);
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buf.data(), DWORD(buf.size()));
        if (n < buf.size()) return std::wstring(buf.data(), n);
        buf.resize(buf.size() * 2);
    }
}

std::wstring module_dir() {
    HMODULE module = nullptr;
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                       reinterpret_cast<LPCWSTR>(&module_dir), &module);
    std::vector<wchar_t> buf(MAX_PATH);
    for (;;) {
        const DWORD n = GetModuleFileNameW(module, buf.data(), DWORD(buf.size()));
        if (n < buf.size()) {
            std::wstring path(buf.data(), n);
            const auto slash = path.find_last_of(L"\\/");
            return slash == std::wstring::npos ? L"." : path.substr(0, slash);
        }
        buf.resize(buf.size() * 2);
    }
}

std::wstring tool_path() { return module_dir() + L"\\SwoopyTool.exe"; }

DWORD parent_pid_of(DWORD pid) {
    DWORD parent = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return 0;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof entry;
    if (Process32FirstW(snap, &entry)) {
        do {
            if (entry.th32ProcessID == pid) parent = entry.th32ParentProcessID;
        } while (Process32NextW(snap, &entry));
    }
    CloseHandle(snap);
    return parent;
}

std::unique_ptr<ChildProcess> start_detached(const std::wstring& exe, const std::wstring& args, DWORD parent_pid) {
    HANDLE parent = OpenProcess(PROCESS_CREATE_PROCESS, FALSE, parent_pid);
    if (!parent) throw WinError("Could not open the parent process", HRESULT_FROM_WIN32(GetLastError()));
    SIZE_T size = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &size);
    std::vector<BYTE> buffer(size);
    auto* attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(buffer.data());
    InitializeProcThreadAttributeList(attributes, 1, 0, &size);
    UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_PARENT_PROCESS, &parent, sizeof(parent), nullptr,
                              nullptr);
    STARTUPINFOEXW si{};
    si.StartupInfo.cb = sizeof si;
    si.lpAttributeList = attributes;
    PROCESS_INFORMATION pi{};
    std::wstring command = L"\"" + exe + L"\" " + args;
    const BOOL ok = CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE,
                                   CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT, nullptr, nullptr,
                                   &si.StartupInfo, &pi);
    const DWORD error = GetLastError();
    DeleteProcThreadAttributeList(attributes);
    CloseHandle(parent);
    if (!ok) throw WinError("Could not start " + utf8(exe), HRESULT_FROM_WIN32(error));
    CloseHandle(pi.hThread);
    return std::make_unique<ChildProcess>(pi.hProcess, pi.dwProcessId);
}

bool start_helper(const std::wstring& exe, const std::wstring& args) {
    std::wstring command = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    // Try to leave any "job" we're in, so the helper isn't ended together with us.
    for (DWORD flags : {DWORD(CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB), DWORD(CREATE_NO_WINDOW)}) {
        std::wstring cmd = command;
        if (CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, flags, nullptr, nullptr, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(pi.hProcess);
            return true;
        }
    }
    return false;
}

std::unique_ptr<ChildProcess> start_process(const std::wstring& exe, const std::wstring& args) {
    std::wstring command = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si,
                        &pi))
        throw WinError("Could not start " + utf8(exe), HRESULT_FROM_WIN32(GetLastError()));
    CloseHandle(pi.hThread);
    return std::make_unique<ChildProcess>(pi.hProcess, pi.dwProcessId);
}

namespace {
using RtlGetVersionFn = LONG(WINAPI*)(OSVERSIONINFOW*);

OSVERSIONINFOW real_version() {
    OSVERSIONINFOW info{};
    info.dwOSVersionInfoSize = sizeof info;
    // GetVersionEx can lie to programs without a manifest; RtlGetVersion doesn't.
    if (HMODULE ntdll = GetModuleHandleW(L"ntdll.dll")) {
        if (auto fn = reinterpret_cast<RtlGetVersionFn>(reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion"))))
            fn(&info);
    }
    return info;
}

std::string arch_name(USHORT machine) {
    switch (machine) {
        case IMAGE_FILE_MACHINE_AMD64: return "x64";
        case IMAGE_FILE_MACHINE_ARM64: return "arm64";
        case IMAGE_FILE_MACHINE_I386: return "x86";
        default: return "unknown";
    }
}
}  // namespace

std::string os_text() {
    const auto v = real_version();
    char buf[64];
    std::snprintf(buf, sizeof buf, "Windows %lu.%lu.%lu", static_cast<unsigned long>(v.dwMajorVersion),
                  static_cast<unsigned long>(v.dwMinorVersion), static_cast<unsigned long>(v.dwBuildNumber));
    return buf;
}

DWORD os_build() { return real_version().dwBuildNumber; }

std::string machine_arch() {
    USHORT process = 0, native = 0;
    if (IsWow64Process2(GetCurrentProcess(), &process, &native)) return arch_name(native);
    return process_arch();
}

std::string process_arch() {
#if defined(_M_ARM64) || defined(__aarch64__)
    return "arm64";
#elif defined(_M_X64) || defined(__x86_64__)
    return "x64";
#else
    return "x86";
#endif
}

}  // namespace ps

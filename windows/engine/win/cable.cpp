#include "win/cable.h"

#include "win/devices.h"
#include "win/policy_config.h"
#include "win/process.h"

#include <bcrypt.h>
#include <setupapi.h>
#include <newdev.h>
#include <urlmon.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <thread>

namespace ps {

namespace fs = std::filesystem;

namespace {

// The official VB-CABLE Driver Pack 45 (x64 + ARM64), checked against this exact file.
const wchar_t* kPackUrl = L"https://download.vb-audio.com/Download_CABLE/VBCABLE_Driver_Pack45.zip";
const char* kPackSha256 = "b950e39f01af1d04ea623c8f6d8eb9b6ea5c477c637295fabf20631c85116bfb";
const wchar_t* kHardwareId = L"VBAudioVACWDM";

bool is_cable_adapter(const Endpoint& e) { return lower(e.adapter) == L"vb-audio virtual cable"; }

std::wstring reg_string(const wchar_t* name) {
    wchar_t buf[1024];
    DWORD size = sizeof(buf);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, kSettingsKey, name, RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS)
        return {};
    return buf;
}

DWORD reg_dword(const wchar_t* name) {
    DWORD value = 0, size = sizeof(value);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, kSettingsKey, name, RRF_RT_REG_DWORD, nullptr, &value, &size) != ERROR_SUCCESS)
        return 0;
    return value;
}

bool reg_set(const wchar_t* name, const std::wstring& text) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, kSettingsKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS)
        return false;
    const bool ok = RegSetValueExW(key, name, 0, REG_SZ, reinterpret_cast<const BYTE*>(text.c_str()),
                                   DWORD((text.size() + 1) * sizeof(wchar_t))) == ERROR_SUCCESS;
    RegCloseKey(key);
    return ok;
}

bool reg_set(const wchar_t* name, DWORD value) {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, kSettingsKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) !=
        ERROR_SUCCESS)
        return false;
    const bool ok =
        RegSetValueExW(key, name, 0, REG_DWORD, reinterpret_cast<const BYTE*>(&value), sizeof(value)) == ERROR_SUCCESS;
    RegCloseKey(key);
    return ok;
}

int run_and_wait(const std::wstring& exe, const std::wstring& args, DWORD timeout_ms, bool hidden) {
    std::wstring command = L"\"" + exe + L"\" " + args;
    STARTUPINFOW si{};
    si.cb = sizeof si;
    if (hidden) {
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
    }
    PROCESS_INFORMATION pi{};
    if (!CreateProcessW(exe.c_str(), command.data(), nullptr, nullptr, FALSE, hidden ? CREATE_NO_WINDOW : 0, nullptr,
                        nullptr, &si, &pi))
        return -1;
    CloseHandle(pi.hThread);
    DWORD code = DWORD(-2);
    if (WaitForSingleObject(pi.hProcess, timeout_ms) == WAIT_OBJECT_0) GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return int(code);
}

std::wstring system_folder() {
    wchar_t buf[MAX_PATH];
    const UINT n = GetSystemDirectoryW(buf, MAX_PATH);
    return std::wstring(buf, n);
}

}  // namespace

std::string sha256_file(const std::wstring& path) {
    std::ifstream f{fs::path(path), std::ios::binary};
    if (!f) return {};
    BCRYPT_ALG_HANDLE alg = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return {};
    std::string out;
    if (BCryptCreateHash(alg, &hash, nullptr, 0, nullptr, 0, 0) == 0) {
        std::vector<char> buf(1 << 16);
        while (f) {
            f.read(buf.data(), std::streamsize(buf.size()));
            const auto got = f.gcount();
            if (got > 0) BCryptHashData(hash, reinterpret_cast<PUCHAR>(buf.data()), ULONG(got), 0);
        }
        UCHAR digest[32];
        if (BCryptFinishHash(hash, digest, sizeof digest, 0) == 0) {
            char hex[3];
            for (UCHAR b : digest) {
                std::snprintf(hex, sizeof hex, "%02x", b);
                out += hex;
            }
        }
        BCryptDestroyHash(hash);
    }
    BCryptCloseAlgorithmProvider(alg, 0);
    return out;
}

CableInfo find_cable() {
    CableInfo info;
    std::vector<Endpoint> feeds, mics;
    try {
        for (const auto& e : list_endpoints(eRender, DEVICE_STATEMASK_ALL))
            if (is_cable_adapter(e)) feeds.push_back(e);
        for (const auto& e : list_endpoints(eCapture, DEVICE_STATE_ACTIVE))
            if (is_cable_adapter(e)) mics.push_back(e);
    } catch (const std::exception&) {
        return info;
    }
    const std::wstring saved_feed = reg_string(L"FeedEndpointId");
    for (const auto& e : feeds) {
        const bool extra = lower(e.description).find(L"16") != std::wstring::npos;
        if (extra) {
            info.extra_id = e.id;
            continue;
        }
        if (e.state != DEVICE_STATE_ACTIVE) continue;
        if (info.feed_id.empty() || e.id == saved_feed) {
            info.feed_id = e.id;
            info.feed_name = e.name;
        }
    }
    const std::wstring saved_mic = reg_string(L"MicEndpointId");
    for (const auto& e : mics) {
        if (info.mic_id.empty() || e.id == saved_mic) {
            info.mic_id = e.id;
            info.mic_name = e.name;
        }
    }
    info.present = !info.feed_id.empty() && !info.mic_id.empty();
    return info;
}

namespace {
// Calls `each` for every VB-CABLE device Windows knows about (also ones that aren't working yet).
template <typename Each>
void for_each_cable_device(Each each) {
    HDEVINFO devs = SetupDiGetClassDevsW(nullptr, nullptr, nullptr, DIGCF_ALLCLASSES);
    if (devs == INVALID_HANDLE_VALUE) return;
    SP_DEVINFO_DATA dev{};
    dev.cbSize = sizeof dev;
    for (DWORD i = 0; SetupDiEnumDeviceInfo(devs, i, &dev); ++i) {
        wchar_t ids[2048] = {};
        if (!SetupDiGetDeviceRegistryPropertyW(devs, &dev, SPDRP_HARDWAREID, nullptr, reinterpret_cast<PBYTE>(ids),
                                               sizeof(ids) - 4, nullptr))
            continue;
        bool match = false;
        for (const wchar_t* p = ids; *p; p += wcslen(p) + 1) match = match || _wcsicmp(p, kHardwareId) == 0;
        if (match) each(devs, dev);
    }
    SetupDiDestroyDeviceInfoList(devs);
}

void reg_remove(const wchar_t* name) { RegDeleteKeyValueW(HKEY_LOCAL_MACHINE, kSettingsKey, name); }
}  // namespace

bool cable_driver_installed() {
    bool found = false;
    for_each_cable_device([&](HDEVINFO, SP_DEVINFO_DATA&) { found = true; });
    return found;
}

bool cable_restart_needed() { return reg_dword(L"RestartNeeded") != 0 && cable_driver_installed(); }

HRESULT rename_endpoint(const std::wstring& id, const std::wstring& name) {
    PROPVARIANT value;
    PropVariantInit(&value);
    value.vt = VT_LPWSTR;
    value.pwszVal = const_cast<LPWSTR>(name.c_str());
    HRESULT hr = E_FAIL;
    try {
        auto device = device_by_id(id);
        ComPtr<IPropertyStore> store;
        hr = device->OpenPropertyStore(STGM_READWRITE, &store);
        if (SUCCEEDED(hr)) hr = store->SetValue(kDeviceDesc, value);
        if (SUCCEEDED(hr)) hr = store->Commit();
    } catch (const WinError& e) {
        hr = e.hr;
    }
    if (FAILED(hr)) {
        ComPtr<IPolicyConfig> policy;
        if (SUCCEEDED(open_policy_config(policy))) hr = policy->SetPropertyValue(id.c_str(), 0, kDeviceDesc, &value);
    }
    return hr;  // (value points at `name`, so it is not cleared)
}

HRESULT set_endpoint_visible(const std::wstring& id, bool visible) {
    ComPtr<IPolicyConfig> policy;
    HRESULT hr = open_policy_config(policy);
    if (SUCCEEDED(hr)) hr = policy->SetEndpointVisibility(id.c_str(), visible ? 1 : 0);
    return hr;
}

int setup_mic(const SetupOptions& o, nlohmann::json& log) {
    auto say = [&](const std::string& text) { log.push_back(text); };
    CableInfo cable = find_cable();
    bool installed_now = false;
    if (cable.present) {
        say("VB-CABLE is already installed.");
    } else {
        // Remember the user's default speakers and microphone; installing a sound driver can change them.
        struct Saved {
            EDataFlow flow;
            ERole role;
            std::wstring id;
        };
        std::vector<Saved> saved;
        for (EDataFlow flow : {eRender, eCapture})
            for (ERole role : {eConsole, eMultimedia, eCommunications})
                saved.push_back({flow, role, default_endpoint_id(flow, role)});

        const fs::path work = o.work_dir.empty() ? fs::temp_directory_path() / L"SwoopySetup" : fs::path(o.work_dir);
        std::error_code ec;
        fs::create_directories(work, ec);
        std::wstring zip = o.pack_zip;
        if (zip.empty()) {
            zip = (work / L"VBCABLE_Driver_Pack45.zip").wstring();
            say("Downloading VB-CABLE from vb-audio.com");
            const HRESULT hr = URLDownloadToFileW(nullptr, kPackUrl, zip.c_str(), 0, nullptr);
            if (FAILED(hr)) {
                say("Download failed: " + hr_text(hr));
                return 2;
            }
        }
        const std::string hash = sha256_file(zip);
        if (hash != kPackSha256) {
            say("The VB-CABLE download is not the expected file (" + hash + ")");
            return 3;
        }
        const fs::path unpacked = work / L"VBCABLE";
        fs::remove_all(unpacked, ec);
        fs::create_directories(unpacked, ec);
        const int tar = run_and_wait(system_folder() + L"\\tar.exe",
                                     L"-xf \"" + zip + L"\" -C \"" + unpacked.wstring() + L"\"", 120000, true);
        const fs::path setup = unpacked / L"VBCABLE_Setup_x64.exe";
        if (tar != 0 || !fs::exists(setup)) {
            say("Could not unpack VB-CABLE (tar " + std::to_string(tar) + ")");
            return 4;
        }
        // Visible: VB-Audio's own window, where the person clicks "Install Driver".
        // Silent: no window (for checks, or once VB-Audio allows bundling).
        say(o.silent ? "Installing VB-CABLE (silent)" : "Opening VB-Audio's installer");
        const int code = o.skip_installer ? -1
                                          : run_and_wait(setup.wstring(), o.silent ? L"-i -h" : L"", o.silent ? 300000 : 1800000, false);
        say("VB-CABLE setup finished with code " + std::to_string(code));
        installed_now = true;
        for (int i = 0; i < 30 && !find_cable().present; ++i) std::this_thread::sleep_for(std::chrono::seconds(1));

        // Put the user's defaults back.
        for (const auto& s : saved) {
            if (s.id.empty() || default_endpoint_id(s.flow, s.role) == s.id) continue;
            const HRESULT hr = set_default_endpoint(s.id, s.role);
            say(std::string("Put back default ") + (s.flow == eRender ? "playback" : "recording") + " device: " +
                hr_text(hr));
        }
        cable = find_cable();
        if (!cable.present) {
            if (!cable_driver_installed()) {
                // VB-Audio's window was closed without installing: nothing to restart for.
                reg_remove(L"RestartNeeded");
                say("VB-CABLE was not installed.");
                return kSetupNotInstalled;
            }
            reg_set(L"InstalledByPitchShift", DWORD(1));
            reg_set(L"RestartNeeded", DWORD(1));
            say("The virtual microphone will be ready after a restart.");
            return kSetupRestart;
        }
    }
    if (installed_now) reg_set(L"InstalledByPitchShift", DWORD(1));
    reg_set(L"RestartNeeded", DWORD(0));
    reg_set(L"FeedEndpointId", cable.feed_id);
    reg_set(L"MicEndpointId", cable.mic_id);
    // Only rename VB-CABLE if Swoopy installed it (someone else's setup stays as it is).
    if (reg_dword(L"InstalledByPitchShift") != 0) {
        const HRESULT feed = rename_endpoint(cable.feed_id, kFeedName);
        const HRESULT mic = rename_endpoint(cable.mic_id, kMicName);
        say("Named the cable: " + hr_text(feed) + ", " + hr_text(mic));
        if (!cable.extra_id.empty()) say("Hid the 16-channel input: " + hr_text(set_endpoint_visible(cable.extra_id, false)));
        if (SUCCEEDED(feed) && SUCCEEDED(mic)) reg_set(L"Renamed", DWORD(1));
    }
    return 0;
}

int restore_cable_names(nlohmann::json& log) {
    if (reg_dword(L"Renamed") == 0) {
        log.push_back("Names were not changed.");
        return 0;
    }
    const CableInfo cable = find_cable();
    int failures = 0;
    if (!cable.feed_id.empty()) failures += FAILED(rename_endpoint(cable.feed_id, L"CABLE Input"));
    if (!cable.mic_id.empty()) failures += FAILED(rename_endpoint(cable.mic_id, L"CABLE Output"));
    if (!cable.extra_id.empty()) set_endpoint_visible(cable.extra_id, true);
    if (failures == 0) reg_set(L"Renamed", DWORD(0));
    log.push_back(failures == 0 ? "Gave VB-CABLE its own names back." : "Could not rename VB-CABLE.");
    return failures == 0 ? 0 : 1;
}

int remove_cable(nlohmann::json& log) {
    std::vector<std::wstring> infs;
    int removed = 0;
    for_each_cable_device([&](HDEVINFO devs, SP_DEVINFO_DATA& dev) {
        HKEY drv = SetupDiOpenDevRegKey(devs, &dev, DICS_FLAG_GLOBAL, 0, DIREG_DRV, KEY_READ);
        if (drv != INVALID_HANDLE_VALUE) {
            wchar_t inf[MAX_PATH];
            DWORD size = sizeof(inf);
            if (RegGetValueW(drv, nullptr, L"InfPath", RRF_RT_REG_SZ, nullptr, inf, &size) == ERROR_SUCCESS)
                infs.push_back(inf);
            RegCloseKey(drv);
        }
        BOOL reboot = FALSE;
        if (DiUninstallDevice(nullptr, devs, &dev, 0, &reboot)) ++removed;
    });
    for (const auto& inf : infs) SetupUninstallOEMInfW(inf.c_str(), SUOI_FORCEDELETE, nullptr);
    log.push_back("Removed " + std::to_string(removed) + " VB-CABLE device(s).");
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, kSettingsKey);
    return 0;
}

}  // namespace ps

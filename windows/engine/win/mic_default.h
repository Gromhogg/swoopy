// While "Your voice" is on, Swoopy Mic is made the Windows default microphone, so call apps
// set to "Default" use it. The previous defaults are written down first
// (%LOCALAPPDATA%\Pitch Shift\mic-defaults.json) and given back when the voice is switched off,
// when Swoopy quits, on the next start after a crash, and by the watchdog.
// Nobody is ever left without their real microphone.
#pragma once
#include "win/com.h"

#include <string>

namespace ps {

std::wstring mic_defaults_path();

// Remembers the current default microphones (once) and makes `cable_mic` the default for every role.
HRESULT take_default_mic(const std::wstring& cable_mic);

// Gives the remembered default microphones back, but only where Swoopy Mic is still the
// default (if the person picked something else meanwhile, that stays). If the remembered mic is
// gone, another real microphone is used. Returns how many roles were changed.
int give_back_default_mic();

// The person's real microphone from before (empty if nothing is remembered).
std::wstring remembered_mic();

bool default_mic_taken();  // the list of remembered defaults exists

}  // namespace ps

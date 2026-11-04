// C pieces the Swift code uses: Rubber Band (pitch shifting), the sound ring, the Advanced processing engine, the
// voice changer (Natural and Realistic modes), and process info (to group helper processes under their app).
#include <rubberband/rubberband-c.h>
#include "AudioRing.h"
#include "Advanced/AdvancedChain.h"
#include "Heavy/HeavyChain.h"
#include "Voice/VoiceChanger.h"
#include "Voice/PulseShifter.h"
#include "Voice/VoiceModel.h"
#include "Voice/SoundGate.h"
#include <libproc.h>
#include <sys/proc_info.h>

// Which app "owns" a helper process (for example Safari for its sound process). Part of macOS, not in public headers.
pid_t responsibility_get_pid_responsible_for_pid(pid_t);

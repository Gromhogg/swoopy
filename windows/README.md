# Swoopy for Windows (beta)

Swoopy changes the pitch of **what you hear** (any app, or all sound) and of **your voice** in
calls (Discord, Zoom and others), live.

**This is a beta.** It has been tested on GitHub's Windows computers, not yet on many real PCs.
Things may not work on yours. If something goes wrong, see [If something goes wrong](#if-something-goes-wrong).

**Needs:** Windows 11 (x64 or ARM, like Snapdragon PCs).

## Install

**Recommended:** open **PowerShell** (click Start, type `PowerShell`, press Enter), paste this line,
and press Enter:

```
irm https://raw.githubusercontent.com/Gromhogg/swoopy/main/install.ps1 | iex
```

- Click **Yes** when Windows asks if you want to allow changes.
- A window from **VB-Audio** may open. Click **Install Driver**. This adds **Swoopy Mic**, which
  carries your voice into calls.
- Swoopy opens when it's done. It's also in the Start menu and on your Desktop.

Run the same line again any time to update.

**Or download it:** get `Swoopy-Setup.exe` from the
[Releases page](https://github.com/Gromhogg/swoopy/releases) and open it.

- Windows may say **"Windows protected your PC"**. Click **More info**, then **Run anyway**.
  (Swoopy is free and isn't signed with a paid certificate, so Windows doesn't know it yet.)
- If **Smart App Control** is on, Windows may block Swoopy completely, with no "Run anyway".
  It can be turned off in **Settings → Privacy & security → Windows Security → App & browser control →
  Smart App Control settings**, but Windows may not let you turn it back on later.
  Think about this before turning it off.

## How to use it

The window has two cards. Each has an on/off switch.

**What you hear**

- The big number is the change in half-steps. `+2` is higher, `−2` is lower, `0` is normal.
  12 half-steps is one octave.
- **−** and **+** move it by one half-step. **0** goes back to normal.
- **Exact amount:** click the number, type any amount from −24 to 24 (like `2.5` or `-1.25`) and
  press **Enter**. **Esc** cancels. While typing, the **↑** and **↓** keys change it by 1.
- The button under the number picks what changes:
  - **All sound**: everything on your PC.
  - Or tick one or more apps (like Spotify or Chrome). Only apps that are playing sound show up.
    Ticked apps that aren't open stay in the list (greyed) and are picked up again when they start.
    A small green dot marks apps playing sound right now.
- When the number looks faded, the apps you picked aren't playing right now.
- Turn on **Advanced processing** for music at bigger amounts: going up, the bass stays deep; going down, the top
  stays bright. A new amount takes a moment longer to kick in.
- Your speakers, headphones and volume keys work like normal.

**Your voice**

- Pick your microphone in the list.
- The big number and **−** **0** **+** work the same as above.
- **Natural** keeps your voice sounding like a person. **Cartoon** sounds like a cartoon character.
- **Test** records 5 seconds of how you sound in calls (red countdown), then plays it back.
  Click again to stop.
- The dot next to **Swoopy Mic** turns green (and gently pulses) while a call app is using your changed voice.

**In Discord, Zoom and other call apps:** leave the microphone on **Default**, or pick
**Swoopy Mic**. While "Your voice" is on, Swoopy Mic is your PC's default microphone.
When you switch it off or quit, your real microphone goes back to being the default.

**Bigger window:** drag an edge or a corner. Everything grows with the window. In a tall, narrow window
the two cards sit one above the other (handy next to Discord). Swoopy remembers the size.

**Closing the window** keeps Swoopy running (its icon is next to the clock).
Click the icon to open the window again. To stop it, right-click the icon and pick **Quit**.
Quitting puts every app's sound and your default microphone back the way they were.

## If something goes wrong

- **A button says "Repair Swoopy Mic":** click it, click **Yes** when Windows asks, then click
  **Install Driver** in VB-Audio's window.
- **A button says "Restart to finish setup":** restart your PC.
- **A button says "Allow microphone":** click it, and turn on **Let desktop apps access your
  microphone** in the Settings page that opens.
- **Call apps hear your normal voice:** make sure "Your voice" is on, and that the call app's
  microphone is **Default** or **Swoopy Mic**. Some apps need to be restarted after you
  change this.
- **An app is too quiet after Swoopy closed unexpectedly:** open Swoopy and quit it again.
  It puts volumes back when it starts. You can also fix it in **Settings → System → Sound →
  Volume mixer**.
- **Anything else:** open **Swoopy Diagnostics** from the Start menu. It puts a file called
  `Swoopy diagnostics.txt` on your Desktop. Send it with your bug report on the
  [Issues page](https://github.com/Gromhogg/swoopy/issues).

## Uninstall

Go to **Settings → Apps → Installed apps**, find **Swoopy (beta)**, and click **Uninstall**.
You can tick boxes to also remove Swoopy Mic (VB-CABLE) and your Swoopy settings.
Both are kept if you don't.

## Credits

- **Swoopy Mic** is [VB-CABLE](https://vb-audio.com/Cable/) by VB-Audio Software
  (www.vb-cable.com). VB-CABLE is donationware. If you keep using it, please consider
  [supporting VB-Audio](https://vb-audio.com/Cable/).
- Pitch shifting by the [Rubber Band Library](https://breakfastquay.com/rubberband/) (GPL).

License: GPL-3.0-or-later (same as the rest of Swoopy). See [LICENSE](../LICENSE).

---

# For developers

This folder holds the Windows version of Swoopy. It is built and tested only on GitHub's
Windows computers, on both x64 and ARM64: the sound engine in `.github/workflows/windows.yml`,
the window app and installer in `.github/workflows/windows-app.yml`.

## Folders

- `engine/dsp/` – the sound math (Rubber Band pitch shifting, tone measuring, WAV files). No Windows code, so its tests also run on a Mac.
- `engine/win/` – Windows sound: devices, app recording ("process loopback"), playing, app volumes.
- `engine/api/` – the small C interface the window app calls (`SwoopyEngine.dll`).
- `../Sources/Advanced/` – "Advanced processing": the Mac app's own engine, built straight in from there (shared, not
  copied). On Windows it uses a small FFT inside the same file instead of Apple's. `engine/dsp/advanced_shifter.*` wraps it.
- `tool/` – `SwoopyTool.exe`: setup, repair and test commands (`diag`, `tonegen`, `probe`, `restore`, `selftest`,
  `make-song`, `render-file`).
- `tests/` – tests for the sound math.
- `app/` – the window (C# / WPF, .NET 10, Windows 11 "Fluent" look).
- `app.tests/` – tests for the window's logic (xUnit), the window checker (`uismoke/`, FlaUI) and picture scripts (`ci/`).
- `installer/` – the installer (`Swoopy.iss`, Inno Setup 6.6+) and its checks (`ci/`).
- `ci/` – scripts used only by the engine's GitHub checks (installing the virtual cable, taking pictures).
- `../install.ps1` – the one-line installer.

## Building

Windows (Visual Studio 2022 or newer, CMake, .NET 10 SDK, Inno Setup 6.6+):

```
cmake -S windows -B build -A x64
cmake --build build --config Release
ctest --test-dir build -C Release
dotnet test windows/app.tests/Swoopy.Tests.csproj
dotnet publish windows/app/Swoopy.csproj -c Release -r win-x64 -p:EngineDir=%CD%\build\out\Release -o dist
copy build\out\Release\SwoopyTool.exe dist\
```

The installer holds both processor types: build `dist-x64` and `dist-arm64` (as above, with `-A ARM64` and
`-r win-arm64`), then `ISCC /DDistX64=... /DDistArm64=... windows\installer\Swoopy.iss`.

Mac (sound math and window logic tests only; needs `brew install cmake rubberband` and the .NET 10 SDK):

```
cmake -S windows -B build-mac && cmake --build build-mac && ./build-mac/dsp_tests
dotnet test windows/app.tests/Swoopy.Tests.csproj
```

Advanced processing offline, same code as live (compare with the Mac app's `--render-file`):
`SwoopyTool make-song --out song.wav`, then `SwoopyTool render-file song.wav out.wav --steps 8 --advanced`.
On the Mac, `-DPS_PORTABLE_FFT=ON` makes the tests use the Windows FFT too, and `-DPS_SYSTEM_RUBBERBAND=OFF` the same
Rubber Band build as Windows. That build gets one small fix (in `CMakeLists.txt`): its resampler's `reset()` now forgets
old sound, so Advanced processing's reused shifters line up like new ones, as on the Mac.

The window app also builds on a Mac (to check for mistakes, not to run):
`dotnet build windows/app/Swoopy.csproj -p:EnableWindowsTargeting=true`.

## Are the sound checks steady?

Run the **Windows** workflow by hand with **repeat** above 0 (Actions → Windows → Run workflow, or
`gh workflow run windows.yml --ref BRANCH -f repeat=10`). It runs only "What you hear" (`e2e-music`) that many times
on each processor type and always ends green (a failed run would send an email each time). The `repeat-x64` and
`repeat-arm64` artifacts hold `summary.md` (passes, and which checks failed how often), every run's log and report,
and the recordings of runs with a failed check or a hiccup. `music_args` passes more options, for example
`--only-later 30` (only the "ticked app opens later" check, 30 times, each right after two other players were
shifted and quit, as in a full run) and `--no-nudge` (see below). Normal pushes still run every check once and fail on
any failed check.

How `e2e-music` measures (in `tool/e2e.cpp`), and why:
- GitHub's runners now and then lose about 10 ms of sound on the way to the cable: the whole cable goes silent, also
  the quiet original, which never goes through Swoopy (about once every 3 minutes of listening; neither the
  engine, the recording nor the test player notices anything). One best-fit sine over a whole recording turned such a
  hiccup into a level 0.5–15 dB too low, or a pitch up to 0.9 Hz off.
- So a tone's level is the middle value of its level in 100 ms pieces (`steady_level`), and its pitch the middle value
  of 0.5 s pieces (`steady_frequency`). A hiccup only changes its own piece.
- The quieted original is measured with a smooth window in 0.5 s pieces (`faint_tone_amplitude`). A sharp-edged
  window let the loud shifted tone spill onto 440 Hz (up to −51 dB in a 2 s recording), so the "original is 50 dB
  down" checks were really measuring that spill. Measured properly, the original is 60 dB down, as set.
- The long runs' "no gaps" check lists pieces where the whole cable went silent on their own
  (`long_run_cable_silences`); a gap of Swoopy's own would still leave the quiet original playing. The voice's
  long run (`e2e-voice`) plays a quiet 1 kHz reference tone on the cable for the same reason
  (`long_voice_cable_silences`).
- Closing a player while it is being shifted lets the cushion run dry once, which counts as a dropout (the sound
  simply ended). The beep section resets the counts first, so its status is about the beeps.
- Each listening window is saved (`music_<name>.wav`) with notes in the report (`<name>_window`): the steady level,
  the quietest piece, the engine's dropouts / skips / lost packets / speaker stream running empty
  (`output_starved`), packets lost on the way to the recording, the test player's own hiccups (`tonegen --log`), and
  where the cable went silent.

Found this way (a real bug, fixed in the engine): on ARM64, a ticked app that opened later sometimes played on at
full volume next to the shifted copy. Its session said 0.001, but Windows had not applied it (the volume was set just
as the app started playing; in about 2 of 5 such starts). The booster notices loud sound that wasn't quieted, so the
engine now writes a slightly different quiet volume (0.000999) to the sessions it quieted in the last 10 s, which
Windows does apply, and the exact one again on the next look (`QuietKeeper::nudge`, status `quiet_nudges`). With
`--only-later 30 --no-nudge` the bug shows up on ARM64; without `--no-nudge` it doesn't.

## The window app

- `Swoopy.exe --preview hear-on,voice-on,cartoon --screenshot shot.png [--theme dark] [--scale 2] [--size 900x450]`
  draws a made-up state into a picture without sound (states are listed in `app/Preview.cs`).
- The window is resizable (smallest = the cards at their base size, largest 1000×640); `app/MainWindow.Layout.cs`
  places the cards (side by side or stacked) and picks the scale. Animations follow Windows' "Animation effects"
  setting (`app/Motion.cs`).
- `Swoopy.exe --quit` asks the running copy to quit (the installer uses this); `--diag [--out file]` writes the
  diagnostics report; `--shot file` asks the running copy for a picture of itself.
- Settings: `%APPDATA%\Pitch Shift\settings.json`. Problems are logged to `%LOCALAPPDATA%\Pitch Shift\app-log.txt`.
- Only one copy runs; a second start talks to the first through a named pipe (`app/SingleInstance.cs`).
- Hidden names keep the app's old name (Pitch Shift), so an update keeps settings and can close an older running
  copy: the folders above, the `HKLM\SOFTWARE\Pitch Shift` key, the "!PitchShiftRestore" sign-in entry and the
  one-copy names in `app/SingleInstance.cs`.

## The installer and VB-CABLE

VB-Audio's license asks for the author's permission before VB-CABLE is bundled or installed silently.
Until that permission is given, `Swoopy-Setup.exe` lets `SwoopyTool setup-mic` download the
official pack from vb-audio.com (checked against a pinned SHA-256) and open VB-Audio's own setup window.
Once permission is given, set `#define BundleCable 1` in `installer/Swoopy.iss` (and put
`VBCABLE_Driver_Pack45.zip` next to it) to bundle it and install it without a window.
The GitHub checks install it silently (`/CABLESILENT`).

Updating a PC that has a version named Pitch Shift keeps its folder (`Program Files\Pitch Shift`), removes the old
files and shortcuts, and renames "Pitch Shift Mic" to "Swoopy Mic" (the `x64-update` install test checks this).

## Releases

When a GitHub release is published, `windows-app.yml` attaches `Swoopy-Setup.exe` and
`Swoopy-Setup.exe.sha256` to it (the release's commit must contain the Windows code). `install.ps1`
picks the newest release that has both files (or, in releases from before the name Swoopy, `PitchShift-Setup.exe`
and its `.sha256`).

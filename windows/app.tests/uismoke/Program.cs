// GitHub checks only: drives the real Swoopy window like a person would (UI Automation via FlaUI),
// checks what it shows and what the engine does, and takes pictures.
//
//   UiSmoke run --app dist\Swoopy.exe --tool dist\SwoopyTool.exe --out ui-out [--source "Swoopy helper"]
//   UiSmoke dismiss-privacy [--out file.png]   clicks through Windows' first-sign-in privacy screen
//   UiSmoke desktop --out file.png             picture of the whole screen
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;

static class Program
{
    static int Main(string[] args)
    {
        SetProcessDpiAwarenessContext(new IntPtr(-4));
        var command = args.Length > 0 ? args[0] : "";
        string? Get(string flag)
        {
            for (var i = 0; i + 1 < args.Length; i++) if (args[i] == flag) return args[i + 1];
            return null;
        }
        try
        {
            return command switch
            {
                "run" => new Smoke(Get("--app")!, Get("--tool")!, Get("--out") ?? "ui-out", Get("--source") ?? "Swoopy helper").Run(),
                "dismiss-privacy" => Privacy.Dismiss(Get("--out")),
                "desktop" => Pictures.Desktop(Get("--out") ?? "desktop.png") ? 0 : 1,
                _ => Usage(),
            };
        }
        catch (Exception e)
        {
            Console.WriteLine("Error: " + e);
            return 2;
        }
    }

    static int Usage()
    {
        Console.WriteLine("UiSmoke run --app Swoopy.exe --tool SwoopyTool.exe --out folder | dismiss-privacy | desktop --out file.png");
        return 1;
    }

    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr value);
}

sealed class Smoke(string appExe, string toolExe, string outDir, string sourceName)
{
    const string Title = "Swoopy (beta)";
    readonly List<JsonObject> checks = new();
    readonly UIA3Automation automation = new();
    int shotNumber;

    void Check(string name, bool pass, object? value = null)
    {
        Console.WriteLine($"{(pass ? "PASS" : "FAIL")}  {name}  {value}");
        checks.Add(new JsonObject { ["name"] = name, ["pass"] = pass, ["value"] = value?.ToString() });
    }

    public int Run()
    {
        Directory.CreateDirectory(outDir);
        var settingsFile = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pitch Shift", "settings.json");
        if (File.Exists(settingsFile)) File.Delete(settingsFile);
        var micBefore = DefaultMic();
        Console.WriteLine($"Default microphone before: {micBefore}");

        // ---------- First start (light colors) ----------
        var app = Process.Start(appExe, "--theme light");
        var window = WaitWindow(app.Id, TimeSpan.FromSeconds(40));
        Check("window opens", window is not null);
        if (window is null) return Finish();
        Check("window title", window.Title == Title, window.Title);
        Thread.Sleep(2500);  // the engine starts after the window shows
        Shot(window, "start");
        var status = Status();
        Check("engine started", status?["started"]?.GetValue<bool>() == true, status?.ToJsonString());

        // ---------- The big number ----------
        var amount = Find(window, "HearAmount");
        Check("number starts at +2", amount?.Name == "+2", amount?.Name);
        TypeAmount(window, "2,5", enter: true);
        Check("typing 2,5 + Enter gives +2.5", WaitName(window, "HearAmount", "+2.5"), Find(window, "HearAmount")?.Name);
        TypeAmount(window, "9", enter: false);
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        Check("Esc cancels typing", WaitName(window, "HearAmount", "+2.5"), Find(window, "HearAmount")?.Name);
        TypeAmount(window, "abc", enter: true);
        Check("bad text is ignored", WaitName(window, "HearAmount", "+2.5"), Find(window, "HearAmount")?.Name);
        Find(window, "HearPlus")?.AsButton().Invoke();
        Check("+ adds one", WaitName(window, "HearAmount", "+3.5"), Find(window, "HearAmount")?.Name);
        TypeAmount(window, "−1,25", enter: true);
        Check("typing −1,25 gives −1.25", WaitName(window, "HearAmount", "−1.25"), Find(window, "HearAmount")?.Name);
        Thread.Sleep(400);
        status = Status();
        var semitones = status?["music"]?["semitones"]?.GetValue<double>();
        Check("engine got −1.25", semitones is double s && Math.Abs(s + 1.25) < 0.001, semitones);
        Shot(window, "typed");

        // ---------- What you hear: tick an app ----------
        var picker = Find(window, "HearPicker");
        Check("picker starts on All sound", picker?.Name == "All sound", picker?.Name);
        picker?.AsButton().Invoke();
        var menu = WaitFor(() => FindMenu(app.Id), TimeSpan.FromSeconds(5));
        Check("app menu opens", menu is not null);
        Pictures.Desktop(Path.Combine(outDir, $"{++shotNumber:00}-menu-desktop.png"));
        if (menu is not null)
        {
            var names = menu.FindAllDescendants(cf => cf.ByControlType(ControlType.MenuItem)).Select(m => m.Name).ToList();
            Check("menu lists apps", names.Contains("All sound") && names.Contains(sourceName), string.Join(" | ", names));
            var item = menu.FindFirstDescendant(cf => cf.ByControlType(ControlType.MenuItem).And(cf.ByName(sourceName)));
            item?.Patterns.Invoke.Pattern.Invoke();
            Thread.Sleep(300);
            // Close the menu (it stays open so several apps can be ticked).
            for (var i = 0; i < 3 && FindMenu(app.Id) is not null; i++)
            {
                window.SetForeground();
                Keyboard.Type(VirtualKeyShort.ESCAPE);
                Thread.Sleep(500);
            }
            Check("app menu closes with Esc", FindMenu(app.Id) is null);
        }
        Check("picker shows the ticked app", WaitName(window, "HearPicker", sourceName), Find(window, "HearPicker")?.Name);
        var running = WaitFor(() =>
        {
            var st = Status();
            return st?["music"]?["state"]?.GetValue<string>() == "running" ? st : null;
        }, TimeSpan.FromSeconds(8));
        Check("engine records the ticked app", running is not null, Status()?["music"]?.ToJsonString());
        var apps = Status()?["music"]?["apps"]?.AsArray();
        Check("engine was given the app's program file",
            apps?.Any(a => a?["exe"]?.GetValue<string>().EndsWith("SwoopyTool.exe", StringComparison.OrdinalIgnoreCase) == true) == true,
            apps?.ToJsonString());
        Shot(window, "app-ticked");

        // ---------- What you hear: off and on ----------
        Toggle(window, "HearSwitch");
        Check("hear switch off stops the sound", WaitFor(() => Status()?["music"]?["state"]?.GetValue<string>() == "off" ? "" : null, TimeSpan.FromSeconds(8)) is not null,
            Status()?["music"]?["state"]);
        Shot(window, "hear-off");
        Toggle(window, "HearSwitch");
        Check("hear switch on starts again", WaitFor(() => Status()?["music"]?["state"]?.GetValue<string>() is "running" or "waiting" ? "" : null, TimeSpan.FromSeconds(8)) is not null,
            Status()?["music"]?["state"]);

        // ---------- What you hear: Advanced processing ----------
        var advanced = WaitFor(() => Find(window, "AdvancedSwitch"), TimeSpan.FromSeconds(3));
        Check("Advanced processing switch is there", advanced?.Name == "Advanced processing", advanced?.Name);
        Check("Advanced processing starts off", advanced?.AsToggleButton().ToggleState == ToggleState.Off, advanced?.AsToggleButton().ToggleState);
        Shot(window, "advanced-off");
        // Turning it on shows an alert first (it may add delay). Cancel: stays off, nothing saved (even a ticked box).
        Toggle(window, "AdvancedSwitch");
        Check("turning Advanced processing on shows the alert", WaitAlert(window, true));
        Check("the alert's title", Find(window, "AdvancedAlertTitle")?.Name == "Advanced processing may cause significant audio delay",
            Find(window, "AdvancedAlertTitle")?.Name);
        Thread.Sleep(500);
        Check("nothing changes before an answer", Status()?["music"]?["advanced"]?.GetValue<bool>() == false, Status()?["music"]?["advanced"]);
        Shot(window, "advanced-alert");
        Find(window, "AdvancedAlertHide")?.Patterns.Toggle.Pattern.Toggle();
        Find(window, "AdvancedAlertCancel")?.AsButton().Invoke();
        Check("Cancel closes the alert", WaitAlert(window, false));
        Check("Cancel puts the switch back off",
            WaitFor(() => Find(window, "AdvancedSwitch")?.AsToggleButton().ToggleState == ToggleState.Off ? "" : null, TimeSpan.FromSeconds(3)) is not null,
            Find(window, "AdvancedSwitch")?.AsToggleButton().ToggleState);
        Thread.Sleep(500);
        Check("Cancel leaves the engine as it was", Status()?["music"]?["advanced"]?.GetValue<bool>() == false, Status()?["music"]?["advanced"]);
        // On again: the alert comes back. Tick "Don't show again", then Turn On.
        Toggle(window, "AdvancedSwitch");
        Check("the alert shows again after Cancel", WaitAlert(window, true));
        Find(window, "AdvancedAlertHide")?.Patterns.Toggle.Pattern.Toggle();
        Check("\"Don't show again\" ticked", Find(window, "AdvancedAlertHide")?.Patterns.Toggle.Pattern.ToggleState.Value == ToggleState.On);
        Find(window, "AdvancedAlertTurnOn")?.AsButton().Invoke();
        Check("Turn On closes the alert", WaitAlert(window, false));
        Check("Advanced processing on reaches the engine",
            WaitFor(() => Status()?["music"]?["advanced"]?.GetValue<bool>() == true ? "" : null, TimeSpan.FromSeconds(5)) is not null,
            Status()?["music"]?["advanced"]);
        var engine = WaitFor(() => Status()?["music"]?["advanced_engine"] as JsonObject, TimeSpan.FromSeconds(10));
        Check("the sound goes through Advanced processing", engine is not null, Status()?["music"]?.ToJsonString());
        Shot(window, "advanced-on");
        Toggle(window, "AdvancedSwitch");
        Check("Advanced processing off reaches the engine",
            WaitFor(() => Status()?["music"]?["advanced"]?.GetValue<bool>() == false && Status()?["music"]?["advanced_engine"] is null ? "" : null, TimeSpan.FromSeconds(10)) is not null,
            Status()?["music"]?.ToJsonString());
        Check("turning it off shows no alert", !AlertShown(window));
        // On again, with no alert this time ("Don't show again"). It should be saved and come back after a restart (checked below).
        Toggle(window, "AdvancedSwitch");
        Thread.Sleep(500);
        Check("\"Don't show again\" is remembered: no alert", !AlertShown(window));
        Check("Advanced processing on again",
            WaitFor(() => Status()?["music"]?["advanced"]?.GetValue<bool>() == true ? "" : null, TimeSpan.FromSeconds(5)) is not null,
            Status()?["music"]?["advanced"]);

        // ---------- Your voice ----------
        var micName = Find(window, "MicPicker")?.Properties.ItemStatus.ValueOrDefault ?? "";
        var hasMic = micName.Length > 0 && micName != "No microphone";
        Check("mic picker shows the chosen microphone", micName.Length > 0, micName);
        if (!hasMic)
        {
            // GitHub's computers have no microphone (the virtual cable is Swoopy Mic itself).
            Check("no microphone: the voice switch can't be turned on", Find(window, "VoiceSwitch")?.IsEnabled == false);
            Check("no microphone: Test is off", Find(window, "TestButton")?.IsEnabled == false);
            Shot(window, "no-microphone");
        }
        else
        {
            Toggle(window, "VoiceSwitch");
            var voiceOn = WaitFor(() => Status()?["voice"]?["state"]?.GetValue<string>() is string v && v != "off" ? v : null, TimeSpan.FromSeconds(6));
            Check("voice switch on starts the voice", voiceOn is not null, voiceOn);
            var micDuring = WaitFor(() => DefaultMic() is string m && m.Contains("Swoopy Mic") ? m : null, TimeSpan.FromSeconds(6));
            Check("while voice is on, Swoopy Mic is the default mic", micDuring is not null, DefaultMic());
            Find(window, "StyleCartoon")?.Patterns.SelectionItem.Pattern.Select();
            Check("Cartoon reaches the engine", WaitFor(() => Status()?["voice"]?["natural"]?.GetValue<bool>() == false ? "" : null, TimeSpan.FromSeconds(3)) is not null);
            Find(window, "TestButton")?.AsButton().Invoke();
            var recording = WaitFor(() => Find(window, "TestButton")?.Name is string n && n.StartsWith("Recording") ? n : null, TimeSpan.FromSeconds(3));
            Check("Test shows the red countdown", recording is not null, Find(window, "TestButton")?.Name);
            Shot(window, "voice-test");
            Find(window, "TestButton")?.AsButton().Invoke();
            Check("Test can be stopped", WaitName(window, "TestButton", "Test", 4000), Find(window, "TestButton")?.Name);
            Shot(window, "voice-on");
            Toggle(window, "VoiceSwitch");
            Check("voice switch off", WaitFor(() => Status()?["voice"]?["state"]?.GetValue<string>() == "off" ? "" : null, TimeSpan.FromSeconds(5)) is not null);
            var micAfter = WaitFor(() => DefaultMic() == micBefore ? micBefore : null, TimeSpan.FromSeconds(6));
            Check("the real default mic is given back", micAfter is not null || micBefore is null, $"{DefaultMic()} (before: {micBefore})");
        }

        // ---------- Resizing: bigger window, bigger everything; tall and narrow: cards one above the other ----------
        var transform = window.Patterns.Transform.PatternOrDefault;
        Check("window can be resized", transform?.CanResize.ValueOrDefault == true);
        if (transform?.CanResize.ValueOrDefault == true)
        {
            var start = window.BoundingRectangle;
            var smallNumber = Find(window, "HearAmount")?.BoundingRectangle.Height ?? 0;
            transform.Resize(1000, 560);
            Thread.Sleep(1000);
            Shot(window, "resized-big");
            var hear = Find(window, "HearSwitch")?.BoundingRectangle ?? default;
            var voice = Find(window, "VoiceSwitch")?.BoundingRectangle ?? default;
            var bigNumber = Find(window, "HearAmount")?.BoundingRectangle.Height ?? 0;
            Check("big window: cards side by side", voice.Left > hear.Right && Math.Abs(voice.Top - hear.Top) < 5, $"{hear} / {voice}");
            Check("big window: the number grows", bigNumber > smallNumber * 1.2, $"{smallNumber} -> {bigNumber}");
            transform.Resize(380, 1000);
            Thread.Sleep(1000);
            Shot(window, "resized-tall");
            hear = Find(window, "HearSwitch")?.BoundingRectangle ?? default;
            voice = Find(window, "VoiceSwitch")?.BoundingRectangle ?? default;
            Check("tall narrow window: cards one above the other", voice.Top > hear.Bottom + 50, $"{hear} / {voice}");
            var size = window.BoundingRectangle;
            Check("window stops at its largest size", size.Height < 760, $"{size.Width}x{size.Height}");
            transform.Resize(start.Width, start.Height);
            Thread.Sleep(800);
        }

        // ---------- Its own picture through the running copy ----------
        var own = Path.GetFullPath(Path.Combine(outDir, $"{++shotNumber:00}-own-picture.png"));
        Process.Start(appExe, $"--shot \"{own}\"")?.WaitForExit(15000);
        Check("running copy saves a picture of itself", File.Exists(own));

        // ---------- Close hides to the tray; opening again brings it back ----------
        window.Patterns.Window.Pattern.Close();
        Thread.Sleep(1500);
        Check("closing the window keeps Swoopy running", !app.HasExited);
        Check("closing the window hides it", !IsWindowVisible(Handle(window)));
        var second = Process.Start(appExe);
        var secondExited = second.WaitForExit(15000);
        Check("a second copy ends right away", secondExited, secondExited ? second.ExitCode : "still running");
        Thread.Sleep(1000);
        Check("opening again shows the window", IsWindowVisible(Handle(window)));
        Shot(window, "reopened");

        // ---------- Settings are saved ----------
        Thread.Sleep(800);
        var saved = File.Exists(settingsFile) ? JsonNode.Parse(File.ReadAllText(settingsFile)) : null;
        Check("settings saved: amount", saved?["hearSteps"]?.GetValue<double>() == -1.25, saved?["hearSteps"]);
        Check("settings saved: ticked app", saved?["hearApps"]?.AsArray().Count == 1 && saved?["hearAll"]?.GetValue<bool>() == false, saved?["hearApps"]?.ToJsonString());
        Check("settings saved: Advanced processing", saved?["hearAdvanced"]?.GetValue<bool>() == true, saved?["hearAdvanced"]);
        Check("settings saved: \"Don't show again\"", saved?["hideAdvancedAlert"]?.GetValue<bool>() == true, saved?["hideAdvancedAlert"]);
        if (hasMic) Check("settings saved: Cartoon", saved?["voiceNatural"]?.GetValue<bool>() == false, saved?["voiceNatural"]);

        // ---------- Quit puts everything back ----------
        var quit = Process.Start(appExe, "--quit");
        quit.WaitForExit(30000);
        Check("--quit ends Swoopy", app.WaitForExit(30000));
        Thread.Sleep(1000);
        var diag = Diag();
        Check("no app volumes left lowered", diag?["restore_pending"]?.AsArray().Count == 0, diag?["restore_pending"]?.ToJsonString());
        Check("no sign-in repair left behind", string.IsNullOrEmpty(diag?["restore_at_sign_in"]?.GetValue<string>()), diag?["restore_at_sign_in"]);
        Check("default mic after quitting", DefaultMic() == micBefore, DefaultMic());

        // ---------- Start again in dark colors: settings come back ----------
        var app2 = Process.Start(appExe, "--theme dark");
        var window2 = WaitWindow(app2.Id, TimeSpan.FromSeconds(40));
        Check("opens again", window2 is not null);
        if (window2 is not null)
        {
            Thread.Sleep(2500);
            Check("amount remembered", Find(window2, "HearAmount")?.Name == "−1.25", Find(window2, "HearAmount")?.Name);
            Check("ticked app remembered", Find(window2, "HearPicker")?.Name == sourceName, Find(window2, "HearPicker")?.Name);
            Check("Advanced processing remembered", Find(window2, "AdvancedSwitch")?.AsToggleButton().ToggleState == ToggleState.On,
                Find(window2, "AdvancedSwitch")?.AsToggleButton().ToggleState);
            Check("Advanced processing given to the engine at start",
                WaitFor(() => Status()?["music"]?["advanced"]?.GetValue<bool>() == true ? "" : null, TimeSpan.FromSeconds(5)) is not null,
                Status()?["music"]?["advanced"]);
            Check("no alert when Advanced processing comes back on at start", !AlertShown(window2));
            Shot(window2, "dark");
        }
        Process.Start(appExe, "--quit").WaitForExit(30000);
        Check("quits again", app2.WaitForExit(30000));
        return Finish();
    }

    int Finish()
    {
        var failed = checks.Count(c => c["pass"]?.GetValue<bool>() != true);
        var report = new JsonObject
        {
            ["machine"] = RuntimeInformation.OSArchitecture.ToString(),
            ["os"] = RuntimeInformation.OSDescription,
            ["failed"] = failed,
            ["checks"] = new JsonArray(checks.Select(c => (JsonNode)c.DeepClone()).ToArray()),
        };
        File.WriteAllText(Path.Combine(outDir, "ui-smoke.json"), report.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        var summary = Environment.GetEnvironmentVariable("GITHUB_STEP_SUMMARY");
        if (!string.IsNullOrEmpty(summary))
        {
            var md = new StringBuilder($"## Window checks ({RuntimeInformation.OSArchitecture})\n\n| check | result | value |\n|---|---|---|\n");
            foreach (var c in checks)
                md.Append($"| {c["name"]} | {(c["pass"]?.GetValue<bool>() == true ? "pass" : "**FAIL**")} | {c["value"]?.ToString().Replace("|", "/")} |\n");
            File.AppendAllText(summary, md.ToString());
        }
        Console.WriteLine($"{checks.Count - failed} passed, {failed} failed");
        return failed == 0 ? 0 : 1;
    }

    // ---------- Helpers ----------

    Window? WaitWindow(int pid, TimeSpan timeout) => WaitFor(() =>
    {
        var desktop = automation.GetDesktop();
        return desktop.FindFirstChild(cf => cf.ByProcessId(pid).And(cf.ByControlType(ControlType.Window)).And(cf.ByName(Title)))?.AsWindow();
    }, timeout);

    // Switches a card on or off through UI Automation (like a screen reader would), waiting for the switch first.
    void Toggle(Window window, string id)
    {
        var toggle = WaitFor(() => Find(window, id), TimeSpan.FromSeconds(5))?.AsToggleButton();
        if (toggle is null)
        {
            Check($"found {id}", false);
            return;
        }
        var before = toggle.ToggleState;
        toggle.Toggle();
        if (WaitFor(() => toggle.ToggleState != before ? "" : null, TimeSpan.FromSeconds(3)) is null)
            Check($"{id} switched", false, before);
    }

    static AutomationElement? Find(AutomationElement root, string id)
    {
        try { return root.FindFirstDescendant(cf => cf.ByAutomationId(id)); }
        catch (Exception) { return null; }
    }

    AutomationElement? FindMenu(int pid)
    {
        foreach (var top in automation.GetDesktop().FindAllChildren(cf => cf.ByProcessId(pid)))
        {
            if (top.AutomationId == "HearMenu") return top;
            var menu = top.FindFirstDescendant(cf => cf.ByAutomationId("HearMenu"));
            if (menu is not null) return menu;
        }
        return null;
    }

    static T? WaitFor<T>(Func<T?> get, TimeSpan timeout) where T : class
    {
        var end = DateTime.UtcNow + timeout;
        while (true)
        {
            try
            {
                var v = get();
                if (v is not null) return v;
            }
            catch (Exception)
            {
            }
            if (DateTime.UtcNow > end) return null;
            Thread.Sleep(200);
        }
    }

    // The "Advanced processing" alert: on screen or not.
    static bool AlertShown(Window window) => Find(window, "AdvancedAlertTurnOn") is { IsOffscreen: false };

    static bool WaitAlert(Window window, bool shown) =>
        WaitFor(() => AlertShown(window) == shown ? "" : null, TimeSpan.FromSeconds(3)) is not null;

    static bool WaitName(AutomationElement root, string id, string name, int ms = 3000) =>
        WaitFor(() => Find(root, id)?.Name == name ? "" : null, TimeSpan.FromMilliseconds(ms)) is not null;

    // Clicks the big number (starts typing), types, and presses Enter.
    static void TypeAmount(Window window, string text, bool enter)
    {
        window.SetForeground();
        Find(window, "HearAmount")?.AsButton().Invoke();
        var box = WaitFor(() => Find(window, "HearAmountBox") is { IsOffscreen: false } b ? b : null, TimeSpan.FromSeconds(3));
        box?.Focus();
        Thread.Sleep(150);
        Keyboard.Type(text);
        if (enter) Keyboard.Type(VirtualKeyShort.RETURN);
        Thread.Sleep(250);
    }

    static IntPtr Handle(AutomationElement window) => window.Properties.NativeWindowHandle.ValueOrDefault;

    void Shot(AutomationElement window, string name)
    {
        var path = Path.Combine(outDir, $"{++shotNumber:00}-{name}.png");
        Pictures.Window(Handle(window), path);
    }

    // The running Swoopy's engine status (asked through its pipe, like a second copy would).
    static JsonNode? Status()
    {
        try
        {
            using var client = new NamedPipeClientStream(".", $"PitchShift.App.{Process.GetCurrentProcess().SessionId}", PipeDirection.InOut);
            client.Connect(3000);
            using var writer = new StreamWriter(client, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);
            writer.WriteLine("status");
            var line = reader.ReadLine();
            return string.IsNullOrEmpty(line) ? null : JsonNode.Parse(line);
        }
        catch (Exception)
        {
            return null;
        }
    }

    JsonNode? Diag()
    {
        try
        {
            using var p = Process.Start(new ProcessStartInfo(toolExe, "diag") { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
            var text = p.StandardOutput.ReadToEnd();
            p.WaitForExit(30000);
            return JsonNode.Parse(text);
        }
        catch (Exception e)
        {
            Console.WriteLine("diag failed: " + e.Message);
            return null;
        }
    }

    // Name of Windows' default recording device.
    string? DefaultMic()
    {
        var endpoints = Diag()?["endpoints"]?.AsArray();
        return endpoints?.FirstOrDefault(e => e?["direction"]?.GetValue<string>() == "recording" && e?["default"]?.GetValue<bool>() == true)?["name"]?.GetValue<string>();
    }

    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
}

static class Pictures
{
    // A picture of one window, even if something covers it (PrintWindow).
    public static bool Window(IntPtr hwnd, string path)
    {
        try
        {
            if (!GetWindowRect(hwnd, out var r)) return false;
            int w = r.Right - r.Left, h = r.Bottom - r.Top;
            if (w <= 0 || h <= 0) return false;
            using var bitmap = new Bitmap(w, h, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bitmap))
            {
                var hdc = g.GetHdc();
                PrintWindow(hwnd, hdc, 2 /* PW_RENDERFULLCONTENT */);
                g.ReleaseHdc(hdc);
            }
            // Cut off the invisible resize border.
            var crop = new Rectangle(0, 0, w, h);
            if (DwmGetWindowAttribute(hwnd, 9, out var f, Marshal.SizeOf<RECT>()) == 0)
                crop = Rectangle.Intersect(crop, new Rectangle(f.Left - r.Left, f.Top - r.Top, f.Right - f.Left, f.Bottom - f.Top));
            using var cut = bitmap.Clone(crop, PixelFormat.Format32bppArgb);
            cut.Save(path, ImageFormat.Png);
            Console.WriteLine($"Saved {path}");
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Picture failed ({path}): {e.Message}");
            return false;
        }
    }

    public static bool Desktop(string path)
    {
        try
        {
            var bounds = System.Windows.Forms.Screen.PrimaryScreen!.Bounds;
            using var bitmap = new Bitmap(bounds.Width, bounds.Height);
            using (var g = Graphics.FromImage(bitmap)) g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
            bitmap.Save(path, ImageFormat.Png);
            Console.WriteLine($"Saved {path}");
            return true;
        }
        catch (Exception e)
        {
            Console.WriteLine($"Desktop picture failed: {e.Message}");
            return false;
        }
    }

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, int attribute, out RECT value, int size);
}

// The ARM64 runners sign in for the first time and sit on Windows' "Choose privacy settings" screen,
// which covers the desktop. This clicks Next/Accept on it (or ends it).
static class Privacy
{
    public static int Dismiss(string? picture)
    {
        using var automation = new UIA3Automation();
        var desktop = automation.GetDesktop();
        foreach (var w in desktop.FindAllChildren())
        {
            string process = "";
            try { process = Process.GetProcessById(w.Properties.ProcessId.ValueOrDefault).ProcessName; }
            catch (Exception) { }
            Console.WriteLine($"window: \"{w.Name}\" class={w.ClassName} process={process}");
        }
        var clicked = 0;
        for (var round = 0; round < 8; round++)
        {
            var any = false;
            foreach (var w in desktop.FindAllChildren())
            {
                AutomationElement? button = null;
                try
                {
                    button = w.FindFirstDescendant(cf => cf.ByControlType(ControlType.Button).And(cf.ByName("Accept").Or(cf.ByName("Next"))));
                }
                catch (Exception)
                {
                }
                if (button is null) continue;
                var text = w.FindFirstDescendant(cf => cf.ByName("Choose privacy settings for your device"));
                if (text is null && !w.Name.Contains("privacy", StringComparison.OrdinalIgnoreCase)) continue;
                Console.WriteLine($"Clicking \"{button.Name}\" on \"{w.Name}\"");
                try { button.Patterns.Invoke.Pattern.Invoke(); }
                catch (Exception) { button.Click(); }
                clicked++;
                any = true;
                Thread.Sleep(2500);
            }
            if (!any) break;
        }
        // If it's still there, end the program that shows it.
        foreach (var name in new[] { "WWAHost", "CloudExperienceHostBroker" })
            foreach (var p in Process.GetProcessesByName(name))
            {
                Console.WriteLine($"Ending {name} ({p.Id})");
                try { p.Kill(); } catch (Exception e) { Console.WriteLine(e.Message); }
            }
        Thread.Sleep(2000);
        // Clicking through it can leave the Start menu open, which would catch typed keys. Close it.
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        Thread.Sleep(500);
        Keyboard.Type(VirtualKeyShort.ESCAPE);
        Thread.Sleep(500);
        if (picture is not null) Pictures.Desktop(picture);
        Console.WriteLine($"Privacy screen: clicked {clicked} button(s)");
        return 0;
    }
}

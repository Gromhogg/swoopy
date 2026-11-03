using System.Diagnostics;
using System.Windows;
using Microsoft.Win32;

namespace PitchShift;

// Starts Swoopy. Options:
//   (none)                          open the window (or bring the running one to the front)
//   --quit                          ask the running Swoopy to quit (the installer uses this)
//   --diag [--out file]             write a diagnostics report (Desktop by default)
//   --preview states --screenshot f picture of a made-up state, no sound (see Preview.cs)
//   --theme light|dark              force light or dark colors
//   --size WxH                      start with this window size (inside the frame)
//   --shot file                     ask the running Swoopy for a picture of its window
public partial class App : Application
{
    public static bool Quitting { get; private set; }
    internal static Tray? Tray { get; private set; }

    static Mutex? oneCopy;  // kept for the whole run: "Swoopy is already open"
    MainWindow? window;
    IDisposable? server;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += (_, ex) =>
        {
            Log.Write(ex.Exception);
            ex.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += (_, ex) => Log.Write(ex.ExceptionObject);

        var args = new Args(e.Args);
        if (args.Has("--diag"))
        {
            Diagnostics.Write(args.Get("--out"));
            Shutdown(0);
            return;
        }

        var theme = args.Get("--theme");
        if (theme == "dark") Theme.Forced = true;
        if (theme == "light") Theme.Forced = false;

        Preview? preview = args.Has("--preview") || args.Has("--screenshot") ? new Preview(args.Get("--preview")) : null;
        if (preview is null && !TakeOver(args)) return;

        Theme.Apply(this);
        SystemEvents.UserPreferenceChanged += (_, _) => Dispatcher.BeginInvoke(() => Theme.Apply(this));

        var scale = double.TryParse(args.Get("--scale"), System.Globalization.NumberStyles.Float,
            System.Globalization.CultureInfo.InvariantCulture, out var s) && s is > 0 and <= 4 ? s : 1;
        var settings = preview?.Settings() ?? Settings.Load(Settings.DefaultPath);
        Size? size = null;
        var sizeText = args.Get("--size")?.Split('x', 'X');
        if (sizeText is { Length: 2 } && double.TryParse(sizeText[0], out var sw) && double.TryParse(sizeText[1], out var sh))
            size = new Size(sw, sh);
        window = new MainWindow(settings, preview is null ? Settings.DefaultPath : null, preview, args.Get("--screenshot"), scale, size);
        if (preview is null)
        {
            Tray = new Tray(ShowWindow, Quit);
            server = SingleInstance.Serve(Dispatcher, Handle);
            SessionEnding += (_, _) => Quit();  // signing out, restarting, or an installer closing the app
        }
        window.Show();
    }

    // Makes sure only one Swoopy runs. Gives false (and ends this copy) if another one is open.
    bool TakeOver(Args args)
    {
        oneCopy = new Mutex(true, SingleInstance.MutexName, out var first);
        if (first)
        {
            if (!args.Has("--quit") && args.Get("--shot") is null) return true;
            Shutdown(0);  // nothing running to quit or picture
            return false;
        }
        oneCopy.Dispose();
        oneCopy = null;
        var command = args.Has("--quit") ? "quit" : args.Get("--shot") is string shot ? "shot " + shot : "show";
        var answered = false;
        string reply = "";
        for (var attempt = 0; attempt < 3 && !answered; attempt++) answered = SingleInstance.Send(command, out reply);
        if (answered && command == "quit" && reply.StartsWith("ok ") && int.TryParse(reply[3..], out var pid))
        {
            // Wait for it to finish putting everything back.
            try { Process.GetProcessById(pid).WaitForExit(20000); }
            catch (ArgumentException) { }
        }
        Shutdown(answered ? 0 : 1);
        return false;
    }

    // Commands from another copy of Swoopy (see SingleInstance).
    (string, Action?) Handle(string command)
    {
        if (command == "show")
        {
            ShowWindow();
            return ("ok", null);
        }
        // Quits after the answer is sent; the other copy waits for this process to end.
        if (command == "quit") return ("ok " + Environment.ProcessId, Quit);
        if (command == "status") return (Engine.Ready ? Engine.StatusJson() : "{\"started\":false}", null);
        if (command.StartsWith("shot ") && window is not null)
        {
            try
            {
                window.SavePicture(command[5..].Trim().Trim('"'));
                return ("ok", null);
            }
            catch (Exception e)
            {
                return ("error " + e.Message, null);
            }
        }
        return ("unknown", null);
    }

    void ShowWindow()
    {
        if (window is null || Quitting) return;
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        // Bring it to the front even if another app is in front.
        window.Topmost = true;
        window.Topmost = false;
        window.Focus();
    }

    // Quit: stop all sound, put every app volume and the default microphone back, then end.
    void Quit()
    {
        if (Quitting) return;
        Quitting = true;
        try
        {
            window?.SaveNow();
            Engine.Shutdown();
        }
        catch (Exception e)
        {
            Log.Write(e);
        }
        Tray?.Dispose();
        server?.Dispose();
        window?.Close();
        try { oneCopy?.ReleaseMutex(); }
        catch (ApplicationException) { }
        oneCopy?.Dispose();
        Shutdown(0);
    }
}

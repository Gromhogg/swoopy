using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Media;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace PitchShift;

// The window: two cards side by side, "What you hear" and "Your voice". No extra text.
public partial class MainWindow : Window
{
    readonly Settings settings;
    readonly string? settingsPath;  // null = don't save (pictures for the checks)
    readonly Preview? preview;
    readonly string? screenshotPath;
    readonly double screenshotScale;
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };

    EngineStatus status = EngineStatus.Empty;
    List<Mic> mics = new();
    bool micsKnown;
    bool updatingMics;
    bool restartNeeded;  // only for pictures (--preview restart); live, the engine says (cable.restart_needed)
    bool settingUp;
    bool askingAdvanced;  // the "Advanced processing" alert is open
    bool dirty;
    DateTime dirtySince, lastSlowCheck;
    VoiceAction action;
    string testPhase = "idle";
    ContextMenu? hearMenu;

    internal MainWindow(Settings settings, string? settingsPath, Preview? preview, string? screenshotPath, double screenshotScale,
        Size? askedSize = null)
    {
        this.settings = settings;
        this.settingsPath = settingsPath;
        this.preview = preview;
        this.screenshotPath = screenshotPath;
        this.screenshotScale = screenshotScale;
        InitializeComponent();

        // Sizes: each card's rows grow with the window (see MainWindow.Layout.cs).
        HearCard.Scaled += ScaleHearRows;
        VoiceCard.Scaled += ScaleVoiceRows;
        ScaleHearRows(HearCard.Scale);
        ScaleVoiceRows(VoiceCard.Scale);

        HearCard.Toggled += on =>
        {
            settings.HearOn = on;
            ApplyHear();
            Changed();
        };
        HearCard.AmountChosen += value =>
        {
            settings.HearSteps = value;
            if (preview is null) Engine.HearSteps(value);
            Changed();
        };
        HearPicker.Click += (_, _) => OpenHearMenu();
        // Checked/Unchecked (not Click), so screen readers and the UI checks can switch it too.
        AdvancedSwitch.Checked += (_, _) => AdvancedPicked(true);
        AdvancedSwitch.Unchecked += (_, _) => AdvancedPicked(false);
        AdvancedAlertTurnOn.Click += (_, _) => CloseAdvancedAlert(turnOn: true);
        AdvancedAlertCancel.Click += (_, _) => CloseAdvancedAlert(turnOn: false);

        VoiceCard.Toggled += on =>
        {
            settings.VoiceOn = on;
            ApplyVoice();
            Changed();
        };
        VoiceCard.AmountChosen += value =>
        {
            settings.VoiceSteps = value;
            if (preview is null) Engine.VoiceSteps(value);
            Changed();
        };
        MicPicker.DropDownOpened += (_, _) => RefreshMics(force: true);
        MicPicker.SelectionChanged += (_, _) => MicPicked();
        NaturalButton.Checked += (_, _) => StylePicked(true);
        CartoonButton.Checked += (_, _) => StylePicked(false);
        TestButton.Click += (_, _) => TestClicked();
        ActionButton.Click += (_, _) => ActionClicked();

        if (settings.WindowLeft is double left && settings.WindowTop is double top && OnScreen(left, top))
        {
            WindowStartupLocation = WindowStartupLocation.Manual;
            Left = left;
            Top = top;
        }
        LocationChanged += (_, _) =>
        {
            if (!IsVisible || WindowState != WindowState.Normal) return;
            settings.WindowLeft = Math.Round(Left);
            settings.WindowTop = Math.Round(Top);
            SaveSoon();
        };
        SourceInitialized += (_, _) =>
        {
            Theme.DarkTitleBar(this);
            HookResizing();
        };
        ContentRendered += (_, _) => Started();
        timer.Tick += (_, _) => Tick();

        if (preview is not null)
        {
            status = preview.Status();
            restartNeeded = preview.RestartNeeded;
        }
        RefreshMics(force: true);
        Refresh();

        // The first size: given (pictures), remembered, or the smallest.
        MeasureCards();
        var start = StartSize(askedSize);
        Root.Width = start.Width;
        Root.Height = start.Height;
        ArrangeCards(start);
    }

    // ---------- Starting ----------

    bool started;

    async void Started()
    {
        if (started) return;
        started = true;
        timer.Start();
        if (screenshotPath is null) BecomeResizable();
        if (preview is not null)
        {
            if (preview.Has("typing")) HearCard.Amount.BeginEditing("2.5");
            if (preview.Has("hover")) HearCard.Amount.Hover(true);
            if (preview.Has("menu")) OpenHearMenu();
            if (preview.Has("advanced-alert")) AdvancedSwitch.IsChecked = true;  // as if clicked: shows the alert
            if (screenshotPath is not null) await TakeScreenshotAndQuit();
            return;
        }
        // The window shows first, then sound starts.
        await Task.Run(Engine.Init);
        if (!Engine.Ready) Log.Write(Engine.Problem);
        ApplyHear();
        ApplyVoice();
        RefreshMics(force: true);
        Tick();
    }

    async Task TakeScreenshotAndQuit()
    {
        await Task.Delay(1200);  // let the switches finish sliding
        try
        {
            SavePicture(screenshotPath!, screenshotScale);
            if (hearMenu is { IsOpen: true })
            {
                var menuPath = Path.Combine(Path.GetDirectoryName(Path.GetFullPath(screenshotPath!))!,
                    Path.GetFileNameWithoutExtension(screenshotPath) + "-menu.png");
                SaveElement(hearMenu, menuPath, screenshotScale, null);
            }
        }
        catch (Exception e)
        {
            Log.Write(e);
            Application.Current.Shutdown(1);
            return;
        }
        Application.Current.Shutdown(0);
    }

    // ---------- Engine ----------

    void ApplyHear()
    {
        if (preview is not null) return;
        Engine.HearAdvanced(settings.HearAdvanced);
        if (!settings.HearOn)
        {
            Engine.HearStop();
            return;
        }
        Engine.HearSteps(settings.HearSteps);
        if (settings.HearAll) Engine.HearAll();
        else Engine.HearApps(settings.HearApps.Select(a => a.Exe));
    }

    void ApplyVoice()
    {
        if (preview is not null) return;
        Engine.VoiceSteps(settings.VoiceSteps);
        Engine.VoiceNatural(settings.VoiceNatural);
        if (settings.VoiceOn) Engine.VoiceStart(settings.VoiceMic);
        else Engine.VoiceStop();
    }

    // About 4 times a second: read what the engine is doing and show it.
    void Tick()
    {
        if (dirty && DateTime.UtcNow - dirtySince > TimeSpan.FromMilliseconds(400)) SaveNow();
        if (preview is not null) return;
        if (Engine.Ready) status = EngineJson.Status(Engine.StatusJson());
        if (!IsVisible) return;
        if (DateTime.UtcNow - lastSlowCheck > TimeSpan.FromSeconds(2))
        {
            lastSlowCheck = DateTime.UtcNow;
            RefreshMics(force: false);
        }
        Refresh();
    }

    // ---------- Showing the state ----------

    public void Refresh()
    {
        var s = settings;
        var st = status;

        var waiting = s.HearOn && st.MusicState == "waiting";
        HearCard.Show(on: s.HearOn, value: s.HearSteps, active: s.HearOn, waiting: waiting);
        var advancedOn = s.HearAdvanced || askingAdvanced;  // stays on while the alert asks
        if (AdvancedSwitch.IsChecked != advancedOn) AdvancedSwitch.IsChecked = advancedOn;
        HearCard.Amount.Hint = st.MusicState == "error" ? st.MusicError
            : waiting ? WaitingTip()
            : s.HearOn && st.MusicState == "running" && st.MusicSpeaker.Length > 0 ? "Playing to " + st.MusicSpeaker
            : "";
        ShowHearTitle();

        var cable = st.CablePresent ?? true;
        var hasMic = !micsKnown || mics.Count > 0;
        var canWork = cable && hasMic;
        VoiceCard.Show(on: s.VoiceOn, value: s.VoiceSteps, active: s.VoiceOn && canWork, waiting: false);
        VoiceCard.Switch.IsEnabled = canWork || s.VoiceOn;
        VoiceCard.Amount.Hint = st.VoiceState == "error" ? st.VoiceError : "";
        MicPicker.IsEnabled = canWork && mics.Count > 0;
        if (NaturalButton.IsChecked != s.VoiceNatural) NaturalButton.IsChecked = s.VoiceNatural;
        if (CartoonButton.IsChecked != !s.VoiceNatural) CartoonButton.IsChecked = !s.VoiceNatural;
        StyleBox.IsEnabled = s.VoiceOn && canWork;
        StyleBox.Opacity = StyleBox.IsEnabled ? 1 : 0.45;

        // Test button: purple "Test", red "● 3" while recording, "■ Stop" while playing back. Fades between them.
        var title = PickerText.TestTitle(st.TestState, st.TestSecondsLeft);
        if (st.TestState != testPhase)
        {
            Motion.Crossfade(TestButton, 0.2);
            testPhase = st.TestState;
        }
        TestButton.Content = title;
        AutomationProperties.SetName(TestButton, st.TestState switch
        {
            "recording" => $"Recording, {Math.Max(1, st.TestSecondsLeft)} seconds left. Stop",
            "playing" => "Stop playing",
            _ => "Test",
        });
        if (st.TestState == "recording") TestButton.Background = Theme.Red;
        else TestButton.ClearValue(BackgroundProperty);
        TestButton.IsEnabled = st.TestState != "idle" || (s.VoiceOn && canWork);

        // "● Swoopy Mic" (green and pulsing while a call app listens), or the one button that's needed.
        var nextAction = PickerText.Action(st, restartNeeded);
        ActionButton.Content = PickerText.ActionTitle(nextAction);
        ActionButton.IsEnabled = !settingUp;
        if (nextAction != action)
        {
            action = nextAction;
            ActionButton.Visibility = action == VoiceAction.None ? Visibility.Collapsed : Visibility.Visible;
            MicStatus.Visibility = action == VoiceAction.None ? Visibility.Visible : Visibility.Collapsed;
            RowsChanged();
        }
        var live = s.VoiceOn && canWork && st.InUse;
        MicDot.IsLive = live;
        MicStatus.ToolTip = live ? "An app is using Swoopy Mic" : "Choose Swoopy Mic as the microphone in Discord, Zoom or any app";
        AutomationProperties.SetName(MicStatus, live ? "Swoopy Mic, in use" : "Swoopy Mic, not in use");
    }

    string WaitingTip()
    {
        var names = settings.HearApps.Select(a => a.Name).ToList();
        return settings.HearAll || names.Count == 0 ? "Waiting for sound" : "Waiting for sound from " + string.Join(", ", names);
    }

    // ---------- What you hear: the app picker ----------

    void ShowHearTitle()
    {
        var names = settings.HearApps.Select(a => a.Name).ToList();
        var title = PickerText.HearTitle(settings.HearAll, names);
        HearPickerText.Text = title;
        AutomationProperties.SetName(HearPicker, title);
        ImageSource? icon = null;
        if (!settings.HearAll && settings.HearApps.Count > 0) icon = AppIcons.For(settings.HearApps[0].Exe);
        HearPickerIcon.Source = icon;
        HearPickerGlyph.Visibility = settings.HearAll ? Visibility.Visible : Visibility.Collapsed;
        ((FrameworkElement)HearPickerIcon.Parent).Visibility =
            settings.HearAll || icon is not null ? Visibility.Visible : Visibility.Collapsed;
    }

    // A menu with "All sound" and the apps that have sound. Tick any number of apps.
    void OpenHearMenu()
    {
        if (HearCard.Amount.IsEditing) HearCard.Amount.Finish(apply: true);
        var sources = preview?.Sources() ?? EngineJson.Sources(Engine.SourcesJson());
        var running = new HashSet<string>(status.MusicApps.Where(a => a.Running).Select(a => a.Exe), StringComparer.OrdinalIgnoreCase);
        var entries = sources.Select(s => (s.Exe, s.Name, Running: true, s.Playing)).ToList();
        foreach (var app in settings.HearApps)
            if (!entries.Any(e => string.Equals(e.Exe, app.Exe, StringComparison.OrdinalIgnoreCase)))
                entries.Add((app.Exe, app.Name, preview is not null || running.Contains(app.Exe), false));
        entries.Sort((a, b) => string.Compare(a.Name, b.Name, StringComparison.CurrentCultureIgnoreCase));

        var menu = new ContextMenu
        {
            PlacementTarget = HearPicker,
            Placement = PlacementMode.Bottom,
            MinWidth = HearPicker.ActualWidth,
            MaxHeight = 420,
        };
        AutomationProperties.SetAutomationId(menu, "HearMenu");
        var all = MenuEntry("All sound", null, glyph: "", ticked: settings.HearAll, dim: false);
        AutomationProperties.SetAutomationId(all, "HearAll");
        all.Click += (_, _) =>
        {
            settings.ChooseAll();
            all.IsChecked = true;
            menu.IsOpen = false;
            HearSourceChanged();
        };
        menu.Items.Add(all);
        if (entries.Count > 0) menu.Items.Add(new Separator());
        foreach (var (exe, name, isRunning, playing) in entries)
        {
            var item = MenuEntry(name, AppIcons.For(exe), glyph: null, ticked: settings.IsTicked(exe), dim: !isRunning, playing: playing);
            item.StaysOpenOnClick = true;  // tick several in a row
            item.ToolTip = playing ? "Playing now" : null;
            item.Click += (_, _) =>
            {
                settings.ToggleApp(exe, name);
                item.IsChecked = settings.IsTicked(exe);
                all.IsChecked = settings.HearAll;
                HearSourceChanged();
            };
            menu.Items.Add(item);
        }
        hearMenu = menu;
        HearPicker.ContextMenu = menu;
        menu.IsOpen = true;
    }

    // One line in the app menu: icon, name, and a small green dot when the app is playing sound right now.
    static MenuItem MenuEntry(string name, ImageSource? icon, string? glyph, bool ticked, bool dim, bool playing = false)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal };
        FrameworkElement picture = icon is not null
            ? new Image { Source = icon, Width = 16, Height = 16 }
            : new TextBlock
            {
                Text = glyph ?? "",
                FontFamily = (FontFamily)Application.Current.FindResource("PsIcons"),
                FontSize = 14,
                Width = 16,
                TextAlignment = TextAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        picture.Margin = new Thickness(0, 0, 8, 0);
        picture.VerticalAlignment = VerticalAlignment.Center;
        picture.Opacity = dim ? 0.4 : 1;
        row.Children.Add(picture);
        row.Children.Add(new TextBlock { Text = name, VerticalAlignment = VerticalAlignment.Center, Opacity = dim ? 0.55 : 1 });
        if (playing)
            row.Children.Add(new System.Windows.Shapes.Ellipse
            {
                Width = 6,
                Height = 6,
                Fill = Theme.Green,
                Margin = new Thickness(7, 1, 0, 0),
                VerticalAlignment = VerticalAlignment.Center,
            });
        var item = new MenuItem { Header = row, IsCheckable = true, IsChecked = ticked };
        AutomationProperties.SetName(item, name);
        if (playing) AutomationProperties.SetHelpText(item, "Playing now");
        return item;
    }

    // "Advanced processing" (made for music). Switching makes a new player in the engine.
    // Turning it on shows an alert first (it adds delay), unless "Don't show again" was ticked.
    void AdvancedPicked(bool on)
    {
        if (askingAdvanced)
        {
            if (!on) CloseAdvancedAlert(turnOn: false);  // switched off another way (a screen reader) while asking
            return;
        }
        if (settings.HearAdvanced == on) return;  // shown from the settings, not a click
        if (on && !settings.HideAdvancedAlert)
        {
            ShowAdvancedAlert();
            return;
        }
        SetAdvanced(on);
    }

    void SetAdvanced(bool on)
    {
        settings.HearAdvanced = on;
        if (preview is null) Engine.HearAdvanced(on);
        Changed();
    }

    // The alert over the window. Enter = Turn On, Esc = Cancel.
    void ShowAdvancedAlert()
    {
        askingAdvanced = true;
        AdvancedAlertHide.IsChecked = false;
        AdvancedAlertTurnOn.IsDefault = true;
        AdvancedAlertCancel.IsCancel = true;
        AdvancedAlert.BeginAnimation(OpacityProperty, null);
        AdvancedAlert.Opacity = 0;
        AdvancedAlert.Visibility = Visibility.Visible;
        Motion.To(AdvancedAlert, OpacityProperty, 1, 0.15);
        Dispatcher.BeginInvoke(DispatcherPriority.Loaded, new Action(() => AdvancedAlertTurnOn.Focus()));
    }

    // Turn On: takes effect (and remembers "Don't show again"). Cancel: the switch goes back off, nothing saved.
    void CloseAdvancedAlert(bool turnOn)
    {
        if (!askingAdvanced) return;
        askingAdvanced = false;
        var hadFocus = AdvancedAlert.IsKeyboardFocusWithin;
        AdvancedAlertTurnOn.IsDefault = false;
        AdvancedAlertCancel.IsCancel = false;
        AdvancedAlert.Visibility = Visibility.Collapsed;
        if (turnOn)
        {
            if (AdvancedAlertHide.IsChecked == true) settings.HideAdvancedAlert = true;
            SetAdvanced(true);
        }
        else
        {
            Refresh();
        }
        if (hadFocus) AdvancedSwitch.Focus();
    }

    void HearSourceChanged()
    {
        if (preview is null && settings.HearOn)
        {
            if (settings.HearAll) Engine.HearAll();
            else Engine.HearApps(settings.HearApps.Select(a => a.Exe));
        }
        Changed();
    }

    // ---------- Your voice ----------

    void RefreshMics(bool force)
    {
        if (MicPicker.IsDropDownOpen && !force) return;
        List<Mic> list;
        if (preview is not null)
        {
            list = preview.Mics();
            micsKnown = true;
        }
        else if (Engine.Ready)
        {
            list = EngineJson.Mics(Engine.MicsJson());
            micsKnown = true;
        }
        else
        {
            return;
        }
        if (list.SequenceEqual(mics) && MicPicker.Items.Count > 0) return;
        mics = list;
        updatingMics = true;
        try
        {
            if (list.Count == 0)
            {
                var none = new Mic("", "No microphone", false);
                MicPicker.ItemsSource = new List<Mic> { none };
                MicPicker.SelectedItem = none;
            }
            else
            {
                MicPicker.ItemsSource = list;
                MicPicker.SelectedItem = PickerText.ChosenMic(list, settings.VoiceMic);
            }
        }
        finally
        {
            updatingMics = false;
        }
        // So screen readers (and the checks) can read the chosen mic without opening the list.
        AutomationProperties.SetItemStatus(MicPicker, (MicPicker.SelectedItem as Mic)?.Name ?? "");
    }

    void MicPicked()
    {
        if (updatingMics || MicPicker.SelectedItem is not Mic mic || mic.Id.Length == 0) return;
        AutomationProperties.SetItemStatus(MicPicker, mic.Name);
        if (mic.Id == settings.VoiceMic) return;
        settings.VoiceMic = mic.Id;
        if (preview is null && settings.VoiceOn) Engine.VoiceStart(mic.Id);
        Changed();
    }

    void StylePicked(bool natural)
    {
        if (settings.VoiceNatural == natural) return;
        settings.VoiceNatural = natural;
        if (preview is null) Engine.VoiceNatural(natural);
        Changed();
    }

    void TestClicked()
    {
        if (preview is not null) return;
        if (status.TestState == "idle") Engine.TestStart();
        else Engine.TestStop();
    }

    void ActionClicked()
    {
        switch (action)
        {
            case VoiceAction.AllowMic:
                Open("ms-settings:privacy-microphone");
                break;
            case VoiceAction.Restart:
                if (MessageBox.Show(this, "Restart Windows now to finish setting up Swoopy Mic?", "Swoopy",
                        MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
                    Run("shutdown.exe", "/r /t 0", elevated: false);
                break;
            case VoiceAction.Repair:
                RepairMic();
                break;
        }
    }

    // Runs "SwoopyTool setup-mic" as administrator (Windows asks first). It shows VB-Audio's own window.
    async void RepairMic()
    {
        var tool = Path.Combine(AppContext.BaseDirectory, "SwoopyTool.exe");
        if (!File.Exists(tool) || preview is not null)
        {
            SystemSounds.Beep.Play();
            return;
        }
        settingUp = true;
        Refresh();
        try
        {
            var p = Run(tool, "setup-mic", elevated: true);
            if (p is not null) await p.WaitForExitAsync();
        }
        finally
        {
            settingUp = false;
            RefreshMics(force: true);
            Refresh();
        }
    }

    static Process? Run(string file, string args, bool elevated)
    {
        try
        {
            return Process.Start(new ProcessStartInfo(file, args)
            {
                UseShellExecute = true,
                Verb = elevated ? "runas" : "",
                WindowStyle = ProcessWindowStyle.Hidden,
            });
        }
        catch (Win32Exception)
        {
            return null;  // the person said No to Windows' question
        }
    }

    static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write(e); }
    }

    // ---------- Settings and window ----------

    void Changed()
    {
        SaveSoon();
        Refresh();
    }

    void SaveSoon()
    {
        if (!dirty) dirtySince = DateTime.UtcNow;
        dirty = true;
    }

    public void SaveNow()
    {
        dirty = false;
        if (settingsPath is null) return;
        try { settings.Save(settingsPath); }
        catch (Exception e) { Log.Write(e); }
    }

    public Settings CurrentSettings => settings;

    static bool OnScreen(double left, double top) =>
        left >= SystemParameters.VirtualScreenLeft - 50 &&
        top >= SystemParameters.VirtualScreenTop - 10 &&
        left < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth - 100 &&
        top < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight - 60;

    protected override void OnClosing(CancelEventArgs e)
    {
        if (preview is null && !App.Quitting)
        {
            // Closing the window keeps Swoopy running in the tray.
            e.Cancel = true;
            HearCard.Amount.Finish(apply: true);
            VoiceCard.Amount.Finish(apply: true);
            Hide();
            SaveNow();
            if (!settings.TrayTipShown)
            {
                settings.TrayTipShown = true;
                App.Tray?.ShowTip();
                SaveNow();
            }
        }
        base.OnClosing(e);
    }

    protected override void OnClosed(EventArgs e)
    {
        base.OnClosed(e);
        timer.Stop();
        if (preview is not null) Application.Current.Shutdown();
    }

    // ---------- Pictures ----------

    // Draws the window's contents (without the title bar) into a PNG file.
    public void SavePicture(string path, double scale = 1) => SaveElement(Root, path, scale, (Brush)FindResource("PsWindowBack"));

    static void SaveElement(FrameworkElement element, string path, double scale, Brush? background)
    {
        var w = element.ActualWidth;
        var h = element.ActualHeight;
        if (element is ContextMenu)
        {
            element.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            w = Math.Max(w, element.DesiredSize.Width);
            h = Math.Max(h, element.DesiredSize.Height);
        }
        var bitmap = new RenderTargetBitmap((int)Math.Ceiling(w * scale), (int)Math.Ceiling(h * scale),
            96 * scale, 96 * scale, PixelFormats.Pbgra32);
        var visual = new DrawingVisual();
        using (var dc = visual.RenderOpen())
        {
            if (background is not null) dc.DrawRectangle(background, null, new Rect(0, 0, w, h));
            dc.DrawRectangle(new VisualBrush(element) { Stretch = Stretch.None, AlignmentX = AlignmentX.Left, AlignmentY = AlignmentY.Top },
                null, new Rect(0, 0, w, h));
        }
        bitmap.Render(visual);
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(bitmap));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        using var file = File.Create(path);
        encoder.Save(file);
    }
}

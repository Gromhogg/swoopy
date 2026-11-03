using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace PitchShift;

// The window's layout. The window can be resized: the cards sit side by side (or one above the other in a tall,
// narrow window) and everything grows with the window, like the Mac app.
public partial class MainWindow
{
    const double Edge = 20, Gap = 16, MaxScale = 1.8, MaxClientWidth = 1000, MaxClientHeight = 640;

    Size minSide;        // smallest window with the cards side by side
    Size minStacked;     // smallest window with one card above the other
    Size chrome;         // title bar and borders around the cards' area
    bool stacked;
    bool resizable;      // after the first show: the window follows the person's resizing
    bool arranged;

    // Sizes the rows inside each card for a scale (1 = smallest window).
    void ScaleHearRows(double s)
    {
        HearPicker.Height = ShiftCard.ControlHeight(s);
        HearPicker.FontSize = ShiftCard.ControlFont(s);
        // "Advanced processing": a small label and a small switch, like the Mac.
        AdvancedRow.Margin = new Thickness(0, Math.Round(12 * s), 0, 0);
        AdvancedLabel.FontSize = 12 + (s - 1) * 2.5;
        AdvancedSwitch.Size = ShiftCard.Large(s) ? new Size(40, 22) : new Size(34, 19);
    }

    void ScaleVoiceRows(double s)
    {
        MicPicker.Height = ShiftCard.ControlHeight(s);
        MicPicker.FontSize = ShiftCard.ControlFont(s);
        StyleRow.Margin = new Thickness(0, Math.Round(12 * s), 0, 0);
        StyleBox.Height = TestButton.Height = ShiftCard.ButtonHeight(s);
        TestButton.Width = Math.Round(72 * s);
        TestBox.Margin = new Thickness(Math.Round(8 * s), 0, 0, 0);
        NaturalButton.FontSize = CartoonButton.FontSize = TestButton.FontSize = ShiftCard.ControlFont(s);
        Footer.Margin = new Thickness(0, Math.Round(12 * s), 0, 0);
        MicStatusText.FontSize = 12 + (s - 1) * 2.5;
        MicDot.Margin = new Thickness(2, 1, Math.Round(6 * s), 0);
        ActionButton.Height = ShiftCard.ButtonHeight(s);
        ActionButton.FontSize = ShiftCard.ControlFont(s);
    }

    // Works out the smallest window sizes (again when a row is shown or hidden).
    void MeasureCards()
    {
        HearCard.ForgetHeights();
        VoiceCard.ForgetHeights();
        var hear = HearCard.NeededHeight(1, ShiftCard.BaseWidth);
        var voice = VoiceCard.NeededHeight(1, ShiftCard.BaseWidth);
        minSide = new Size(2 * ShiftCard.BaseWidth + Gap + 2 * Edge, Math.Max(hear, voice) + 2 * Edge);
        minStacked = new Size(ShiftCard.BaseWidth + 2 * Edge, hear + voice + Gap + 2 * Edge);
        if (resizable) ApplyLimits();
    }

    void ApplyLimits()
    {
        MinWidth = minStacked.Width + chrome.Width;
        MinHeight = minSide.Height + chrome.Height;
        MaxWidth = MaxClientWidth + chrome.Width;
        MaxHeight = Math.Max(MaxClientHeight, minStacked.Height) + chrome.Height;
    }

    // A window can be small and wide (cards side by side) or narrow and tall (one above the other), not both.
    Size Allowed(Size size, bool narrow)
    {
        var w = Math.Min(Math.Max(size.Width, minStacked.Width), MaxClientWidth);
        var h = Math.Min(Math.Max(size.Height, minSide.Height), Math.Max(MaxClientHeight, minStacked.Height));
        if (w < minSide.Width && h < minStacked.Height)
        {
            if (narrow) h = minStacked.Height;
            else w = minSide.Width;
        }
        return new Size(Math.Round(w), Math.Round(h));
    }

    // The first size: given (pictures), remembered, or the smallest.
    Size StartSize(Size? asked)
    {
        if (asked is Size a) return Allowed(a, a.Width < minSide.Width);
        if (settings.WindowWidth is double w && settings.WindowHeight is double h) return Allowed(new Size(w, h), w < minSide.Width);
        return minSide;
    }

    // After the window first shows: from now on it follows resizing.
    void BecomeResizable()
    {
        if (resizable) return;
        chrome = new Size(Math.Max(0, ActualWidth - Root.ActualWidth), Math.Max(0, ActualHeight - Root.ActualHeight));
        resizable = true;
        ApplyLimits();
        SizeToContent = SizeToContent.Manual;
        Root.Width = double.NaN;
        Root.Height = double.NaN;
        Root.SizeChanged += (_, e) =>
        {
            ArrangeCards(e.NewSize);
            if (WindowState == WindowState.Normal)
            {
                settings.WindowWidth = Math.Round(e.NewSize.Width);
                settings.WindowHeight = Math.Round(e.NewSize.Height);
                SaveSoon();
            }
        };
    }

    // The biggest scale at which the cards fit: limited by the card width, then shrunk until they fit the height.
    double BestScale(Size size, bool stack)
    {
        var width = stack ? size.Width - 2 * Edge : (size.Width - 2 * Edge - Gap) / 2;
        var height = size.Height - 2 * Edge - (stack ? Gap : 0);
        bool Fits(double s)
        {
            var hear = HearCard.NeededHeight(s, width);
            var voice = VoiceCard.NeededHeight(s, width);
            return (stack ? hear + voice : Math.Max(hear, voice)) <= height + 0.5;
        }
        var widest = Math.Floor(Math.Min(MaxScale, width / ShiftCard.BaseWidth) * 100) / 100;
        if (widest <= 1 || Fits(widest)) return Math.Max(1, widest);
        double low = 1, high = widest;
        while (high - low > 0.01)
        {
            var middle = Math.Round((low + high) / 2 * 100) / 100;
            if (middle == low || middle == high) break;
            if (Fits(middle)) low = middle;
            else high = middle;
        }
        return low;
    }

    // Places the cards: side by side, or one above the other when that lets everything be more than 5% bigger.
    void ArrangeCards(Size size)
    {
        if (minSide.Width == 0 || size.Width < 1 || size.Height < 1) return;
        var canSide = size.Width >= minSide.Width - 0.5;
        var canStack = size.Height >= minStacked.Height - 0.5;
        var useStack = !canSide;
        double scale;
        if (canSide && canStack)
        {
            var side = BestScale(size, false);
            var stack = BestScale(size, true);
            useStack = stack > side + (stacked ? -0.05 : 0.05);  // a little stickiness so it doesn't flip back and forth
            scale = useStack ? stack : side;
        }
        else
        {
            scale = BestScale(size, useStack);
        }
        var moved = arranged && useStack != stacked;
        stacked = useStack;
        arranged = true;

        var area = new Rect(Edge, Edge, Math.Max(0, size.Width - 2 * Edge), Math.Max(0, size.Height - 2 * Edge));
        if (stacked)
        {
            var hear = HearCard.NeededHeight(scale, area.Width);
            var voice = VoiceCard.NeededHeight(scale, area.Width);
            var extra = Math.Max(0, (area.Height - Gap - hear - voice) / 2);
            var top = Math.Round(hear + extra);
            Put(HearCard, area.Left, area.Top, area.Width, top, scale, extra);
            Put(VoiceCard, area.Left, area.Top + top + Gap, area.Width, Math.Max(0, area.Height - top - Gap), scale, extra);
        }
        else
        {
            var width = Math.Floor((area.Width - Gap) / 2);
            var hear = HearCard.NeededHeight(scale, width);
            var voice = VoiceCard.NeededHeight(scale, width);
            var extra = Math.Max(0, area.Height - Math.Max(hear, voice));
            Put(HearCard, area.Left, area.Top, width, area.Height, scale, extra);
            Put(VoiceCard, area.Right - width, area.Top, width, area.Height, scale, extra);
        }
        if (moved) Settle(VoiceCard, stacked ? new Vector(0, 24) : new Vector(24, 0));
    }

    static void Put(ShiftCard card, double x, double y, double width, double height, double scale, double extra)
    {
        Canvas.SetLeft(card, x);
        Canvas.SetTop(card, y);
        card.Width = width;
        card.Height = height;
        card.Apply(scale);
        card.Place(width);
        card.Spread(extra);
    }

    // When the layout changes, the "Your voice" card fades into its new place, coming up from below (or in from
    // the right).
    void Settle(UIElement card, Vector from)
    {
        if (!IsVisible) return;
        var move = new TranslateTransform();
        card.RenderTransform = move;
        var time = TimeSpan.FromSeconds(0.25);
        if (Motion.Moves)
        {
            move.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(from.X, 0, time) { EasingFunction = Motion.EaseOut });
            move.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(from.Y, 0, time) { EasingFunction = Motion.EaseOut });
        }
        card.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, time) { EasingFunction = Motion.EaseOut });
    }

    // Called when the footer changes between "● Swoopy Mic" and a button: the cards may need more room.
    void RowsChanged()
    {
        MeasureCards();
        if (!resizable)
        {
            var start = StartSize(null);
            if (double.IsNaN(Root.Width) || Root.Width < start.Width) Root.Width = start.Width;
            if (double.IsNaN(Root.Height) || Root.Height < start.Height) Root.Height = start.Height;
            ArrangeCards(new Size(Root.Width, Root.Height));
            return;
        }
        var now = new Size(Root.ActualWidth, Root.ActualHeight);
        var fixedSize = Allowed(now, now.Width < minSide.Width);
        if (fixedSize != now && WindowState == WindowState.Normal)
        {
            Width = fixedSize.Width + chrome.Width;
            Height = fixedSize.Height + chrome.Height;
        }
        ArrangeCards(new Size(Root.ActualWidth, Root.ActualHeight));
    }

    // ---------- Resizing by dragging an edge (keeps "small and wide" or "narrow and tall", never both) ----------

    const int WM_SIZING = 0x0214, GWL_STYLE = -16, WS_MAXIMIZEBOX = 0x10000;

    void HookResizing()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        // No maximize button: the window has a largest size.
        SetWindowLong(hwnd, GWL_STYLE, GetWindowLong(hwnd, GWL_STYLE) & ~WS_MAXIMIZEBOX);
        HwndSource.FromHwnd(hwnd)?.AddHook(WndProc);
    }

    IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WM_SIZING || !resizable) return IntPtr.Zero;
        var r = Marshal.PtrToStructure<RECT>(lParam);
        var dpi = VisualTreeHelper.GetDpi(this);
        var client = new Size((r.Right - r.Left) / dpi.DpiScaleX - chrome.Width, (r.Bottom - r.Top) / dpi.DpiScaleY - chrome.Height);
        var want = Allowed(client, Root.ActualWidth < minSide.Width - 0.5);
        var w = (int)Math.Round((want.Width + chrome.Width) * dpi.DpiScaleX);
        var h = (int)Math.Round((want.Height + chrome.Height) * dpi.DpiScaleY);
        var edge = wParam.ToInt32();
        if (w != r.Right - r.Left)
        {
            if (edge is 1 or 4 or 7) r.Left = r.Right - w;  // dragging a left edge
            else r.Right = r.Left + w;
        }
        if (h != r.Bottom - r.Top)
        {
            if (edge is 3 or 4 or 5) r.Top = r.Bottom - h;  // dragging a top edge
            else r.Bottom = r.Top + h;
        }
        Marshal.StructureToPtr(r, lParam, false);
        handled = true;
        return new IntPtr(1);
    }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")] static extern int SetWindowLong(IntPtr hwnd, int index, int value);
}

using System.IO;
using System.Windows;
using Forms = System.Windows.Forms;

namespace PitchShift;

// The icon next to the clock. Click it to open the window; right-click for Open and Quit.
sealed class Tray : IDisposable
{
    readonly Forms.NotifyIcon icon;

    public Tray(Action open, Action quit)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open", null, (_, _) => open());
        menu.Items.Add("Quit", null, (_, _) => quit());
        icon = new Forms.NotifyIcon
        {
            Text = "Swoopy",
            Icon = LoadIcon(),
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.MouseClick += (_, e) =>
        {
            if (e.Button == Forms.MouseButtons.Left) open();
        };
    }

    static System.Drawing.Icon LoadIcon()
    {
        try
        {
            var stream = Application.GetResourceStream(new Uri("pack://application:,,,/AppIcon.ico"))?.Stream;
            if (stream is not null)
            {
                using (stream) return new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
            }
        }
        catch (Exception e)
        {
            Log.Write(e);
        }
        return System.Drawing.SystemIcons.Application;
    }

    // Shown once, the first time the window is closed.
    public void ShowTip() =>
        icon.ShowBalloonTip(6000, "Swoopy is still on", "To stop it, right-click this icon and pick Quit.", Forms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}

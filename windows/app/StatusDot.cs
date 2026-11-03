using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace PitchShift;

// The dot next to "Swoopy Mic": grey, or green with a gentle pulse while a call app is listening
// (a ring grows to 2.4 times its size and fades, every 2 seconds).
sealed class StatusDot : Grid
{
    readonly Ellipse dot = new(), halo = new();
    readonly ScaleTransform grow = new();
    bool live;

    public StatusDot()
    {
        Width = Height = 8;
        foreach (var e in new[] { halo, dot })
        {
            e.Width = e.Height = 8;
            e.SetResourceReference(Shape.FillProperty, "PsDotOff");
            Children.Add(e);
        }
        halo.Opacity = 0;
        halo.RenderTransformOrigin = new Point(0.5, 0.5);
        halo.RenderTransform = grow;
        IsHitTestVisible = false;
        IsVisibleChanged += (_, _) => Update();
    }

    public bool IsLive
    {
        get => live;
        set
        {
            if (value == live) return;
            live = value;
            Update();
        }
    }

    void Update()
    {
        if (live)
        {
            dot.Fill = halo.Fill = Theme.Green;
        }
        else
        {
            dot.SetResourceReference(Shape.FillProperty, "PsDotOff");
            halo.SetResourceReference(Shape.FillProperty, "PsDotOff");
        }
        var pulse = live && IsVisible && Motion.Moves;
        if (!pulse)
        {
            grow.BeginAnimation(ScaleTransform.ScaleXProperty, null);
            grow.BeginAnimation(ScaleTransform.ScaleYProperty, null);
            halo.BeginAnimation(OpacityProperty, null);
            halo.Opacity = 0;
            return;
        }
        var every = new Duration(TimeSpan.FromSeconds(2));
        var size = new DoubleAnimation(1, 2.4, every) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Motion.EaseOut };
        grow.BeginAnimation(ScaleTransform.ScaleXProperty, size);
        grow.BeginAnimation(ScaleTransform.ScaleYProperty, size);
        halo.BeginAnimation(OpacityProperty, new DoubleAnimation(0.45, 0, every) { RepeatBehavior = RepeatBehavior.Forever, EasingFunction = Motion.EaseOut });
    }
}

using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace PitchShift;

// "Swoopy Diagnostics" (Start menu): writes a report about this PC's sound setup to the Desktop,
// for sending along with a bug report. Swoopy.exe --diag [--out file]
static class Diagnostics
{
    public static string Write(string? outPath)
    {
        var report = new StringBuilder();
        report.AppendLine("Swoopy diagnostics");
        report.AppendLine($"Made: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        report.AppendLine($"App: {AppVersion} ({RuntimeInformation.ProcessArchitecture})");
        report.AppendLine($"Windows: {RuntimeInformation.OSDescription} ({RuntimeInformation.OSArchitecture})");
        report.AppendLine($"Engine: {Engine.Version}");
        report.AppendLine();

        report.AppendLine("== Swoopy right now ==");
        report.AppendLine(SingleInstance.Send("status", out var status, 2000) ? status : "(not running)");
        report.AppendLine();

        report.AppendLine("== Settings ==");
        report.AppendLine(ReadText(Settings.DefaultPath) ?? "(none yet)");
        report.AppendLine();

        report.AppendLine("== Sound setup (SwoopyTool diag) ==");
        report.AppendLine(RunTool("diag"));
        report.AppendLine();

        report.AppendLine("== App log ==");
        report.AppendLine(ReadText(Log.PathName) ?? "(empty)");

        var path = outPath ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            "Swoopy diagnostics.txt");
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        File.WriteAllText(path, report.ToString(), new UTF8Encoding(false));
        if (outPath is null)
        {
            // Show the file in its folder.
            try { Process.Start("explorer.exe", $"/select,\"{path}\""); }
            catch (Exception) { }
        }
        return path;
    }

    public static string AppVersion =>
        Assembly.GetEntryAssembly()?.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "?";

    static string? ReadText(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch (Exception e) { return $"(can't read: {e.Message})"; }
    }

    static string RunTool(string args)
    {
        var tool = Path.Combine(AppContext.BaseDirectory, "SwoopyTool.exe");
        if (!File.Exists(tool)) return "(SwoopyTool.exe is missing)";
        try
        {
            using var p = Process.Start(new ProcessStartInfo(tool, args)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = Encoding.UTF8,
            })!;
            var output = p.StandardOutput.ReadToEndAsync();
            if (!p.WaitForExit(30000))
            {
                p.Kill();
                return "(took too long)";
            }
            return output.Result;
        }
        catch (Exception e)
        {
            return $"(didn't run: {e.Message})";
        }
    }
}

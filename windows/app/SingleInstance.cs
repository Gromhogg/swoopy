using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Threading;

namespace PitchShift;

// Only one Swoopy runs at a time. Starting it again sends the running one a short command
// ("show", "quit", "status", "shot <file>") through a named pipe.
static class SingleInstance
{
    public const string MutexName = @"Local\PitchShift.App";
    static string PipeName => $"PitchShift.App.{Process.GetCurrentProcess().SessionId}";

    // Sends one command to the running Swoopy. Gives false if none answers.
    public static bool Send(string command, out string reply, int timeoutMs = 5000)
    {
        reply = "";
        try
        {
            if (command == "show") AllowSetForegroundWindow(-1);  // lets the running one come to the front
            using var client = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut);
            client.Connect(timeoutMs);
            using var writer = new StreamWriter(client, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
            using var reader = new StreamReader(client, Encoding.UTF8, false, 1024, leaveOpen: true);
            writer.WriteLine(command);
            reply = reader.ReadLine() ?? "";
            return true;
        }
        catch (Exception e) when (e is IOException or TimeoutException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    // Answers commands until the app quits. `handle` runs on the window's thread and gives the reply,
    // plus something to do once the reply has been sent (like quitting).
    public static IDisposable Serve(Dispatcher dispatcher, Func<string, (string Reply, Action? After)> handle)
    {
        var stop = new CancellationTokenSource();
        Task.Run(async () =>
        {
            while (!stop.IsCancellationRequested)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync(stop.Token);
                    using var reader = new StreamReader(server, Encoding.UTF8, false, 1024, leaveOpen: true);
                    await using var writer = new StreamWriter(server, new UTF8Encoding(false), 1024, leaveOpen: true) { AutoFlush = true };
                    var line = await reader.ReadLineAsync(stop.Token) ?? "";
                    var (reply, after) = await dispatcher.InvokeAsync(() => handle(line.Trim()));
                    await writer.WriteLineAsync(reply.Replace('\n', ' ').Replace('\r', ' '));
                    try { server.WaitForPipeDrain(); }
                    catch (IOException) { }
                    if (after is not null) await dispatcher.InvokeAsync(after);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (Exception e)
                {
                    Log.Write(e);
                    await Task.Delay(300);
                }
            }
        });
        return new Stopper(stop);
    }

    sealed class Stopper(CancellationTokenSource stop) : IDisposable
    {
        public void Dispose() => stop.Cancel();
    }

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);
}

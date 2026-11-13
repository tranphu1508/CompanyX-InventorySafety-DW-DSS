using System.Diagnostics;
using System.Collections.Concurrent;

namespace DssInventoryMvc.Data;

// Only job status leaves this service. Plans are published by Python to SIM and read by the repository.
public sealed class OrderSolver(IWebHostEnvironment environment, IHostApplicationLifetime lifetime,
    ILogger<OrderSolver> logger)
{
    public sealed record Input(int Run, int Product, int Qty, string Known, string Due);
    public sealed record Status(string Id, string State, string Message);
    private readonly ConcurrentDictionary<string, Status> jobs = new();
    private readonly Dictionary<Input, string> active = new();
    private readonly SemaphoreSlim queue = new(1);
    private readonly object gate = new();
    public Status? Get(string id) => jobs.GetValueOrDefault(id);
    public Status Start(Input input)
    {
        lock (gate)
        {
            if (active.TryGetValue(input, out var existing)) return jobs[existing];
            var id = Guid.NewGuid().ToString("N");
            jobs[id] = new(id, "queued", "Đang chờ bộ giải…");
            active[input] = id;
            _ = Task.Run(() => Run(input, id));
            return jobs[id];
        }
    }
    private async Task Run(Input input, string id)
    {
        var entered = false;
        try
        {
            await queue.WaitAsync(lifetime.ApplicationStopping);
            entered = true;
            jobs[id] = new(id, "running", "Bộ giải đang chạy; kết quả sẽ được lưu vào SIM warehouse…");
            var root = Path.GetFullPath(Path.Combine(environment.ContentRootPath, "../.."));
            var folder = Path.Combine(root, "_local", "web-jobs", id);
            Directory.CreateDirectory(folder);
            var start = new ProcessStartInfo(Path.Combine(root, ".venv", "Scripts", "python.exe"))
            {
                WorkingDirectory = root, UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            foreach (var arg in new[] { "-u", "-B", "Tools/cube_pipeline/earliest_day_offer.py",
                "--run", input.Run.ToString(), "--product", input.Product.ToString(), "--qty", input.Qty.ToString(),
                "--known", input.Known, "--due", input.Due, "--folder", folder, "--prepare-opening" })
                start.ArgumentList.Add(arg);
            start.Environment["PYTHONUTF8"] = "1";
            start.Environment["TEMP"] = folder;
            start.Environment["TMP"] = folder;
            using var process = Process.Start(start) ?? throw new InvalidOperationException("Cannot start solver.");
            using var registration = lifetime.ApplicationStopping.Register(() =>
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
                catch (InvalidOperationException) { }
            });
            await using var stdout = new FileStream(Path.Combine(folder, "stdout.log"), FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
            await using var stderr = new FileStream(Path.Combine(folder, "stderr.log"), FileMode.Create, FileAccess.Write, FileShare.ReadWrite);
            await Task.WhenAll(process.StandardOutput.BaseStream.CopyToAsync(stdout),
                process.StandardError.BaseStream.CopyToAsync(stderr), process.WaitForExitAsync());
            if (process.ExitCode != 0) throw new InvalidOperationException($"Solver exited {process.ExitCode}. Job {id}");
            jobs[id] = new(id, "done", "Đã lưu kết quả vào SIM warehouse. Đang đọc lại phương án…");
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Order solver failed: {Job}", id);
            jobs[id] = new(id, "failed", $"Bộ giải chưa hoàn tất. Vui lòng thử lại hoặc kiểm tra log tác vụ {id}.");
        }
        finally
        {
            if (entered) queue.Release();
            lock (gate) active.Remove(input);
        }
    }
}

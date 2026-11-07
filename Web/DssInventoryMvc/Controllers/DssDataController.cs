using DssInventoryMvc.Data;
using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

[ApiController]
[Route("api/dss")]
public sealed class DssDataController(DssSqlRepository repository) : ControllerBase
{
    [HttpGet("bootstrap")]
    public async Task<IActionResult> Bootstrap(CancellationToken ct)
    {
        var runs = await repository.RunsAsync(ct);
        var pairs = await repository.PairsAsync(ct);
        var products = await repository.ProductsAsync(ct);
        return Ok(new { runs, pairs, products, defaultRunId = pairs.FirstOrDefault(p => p.DeliveryRule == "Mất đơn tại hạn giao")?.BaselineRunId });
    }

    [HttpGet("run/{id:int}")]
    public async Task<IActionResult> Run(int id, CancellationToken ct)
    {
        var result = await repository.RunAsync(id, ct);
        return result is null ? NotFound() : Ok(result);
    }

    [HttpGet("compare")]
    public async Task<IActionResult> Compare([FromQuery] int candidateRunId, [FromQuery] int months = 18, CancellationToken ct = default)
    {
        if (months is not (0 or 12 or 18 or 24 or 36)) return BadRequest(new { error = "Giai đoạn không hợp lệ." });
        var result = await repository.CompareAsync(candidateRunId, months, ct);
        return result is null ? NotFound() : Ok(result);
    }

    [HttpGet("snapshot")]
    public async Task<IActionResult> Snapshot([FromQuery] int runId, [FromQuery] int productId,
        [FromQuery] DateOnly date, CancellationToken ct)
    {
        if (runId <= 0 || productId <= 0 || date == default) return BadRequest(new { error = "Thiếu thông tin tra cứu." });
        var result = await repository.SnapshotAsync(runId, productId, date, ct);
        return result is null ? NotFound() : Ok(result);
    }
}

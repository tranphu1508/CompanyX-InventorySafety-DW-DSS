using DssInventoryMvc.Data;
using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

[ApiController]
[Route("api/dss/replay")]
public sealed class OrderReplayController(DssSqlRepository repository, OrderSolver solver) : ControllerBase
{
    public sealed record SearchInput(int Run, int Product, decimal Qty, string Known, string Due);

    [HttpPost("search-day")]
    [ValidateAntiForgeryToken]
    public async Task<IActionResult> SearchDay(SearchInput input, CancellationToken ct)
    {
        if (input.Qty <= 0 || input.Qty != decimal.Truncate(input.Qty))
            return BadRequest(new { message = "Số lượng cần phải là số nguyên dương." });
        if (input.Qty > int.MaxValue)
            return BadRequest(new { message = "Số lượng vượt quá giới hạn hỗ trợ." });
        if (!DateOnly.TryParseExact(input.Known, "yyyy-MM-dd", out var known) ||
            !DateOnly.TryParseExact(input.Due, "yyyy-MM-dd", out var due) || due < known)
            return BadRequest(new { message = "Hãy nhập ngày hợp lệ." });
        var pairs = await repository.PairsAsync(ct);
        if (!pairs.Any(p => p.BaselineRunId == input.Run)) return BadRequest(new { message = "Kịch bản nền không hợp lệ." });
        var run = (await repository.RunsAsync(ct)).SingleOrDefault(r => r.Id == input.Run);
        if (run is null || known < new DateOnly(2013, 7, 1) ||
            int.Parse(known.ToString("yyyyMMdd")) < run.StartKey || int.Parse(due.ToString("yyyyMMdd")) > run.EndKey)
            return BadRequest(new { message = "Hãy nhập ngày hợp lệ trong khoảng mô phỏng từ 01/07/2013 đến hết kịch bản nền." });
        if (!(await repository.ProductsAsync(ct)).Any(p => p.ProductId == input.Product))
            return BadRequest(new { message = "Hãy chọn sản phẩm hợp lệ." });
        var qty = (int)input.Qty;
        if ((await repository.DayOffers(input.Run, input.Product, qty, known, due, ct)).Any())
            return Ok(new { state = "done", message = "Đã có kết quả trong SIM warehouse." });
        return Accepted(solver.Start(new(input.Run, input.Product, qty, input.Known, input.Due)));
    }

    [HttpGet("search-day/{id}")]
    public IActionResult SearchStatus(string id) => solver.Get(id) is { } status ? Ok(status) : NotFound();

    [HttpGet("day-plans")]
    public async Task<IActionResult> DayPlans(int run,int product,int qty,DateOnly known,DateOnly due,CancellationToken ct) =>
        Ok(await repository.DayOffers(run,product,qty,known,due,ct));

    [HttpGet("cases")]
    public async Task<IActionResult> Cases(int run,int product,CancellationToken ct) =>
        Ok(await repository.Cases(run,product,ct));

    [HttpGet("opening")]
    public async Task<IActionResult> Opening(int run,int product,DateOnly date,int? qty,CancellationToken ct)
    {
        if(date==default || qty is <=0) return BadRequest();
        return Ok(await repository.Opening(run,product,date,qty,ct));
    }

    [HttpGet("options")]
    public async Task<IActionResult> Options(int run,int product,int caseKey,int qty,CancellationToken ct) =>
        Ok(await repository.Options(run,product,caseKey,qty,ct));

    [HttpGet("detail")]
    public async Task<IActionResult> Detail(int run,int product,int caseKey,int qty,string candidate,CancellationToken ct)
    {
        var cases=await repository.Cases(run,product,ct);
        var saved=cases.SingleOrDefault(x=>Convert.ToInt64(x["caseKey"])==caseKey && Convert.ToInt32(x["qty"])==qty);
        if(saved is null) return NotFound();
        var options=await repository.Options(run,product,caseKey,qty,ct);
        var selected=options.SingleOrDefault(x=>Equals(x["candidateId"],candidate));
        if(selected?["branchRun"] is null) return NotFound();
        var branch=Convert.ToInt32(selected["branchRun"]);
        var start=(DateTime)saved["knownAt"]!;
        var end=(DateTime)saved["endAt"]!;
        var impact=selected["controlRun"] is null ? null :
            (await repository.Impact(branch,Convert.ToInt32(selected["controlRun"]),product,start,end,ct)).SingleOrDefault();
        var plan=selected["orderId"] is null ? [] :
            await repository.Plan(branch,Convert.ToInt32(selected["orderId"]),start,ct);
        return Ok(new {impact, plan});
    }
}

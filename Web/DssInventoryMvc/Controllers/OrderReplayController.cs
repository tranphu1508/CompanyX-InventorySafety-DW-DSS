using DssInventoryMvc.Data;
using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

[ApiController]
[Route("api/dss/replay")]
public sealed class OrderReplayController(DssSqlRepository repository) : ControllerBase
{
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

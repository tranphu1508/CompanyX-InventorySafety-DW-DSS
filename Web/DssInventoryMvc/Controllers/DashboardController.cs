using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

public sealed class DashboardController : Controller
{
    [HttpGet]
    public IActionResult Index() => View();
}

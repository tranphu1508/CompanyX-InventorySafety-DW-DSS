using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

public sealed class OperationsController : Controller
{
    [HttpGet]
    public IActionResult Index() => View();
}

using Microsoft.AspNetCore.Mvc;

namespace DssInventoryMvc.Controllers;

public sealed class OrdersController : Controller
{
    [HttpGet]
    public IActionResult Index() => View();
}

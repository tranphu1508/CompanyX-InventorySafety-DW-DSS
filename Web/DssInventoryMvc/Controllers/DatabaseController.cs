using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.SqlClient;

namespace DssInventoryMvc.Controllers;

[ApiController]
[Route("api/database")]
public sealed class DatabaseController(IConfiguration configuration) : ControllerBase
{
    [HttpGet("status")]
    public async Task<IActionResult> Status(CancellationToken cancellationToken)
    {
        var connectionString = configuration.GetConnectionString("DssSqlServer");
        if (string.IsNullOrWhiteSpace(connectionString))
        {
            return Ok(new { configured = false, connected = false });
        }

        try
        {
            var settings = new SqlConnectionStringBuilder(connectionString) { ConnectTimeout = 3 };
            await using var connection = new SqlConnection(settings.ConnectionString);
            await connection.OpenAsync(cancellationToken);
            return Ok(new { configured = true, connected = true });
        }
        catch (Exception error) when (error is SqlException or InvalidOperationException or ArgumentException)
        {
            // Do not return a connection string, credentials, or server details to the browser.
            return Ok(new { configured = true, connected = false });
        }
    }
}

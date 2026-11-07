using Microsoft.EntityFrameworkCore;

namespace DssInventoryMvc.Data;

/// <summary>
/// SQL Server context. Entity mappings are added once the existing DSS schema is provided.
/// No tables or sample records are created by this project.
/// </summary>
public sealed class DssDbContext(DbContextOptions<DssDbContext> options) : DbContext(options);

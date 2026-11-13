using DssInventoryMvc.Data;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// Direct local builds also need the static asset manifest outside Development.
builder.WebHost.UseStaticWebAssets();

builder.Services.AddControllersWithViews();
builder.Services.AddScoped<DssSqlRepository>();

// Read-only DSS reports use DssSqlRepository; the optional context supports SQL connectivity.
var connectionString = builder.Configuration.GetConnectionString("DssSqlServer");
if (!string.IsNullOrWhiteSpace(connectionString))
{
    builder.Services.AddDbContext<DssDbContext>(options =>
        options.UseSqlServer(connectionString));
}

var app = builder.Build();

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
}

app.UseHttpsRedirection();
app.UseRouting();

app.UseAuthorization();

app.MapStaticAssets();

app.MapControllerRoute(
    name: "default",
    pattern: "{controller=Dashboard}/{action=Index}/{id?}")
    .WithStaticAssets();


app.Run();

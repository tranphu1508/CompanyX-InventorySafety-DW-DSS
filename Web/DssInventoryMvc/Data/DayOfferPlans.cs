namespace DssInventoryMvc.Data;

public sealed partial class DssSqlRepository
{
    public Task<List<Dictionary<string, object?>>> DayOffers(int run, int product, int qty,
        DateOnly known, DateOnly due, CancellationToken ct) => ReplayRows("""
        WITH family AS (
          SELECT ProductKey FROM act_input.BusinessProduct WHERE ProductID=@product
          UNION ALL
          SELECT b.ComponentProductKey FROM family f JOIN act_input.BusinessBOM b ON b.AssemblyProductKey=f.ProductKey
          WHERE b.IsStructureValid=1 AND b.StartDate<=@known AND (b.EndDate IS NULL OR b.EndDate>=@known)
        )
        SELECT h.Slot slot,h.DueAt due,
          TRY_CONVERT(int,JSON_VALUE(h.PlanJSON,'$.plannedShip')) plannedShip,
          TRY_CONVERT(int,JSON_VALUE(h.PlanJSON,'$.plannedLoss')) plannedLoss,
          (SELECT p.ProductName name,p.ProductID productId,a.PlanAt startDate,a.PlannedCompletionAt finishDate,
                  SUM(a.Quantity) qty FROM OPENJSON(h.PlanJSON,'$.actions')
           WITH (ProductID int,ActionCode varchar(50),PlanAt date,PlannedCompletionAt date,Quantity float) a
           JOIN act_input.BusinessProduct p ON p.ProductID=a.ProductID
           WHERE a.ActionCode='PRODUCTION_START' AND p.ProductKey IN (SELECT ProductKey FROM family)
           GROUP BY p.ProductName,p.ProductID,a.PlanAt,a.PlannedCompletionAt
           ORDER BY a.PlanAt,p.ProductName FOR JSON PATH) jobs
        FROM cxdetail.DayOfferPlan h WHERE h.BaseRunKey=@run AND h.ProductID=@product
          AND h.Quantity=@qty AND h.KnownAt=@known AND h.OriginalDue=@due ORDER BY h.Slot
        """,ct,("@run",run),("@product",product),("@qty",qty),
            ("@known",known.ToDateTime(TimeOnly.MinValue)),("@due",due.ToDateTime(TimeOnly.MinValue)));
}

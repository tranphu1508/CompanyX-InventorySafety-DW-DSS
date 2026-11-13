namespace DssInventoryMvc.Data;

public sealed partial class DssSqlRepository
{
    public Task<List<Dictionary<string, object?>>> DayOffers(int run, int product, int qty,
        DateOnly known, DateOnly due, CancellationToken ct) => ReplayRows("""
        WITH family AS (
          SELECT ProductKey,0 bomLevel,
            CAST(RIGHT('0000000000'+CONVERT(varchar(10),ProductKey),10) AS varchar(2000)) bomPath
          FROM act_input.BusinessProduct WHERE ProductID=@product
          UNION ALL
          SELECT b.ComponentProductKey,f.bomLevel+1,
            CAST(f.bomPath+'/'+RIGHT('0000000000'+CONVERT(varchar(10),b.ComponentProductKey),10) AS varchar(2000))
          FROM family f JOIN act_input.BusinessBOM b ON b.AssemblyProductKey=f.ProductKey
          WHERE b.IsStructureValid=1 AND b.StartDate<=@known
            AND (b.EndDate IS NULL OR b.EndDate>=@known) AND f.bomLevel<20
        ), nodes AS (
          SELECT *,ROW_NUMBER() OVER(PARTITION BY ProductKey ORDER BY bomLevel,bomPath) occurrence FROM family
        ), offers AS (
          SELECT h.Slot,h.DueAt,CONVERT(varchar(10),h.Slot) Variant,h.PlanJSON
          FROM cxdetail.DayOfferPlan h
          WHERE h.BaseRunKey=@run AND h.ProductID=@product AND h.Quantity=@qty
            AND h.KnownAt=@known AND h.OriginalDue=@due
            AND NOT(h.Slot='A' AND JSON_QUERY(h.PlanJSON,'$.priority') IS NOT NULL)
          UNION ALL
          SELECT CONVERT(char(1),CASE WHEN JSON_VALUE(j.value,'$.variant')='C' THEN 'C' ELSE 'A' END),
            h.OriginalDue,CONVERT(varchar(10),JSON_VALUE(j.value,'$.variant')),j.value
          FROM cxdetail.DayOfferPlan h CROSS APPLY OPENJSON(h.PlanJSON,'$.priority.variants') j
          WHERE h.BaseRunKey=@run AND h.ProductID=@product AND h.Quantity=@qty
            AND h.KnownAt=@known AND h.OriginalDue=@due AND h.Slot='A'
        )
        SELECT h.Slot slot,h.DueAt due,h.Variant variant,
          JSON_VALUE(h.PlanJSON,'$.status') planStatus,
          JSON_VALUE(h.PlanJSON,'$.explanation') explanation,
          JSON_QUERY(h.PlanJSON,'$.impact') impactJson,
          JSON_QUERY(h.PlanJSON,'$.orderChanges') orderChangesJson,
          TRY_CONVERT(int,JSON_VALUE(h.PlanJSON,'$.plannedShip')) plannedShip,
          TRY_CONVERT(int,JSON_VALUE(h.PlanJSON,'$.plannedLoss')) plannedLoss,
          JSON_VALUE(h.PlanJSON,'$.search.status') searchStatus,
          CASE WHEN h.Variant='A1'
            AND COALESCE(lv.RepresentedQty,0)=TRY_CONVERT(decimal(28,8),JSON_VALUE(h.PlanJSON,'$.impact.additionalLostUnits'))
            AND COALESCE(lv.MissingPriceCount,0)=0
            THEN COALESCE(lv.LostValue,0) END additionalLostValue,
          (SELECT p.ProductName name,p.ProductID productId,f.bomLevel,f.bomPath,
                  a.PlanAt startDate,a.PlannedCompletionAt finishDate,SUM(a.Quantity) qty
           FROM nodes f JOIN act_input.BusinessProduct p ON p.ProductKey=f.ProductKey
           LEFT JOIN OPENJSON(h.PlanJSON,'$.actions')
           WITH (ProductID int,ActionCode varchar(50),PlanAt date,
                 PlannedCompletionAt date,Quantity float) a
             ON a.ProductID=p.ProductID AND a.ActionCode='PRODUCTION_START' AND a.Quantity>0
           WHERE f.occurrence=1 AND (p.MakeFlag=1 OR f.bomLevel=0)
           GROUP BY p.ProductName,p.ProductID,f.bomLevel,f.bomPath,a.PlanAt,a.PlannedCompletionAt
           ORDER BY f.bomPath,a.PlanAt FOR JSON PATH) jobs
        FROM offers h
        OUTER APPLY (
          SELECT SUM(CONVERT(decimal(28,8),s.OrderQty)) RepresentedQty,
                 SUM(CONVERT(decimal(28,8),s.OrderQty)*p.ListPrice) LostValue,
                 SUM(CASE WHEN p.ProductKey IS NULL OR p.ListPrice IS NULL THEN 1 ELSE 0 END) MissingPriceCount
          FROM act_input.BusinessSalesLine s
          LEFT JOIN act_input.BusinessProduct p ON p.ProductKey=s.ProductKey
          WHERE s.IsDemandEligible=1 AND EXISTS (
            SELECT 1 FROM OPENJSON(h.PlanJSON,'$.impact.additionalLostOrderIds') lost
            WHERE TRY_CONVERT(bigint,lost.value)=s.SalesOrderID)
        ) lv
        ORDER BY CASE h.Slot WHEN 'A' THEN 0 WHEN 'B' THEN 1 ELSE 2 END,h.Variant,h.DueAt
        """,ct,("@run",run),("@product",product),("@qty",qty),
            ("@known",known.ToDateTime(TimeOnly.MinValue)),
            ("@due",due.ToDateTime(TimeOnly.MinValue)));
}

using Microsoft.Data.SqlClient;

namespace DssInventoryMvc.Data;

public sealed partial class DssSqlRepository
{
    // Each result set is a read-only projection for the order replay screen.
    private async Task<List<Dictionary<string, object?>>> ReplayRows(string sql, CancellationToken ct,
        params (string Name, object Value)[] parameters)
    {
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection);
        foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter.Name, parameter.Value);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<Dictionary<string, object?>>();
        while (await reader.ReadAsync(ct))
        {
            var row = new Dictionary<string, object?>();
            for (var i = 0; i < reader.FieldCount; i++)
                row.Add(reader.GetName(i), reader.IsDBNull(i) ? null : reader.GetValue(i));
            rows.Add(row);
        }
        return rows;
    }

    // Use the declared FULL options so publication order cannot change the original deadline.
    private const string Basket = """
        WITH basket AS (
          SELECT i.InquiryKey AS caseKey,i.KnownAt AS knownAt,i.AnalysisEnd AS endAt,
                 j.id AS candidateId, t.due AS due, l.qty AS qty
          FROM cxcontrol.Inquiry i
          JOIN cxcontrol.InquiryPurpose usecase ON usecase.InquiryKey=i.InquiryKey AND usecase.Purpose='ORDER_INQUIRY'
          CROSS APPLY OPENJSON(i.RequestJSON,'$.candidates') WITH
            (id nvarchar(160) '$.candidate_id', kind varchar(20) '$.kind', tranches nvarchar(max) '$.tranches' AS JSON) j
          CROSS APPLY OPENJSON(j.tranches) WITH (due date '$.due_date', lines nvarchar(max) '$.lines' AS JSON) t
          CROSS APPLY OPENJSON(t.lines) WITH (pid int '$.product_id', qty int '$.quantity') l
          WHERE j.kind='FULL' AND (SELECT COUNT(*) FROM OPENJSON(t.lines))=1 AND l.pid=@product
            AND JSON_VALUE(i.RequestJSON,'$.initialization_mode')='BASELINE_AT_START'
            AND TRY_CONVERT(int,JSON_VALUE(i.RequestJSON,'$.base_run_key'))=@run
            AND EXISTS (SELECT 1 FROM dss.Dim_PlanningRun b WHERE b.PlanningRunKey=@run AND b.RunCode=i.BaseRunCode)
        )
        """;

    public Task<List<Dictionary<string, object?>>> Cases(int run, int product, CancellationToken ct) =>
        ReplayRows(Basket + """
            
            SELECT caseKey,knownAt,endAt,qty,MIN(due) AS originalDue FROM basket GROUP BY caseKey,knownAt,endAt,qty
            ORDER BY knownAt,caseKey,qty
            """,ct,("@run",run),("@product",product));

    public Task<List<Dictionary<string, object?>>> Opening(int run,int product,DateOnly day,int? qty,CancellationToken ct) =>
        ReplayRows("""
            WITH opening AS (
              SELECT p.ProductKey,p.ProductName,p.ListPrice AS unitPrice,SUM(f.OnHandQty) AS stock,SUM(f.ProductionWIPQty) AS wip
              FROM act_input.BusinessProduct p JOIN dss.Fact_SimulationDaily f ON f.ProductKey=p.ProductKey
              WHERE p.ProductID=@product AND p.CategoryName=N'Bikes' AND f.PlanningRunKey=@run
                AND f.DateKey=CONVERT(int,CONVERT(char(8),DATEADD(day,-1,@day),112))
                AND EXISTS(SELECT 1 FROM bi.CompletedRuns cr WHERE cr.PlanningRunKey=@run AND CONVERT(int,CONVERT(char(8),@day,112)) BETWEEN cr.SimulationStartDateKey AND cr.SimulationEndDateKey)
              GROUP BY p.ProductKey,p.ProductName,p.ListPrice
            ), bom AS (
              SELECT b.ComponentProductKey k, p.ProductID productId, p.ProductName name,SUM(b.PerAssemblyQty) AS factor
              FROM opening o JOIN act_input.BusinessBOM b ON b.AssemblyProductKey=o.ProductKey
              JOIN act_input.BusinessProduct p ON p.ProductKey=b.ComponentProductKey AND p.MakeFlag=1
              WHERE b.IsStructureValid=1 AND b.StartDate<=@day AND (b.EndDate IS NULL OR b.EndDate>=@day)
              GROUP BY b.ComponentProductKey,p.ProductID,p.ProductName
            )
            SELECT o.ProductName AS productName,o.unitPrice,o.stock,o.wip,b.name AS componentName,b.productId AS componentProductId,
                   CASE WHEN @qty IS NULL OR b.k IS NULL THEN NULL WHEN @qty<=o.stock THEN 0
                        WHEN a.hand IS NULL THEN NULL WHEN (@qty-o.stock)*b.factor>a.hand THEN (@qty-o.stock)*b.factor-a.hand ELSE 0 END AS missing
            FROM opening o LEFT JOIN bom b ON 1=1 OUTER APPLY (
              SELECT SUM(f.OnHandQty) hand FROM dss.Fact_SimulationDaily f WHERE f.ProductKey=b.k AND f.PlanningRunKey=@run
              AND f.DateKey=CONVERT(int,CONVERT(char(8),DATEADD(day,-1,@day),112))
            ) a ORDER BY b.name
            """,ct,("@run",run),("@product",product),("@day",day.ToDateTime(TimeOnly.MinValue)),("@qty",(object?)qty??DBNull.Value));

    public Task<List<Dictionary<string, object?>>> Options(int run,int product,int id,int qty,CancellationToken ct) =>
        ReplayRows(Basket + """
            
            ,selected AS (SELECT * FROM basket WHERE caseKey=@id AND qty=@qty),
            options AS (
              SELECT s.caseKey,s.candidateId,s.due,CASE WHEN s.due=MIN(s.due) OVER() THEN 'A' ELSE 'B' END AS slot FROM selected s
              UNION ALL SELECT DISTINCT s.caseKey,c.CandidateID,NULL,'C' FROM selected s JOIN cxcontrol.Candidate c
                   ON c.InquiryKey=s.caseKey AND c.CandidateKind='BASELINE'
            )
            SELECT o.slot,o.candidateId,o.due,c.PlanningRunKey AS branchRun, ord.CompletedAt AS completedAt,
                   ord.OrderStatus AS orderStatus,ord.CancelledAt AS cancelledAt,t.SourceSalesOrderID AS orderId,
                   CASE WHEN o.slot='C' THEN @qty END AS declinedQty,ctrl.controlRun
            FROM options o LEFT JOIN cxcontrol.Candidate c ON c.InquiryKey=o.caseKey AND c.CandidateID=o.candidateId
              AND EXISTS(SELECT 1 FROM bi.CompletedRuns r WHERE r.PlanningRunKey=c.PlanningRunKey)
              AND EXISTS(SELECT 1 FROM cxdetail.RunDetail d WHERE d.PlanningRunKey=c.PlanningRunKey)
            LEFT JOIN cxcontrol.Tranche t ON t.CandidateKey=c.CandidateKey AND t.DueDate=o.due AND EXISTS
              (SELECT 1 FROM cxcontrol.InquiryLine l JOIN act_input.BusinessProduct p ON p.ProductKey=l.ProductKey
               WHERE l.TrancheKey=t.TrancheKey AND p.ProductID=@product AND l.RequestedQty=@qty)
            LEFT JOIN dss.Fact_SimulationOrder ord ON ord.PlanningRunKey=c.PlanningRunKey AND ord.SourceSalesOrderID=t.SourceSalesOrderID
            OUTER APPLY (SELECT CASE WHEN COUNT(*)=1 THEN MIN(b.PlanningRunKey) END AS controlRun FROM cxcontrol.Candidate b
              JOIN bi.CompletedRuns r ON r.PlanningRunKey=b.PlanningRunKey JOIN cxdetail.RunDetail d ON d.PlanningRunKey=b.PlanningRunKey
              WHERE b.InquiryKey=o.caseKey AND b.CandidateKind='BASELINE' AND b.SharedStateHash=c.SharedStateHash) ctrl
            ORDER BY o.slot,o.due,o.candidateId
            """,ct,("@run",run),("@product",product),("@id",id),("@qty",qty));

    public Task<List<Dictionary<string, object?>>> Impact(int run,int control,int product,DateTime from,DateTime to,
        CancellationToken ct) => ReplayRows("""
        WITH days AS (
          SELECT f.PlanningRunKey,f.DateKey,SUM(f.OnHandValue+f.WIPValue) val,
            SUM(CASE WHEN p.ProductID=@product THEN f.OnHandQty END) AS bike
          FROM dss.Fact_SimulationDaily f JOIN act_input.BusinessProduct p ON p.ProductKey=f.ProductKey
          WHERE f.PlanningRunKey IN (@run,@control) AND f.DateKey BETWEEN CONVERT(int,CONVERT(char(8),@from,112)) AND CONVERT(int,CONVERT(char(8),@to,112))
          GROUP BY f.PlanningRunKey,f.DateKey
        ), delta AS (
          SELECT AVG(a.bike)-AVG(b.bike) AS qtyDelta,100.0*(AVG(a.bike)-AVG(b.bike))/NULLIF(AVG(b.bike),0) AS qtyPct,
                 AVG(a.val)-AVG(b.val) AS valueDelta FROM days a JOIN days b ON b.DateKey=a.DateKey
          WHERE a.PlanningRunKey=@run AND b.PlanningRunKey=@control
          HAVING COUNT(a.bike)=DATEDIFF(day,@from,@to)+1 AND COUNT(b.bike)=DATEDIFF(day,@from,@to)+1
        ), otherOrders AS (
          SELECT x.CompletedAt,x.DueAt FROM dss.Fact_SimulationOrder x JOIN dss.Fact_SimulationOrder y
           ON y.SourceSalesOrderID=x.SourceSalesOrderID AND y.PlanningRunKey=@control
          WHERE x.PlanningRunKey=@run AND x.DueAt BETWEEN @from AND @to AND y.CompletedAt<=y.DueAt
            AND (x.CompletedAt>x.DueAt OR x.CompletedAt IS NULL)
        )
        SELECT d.*, (SELECT COUNT(*) FROM otherOrders WHERE CompletedAt<=@to) AS newlyLate,
               (SELECT AVG(CONVERT(float,DATEDIFF(day,DueAt,CompletedAt))) FROM otherOrders WHERE CompletedAt<=@to) AS meanLateDays,
               (SELECT COUNT(*) FROM otherOrders WHERE CompletedAt IS NULL OR CompletedAt>@to) AS unfilledByEnd FROM delta d
        """,ct,("@run",run),("@control",control),("@product",product),("@from",from),("@to",to));

    public Task<List<Dictionary<string, object?>>> Plan(int run,int order,DateTime known,CancellationToken ct) =>
        ReplayRows("""
        WITH ver AS (SELECT TOP(1) DecisionVersionID,DecisionAt FROM cxdetail.PlanVersion
          WHERE PlanningRunKey=@run AND DecisionAt=@known ORDER BY SolveSequence DESC),
        attributed AS (
          SELECT a.SupplyActionRowNumber AS actionNo,SUM(a.AllocatedQty) AS qty
          FROM cxdetail.AdvisoryAllocation a JOIN ver ON ver.DecisionVersionID=a.DecisionVersionID
          WHERE a.PlanningRunKey=@run AND a.SalesOrderID=@order AND a.ConsumerType='SALES_ORDER_LINE'
             AND a.SupplyKind='PLANNED_PRODUCTION' GROUP BY a.SupplyActionRowNumber
          UNION ALL
          SELECT m.ComponentSupplyActionRowNumber,SUM(m.AttributedQty) FROM cxdetail.PlanOrderMaterial m
          JOIN ver ON ver.DecisionVersionID=m.DecisionVersionID WHERE m.PlanningRunKey=@run AND m.SalesOrderID=@order
            AND m.ComponentSupplyKind='PLANNED_PRODUCTION' GROUP BY m.ComponentSupplyActionRowNumber
        )
        SELECT p.ProductName AS name,p.ProductID AS productId,SUM(e.qty) AS qty,
             v.DecisionAt AS versionDate,release.date AS releaseDate,
             a.PlanAt AS startDate,a.PlannedCompletionAt AS finishDate
        FROM attributed e JOIN ver v ON 1=1 JOIN cxdetail.PlanAction a ON a.PlanningRunKey=@run
             AND a.DecisionVersionID=v.DecisionVersionID AND a.RowNumber=e.actionNo AND a.ActionCode='PRODUCTION_START'
        JOIN act_input.BusinessProduct p ON p.ProductID=a.ProductID
        OUTER APPLY (
          SELECT CASE WHEN COUNT(DISTINCT q.d)=1 THEN MIN(q.d) END AS date
          FROM (
            SELECT j.CreatedAt AS d FROM cxdetail.ProductionJobDay j
            WHERE j.PlanningRunKey=@run AND j.Date=DATEADD(day,-1,@known) AND j.ProductID=a.ProductID AND j.QueuedQty>0
            UNION ALL
            SELECT req.PlanAt FROM cxdetail.PlanAction req
            WHERE req.PlanningRunKey=@run AND req.DecisionVersionID=a.DecisionVersionID AND req.ProductID=a.ProductID
              AND req.ActionCode='PRODUCTION_REQUEST' AND req.Quantity>0
          ) q WHERE q.d<=DATEADD(day,-a.QueueAge,a.PlanAt)
        ) release
        GROUP BY a.RowNumber,p.ProductName,p.ProductID,v.DecisionAt,release.date,a.PlanAt,a.PlannedCompletionAt
        ORDER BY a.PlanAt,p.ProductName,a.RowNumber
        """,ct,("@run",run),("@order",order),("@known",known));
}

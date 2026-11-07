using Microsoft.Data.SqlClient;

namespace DssInventoryMvc.Data;

public sealed record DssRun(int Id, string Policy, string CaseName, int StartKey, int EndKey, DateTime CompletedAt);
public sealed record DssPair(int BaselineRunId, int CandidateRunId, string DeliveryRule);
public sealed record DssProduct(int ProductKey, int ProductId, string Name, string Number, int DaysToManufacture);
public sealed record DssSegment(string Label, decimal Value);
public sealed record DssProduction(long ProductId, string ProductName, DateTime StartAt, DateTime? CompletedAt, decimal StartedQty, decimal GoodQty);
public sealed record DssMetrics(decimal CustomerDueQty, decimal OnTimeDeliveredQty, decimal OnTimeUnitRate,
    decimal LostQty, decimal FilledQty, decimal EndingBacklogQty, long DueOrderCount,
    long OnTimeFullOrderCount, long LostOrderCount, decimal AvgInventoryValue,
    decimal EndingOnHandQty, decimal EndingWipQty);
public sealed record DssRunResult(int RunId, DssMetrics Metrics, DssSegment[] Inventory,
    DssSegment[] Orders, DssProduction[] Production);
public sealed record DssMonth(int RunId, int MonthKey, decimal LostQty, decimal DeliveredQty,
    decimal AvgOnHandQty, decimal AvgInventoryValue, long DayCount,
    long DueOrderCount, long OnTimeOrderCount, long FilledOrderCount);
public sealed record DssComparison(DssPair Pair, DssRunResult Baseline, DssRunResult Candidate,
    DssMonth[] Monthly, int FromMonth, int ToMonth);
public sealed record DssSnapshot(int RunId, int ProductId, string ProductName, int DateKey,
    decimal OnHandQty, decimal WipQty, int BomComponentCount);

/// <summary>Read-only projections from the published SIM warehouse. No simulation is executed here.</summary>
public sealed partial class DssSqlRepository(IConfiguration configuration)
{
    private readonly string _connectionString = configuration.GetConnectionString("DssSqlServer")
        ?? throw new InvalidOperationException("ConnectionStrings:DssSqlServer is not configured.");

    private async Task<SqlConnection> OpenAsync(CancellationToken ct)
    {
        var connection = new SqlConnection(_connectionString);
        await connection.OpenAsync(ct);
        return connection;
    }

    public async Task<DssRun[]> RunsAsync(CancellationToken ct)
    {
        const string sql = """
            SELECT r.PlanningRunKey, p.PolicyName, c.CaseName,
                   r.SimulationStartDateKey, r.SimulationEndDateKey, r.CompletedAt
            FROM bi.CompletedRuns r
            JOIN bi.ExperimentCases c ON c.ExperimentCaseKey=r.ExperimentCaseKey
            JOIN dss.Dim_PolicyConfigVersion pc ON pc.PolicyConfigVersionKey=r.PolicyConfigVersionKey
            JOIN dss.Dim_PolicyType p ON p.PolicyTypeKey=pc.PolicyTypeKey
            ORDER BY r.CompletedAt DESC
            """;
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<DssRun>();
        while (await reader.ReadAsync(ct))
            rows.Add(new(reader.GetInt32(0), reader.GetString(1), reader.GetString(2),
                reader.GetInt32(3), reader.GetInt32(4), reader.GetDateTime(5)));
        return rows.ToArray();
    }

    public async Task<DssPair[]> PairsAsync(CancellationToken ct)
    {
        const string sql = """
            SELECT b.PlanningRunKey, c.PlanningRunKey,
                   CASE WHEN scope.AllowBackorders=1 THEN N'Cho phép giao bù'
                        ELSE N'Mất đơn tại hạn giao' END
            FROM cxcontrol.Candidate c
            JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
            JOIN cxcontrol.Baseline b ON b.RunCode=i.BaseRunCode
            JOIN cxactive.ActiveRunScope scope ON scope.PlanningRunKey=b.PlanningRunKey
            WHERE c.CandidateKind=N'BASELINE' AND i.KnownAt='20130701' AND i.AnalysisEnd='20140630'
              AND NOT EXISTS (SELECT 1 FROM cxcontrol.Tranche t JOIN cxcontrol.Candidate other ON other.CandidateKey=t.CandidateKey WHERE other.InquiryKey=i.InquiryKey)
              AND EXISTS(SELECT 1 FROM bi.CompletedRuns r WHERE r.PlanningRunKey=c.PlanningRunKey)
            ORDER BY b.PlanningRunKey
            """;
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<DssPair>();
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetInt32(0), reader.GetInt32(1), reader.GetString(2)));
        return rows.ToArray();
    }

    public async Task<DssProduct[]> ProductsAsync(CancellationToken ct)
    {
        const string sql = """
            SELECT ProductKey,ProductID,ProductName,ProductNumber,COALESCE(DaysToManufacture,0)
            FROM act_input.BusinessProduct
            WHERE CategoryName=N'Bikes' AND FinishedGoodsFlag=1 AND MakeFlag=1 AND ProductKey>0
            ORDER BY ProductName
            """;
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<DssProduct>();
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetInt32(0), reader.GetInt32(1), reader.GetString(2), reader.GetString(3), reader.GetInt32(4)));
        return rows.ToArray();
    }

    public async Task<DssRunResult?> RunAsync(int runId, CancellationToken ct)
    {
        await using var connection = await OpenAsync(ct);
        const string summarySql = """
            SELECT s.CustomerDueQty,s.OnTimeDeliveredQty,s.OnTimeUnitRate,s.LostQty,
                   s.FilledQty,s.EndingBacklogQty,s.DueOrderCount,s.OnTimeFullOrderCount,
                   s.LostOrderCount,s.AvgInventoryValue,
                   COALESCE(d.OnHandQty,0),COALESCE(d.ProductionWIPQty,0)
            FROM bi.RunSummary s
            JOIN bi.CompletedRuns r ON r.PlanningRunKey=s.PlanningRunKey
            LEFT JOIN bi.InventoryPerRunDay d ON d.PlanningRunKey=r.PlanningRunKey
                 AND d.DateKey=r.SimulationEndDateKey
            WHERE s.PlanningRunKey=@runId AND s.ValidationStatus='PASSED'
            """;
        DssMetrics? metrics;
        await using (var command = new SqlCommand(summarySql, connection))
        {
            command.Parameters.AddWithValue("@runId", runId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            if (!await reader.ReadAsync(ct)) return null;
            metrics = new(ReadDecimal(reader, 0), ReadDecimal(reader, 1), ReadDecimal(reader, 2),
                ReadDecimal(reader, 3), ReadDecimal(reader, 4), ReadDecimal(reader, 5),
                ReadLong(reader, 6), ReadLong(reader, 7), ReadLong(reader, 8),
                ReadDecimal(reader, 9), ReadDecimal(reader, 10), ReadDecimal(reader, 11));
        }

        const string inventorySql = """
            SELECT COALESCE(SUM(CASE WHEN p.FinishedGoodsFlag=1 THEN f.OnHandQty ELSE 0 END),0),
                   COALESCE(SUM(CASE WHEN p.FinishedGoodsFlag=0 THEN f.OnHandQty ELSE 0 END),0),
                   COALESCE(SUM(f.ProductionWIPQty),0)
            FROM bi.SimulationDaily f
            JOIN bi.CompletedRuns r ON r.PlanningRunKey=f.PlanningRunKey
            JOIN act_input.BusinessProduct p ON p.ProductKey=f.ProductKey
            WHERE f.PlanningRunKey=@runId AND f.DateKey=r.SimulationEndDateKey
            """;
        DssSegment[] inventory;
        await using (var command = new SqlCommand(inventorySql, connection))
        {
            command.Parameters.AddWithValue("@runId", runId);
            await using var reader = await command.ExecuteReaderAsync(ct);
            await reader.ReadAsync(ct);
            inventory = [new("Thành phẩm", ReadDecimal(reader, 0)),
                new("Linh kiện và vật tư", ReadDecimal(reader, 1)),
                new("Đang sản xuất", ReadDecimal(reader, 2))];
        }

        var lateOrders = Math.Max(0, metrics.DueOrderCount - metrics.OnTimeFullOrderCount - metrics.LostOrderCount);
        DssSegment[] orders = [new("Đúng hạn", metrics.OnTimeFullOrderCount),
            new("Giao trễ", lateOrders), new("Mất đơn", metrics.LostOrderCount)];
        var production = await ProductionAsync(connection, runId, ct);
        return new(runId, metrics, inventory, orders, production);
    }

    private static async Task<DssProduction[]> ProductionAsync(SqlConnection connection, int runId, CancellationToken ct)
    {
        const string sql = """
            SELECT TOP (12) e.ProductID,COALESCE(p.ProductName,CONVERT(nvarchar(30),e.ProductID)),
                   e.StartAt,e.CompletedAt,e.StartedQty,e.GoodQty
            FROM cxdetail.ProductionExecution e
            LEFT JOIN act_input.BusinessProduct p ON p.ProductID=e.ProductID
            WHERE e.PlanningRunKey=@runId
            ORDER BY e.StartAt DESC,e.DetailRowID DESC
            """;
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@runId", runId);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<DssProduction>();
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetInt64(0), reader.GetString(1),
            reader.GetDateTime(2), reader.IsDBNull(3) ? null : reader.GetDateTime(3),
            ReadDecimal(reader, 4), ReadDecimal(reader, 5)));
        return rows.ToArray();
    }

    public async Task<DssComparison?> CompareAsync(int candidateRunId, int months, CancellationToken ct)
    {
        var pair = (await PairsAsync(ct)).FirstOrDefault(p => p.CandidateRunId == candidateRunId);
        if (pair is null) return null;
        var runs = await RunsAsync(ct);
        var candidateInfo = runs.FirstOrDefault(r => r.Id == candidateRunId);
        if (candidateInfo is null) return null;
        var baseline = await RunAsync(pair.BaselineRunId, ct);
        var candidate = await RunAsync(pair.CandidateRunId, ct);
        if (baseline is null || candidate is null) return null;
        var end = DateFromKey(candidateInfo.EndKey);
        var start = months == 0 ? DateFromKey(candidateInfo.StartKey)
            : new DateOnly(end.Year, end.Month, 1).AddMonths(1 - Math.Clamp(months, 1, 48));
        if (start < DateFromKey(candidateInfo.StartKey)) start = DateFromKey(candidateInfo.StartKey);
        var fromKey = KeyFromDate(start);
        var toKey = candidateInfo.EndKey;

        const string sql = """
            WITH daily AS (
              SELECT PlanningRunKey,DateKey/100 AS MonthKey,
                     SUM(LostQty) LostQty,
                     SUM(OnTimeDeliveredQty+LateDeliveredQty) DeliveredQty
              FROM dss.Fact_SimulationDaily
              WHERE PlanningRunKey IN (@baseId,@candidateId) AND DateKey BETWEEN @fromKey AND @toKey
              GROUP BY PlanningRunKey,DateKey/100
            ), inventory AS (
              SELECT PlanningRunKey,DateKey/100 AS MonthKey,
                     AVG(OnHandQty) AvgOnHandQty,AVG(OnHandValue+WIPValue) AvgInventoryValue,
                     COUNT_BIG(*) DayCount
              FROM bi.InventoryPerRunDay
              WHERE PlanningRunKey IN (@baseId,@candidateId) AND DateKey BETWEEN @fromKey AND @toKey
              GROUP BY PlanningRunKey,DateKey/100
            ), orders AS (
              SELECT PlanningRunKey,YEAR(DueAt)*100+MONTH(DueAt) AS MonthKey,
                     COUNT_BIG(*) DueOrderCount,
                     SUM(CONVERT(bigint,CASE WHEN OrderStatus='FULFILLED' AND CompletedAt<=DueAt THEN 1 ELSE 0 END)) OnTimeOrderCount,
                     SUM(CONVERT(bigint,CASE WHEN OrderStatus='FULFILLED' THEN 1 ELSE 0 END)) FilledOrderCount
              FROM dss.Fact_SimulationOrder
              WHERE PlanningRunKey IN (@baseId,@candidateId)
                AND DueAt>=CONVERT(date,CONVERT(char(8),@fromKey),112)
                AND DueAt<DATEADD(day,1,CONVERT(date,CONVERT(char(8),@toKey),112))
              GROUP BY PlanningRunKey,YEAR(DueAt)*100+MONTH(DueAt)
            )
            SELECT d.PlanningRunKey,d.MonthKey,d.LostQty,d.DeliveredQty,
                   COALESCE(i.AvgOnHandQty,0),COALESCE(i.AvgInventoryValue,0),
                   COALESCE(i.DayCount,0),COALESCE(o.DueOrderCount,0),
                   COALESCE(o.OnTimeOrderCount,0),COALESCE(o.FilledOrderCount,0)
            FROM daily d
            LEFT JOIN inventory i ON i.PlanningRunKey=d.PlanningRunKey AND i.MonthKey=d.MonthKey
            LEFT JOIN orders o ON o.PlanningRunKey=d.PlanningRunKey AND o.MonthKey=d.MonthKey
            ORDER BY d.MonthKey,d.PlanningRunKey
            """;
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection) { CommandTimeout = 60 };
        command.Parameters.AddWithValue("@baseId", pair.BaselineRunId);
        command.Parameters.AddWithValue("@candidateId", pair.CandidateRunId);
        command.Parameters.AddWithValue("@fromKey", fromKey);
        command.Parameters.AddWithValue("@toKey", toKey);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<DssMonth>();
        while (await reader.ReadAsync(ct)) rows.Add(new(reader.GetInt32(0), reader.GetInt32(1),
            ReadDecimal(reader, 2), ReadDecimal(reader, 3), ReadDecimal(reader, 4),
            ReadDecimal(reader, 5), ReadLong(reader, 6), ReadLong(reader, 7),
            ReadLong(reader, 8), ReadLong(reader, 9)));
        return new(pair, baseline, candidate, rows.ToArray(), fromKey / 100, toKey / 100);
    }

    public async Task<DssSnapshot?> SnapshotAsync(int runId, int productId, DateOnly date, CancellationToken ct)
    {
        const string sql = """
            SELECT p.ProductID,p.ProductName,
                   COALESCE(SUM(f.OnHandQty),0),COALESCE(SUM(f.ProductionWIPQty),0),
                   (SELECT COUNT(DISTINCT b.ComponentProductKey) FROM act_input.BusinessBOM b
                    WHERE b.AssemblyProductKey=p.ProductKey AND b.IsStructureValid=1
                      AND b.StartDate<=@date AND (b.EndDate IS NULL OR b.EndDate>=@date))
            FROM act_input.BusinessProduct p
            JOIN bi.CompletedRuns r ON r.PlanningRunKey=@runId
            LEFT JOIN dss.Fact_SimulationDaily f ON f.ProductKey=p.ProductKey
                AND f.PlanningRunKey=r.PlanningRunKey AND f.DateKey=@dateKey
            WHERE p.ProductID=@productId
              AND @dateKey BETWEEN r.SimulationStartDateKey AND r.SimulationEndDateKey
            GROUP BY p.ProductKey,p.ProductID,p.ProductName
            """;
        await using var connection = await OpenAsync(ct);
        await using var command = new SqlCommand(sql, connection);
        command.Parameters.AddWithValue("@runId", runId);
        command.Parameters.AddWithValue("@productId", productId);
        command.Parameters.AddWithValue("@date", date.ToDateTime(TimeOnly.MinValue));
        command.Parameters.AddWithValue("@dateKey", KeyFromDate(date));
        await using var reader = await command.ExecuteReaderAsync(ct);
        if (!await reader.ReadAsync(ct)) return null;
        return new(runId, reader.GetInt32(0), reader.GetString(1), KeyFromDate(date),
            ReadDecimal(reader, 2), ReadDecimal(reader, 3), reader.GetInt32(4));
    }

    private static decimal ReadDecimal(SqlDataReader reader, int index) => reader.IsDBNull(index) ? 0 : reader.GetDecimal(index);
    private static long ReadLong(SqlDataReader reader, int index) => reader.IsDBNull(index) ? 0 : reader.GetInt64(index);
    private static DateOnly DateFromKey(int key) => new(key / 10000, key / 100 % 100, key % 100);
    private static int KeyFromDate(DateOnly date) => date.Year * 10000 + date.Month * 100 + date.Day;
}

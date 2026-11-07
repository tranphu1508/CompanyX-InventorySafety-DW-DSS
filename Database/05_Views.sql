IF SCHEMA_ID('bi') IS NULL EXEC('CREATE SCHEMA bi AUTHORIZATION dbo');
GO
CREATE OR ALTER VIEW bi.ExperimentCases AS
SELECT c.* FROM dss.ExperimentCase c JOIN dss.Dim_ExperimentVersion e ON e.ExperimentVersionKey=c.ExperimentVersionKey WHERE e.LifecycleStatus='PUBLISHED';
GO
CREATE OR ALTER VIEW bi.CompletedRuns AS
SELECT r.* FROM dss.v_PlanningRunContext r
JOIN bi.ExperimentCases c ON c.ExperimentCaseKey=r.ExperimentCaseKey
WHERE r.RunStatus='SUCCEEDED';
GO
CREATE OR ALTER VIEW bi.RunSummary AS
SELECT f.* FROM dss.Fact_RunSummary f
JOIN bi.CompletedRuns r ON r.PlanningRunKey=f.PlanningRunKey;
GO
CREATE OR ALTER VIEW bi.SimulationDaily AS
SELECT f.* FROM dss.Fact_SimulationDaily f
JOIN bi.CompletedRuns r ON r.PlanningRunKey=f.PlanningRunKey;
GO
CREATE OR ALTER VIEW bi.SimulationOrder AS
SELECT f.* FROM dss.Fact_SimulationOrder f
JOIN bi.CompletedRuns r ON r.PlanningRunKey=f.PlanningRunKey;
GO
CREATE OR ALTER VIEW bi.OptimizationSolve AS
SELECT f.* FROM dss.Fact_OptimizationSolve f
JOIN bi.CompletedRuns r ON r.PlanningRunKey=f.PlanningRunKey;
GO
CREATE OR ALTER VIEW bi.InventoryPerRunDay AS
SELECT PlanningRunKey, DateKey,
 SUM(OnHandQty) AS OnHandQty, SUM(ProductionWIPQty) AS ProductionWIPQty,
 SUM(OnHandValue) AS OnHandValue, SUM(WIPValue) AS WIPValue,
 SUM(OwnedInTransitValue) AS OwnedInTransitValue
FROM bi.SimulationDaily GROUP BY PlanningRunKey,DateKey;
GO

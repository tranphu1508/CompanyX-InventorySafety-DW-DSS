-- Separate inquiry-cube preflight. Run RunDayCache.sql immediately before this file.
-- Read-only data contract for the MOLAP daily-average denominator.
-- Each eligible run/product/location must have one row for every simulation day,
-- including true zero-stock days. No missing date may silently shrink a denominator.
SET NOCOUNT ON;
-- Materialize only the small run header in a session-local table variable. This
-- prevents repeated expansion of the multi-join context view in grid checks.
DECLARE @Runs TABLE(
 PlanningRunKey int NOT NULL PRIMARY KEY,
 ScenarioVersionKey bigint NOT NULL,
 SimulationStartDateKey int NOT NULL,
 SimulationEndDateKey int NOT NULL
);
INSERT @Runs(PlanningRunKey,ScenarioVersionKey,SimulationStartDateKey,SimulationEndDateKey)
SELECT PlanningRunKey,ScenarioVersionKey,SimulationStartDateKey,SimulationEndDateKey FROM cxolap.DimRun;
IF NOT EXISTS(SELECT 1 FROM @Runs)
 THROW 51010, 'MOLAP preflight: no published succeeded validated simulation run.', 1;

IF EXISTS(
 SELECT 1 FROM @Runs r
 LEFT JOIN dw.Dim_Date ds ON ds.DateKey=r.SimulationStartDateKey
 LEFT JOIN dw.Dim_Date de ON de.DateKey=r.SimulationEndDateKey
 WHERE ds.CalendarDate IS NULL OR de.CalendarDate IS NULL OR ds.CalendarDate>de.CalendarDate)
 THROW 51011, 'MOLAP preflight: invalid or missing simulation date interval.', 1;

IF EXISTS(
 SELECT 1 FROM @Runs r
 WHERE NOT EXISTS(SELECT 1 FROM dss.Fact_SimulationDaily f WHERE f.PlanningRunKey=r.PlanningRunKey))
 THROW 51012, 'MOLAP preflight: eligible run has no daily facts.', 1;

IF EXISTS(
 SELECT 1 FROM dss.Fact_SimulationDaily f
 JOIN @Runs r ON r.PlanningRunKey=f.PlanningRunKey
 LEFT JOIN dw.Dim_Date d ON d.DateKey=f.DateKey
 WHERE d.CalendarDate IS NULL OR f.DateKey<r.SimulationStartDateKey OR f.DateKey>r.SimulationEndDateKey)
 THROW 51013, 'MOLAP preflight: daily fact date is unknown or outside the simulation interval.', 1;

IF EXISTS(
 SELECT f.PlanningRunKey,f.ProductKey,f.LocationKey
 FROM dss.Fact_SimulationDaily f
 JOIN @Runs r ON r.PlanningRunKey=f.PlanningRunKey
 JOIN dw.Dim_Date ds ON ds.DateKey=r.SimulationStartDateKey
 JOIN dw.Dim_Date de ON de.DateKey=r.SimulationEndDateKey
 GROUP BY f.PlanningRunKey,f.ProductKey,f.LocationKey,ds.CalendarDate,de.CalendarDate
 HAVING COUNT_BIG(*)<>DATEDIFF(day,ds.CalendarDate,de.CalendarDate)+1
 OR COUNT(DISTINCT f.DateKey)<>DATEDIFF(day,ds.CalendarDate,de.CalendarDate)+1)
 THROW 51014, 'MOLAP preflight: incomplete daily calendar grid for a run/product/location.', 1;

IF EXISTS(
 SELECT 1 FROM dss.Fact_SimulationDaily f
 JOIN @Runs r ON r.PlanningRunKey=f.PlanningRunKey
 LEFT JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey
 LEFT JOIN dw.Dim_UnitMeasure u ON u.UnitMeasureKey=sp.StockUnitMeasureKey
 WHERE sp.ProductKey IS NULL OR u.UnitMeasureKey IS NULL)
 THROW 51015, 'MOLAP preflight: daily row would lose product/unit mapping in the cube view.', 1;

-- The denominator is derived once per run/date, not once per product or location.
IF EXISTS(
 SELECT r.PlanningRunKey
 FROM @Runs r
 JOIN dw.Dim_Date ds ON ds.DateKey=r.SimulationStartDateKey
 JOIN dw.Dim_Date de ON de.DateKey=r.SimulationEndDateKey
 LEFT JOIN cxcontrol.FactRunDay rd ON rd.PlanningRunKey=r.PlanningRunKey
 GROUP BY r.PlanningRunKey,ds.CalendarDate,de.CalendarDate
 HAVING COUNT_BIG(rd.DateKey)<>DATEDIFF(day,ds.CalendarDate,de.CalendarDate)+1)
 THROW 51016, 'MOLAP preflight: run/day denominator does not cover the full interval.', 1;

SELECT N'PASSED' SourcePreflightStatus,COUNT_BIG(*) EligibleRuns
FROM @Runs;

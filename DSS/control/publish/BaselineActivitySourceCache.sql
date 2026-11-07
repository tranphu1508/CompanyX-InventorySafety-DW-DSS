-- Run after FactSourceCache.sql, under the publication/process operation gate.
-- Only the owned new-cube view changes; original cxolap views remain untouched.
SET NOCOUNT ON;SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Requires owned source copy',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=1 AND major_id=OBJECT_ID('cxcontrol.EligibleRunSnapshot') AND name='CompanyXControlOwner' AND CONVERT(nvarchar(100),value)='companyx-control-20261105') THROW 51000,'Missing owned eligibility snapshot',1;
IF EXISTS(SELECT PlanningRunKey,ScenarioVersionKey,SimulationStartDateKey,SimulationEndDateKey FROM cxolap.DimRun EXCEPT SELECT * FROM cxcontrol.EligibleRunSnapshot) OR EXISTS(SELECT * FROM cxcontrol.EligibleRunSnapshot EXCEPT SELECT PlanningRunKey,ScenarioVersionKey,SimulationStartDateKey,SimulationEndDateKey FROM cxolap.DimRun) THROW 51000,'Refresh exact eligible run snapshot first',1;
GO
CREATE OR ALTER VIEW cxcontrol.FactBaselineActivity AS
SELECT a.*,sp.StockUnitMeasureKey FROM cxcontrol.BaselineActivity a
JOIN cxcontrol.EligibleRunSnapshot r ON r.PlanningRunKey=a.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=a.ProductKey;

GO
GRANT SELECT ON cxcontrol.FactBaselineActivity TO [CompanyXMOLAPReader];
GO

-- New-cube eligibility helper; no old view or fact is altered.
SET NOCOUNT ON; SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Requires owned source copy',1;
IF OBJECT_ID('cxcontrol.EligibleRunSnapshot','U') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=1 AND major_id=OBJECT_ID('cxcontrol.EligibleRunSnapshot') AND name='CompanyXControlOwner' AND CONVERT(nvarchar(100),value)='companyx-control-20261105') THROW 51000,'Refusing unmarked eligibility cache',1;
SELECT PlanningRunKey,ScenarioVersionKey,SimulationStartDateKey,SimulationEndDateKey INTO #EligibleStage
FROM cxolap.DimRun OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE);
CREATE UNIQUE CLUSTERED INDEX IX_EligibleStage ON #EligibleStage(PlanningRunKey);
BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lockResult int;
 EXEC @lockResult=sys.sp_getapplock @Resource='companyx-control-eligibility-cache',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=60000;
 IF @lockResult<0 THROW 51000,'Eligibility cache lock failed',1;
 IF OBJECT_ID('cxcontrol.EligibleRunSnapshot','U') IS NULL BEGIN
  CREATE TABLE cxcontrol.EligibleRunSnapshot(PlanningRunKey int NOT NULL PRIMARY KEY,ScenarioVersionKey bigint NOT NULL,SimulationStartDateKey int NOT NULL,SimulationEndDateKey int NOT NULL);
  EXEC sys.sp_addextendedproperty @name='CompanyXControlOwner',@value='companyx-control-20261105',@level0type='SCHEMA',@level0name='cxcontrol',@level1type='TABLE',@level1name='EligibleRunSnapshot';
 END;
 IF EXISTS(SELECT * FROM cxcontrol.EligibleRunSnapshot EXCEPT SELECT * FROM #EligibleStage) THROW 51000,'Existing eligible run metadata changed',1;
 INSERT cxcontrol.EligibleRunSnapshot SELECT e.* FROM #EligibleStage e WHERE NOT EXISTS(SELECT 1 FROM cxcontrol.EligibleRunSnapshot p WHERE p.PlanningRunKey=e.PlanningRunKey);
 IF EXISTS(SELECT * FROM #EligibleStage EXCEPT SELECT * FROM cxcontrol.EligibleRunSnapshot) THROW 51000,'Eligibility cache incomplete',1;
 COMMIT TRANSACTION;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;
GO
CREATE OR ALTER VIEW cxcontrol.FactSimulationDaily AS
SELECT f.*,sp.StockUnitMeasureKey,
 CONVERT(decimal(28,8),f.OnHandValue+f.WIPValue) InventoryValue,
 CONVERT(decimal(28,8),f.OnHandValue+f.WIPValue) InventoryValueDaySum,
 CONVERT(bigint,1) DailyRowCount
FROM dss.Fact_SimulationDaily f
JOIN cxcontrol.EligibleRunSnapshot r ON r.PlanningRunKey=f.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey;

GO
CREATE OR ALTER VIEW cxcontrol.FactOrderLineService AS
SELECT f.PlanningRunKey,f.EntityCode,f.ProductKey,sp.StockUnitMeasureKey,
 f.DueDateKey,COALESCE(f.CompletionDateKey,0) CompletionDateKey,
 f.CustomerOrderCode,f.EvaluationCohort,f.IsDueInEvaluationPeriod,
 f.ObligationQty,f.OTUDemandQty,f.OTUOnTimeQty,f.OnTimeQty,f.LateQty,f.FilledQty,f.LostQty,
 f.UnfilledQtyAtEnd,f.OverdueUnfilledQtyAtEnd,f.LateUnitDays,
 f.CompletionLateDays,CONVERT(bigint,1) LineCount,
 CONVERT(bigint,CASE WHEN f.CompletionDateKey IS NOT NULL THEN 1 ELSE 0 END) CompletedLineCount,
 CONVERT(decimal(28,8),CASE WHEN f.IsDueInEvaluationPeriod=1 THEN f.FilledQty ELSE 0 END) DueCohortFilledQty,
 CONVERT(decimal(28,8),CASE WHEN f.IsDueInEvaluationPeriod=1 THEN f.LostQty ELSE 0 END) DueCohortLostQty,
 CONVERT(decimal(28,8),CASE WHEN f.IsDueInEvaluationPeriod=1 THEN f.UnfilledQtyAtEnd ELSE 0 END) DueCohortEndingBacklogQty
FROM cxolap.OrderLineSnapshot f
JOIN cxcontrol.EligibleRunSnapshot r ON r.PlanningRunKey=f.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey;

GO
GRANT SELECT ON SCHEMA::cxcontrol TO [CompanyXMOLAPReader];
GO

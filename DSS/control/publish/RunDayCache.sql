-- New inquiry-cube helper only. Existing cxolap views and legacy cube stay unchanged.
-- Refresh after successful publication and before processing CompanyX_InquirySimulation.
-- CalendarDayCount is one per actually present eligible Run/Date, not a product-row sum.
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_NAME()<>N'CompanyX_DW_SIM_20261107'
 OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0
  AND name=N'CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)=N'companyx-split-20261107')
 THROW 51000,'Requires the owned MOLAP source copy',1;
IF SCHEMA_ID(N'cxcontrol') IS NULL THROW 51000,'Install the control schema first',1;
IF OBJECT_ID(N'cxcontrol.RunDaySnapshot',N'U') IS NOT NULL
 AND NOT EXISTS(SELECT 1 FROM sys.extended_properties
  WHERE class=1 AND major_id=OBJECT_ID(N'cxcontrol.RunDaySnapshot')
  AND name=N'CompanyXControlOwner' AND CONVERT(nvarchar(100),value)=N'companyx-control-20261105')
 THROW 51000,'Refusing an unmarked RunDaySnapshot table',1;

-- A tiny materialized eligibility relation prevents the optimizer expanding the
-- planning-context joins into the full Daily scan. Preserve the original joins.
SELECT PlanningRunKey,ScenarioVersionKey INTO #RunDayEligible
FROM cxolap.DimRun OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE);
CREATE UNIQUE CLUSTERED INDEX IX_RunDayEligible ON #RunDayEligible(PlanningRunKey);

SELECT f.PlanningRunKey,f.DateKey,CONVERT(bigint,1) CalendarDayCount
INTO #RunDayStage
FROM dss.Fact_SimulationDaily f
JOIN #RunDayEligible r ON r.PlanningRunKey=f.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey
GROUP BY f.PlanningRunKey,f.DateKey
OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE);
CREATE UNIQUE CLUSTERED INDEX IX_RunDayStage ON #RunDayStage(PlanningRunKey,DateKey);

BEGIN TRY
 BEGIN TRANSACTION;
 DECLARE @lockResult int;
 EXEC @lockResult=sys.sp_getapplock @Resource=N'companyx-control-20261105.RunDaySnapshot',
  @LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=60000;
 IF @lockResult<0 THROW 51000,'Could not lock owned RunDay cache refresh',1;
 IF OBJECT_ID(N'cxcontrol.RunDaySnapshot',N'U') IS NULL
 BEGIN
  CREATE TABLE cxcontrol.RunDaySnapshot(
   PlanningRunKey int NOT NULL,
   DateKey int NOT NULL,
   CalendarDayCount bigint NOT NULL,
   CONSTRAINT PK_cxcontrol_RunDaySnapshot PRIMARY KEY(PlanningRunKey,DateKey),
   CONSTRAINT CK_cxcontrol_RunDaySnapshot_Count CHECK(CalendarDayCount=1)
  );
  EXEC sys.sp_addextendedproperty @name=N'CompanyXControlOwner',@value=N'companyx-control-20261105',
   @level0type=N'SCHEMA',@level0name=N'cxcontrol',@level1type=N'TABLE',@level1name=N'RunDaySnapshot';
 END;
 -- Published results are immutable. A refresh may add runs/dates; it must never
 -- silently alter or remove an existing run's calendar membership.
 IF EXISTS(SELECT PlanningRunKey,DateKey,CalendarDayCount FROM cxcontrol.RunDaySnapshot
  EXCEPT SELECT PlanningRunKey,DateKey,CalendarDayCount FROM #RunDayStage)
  THROW 51000,'Existing RunDay cache differs from eligible source rows',1;
 IF EXISTS(SELECT s.PlanningRunKey,s.DateKey,s.CalendarDayCount FROM #RunDayStage s
  WHERE EXISTS(SELECT 1 FROM cxcontrol.RunDaySnapshot p WHERE p.PlanningRunKey=s.PlanningRunKey)
  EXCEPT SELECT PlanningRunKey,DateKey,CalendarDayCount FROM cxcontrol.RunDaySnapshot)
  THROW 51000,'An existing RunDay cache run acquired additional dates',1;
 INSERT cxcontrol.RunDaySnapshot(PlanningRunKey,DateKey,CalendarDayCount)
 SELECT s.PlanningRunKey,s.DateKey,s.CalendarDayCount FROM #RunDayStage s
 WHERE NOT EXISTS(SELECT 1 FROM cxcontrol.RunDaySnapshot p
  WHERE p.PlanningRunKey=s.PlanningRunKey AND p.DateKey=s.DateKey);
 IF EXISTS(SELECT PlanningRunKey,DateKey,CalendarDayCount FROM #RunDayStage
  EXCEPT SELECT PlanningRunKey,DateKey,CalendarDayCount FROM cxcontrol.RunDaySnapshot)
  THROW 51000,'RunDay cache refresh did not preserve all eligible source rows',1;
 EXEC(N'CREATE OR ALTER VIEW cxcontrol.FactRunDay AS
 SELECT PlanningRunKey,DateKey,CalendarDayCount FROM cxcontrol.RunDaySnapshot;');
 COMMIT TRANSACTION;
 SELECT COUNT_BIG(*) SnapshotRows,COUNT(DISTINCT PlanningRunKey) RunCount
 FROM cxcontrol.RunDaySnapshot;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;

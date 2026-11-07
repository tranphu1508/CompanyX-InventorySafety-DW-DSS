-- Refresh only the existing copied-warehouse cache; do not ALTER old views.
SET NOCOUNT ON; SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF OBJECT_ID('cxolap.OrderLineSnapshot','U') IS NULL THROW 51000,'Original owned cache is absent',1;
SELECT PlanningRunKey,COUNT_BIG(*) RowsBefore,CHECKSUM_AGG(BINARY_CHECKSUM(*)) RowChecksum
INTO #oldCache FROM cxolap.OrderLineSnapshot GROUP BY PlanningRunKey;
SELECT f.* INTO #cxcontrolOrderLineStage
FROM dss.v_SimulationOrderLine f OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE);
IF EXISTS(SELECT PlanningRunKey,RowsBefore,RowChecksum FROM #oldCache
 EXCEPT SELECT PlanningRunKey,COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM #cxcontrolOrderLineStage
 WHERE PlanningRunKey IN(SELECT PlanningRunKey FROM #oldCache) GROUP BY PlanningRunKey)
 THROW 51000,'Existing order-line cache data changed; inspection required',1;
BEGIN TRY
 BEGIN TRANSACTION;
 TRUNCATE TABLE cxolap.OrderLineSnapshot;
 INSERT cxolap.OrderLineSnapshot SELECT * FROM #cxcontrolOrderLineStage;
 COMMIT TRANSACTION;
 SELECT COUNT_BIG(*) SnapshotRows FROM cxolap.OrderLineSnapshot;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK TRANSACTION;
 THROW;
END CATCH;

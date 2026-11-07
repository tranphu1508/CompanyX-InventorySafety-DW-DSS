-- Read-only guard/evidence for the integrated demo's one permitted OLTP/warehouse pair.
SET NOCOUNT ON;
IF DB_NAME() <> N'CompanyX_DW_ACT_20261107'
    THROW 51051, 'Wrong warehouse.',1;
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)=N'companyx-split-20261107')
 OR NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXDemoOwner' AND CONVERT(nvarchar(100),value)=N'CompanyX_Demo_20261103')
 OR EXISTS (SELECT 1 FROM sys.database_files WHERE LEFT(physical_name,LEN(@FileRoot)) <> @FileRoot)
    THROW 51052, 'Expected the owned warehouse copy under Project/GPT/data.',1;
IF DB_ID(N'CompanyX_Demo') IS NULL
    THROW 51053, 'The CompanyX_Demo OLTP clone must be restored before running the demo.',1;
IF NOT EXISTS (SELECT 1 FROM CompanyX_Demo.sys.extended_properties WHERE class=0 AND name=N'CompanyXDemoOwner' AND CONVERT(nvarchar(100),value)=N'CompanyX_Demo_20261103')
 OR NOT EXISTS (SELECT 1 FROM etl_v2.State WHERE Id=1 AND SourceDatabase=N'CompanyX_Demo')
    THROW 51054, 'OLTP ownership or ETL source binding is incorrect.',1;
IF EXISTS (SELECT 1 FROM etl.ETL_LoadBatch WHERE Status=N'RUNNING')
    THROW 51055, 'An unfinished ETL batch or DSS run requires reconciliation.',1;
DECLARE @sourceVersion bigint;
EXEC CompanyX_Demo.sys.sp_executesql N'SELECT @v=CHANGE_TRACKING_CURRENT_VERSION()',N'@v bigint OUTPUT',@sourceVersion OUTPUT;
IF @sourceVersion IS NULL OR EXISTS (SELECT 1 FROM etl_v2.State WHERE LastVersion>@sourceVersion)
    THROW 51056, 'Invalid source Change Tracking state.',1;

SELECT @sourceVersion AS oltpVersion, s.LastVersion AS lastVersion, s.LastBatchID AS lastBatchId,
       b.PreviousVersion AS previousVersion, b.CapturedVersion AS capturedVersion,
       a.LoadMode AS loadMode, a.Status AS batchStatus, a.ValidationStatus AS validationStatus,
       b.SourceChangeCount AS sourceChanges, b.TargetChangeCount AS targetChanges,
       (SELECT COUNT_BIG(*) FROM CompanyX_Demo.Sales.SalesOrderDetail) AS oltpSalesLines,
       (SELECT COUNT_BIG(*) FROM CompanyX_Demo.Purchasing.PurchaseOrderDetail) AS oltpPurchaseLines,
       (SELECT COUNT_BIG(*) FROM dw.Fact_SalesOrderLine) AS warehouseSalesLines,
       (SELECT COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine) AS warehousePurchaseLines,
       (SELECT COUNT_BIG(*) FROM dw.Fact_InventoryOnHand) AS warehouseInventoryRows,
       (SELECT COUNT_BIG(*) FROM dss.Fact_DemandDaily) AS warehouseDemandRows
FROM etl_v2.State AS s
LEFT JOIN etl.ETL_LoadBatch AS a ON a.LoadBatchID=s.LastBatchID AND a.PipelineName=N'DWH_INCREMENTAL_V2'
LEFT JOIN etl_v2.BatchState AS b ON b.BatchId=s.LastBatchID
WHERE s.Id=1
FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES;

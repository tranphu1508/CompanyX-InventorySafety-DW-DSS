IF LEFT(DB_NAME(),LEN(N'InventorySafety_Demo'))<>N'InventorySafety_Demo' THROW 51814,'Protected warehouse',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE name=N'CompanyXSSISDeployment' AND CONVERT(nvarchar(100),value)=N'SSIS_20261029') THROW 51817,'Deployment is incomplete',1;
IF OBJECT_ID(N'etl_v2.Run',N'P') IS NULL OR OBJECT_ID(N'dss.InputSnapshot_ProductionLeadTime',N'U') IS NULL THROW 51818,'Required objects are missing',1;
IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@SourceDatabase) THROW 51816,'Source mismatch',1;
IF EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXDemoOwner') THROW 51819,'Owner marker already exists; do not redeploy',1;
EXEC sys.sp_addextendedproperty @name=N'CompanyXDemoOwner',@value=N'CompanyX_Demo_20261103';

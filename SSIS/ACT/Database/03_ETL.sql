IF DB_NAME()<>N'CompanyX_DW_ACT_20261107' THROW 51000,'ACT ETL cannot target another database.',1;
IF DB_NAME() IN (N'InventorySafety',N'CompanyX',N'master',N'model',N'msdb',N'tempdb') THROW 51700,'Protected database',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE name=N'CompanyXSSISDeployment' AND CONVERT(nvarchar(100),value)=N'SSIS_20261029') THROW 51701,'Target is not this package deployment',1;
IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@SourceDatabase) THROW 51706,'Source configuration mismatch',1;
EXEC etl_v2.Run;

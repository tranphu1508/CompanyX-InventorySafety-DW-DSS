IF @SourceDatabase IS NULL OR @TargetDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo'))<>N'CompanyX_Demo'
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo'))<>N'InventorySafety_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase=@TargetDatabase
 THROW 51810,'Only isolated CompanyX_Demo / InventorySafety_Demo databases are allowed.',1;
IF DB_ID(@SourceDatabase) IS NULL THROW 51811,'Restore the demo source first.',1;
DECLARE @q nvarchar(max)=N'USE '+QUOTENAME(@SourceDatabase)+N'; IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'') THROW 51812,''Source is not owned by this demo package.'',1;';
EXEC sys.sp_executesql @q;
-- SSIS ADO.NET input parameters: @TargetDatabase, @DataDirectory.
SET NOCOUNT ON; SET XACT_ABORT ON;
IF @TargetDatabase IS NULL OR LEN(@TargetDatabase)=0 OR LEN(@TargetDatabase)>100
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9_]%'
 OR @TargetDatabase IN ('master','model','msdb','tempdb','CompanyX','InventorySafety')
 THROW 51700,'Choose a new team DW name; production/source databases are protected.',1;
IF DB_ID(@TargetDatabase) IS NOT NULL THROW 51701,'Target already exists; no overwrite or drop.',1;
IF DB_ID(@SourceDatabase) IS NULL THROW 51702,'Restore your CompanyX OLTP on this SQL instance first.',1;
IF @SourceDatabase IS NULL OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9_]%' OR @SourceDatabase=@TargetDatabase THROW 51702,'Invalid source database',1;
DECLARE @SQL nvarchar(max)=N'CREATE DATABASE '+QUOTENAME(@TargetDatabase);
IF NULLIF(@DataDirectory,N'') IS NOT NULL
BEGIN
 DECLARE @Folder nvarchar(4000)=@DataDirectory+CASE WHEN RIGHT(@DataDirectory,1) IN ('\','/') THEN '' ELSE '\' END;
 SET @SQL+=N' ON PRIMARY (NAME=N'''+REPLACE(@TargetDatabase,'''','''''')+N''',FILENAME=N'''+REPLACE(@Folder+@TargetDatabase+'.mdf','''','''''')+N''',SIZE=128MB,FILEGROWTH=64MB) LOG ON (NAME=N'''+REPLACE(@TargetDatabase+'_log','''','''''')+N''',FILENAME=N'''+REPLACE(@Folder+@TargetDatabase+'_log.ldf','''','''''')+N''',SIZE=64MB,FILEGROWTH=64MB)';
END;
EXEC sys.sp_executesql @SQL;
SET @SQL=N'ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET ALLOW_SNAPSHOT_ISOLATION ON; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET RECOVERY SIMPLE; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET READ_COMMITTED_SNAPSHOT ON; ALTER DATABASE '+QUOTENAME(@TargetDatabase)+N' SET COMPATIBILITY_LEVEL=160;';
EXEC sys.sp_executesql @SQL;

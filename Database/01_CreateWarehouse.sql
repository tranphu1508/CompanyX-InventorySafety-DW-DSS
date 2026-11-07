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

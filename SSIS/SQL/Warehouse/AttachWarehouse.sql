-- Runs only after Tools/warehouse_bundle.py verify accepts the detached manifest.
-- Inputs: @PackageRoot, @DataDirectory, @SourceDatabase, @TargetDatabase.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0
 OR SERVERPROPERTY('InstanceName') IS NOT NULL OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS
    <>CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51870,'Warehouse attach requires the local default SQL Server 2022 instance.',1;
IF @TargetDatabase IS NULL OR LEN(@TargetDatabase)>LEN(N'InventorySafety_Demo')+60
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo')) COLLATE Latin1_General_100_BIN2<>N'InventorySafety_Demo'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase IS NULL OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51870,'Only isolated demo source and warehouse names are allowed.',1;
DECLARE @Folder nvarchar(4000)=@PackageRoot+N'\Warehouse';
IF @PackageRoot IS NULL OR @PackageRoot NOT LIKE N'[A-Za-z]:\%'
 OR RIGHT(@PackageRoot,1) IN (N'\',N'/') OR @PackageRoot LIKE N'%\..\%' OR @PackageRoot LIKE N'%/../%'
 OR @DataDirectory IS NULL OR @DataDirectory COLLATE Latin1_General_100_BIN2<>@Folder COLLATE Latin1_General_100_BIN2
    THROW 51871,'Warehouse attach is restricted to PackageRoot\Warehouse.',1;
DECLARE @Resource nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase;
IF ISNULL(APPLOCK_MODE(N'public',@Resource,N'Session'),N'NoLock')<>N'Exclusive'
    THROW 51872,'Warehouse setup lock was not retained.',1;
IF DB_ID(@TargetDatabase) IS NOT NULL THROW 51873,'Warehouse appeared after preflight; nothing will be overwritten.',1;
DECLARE @Mdf nvarchar(4000)=@Folder+N'\'+@TargetDatabase+N'.mdf';
DECLARE @Ldf nvarchar(4000)=@Folder+N'\'+@TargetDatabase+N'_log.ldf';
IF EXISTS(SELECT 1 FROM sys.master_files WHERE physical_name IN (@Mdf,@Ldf))
    THROW 51875,'A warehouse file is already attached to another database.',1;
DECLARE @Query nvarchar(max)=N'CREATE DATABASE '+QUOTENAME(@TargetDatabase)
 +N' ON (FILENAME=N'''+REPLACE(@Mdf,N'''',N'''''')+N'''),'
 +N'(FILENAME=N'''+REPLACE(@Ldf,N'''',N'''''')+N''') FOR ATTACH;';
EXEC sys.sp_executesql @Query;
-- The next SSIS task validates ONLINE, owner, source binding, deployment and column contract.
-- Failure retains all data for inspection; no automatic drop/delete is performed.

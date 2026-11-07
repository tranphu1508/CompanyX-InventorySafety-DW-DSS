-- SSIS Master connection; local portable warehouse selection, no database writes.
-- Inputs: @PackageRoot, @DataDirectory, @SourceDatabase, @TargetDatabase.
-- Result: WarehouseAction (0=existing, 1=create, 2=verify and attach detached bundle).
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0
 OR SERVERPROPERTY('InstanceName') IS NOT NULL OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS
    <>CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51870,'Warehouse setup requires the local default SQL Server 2022 instance.',1;
IF @TargetDatabase IS NULL OR LEN(@TargetDatabase)>LEN(N'InventorySafety_Demo')+60
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo')) COLLATE Latin1_General_100_BIN2<>N'InventorySafety_Demo'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase IS NULL OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51870,'Only isolated demo source and warehouse names are allowed.',1;
IF @PackageRoot IS NULL OR @PackageRoot NOT LIKE N'[A-Za-z]:\%'
 OR RIGHT(@PackageRoot,1) IN (N'\',N'/') OR @PackageRoot LIKE N'%\..\%'
 OR @PackageRoot LIKE N'%/../%' OR @PackageRoot LIKE N'%"%'
    THROW 51870,'PackageRoot must be the absolute local demo directory.',1;
DECLARE @Folder nvarchar(4000)=@PackageRoot+N'\Warehouse';
IF @DataDirectory IS NULL OR @DataDirectory COLLATE Latin1_General_100_BIN2<>@Folder COLLATE Latin1_General_100_BIN2
    THROW 51871,'DataDirectory must be PackageRoot\Warehouse. Open the demo through its launcher to refresh paths.',1;
DECLARE @Mdf nvarchar(4000)=@Folder+N'\'+@TargetDatabase+N'.mdf';
DECLARE @Ldf nvarchar(4000)=@Folder+N'\'+@TargetDatabase+N'_log.ldf';
IF LEN(@Mdf)>259 OR LEN(@Ldf)>259 THROW 51871,'Warehouse path is too long for SQL Server.',1;
DECLARE @Resource nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase,@Result int;
EXEC @Result=sys.sp_getapplock @Resource=@Resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
IF @Result<0 THROW 51872,'Another setup or packaging operation is using this warehouse.',1;
IF DB_ID(@TargetDatabase) IS NOT NULL
BEGIN
    IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@TargetDatabase AND state_desc=N'ONLINE')
        THROW 51873,'Existing warehouse is not ONLINE; it will not be changed.',1;
    IF (SELECT COUNT(*) FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase))<>2
     OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=0 AND physical_name COLLATE Latin1_General_100_BIN2=@Mdf COLLATE Latin1_General_100_BIN2)
     OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=1 AND physical_name COLLATE Latin1_General_100_BIN2=@Ldf COLLATE Latin1_General_100_BIN2)
        THROW 51874,'Existing warehouse files are outside this demo Warehouse folder. Relocate it safely after all runs finish; setup will not move or overwrite it.',1;
    DECLARE @PinPath nvarchar(4000)=@PackageRoot+N'\SSIS\schema_pin.json',@Pin nvarchar(max),@Query nvarchar(max);
    SET @Query=N'SELECT @j=CONVERT(nvarchar(max),CONVERT(varchar(max),BulkColumn) COLLATE Latin1_General_100_CI_AS_SC_UTF8) FROM OPENROWSET(BULK N'''+REPLACE(@PinPath,N'''',N'''''')+N''',SINGLE_BLOB) F;';
    EXEC sys.sp_executesql @Query,N'@j nvarchar(max) OUTPUT',@j=@Pin OUTPUT;
    IF ISNULL(ISJSON(@Pin),0)<>1 OR NOT EXISTS(SELECT 1 FROM OPENJSON(@Pin,'$.columns'))
        THROW 51877,'Missing or invalid warehouse column contract.',1;
    SET @Query=N'USE '+QUOTENAME(@TargetDatabase)+N';
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXSSISDeployment'' AND CONVERT(nvarchar(100),value)=N''SSIS_20261029'')
 OR OBJECT_ID(N''etl_v2.Run'',N''P'') IS NULL OR OBJECT_ID(N''dss.InputSnapshot_ProductionLeadTime'',N''U'') IS NULL
 THROW 51878,''Existing warehouse ownership or deployment is incompatible; no reset is allowed.'',1;
IF OBJECT_ID(N''etl_v2.State'',N''U'') IS NULL THROW 51878,''Warehouse source binding is missing.'',1;
IF (SELECT COUNT(*) FROM etl_v2.State)<>1 OR NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@Source)
 THROW 51878,''Warehouse source binding does not match this demo.'',1;
IF EXISTS(SELECT TableName,ColumnName,TypeName,MaxLength,[Precision],Scale,IsNullable,IsIdentity
 FROM OPENJSON(@Pin,''$.columns'') WITH(TableName nvarchar(200),ColumnName sysname,TypeName sysname,MaxLength int,[Precision] int,Scale int,IsNullable bit,IsIdentity bit)
 EXCEPT SELECT s.name+''.''+t.name,c.name,ty.name,c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity
 FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id)
 THROW 51877,''Warehouse column contract changed.'',1;';
    EXEC sys.sp_executesql @Query,N'@Source sysname,@Pin nvarchar(max)',@Source=@SourceDatabase,@Pin=@Pin;
    SELECT CONVERT(int,0) AS WarehouseAction;
    RETURN;
END;
DECLARE @MdfExists int=(SELECT file_exists FROM sys.dm_os_file_exists(@Mdf));
DECLARE @LdfExists int=(SELECT file_exists FROM sys.dm_os_file_exists(@Ldf));
IF ISNULL(@MdfExists,0)<>ISNULL(@LdfExists,0)
    THROW 51875,'Only one warehouse file exists. Partial files are retained; do not overwrite them.',1;
IF @MdfExists=1 AND @LdfExists=1
BEGIN
    IF NOT EXISTS(SELECT 1 FROM sys.dm_os_file_exists(@Folder+N'\warehouse_manifest.json') WHERE file_exists=1)
        THROW 51875,'Detached warehouse files require warehouse_manifest.json produced by the packaging package.',1;
    SELECT CONVERT(int,2) AS WarehouseAction;
    RETURN;
END;
DECLARE @DriveSpace table(Drive char(1),FreeMB int);
INSERT @DriveSpace EXEC master.dbo.xp_fixeddrives;
IF NOT EXISTS(SELECT 1 FROM @DriveSpace WHERE Drive=LEFT(@Folder,1) AND FreeMB>=2240)
    THROW 51876,'Creating the warehouse needs 192 MiB plus a 2 GiB free-space reserve.',1;
SELECT CONVERT(int,1) AS WarehouseAction;

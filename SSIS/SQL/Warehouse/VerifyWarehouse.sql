-- Final check for existing, newly created or attached warehouse. No schema/data writes.
-- Inputs: @PackageRoot, @DataDirectory, @SourceDatabase, @TargetDatabase.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0
 OR SERVERPROPERTY('InstanceName') IS NOT NULL OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS
    <>CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51870,'Warehouse verification requires the local default SQL Server 2022 instance.',1;
IF @TargetDatabase IS NULL OR LEN(@TargetDatabase)>LEN(N'InventorySafety_Demo')+60
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo')) COLLATE Latin1_General_100_BIN2<>N'InventorySafety_Demo'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase IS NULL OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51870,'Only isolated demo source and warehouse names are allowed.',1;
DECLARE @Folder nvarchar(4000)=@PackageRoot+N'\Warehouse';
IF @DataDirectory IS NULL OR @DataDirectory COLLATE Latin1_General_100_BIN2<>@Folder COLLATE Latin1_General_100_BIN2
    THROW 51871,'Warehouse data directory differs from the demo folder.',1;
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@TargetDatabase AND state_desc=N'ONLINE')
    THROW 51873,'Warehouse is not ONLINE.',1;
IF (SELECT COUNT(*) FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase))<>2
 OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=0 AND physical_name COLLATE Latin1_General_100_BIN2=(@Folder+N'\'+@TargetDatabase+N'.mdf') COLLATE Latin1_General_100_BIN2)
 OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=1 AND physical_name COLLATE Latin1_General_100_BIN2=(@Folder+N'\'+@TargetDatabase+N'_log.ldf') COLLATE Latin1_General_100_BIN2)
    THROW 51874,'Warehouse physical files do not match the portable demo folder.',1;
DECLARE @PinPath nvarchar(4000)=@PackageRoot+N'\SSIS\schema_pin.json',@Pin nvarchar(max),@Query nvarchar(max);
SET @Query=N'SELECT @j=CONVERT(nvarchar(max),CONVERT(varchar(max),BulkColumn) COLLATE Latin1_General_100_CI_AS_SC_UTF8) FROM OPENROWSET(BULK N'''+REPLACE(@PinPath,N'''',N'''''')+N''',SINGLE_BLOB) F;';
EXEC sys.sp_executesql @Query,N'@j nvarchar(max) OUTPUT',@j=@Pin OUTPUT;
IF ISJSON(@Pin)<>1 OR NOT EXISTS(SELECT 1 FROM OPENJSON(@Pin,'$.columns'))
    THROW 51877,'Missing or invalid warehouse column contract.',1;
SET @Query=N'USE '+QUOTENAME(@TargetDatabase)+N';
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 THROW 51878,''Warehouse owner marker mismatch; no redeployment is allowed.'',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXSSISDeployment'' AND CONVERT(nvarchar(100),value)=N''SSIS_20261029'')
 OR OBJECT_ID(N''etl_v2.Run'',N''P'') IS NULL OR OBJECT_ID(N''dss.InputSnapshot_ProductionLeadTime'',N''U'') IS NULL
 THROW 51878,''Warehouse deployment is incomplete; no automatic reset is allowed.'',1;
IF OBJECT_ID(N''etl_v2.State'',N''U'') IS NULL THROW 51878,''Warehouse source binding is missing.'',1;
IF (SELECT COUNT(*) FROM etl_v2.State)<>1 OR NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@Source)
 THROW 51878,''Warehouse source binding does not match this demo.'',1;
IF EXISTS(SELECT TableName,ColumnName,TypeName,MaxLength,[Precision],Scale,IsNullable,IsIdentity
 FROM OPENJSON(@Pin,''$.columns'') WITH(TableName nvarchar(200),ColumnName sysname,TypeName sysname,MaxLength int,[Precision] int,Scale int,IsNullable bit,IsIdentity bit)
 EXCEPT SELECT s.name+''.''+t.name,c.name,ty.name,c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity
 FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id)
 THROW 51877,''Warehouse column contract changed.'',1;';
EXEC sys.sp_executesql @Query,N'@Source sysname,@Pin nvarchar(max)',@Source=@SourceDatabase,@Pin=@Pin;
DECLARE @Resource nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase,@Result int;
EXEC @Result=sys.sp_releaseapplock @Resource=@Resource,@LockOwner='Session';
IF @Result<0 THROW 51872,'Could not release warehouse setup lock.',1;

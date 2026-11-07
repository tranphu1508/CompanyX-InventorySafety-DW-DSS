-- Native Execute SQL task after the two SSIS File System COPY tasks.
-- Inputs: @SourceDatabase, @RuntimeMdf, @RuntimeLdf, @AttachToken (NVARCHAR).
-- SHA256 pins are from Database/Source/source_manifest.json. Never attach distribution files.
-- On any error, copied files / a partially attached database remain for inspection.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0
 OR SERVERPROPERTY('InstanceName') IS NOT NULL
 OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS
    <> CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51850, 'Attach requires the local SQL Server 2022 default instance and Master connection.', 1;
IF @SourceDatabase IS NULL
 OR LEN(@SourceDatabase)<LEN(N'CompanyX_Demo') OR LEN(@SourceDatabase)>LEN(N'CompanyX_Demo')+70
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51850, 'Only isolated CompanyX_Demo source names are allowed.', 1;
DECLARE @LockResource nvarchar(255)=N'CompanyXDemo:SourceAttach:'+@SourceDatabase;
IF ISNULL(APPLOCK_MODE(N'public',@LockResource,N'Session'),N'NoLock')<>N'Exclusive'
    THROW 51854, 'Source attach session lock was not retained.', 1;
IF DB_ID(@SourceDatabase) IS NOT NULL
    THROW 51857, 'Source database appeared after preflight; nothing will be overwritten.', 1;
IF @AttachToken IS NULL OR LEN(@AttachToken)<>32
 OR @AttachToken COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Fa-f0-9]%'
    THROW 51855, 'Invalid source attach token.', 1;
DECLARE @DataRoot nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @LogRoot nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath'));
IF @DataRoot IS NULL OR @LogRoot IS NULL
 OR @DataRoot NOT LIKE N'[A-Za-z]:\%' OR @LogRoot NOT LIKE N'[A-Za-z]:\%'
    THROW 51855, 'SQL Server default directories must be local absolute paths.', 1;
IF RIGHT(@DataRoot,1)<>N'\' SET @DataRoot+=N'\';
IF RIGHT(@LogRoot,1)<>N'\' SET @LogRoot+=N'\';
IF @RuntimeMdf IS NULL OR @RuntimeLdf IS NULL
 OR @RuntimeMdf COLLATE Latin1_General_100_BIN2<>(@DataRoot+@SourceDatabase+N'_SSIS_'+@AttachToken+N'.mdf') COLLATE Latin1_General_100_BIN2
 OR @RuntimeLdf COLLATE Latin1_General_100_BIN2<>(@LogRoot+@SourceDatabase+N'_SSIS_'+@AttachToken+N'_log.ldf') COLLATE Latin1_General_100_BIN2
    THROW 51855, 'Attach paths must be the unique copies in SQL Server default directories.', 1;
IF EXISTS(SELECT 1 FROM sys.master_files WHERE physical_name IN (@RuntimeMdf,@RuntimeLdf))
    THROW 51857, 'One of the source copies is already attached.', 1;

DECLARE @Hash varbinary(32), @Bytes bigint, @Query nvarchar(max), @Message nvarchar(2048);
SET @Query=N'SELECT @h=HASHBYTES(''SHA2_256'',BulkColumn),@n=DATALENGTH(BulkColumn) FROM OPENROWSET(BULK N'''
 +REPLACE(@RuntimeMdf,N'''',N'''''')+N''',SINGLE_BLOB) AS F;';
EXEC sys.sp_executesql @Query,N'@h varbinary(32) OUTPUT,@n bigint OUTPUT',@h=@Hash OUTPUT,@n=@Bytes OUTPUT;
IF @Bytes<>276824064 OR @Hash<>0x9bea3fafc83ab3b1b04663c67b5b8de88654c5077322d983302970a13b6f7be2 OR @Hash IS NULL
BEGIN
    SET @Message=N'MDF checksum/size mismatch; copy retained at '+@RuntimeMdf;
    THROW 51858,@Message,1;
END;
SET @Hash=NULL; SET @Bytes=NULL;
SET @Query=N'SELECT @h=HASHBYTES(''SHA2_256'',BulkColumn),@n=DATALENGTH(BulkColumn) FROM OPENROWSET(BULK N'''
 +REPLACE(@RuntimeLdf,N'''',N'''''')+N''',SINGLE_BLOB) AS F;';
EXEC sys.sp_executesql @Query,N'@h varbinary(32) OUTPUT,@n bigint OUTPUT',@h=@Hash OUTPUT,@n=@Bytes OUTPUT;
IF @Bytes<>142606336 OR @Hash<>0xd3d90ab6294a19adf5ebc7b511770b7dea6558df2ffb6ae9c421a670af56cc52 OR @Hash IS NULL
BEGIN
    SET @Message=N'LDF checksum/size mismatch; copy retained at '+@RuntimeLdf;
    THROW 51858,@Message,1;
END;
SET @Query=N'CREATE DATABASE '+QUOTENAME(@SourceDatabase)
 +N' ON (FILENAME=N'''+REPLACE(@RuntimeMdf,N'''',N'''''')+N'''),'
 +N'(FILENAME=N'''+REPLACE(@RuntimeLdf,N'''',N'''''')+N''') FOR ATTACH;';
EXEC sys.sp_executesql @Query;
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@SourceDatabase AND state_desc=N'ONLINE')
    THROW 51852, 'The attached source is not ONLINE; runtime copies are retained.', 1;
SET @Query=N'USE '+QUOTENAME(@SourceDatabase)+N';
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner''
 AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 THROW 51853, ''The attached source does not contain the expected demo owner marker.'', 1;';
EXEC sys.sp_executesql @Query;

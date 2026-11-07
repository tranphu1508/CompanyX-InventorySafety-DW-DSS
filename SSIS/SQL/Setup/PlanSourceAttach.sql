-- Native SSIS setup: inspect the source and plan runtime copies of detached MDF/LDF.
-- ADO.NET Master parameters: @SourceDatabase. Single-row result is mapped to SSIS variables.
-- The retained Master connection keeps the session application lock through copy/attach.
SET NOCOUNT ON;
IF DB_NAME() <> N'master' OR @@TRANCOUNT <> 0
    THROW 51850, 'Use the Master connection outside a transaction for source attach.', 1;
IF SERVERPROPERTY('InstanceName') IS NOT NULL
 OR ISNULL(HOST_NAME(), N'') COLLATE Latin1_General_100_CI_AS
    <> CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51850, 'Source setup supports only the local default SQL Server instance.', 1;
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
    THROW 51850, 'The packaged source requires SQL Server 2022 (16.x).', 1;
IF @SourceDatabase IS NULL
 OR LEN(@SourceDatabase) < LEN(N'CompanyX_Demo')
 OR LEN(@SourceDatabase) > LEN(N'CompanyX_Demo') + 70
 OR LEFT(@SourceDatabase, LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2 <> N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51850, 'Only isolated CompanyX_Demo source names are allowed.', 1;
DECLARE @LockResource nvarchar(255) = N'CompanyXDemo:SourceAttach:' + @SourceDatabase;
DECLARE @LockResult int;
EXEC @LockResult = sys.sp_getapplock @Resource=@LockResource, @LockMode='Exclusive', @LockOwner='Session', @LockTimeout=0;
IF @LockResult < 0 THROW 51854, 'Another source setup is using this demo database.', 1;

IF DB_ID(@SourceDatabase) IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name=@SourceDatabase AND state_desc=N'ONLINE')
        THROW 51852, 'The existing source is not ONLINE; it will not be overwritten.', 1;
    DECLARE @OwnerQuery nvarchar(max) = N'USE ' + QUOTENAME(@SourceDatabase) + N';
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner''
 AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 THROW 51853, ''The existing source is not owned by this demo; it will not be overwritten.'', 1;';
    EXEC sys.sp_executesql @OwnerQuery;
    SELECT CONVERT(bit,0) AS SourceNeedsAttach,
           CONVERT(nvarchar(4000),N'') AS SourceRuntimeMdf,
           CONVERT(nvarchar(4000),N'') AS SourceRuntimeLdf,
           CONVERT(nvarchar(32),N'') AS SourceAttachToken;
    RETURN;
END;

DECLARE @DataRoot nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @LogRoot nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath'));
IF @DataRoot IS NULL OR @LogRoot IS NULL
 OR @DataRoot NOT LIKE N'[A-Za-z]:\%' OR @LogRoot NOT LIKE N'[A-Za-z]:\%'
    THROW 51855, 'SQL Server default data/log directories must be local absolute paths.', 1;
IF RIGHT(@DataRoot,1)<>N'\' SET @DataRoot+=N'\';
IF RIGHT(@LogRoot,1)<>N'\' SET @LogRoot+=N'\';
IF NOT EXISTS(SELECT 1 FROM sys.dm_os_file_exists(@DataRoot) WHERE file_is_a_directory=1)
 OR NOT EXISTS(SELECT 1 FROM sys.dm_os_file_exists(@LogRoot) WHERE file_is_a_directory=1)
    THROW 51855, 'SQL Server default data/log directory does not exist.', 1;

-- The two pinned distribution files total 400 MiB; preserve a 2 GiB reserve.
DECLARE @DriveSpace table(Drive char(1), FreeMB int);
INSERT @DriveSpace EXEC master.dbo.xp_fixeddrives;
DECLARE @MdfMB int=264, @LdfMB int=136, @ReserveMB int=2048;
IF LEFT(@DataRoot,1)=LEFT(@LogRoot,1)
BEGIN
    IF NOT EXISTS(SELECT 1 FROM @DriveSpace WHERE Drive=LEFT(@DataRoot,1) AND FreeMB>=@MdfMB+@LdfMB+@ReserveMB)
        THROW 51856, 'Not enough free space for runtime source copies plus the 2 GiB reserve.', 1;
END
ELSE
BEGIN
    IF NOT EXISTS(SELECT 1 FROM @DriveSpace WHERE Drive=LEFT(@DataRoot,1) AND FreeMB>=@MdfMB+@ReserveMB)
     OR NOT EXISTS(SELECT 1 FROM @DriveSpace WHERE Drive=LEFT(@LogRoot,1) AND FreeMB>=@LdfMB+@ReserveMB)
        THROW 51856, 'Not enough data/log drive space for source copies plus the 2 GiB reserve.', 1;
END;
DECLARE @Token nvarchar(32)=REPLACE(CONVERT(nvarchar(36),NEWID()),N'-',N'');
DECLARE @Mdf nvarchar(4000)=@DataRoot+@SourceDatabase+N'_SSIS_'+@Token+N'.mdf';
DECLARE @Ldf nvarchar(4000)=@LogRoot+@SourceDatabase+N'_SSIS_'+@Token+N'_log.ldf';
IF LEN(@Mdf)>259 OR LEN(@Ldf)>259
    THROW 51855, 'The generated runtime source path is too long.', 1;
IF EXISTS(SELECT 1 FROM sys.dm_os_file_exists(@Mdf) WHERE file_exists=1)
 OR EXISTS(SELECT 1 FROM sys.dm_os_file_exists(@Ldf) WHERE file_exists=1)
 OR EXISTS(SELECT 1 FROM sys.master_files WHERE physical_name IN (@Mdf,@Ldf))
    THROW 51857, 'Runtime source destinations already exist; no file will be overwritten.', 1;
SELECT CONVERT(bit,1) AS SourceNeedsAttach,
       @Mdf AS SourceRuntimeMdf, @Ldf AS SourceRuntimeLdf, @Token AS SourceAttachToken;

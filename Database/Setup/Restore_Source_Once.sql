/*
CompanyX demo: restore the source ONCE on the local default SQL Server 2022.

Open this file in SSMS, connect to localhost with Windows Authentication,
check @BackupFile / @SourceDatabase below, then Execute. SQLCMD mode is not needed.
The SQL Server service must be able to read CompanyX.bak and write its default
data/log folders. SQL Server stores the live database; the project retains the
original portable .bak. Run 10_KhoiTao.dtsx afterwards to initialize the warehouse.

An existing ONLINE database with the demo owner marker is left unchanged.
An existing unowned/offline database is refused. No WITH REPLACE, DROP, detach,
overwrite, schema change, ETL or simulation is performed by this setup script.
If a restore or ownership-marking step fails, the partial database/files remain
for inspection; the script does not delete them or silently retry the restore.

Metadata layouts below are those of SQL Server 2022 (16.x).
https://learn.microsoft.com/sql/t-sql/statements/restore-statements-headeronly-transact-sql
https://learn.microsoft.com/sql/t-sql/statements/restore-statements-filelistonly-transact-sql
*/
USE [master];
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @BackupFile nvarchar(4000) = N'D:\Study\Bách Khoa University\Kho Dữ Liệu và Hệ Hỗ trợ Quyết Định\Project\DSS\CompX_InventorySafetyDemo_20261104\CompanyX.bak';
DECLARE @SourceDatabase sysname = N'CompanyX_Demo';
DECLARE @ValidateOnly bit = 0; -- 1: verify backup, paths and capacity; do not restore.
DECLARE @ExpectedBackupHash varchar(64) = '07f1161f90b4fb7aab26f08f6046420855fc32b94f37f4b13a7fd00ecbbe2fb8';
DECLARE @Owner nvarchar(100) = N'CompanyX_Demo_20261103';

IF @@TRANCOUNT <> 0
    THROW 51850, 'Run the restore setup outside a user transaction.', 1;
IF CONVERT(int, SERVERPROPERTY('ProductMajorVersion')) <> 16
 OR SERVERPROPERTY('InstanceName') IS NOT NULL
    THROW 51850, 'This setup script targets the local default SQL Server 2022 instance.', 1;
IF ISNULL(HOST_NAME(), N'') COLLATE Latin1_General_100_CI_AS
    <> CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51850, 'Run this setup from the SQL Server Windows machine.', 1;
IF @SourceDatabase IS NULL
 OR LEN(@SourceDatabase) < LEN(N'CompanyX_Demo')
 OR LEN(@SourceDatabase) > LEN(N'CompanyX_Demo') + 70
 OR LEFT(@SourceDatabase, LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2 <> N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51850, 'Only isolated CompanyX_Demo source names are allowed.', 1;

DECLARE @Sql nvarchar(max), @LockResult int, @ReleaseResult int;
DECLARE @LockName nvarchar(255) = N'CompanyXDemo:RestoreSource:' + @SourceDatabase;
EXEC @LockResult = sys.sp_getapplock @Resource = @LockName,
    @LockMode = 'Exclusive', @LockOwner = 'Session', @LockTimeout = 0;
IF @LockResult < 0
    THROW 51854, 'Another setup session is preparing this demo source.', 1;

BEGIN TRY
    IF DB_ID(@SourceDatabase) IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @SourceDatabase AND state_desc = N'ONLINE')
            THROW 51852, 'The existing source is not ONLINE; inspect it without overwriting it.', 1;
        SET @Sql = N'USE ' + QUOTENAME(@SourceDatabase) + N';
            IF NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE class = 0
              AND name = N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100), value) = @Owner)
              THROW 51853, ''The existing source is unowned; it will not be overwritten.'', 1;';
        EXEC sys.sp_executesql @Sql, N'@Owner nvarchar(100)', @Owner;
        EXEC @ReleaseResult = sys.sp_releaseapplock @Resource = @LockName, @LockOwner = 'Session';
        SELECT N'ALREADY_PRESENT' AS SetupStatus, @SourceDatabase AS SourceDatabase;
        RETURN;
    END;

    SET @BackupFile = REPLACE(@BackupFile, N'/', N'\');
    IF @BackupFile IS NULL OR @BackupFile NOT LIKE N'[A-Za-z]:\%'
     OR @BackupFile LIKE N'%..%' OR RIGHT(@BackupFile, 13) <> N'\CompanyX.bak'
        THROW 51855, 'Choose the original local CompanyX.bak with an absolute path.', 1;

    CREATE TABLE #SourceFileExists (FileExists int, IsDirectory int, ParentExists int);
    INSERT #SourceFileExists EXEC master.dbo.xp_fileexist @BackupFile;
    IF NOT EXISTS (SELECT 1 FROM #SourceFileExists WHERE FileExists = 1 AND IsDirectory = 0)
        THROW 51855, 'CompanyX.bak is missing or unreadable by the SQL Server service.', 1;

    DECLARE @BackupBytes varbinary(max);
    SET @Sql = N'SELECT @Bytes = BulkColumn FROM OPENROWSET(BULK N''' + REPLACE(@BackupFile, N'''', N'''''') + N''', SINGLE_BLOB) b;';
    EXEC sys.sp_executesql @Sql, N'@Bytes varbinary(max) OUTPUT', @BackupBytes OUTPUT;
    IF LOWER(CONVERT(varchar(64), HASHBYTES('SHA2_256', @BackupBytes), 2)) <> @ExpectedBackupHash
        THROW 51856, 'CompanyX.bak differs from the protected original backup.', 1;
    SET @BackupBytes = NULL;

    CREATE TABLE #SourceBackupHeader (
        BackupName nvarchar(128), BackupDescription nvarchar(255), BackupType smallint,
        ExpirationDate datetime, Compressed bit, Position smallint, DeviceType tinyint,
        UserName nvarchar(128), ServerName nvarchar(128), DatabaseName nvarchar(128),
        DatabaseVersion int, DatabaseCreationDate datetime, BackupSize numeric(20,0),
        FirstLSN numeric(25,0), LastLSN numeric(25,0), CheckpointLSN numeric(25,0),
        DatabaseBackupLSN numeric(25,0), BackupStartDate datetime, BackupFinishDate datetime,
        SortOrder smallint, CodePage smallint, UnicodeLocaleId int, UnicodeComparisonStyle int,
        CompatibilityLevel tinyint, SoftwareVendorId int, SoftwareVersionMajor int,
        SoftwareVersionMinor int, SoftwareVersionBuild int, MachineName nvarchar(128), Flags int,
        BindingID uniqueidentifier, RecoveryForkID uniqueidentifier, Collation nvarchar(128),
        FamilyGUID uniqueidentifier, HasBulkLoggedData bit, IsSnapshot bit, IsReadOnly bit,
        IsSingleUser bit, HasBackupChecksums bit, IsDamaged bit, BeginsLogChain bit,
        HasIncompleteMetaData bit, IsForceOffline bit, IsCopyOnly bit,
        FirstRecoveryForkID uniqueidentifier, ForkPointLSN numeric(25,0), RecoveryModel nvarchar(60),
        DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
        BackupTypeDescription nvarchar(60), BackupSetGUID uniqueidentifier, CompressedBackupSize bigint,
        Containment tinyint, KeyAlgorithm nvarchar(32), EncryptorThumbprint varbinary(20),
        EncryptorType nvarchar(32), LastValidRestoreTime datetime, TimeZone nvarchar(32),
        CompressionAlgorithm nvarchar(32)
    );
    SET @Sql = N'RESTORE HEADERONLY FROM DISK = N''' + REPLACE(@BackupFile, N'''', N'''''') + N''' WITH FILE = 1;';
    INSERT #SourceBackupHeader EXEC sys.sp_executesql @Sql;
    IF NOT EXISTS (SELECT 1 FROM #SourceBackupHeader
                   WHERE DatabaseName = N'CompanyX' AND BackupType = 1 AND Position = 1)
        THROW 51856, 'Backup set 1 must be a full CompanyX database backup.', 1;
    RESTORE VERIFYONLY FROM DISK = @BackupFile WITH FILE = 1, CHECKSUM;

    CREATE TABLE #SourceBackupFiles (
        LogicalName nvarchar(128), PhysicalName nvarchar(260), Type char(1),
        FileGroupName nvarchar(128), Size numeric(20,0), MaxSize numeric(20,0), FileID bigint,
        CreateLSN numeric(25,0), DropLSN numeric(25,0), UniqueID uniqueidentifier,
        ReadOnlyLSN numeric(25,0), ReadWriteLSN numeric(25,0), BackupSizeInBytes bigint,
        SourceBlockSize int, FileGroupID int, LogGroupGUID uniqueidentifier,
        DifferentialBaseLSN numeric(25,0), DifferentialBaseGUID uniqueidentifier,
        IsReadOnly bit, IsPresent bit, TDEThumbprint varbinary(32), SnapshotURL nvarchar(360)
    );
    SET @Sql = N'RESTORE FILELISTONLY FROM DISK = N''' + REPLACE(@BackupFile, N'''', N'''''') + N''' WITH FILE = 1;';
    INSERT #SourceBackupFiles EXEC sys.sp_executesql @Sql;
    IF NOT EXISTS (SELECT 1 FROM #SourceBackupFiles)
     OR EXISTS (SELECT 1 FROM #SourceBackupFiles WHERE Type NOT IN ('D','L') OR IsPresent <> 1 OR Size <= 0)
        THROW 51857, 'Only present SQL data and log files are supported by this setup.', 1;

    DECLARE @DataDirectory nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
    DECLARE @LogDirectory nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));
    IF @DataDirectory IS NULL OR @LogDirectory IS NULL
     OR @DataDirectory NOT LIKE N'[A-Za-z]:\%' OR @LogDirectory NOT LIKE N'[A-Za-z]:\%'
        THROW 51858, 'Configure accessible local default SQL data and log directories first.', 1;
    IF RIGHT(@DataDirectory, 1) <> N'\' SET @DataDirectory += N'\';
    IF RIGHT(@LogDirectory, 1) <> N'\' SET @LogDirectory += N'\';

    CREATE TABLE #SourceRestoreTargets (LogicalName nvarchar(128), TargetPath nvarchar(4000), Bytes numeric(20,0));
    INSERT #SourceRestoreTargets
    SELECT LogicalName,
        CASE WHEN Type = 'D' THEN @DataDirectory ELSE @LogDirectory END
        + @SourceDatabase + N'_' + REPLACE(CONVERT(nvarchar(36), NEWID()), N'-', N'')
        + CASE WHEN Type = 'D' THEN N'.mdf' ELSE N'.ldf' END, Size
    FROM #SourceBackupFiles;
    IF EXISTS (SELECT 1 FROM #SourceRestoreTargets WHERE LEN(TargetPath) > 260)
        THROW 51858, 'A generated SQL data/log path exceeds 260 characters.', 1;

    CREATE TABLE #SourceDriveSpace (Drive char(1), MBFree bigint);
    INSERT #SourceDriveSpace EXEC master.dbo.xp_fixeddrives;
    IF EXISTS (
        SELECT 1 FROM (SELECT LEFT(TargetPath,1) AS Drive, SUM(Bytes) AS Bytes FROM #SourceRestoreTargets GROUP BY LEFT(TargetPath,1)) need
        LEFT JOIN #SourceDriveSpace free ON free.Drive = need.Drive
        WHERE free.Drive IS NULL OR CONVERT(decimal(28,0),free.MBFree)*1048576 <= need.Bytes + CONVERT(bigint,2147483648)
    ) THROW 51859, 'Insufficient free space: retain at least 2 GiB beyond restored files on each target drive.', 1;

    DECLARE @LogicalName nvarchar(128), @TargetPath nvarchar(4000), @Moves nvarchar(max) = N'';
    DECLARE SourceRestoreFiles CURSOR LOCAL FAST_FORWARD FOR
        SELECT LogicalName, TargetPath FROM #SourceRestoreTargets ORDER BY LogicalName;
    OPEN SourceRestoreFiles;
    FETCH NEXT FROM SourceRestoreFiles INTO @LogicalName, @TargetPath;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        TRUNCATE TABLE #SourceFileExists;
        INSERT #SourceFileExists EXEC master.dbo.xp_fileexist @TargetPath;
        IF EXISTS (SELECT 1 FROM #SourceFileExists WHERE FileExists = 1 OR IsDirectory = 1 OR ParentExists <> 1)
         OR EXISTS (SELECT 1 FROM sys.master_files WHERE physical_name = @TargetPath)
            THROW 51858, 'A restore destination exists or its parent is unavailable; no file will be overwritten.', 1;
        SET @Moves += N', MOVE N''' + REPLACE(@LogicalName, N'''', N'''''')
            + N''' TO N''' + REPLACE(@TargetPath, N'''', N'''''') + N'''';
        FETCH NEXT FROM SourceRestoreFiles INTO @LogicalName, @TargetPath;
    END;
    CLOSE SourceRestoreFiles;
    DEALLOCATE SourceRestoreFiles;

    IF @ValidateOnly = 1
    BEGIN
        EXEC @ReleaseResult = sys.sp_releaseapplock @Resource = @LockName, @LockOwner = 'Session';
        SELECT N'VALIDATED_ONLY' AS SetupStatus, @SourceDatabase AS SourceDatabase;
        SELECT LogicalName, CONVERT(nvarchar(260), TargetPath) AS TargetPath, Bytes FROM #SourceRestoreTargets;
        RETURN;
    END;
    -- Check again immediately before restore; restore never uses WITH REPLACE.
    IF DB_ID(@SourceDatabase) IS NOT NULL
        THROW 51853, 'The target source appeared during validation; setup stopped without overwriting it.', 1;
    SET @Sql = N'RESTORE DATABASE ' + QUOTENAME(@SourceDatabase)
        + N' FROM DISK = N''' + REPLACE(@BackupFile, N'''', N'''''')
        + N''' WITH FILE = 1, CHECKSUM, RECOVERY' + @Moves + N';';
    EXEC sys.sp_executesql @Sql;
    SET @Sql = N'EXEC ' + QUOTENAME(@SourceDatabase)
        + N'.sys.sp_addextendedproperty @name = N''CompanyXDemoOwner'', @value = @Owner;';
    EXEC sys.sp_executesql @Sql, N'@Owner nvarchar(100)', @Owner;
    EXEC @ReleaseResult = sys.sp_releaseapplock @Resource = @LockName, @LockOwner = 'Session';
    SELECT N'RESTORED' AS SetupStatus, @SourceDatabase AS SourceDatabase;
    SELECT LogicalName, CONVERT(nvarchar(260), TargetPath) AS TargetPath, Bytes FROM #SourceRestoreTargets;
END TRY
BEGIN CATCH
    EXEC @ReleaseResult = sys.sp_releaseapplock @Resource = @LockName, @LockOwner = 'Session';
    THROW;
END CATCH;

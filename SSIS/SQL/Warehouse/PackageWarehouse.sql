-- 90_DongGoi: cleanly detach ONLY this owned in-folder target after Python read-only preflight.
-- Master retained ADO.NET parameters: @PackageRoot,@SourceDatabase,@TargetDatabase,@PackageToken.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0 OR SERVERPROPERTY('InstanceName') IS NOT NULL
 OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS<>CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
 THROW 51870,'Packaging requires local default SQL Server 2022 and Master outside a transaction.',1;
IF @SourceDatabase IS NULL OR @TargetDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo')) COLLATE Latin1_General_100_BIN2<>N'InventorySafety_Demo'
 OR LEN(@SourceDatabase)>82 OR LEN(@TargetDatabase)>80
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 THROW 51870,'Only isolated demo databases may be packaged.',1;
DECLARE @pair nvarchar(255)=N'CompanyXDemo:'+@SourceDatabase+N':'+@TargetDatabase;
DECLARE @setup nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase;
IF ISNULL(APPLOCK_MODE(N'public',@pair,N'Session'),N'NoLock')<>N'Exclusive'
 OR ISNULL(APPLOCK_MODE(N'public',@setup,N'Session'),N'NoLock')<>N'Exclusive'
 THROW 51871,'The packaging session locks were not retained.',1;
SET @PackageRoot=REPLACE(@PackageRoot,N'/',N'\');
IF RIGHT(@PackageRoot,1)=N'\' SET @PackageRoot=LEFT(@PackageRoot,LEN(@PackageRoot)-1);
IF @PackageRoot IS NULL OR @PackageRoot NOT LIKE N'[A-Za-z]:\%' OR @PackageRoot LIKE N'%..%'
 OR @PackageToken IS NULL OR LEN(@PackageToken)<>32 OR @PackageToken COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Fa-f0-9]%'
 THROW 51870,'Invalid packaging root or token.',1;
DECLARE @mdf nvarchar(4000)=@PackageRoot+N'\Warehouse\'+@TargetDatabase+N'.mdf';
DECLARE @ldf nvarchar(4000)=@PackageRoot+N'\Warehouse\'+@TargetDatabase+N'_log.ldf';
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@TargetDatabase AND state_desc=N'ONLINE')
 OR (SELECT COUNT(*) FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase))<>2
 OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=0 AND physical_name=@mdf)
 OR NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(@TargetDatabase) AND type=1 AND physical_name=@ldf)
 THROW 51873,'Warehouse must be ONLINE with exactly the two expected files inside this demo.',1;
DECLARE @candidatePath nvarchar(4000)=@PackageRoot+N'\Warehouse\warehouse_candidate.json';
DECLARE @raw varbinary(max),@candidate nvarchar(max),@q nvarchar(max);
SET @q=N'SELECT @r=BulkColumn FROM OPENROWSET(BULK N'''+REPLACE(@candidatePath,N'''',N'''''')+N''',SINGLE_BLOB)f;';
EXEC sys.sp_executesql @q,N'@r varbinary(max) OUTPUT',@r=@raw OUTPUT;
SET @candidate=CONVERT(nvarchar(max),CONVERT(varchar(max),@raw) COLLATE Latin1_General_100_BIN2_UTF8);
IF ISJSON(@candidate)<>1 OR ISNULL(JSON_VALUE(@candidate,'$.format'),N'')<>N'companyx.warehouse.bundle.v1'
 OR ISNULL(JSON_VALUE(@candidate,'$.state'),N'')<>N'PREPARED' OR ISNULL(JSON_VALUE(@candidate,'$.token'),N'')<>@PackageToken
 OR ISNULL(JSON_VALUE(@candidate,'$.target_database'),N'')<>@TargetDatabase OR ISNULL(JSON_VALUE(@candidate,'$.source_database'),N'')<>@SourceDatabase
 OR ISNULL(JSON_VALUE(@candidate,'$.owner_marker'),N'')<>N'CompanyX_Demo_20261103'
 OR COALESCE(TRY_CONVERT(int,ISNULL(JSON_VALUE(@candidate,'$.identity.database_id'),N'')),-1)<>DB_ID(@TargetDatabase)
 OR ISNULL(JSON_VALUE(@candidate,'$.identity.create_date'),N'')<>(SELECT CONVERT(nvarchar(33),create_date,126) FROM sys.databases WHERE name=@TargetDatabase)
 THROW 51874,'Warehouse preflight candidate is missing, stale or for another database.',1;
-- Acquire the same target-scoped locks used by ETL and result publication.
-- Release target locks before detach; retained Master pair/setup locks continue blocking normal workflows.
SET @q=N'USE '+QUOTENAME(@TargetDatabase)+N';
DECLARE @r int;
EXEC @r=sys.sp_getapplock @Resource=N''DSS_RESULT'',@LockMode=''Exclusive'',@LockOwner=''Session'',@LockTimeout=0;
IF @r<0 THROW 51871,''Publication is active.'',1;
EXEC @r=sys.sp_getapplock @Resource=N''InventorySafety_FullLoad'',@LockMode=''Exclusive'',@LockOwner=''Session'',@LockTimeout=0;
IF @r<0 THROW 51871,''ETL is active.'',1;
EXEC @r=sys.sp_getapplock @Resource=N''CompanyX_SSIS_NATIVE_IO'',@LockMode=''Exclusive'',@LockOwner=''Session'',@LockTimeout=0;
IF @r<0 THROW 51871,''Native publication is active.'',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXSSISDeployment'' AND CONVERT(nvarchar(100),value)=N''SSIS_20261029'')
 OR (SELECT COUNT(*) FROM etl_v2.State)<>1
 OR (SELECT COUNT(*) FROM etl_v2.State WHERE SourceDatabase=@source)<>1
 THROW 51873,''Warehouse ownership/deployment/source binding differs.'',1;
IF EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE Status=''RUNNING'')
 OR EXISTS(SELECT 1 FROM dss.Dim_PlanningRun WHERE RunStatus IN (''RUNNING'',''PENDING'',''STARTING''))
 THROW 51871,''A warehouse batch or DSS run is not idle.'',1;
IF (SELECT COUNT_BIG(*) FROM dss.Dim_PlanningRun)<>COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@candidate,''$.runs.run_count'')),-1)
 OR (SELECT COALESCE(MAX(PlanningRunKey),0) FROM dss.Dim_PlanningRun)<>COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@candidate,''$.runs.last_run_key'')),-1)
 OR (SELECT COUNT_BIG(*) FROM etl.ETL_LoadBatch)<>COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@candidate,''$.batches.batch_count'')),-1)
 OR (SELECT COALESCE(MAX(LoadBatchID),0) FROM etl.ETL_LoadBatch)<>COALESCE(TRY_CONVERT(bigint,JSON_VALUE(@candidate,''$.batches.last_batch_id'')),-1)
 THROW 51874,''Warehouse metadata changed after packaging preflight.'',1;
EXEC sys.sp_releaseapplock @Resource=N''CompanyX_SSIS_NATIVE_IO'',@LockOwner=''Session'';
EXEC sys.sp_releaseapplock @Resource=N''InventorySafety_FullLoad'',@LockOwner=''Session'';
EXEC sys.sp_releaseapplock @Resource=N''DSS_RESULT'',@LockOwner=''Session'';';
EXEC sys.sp_executesql @q,N'@source sysname,@candidate nvarchar(max)',@SourceDatabase,@candidate;
IF EXISTS(SELECT 1 FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id=s.session_id
 WHERE s.is_user_process=1 AND s.session_id<>@@SPID AND (s.database_id=DB_ID(@TargetDatabase) OR r.database_id=DB_ID(@TargetDatabase)))
 OR EXISTS(SELECT 1 FROM sys.dm_tran_database_transactions d JOIN sys.dm_tran_session_transactions s ON s.transaction_id=d.transaction_id
 WHERE d.database_id=DB_ID(@TargetDatabase) AND s.is_user_transaction=1)
 THROW 51871,'Another connection or user transaction prevents clean detach.',1;
-- sp_detach_db refuses an in-use database. Never force SINGLE_USER, KILL or rollback others.
EXEC master.dbo.sp_detach_db @dbname=@TargetDatabase,@skipchecks=N'true',@keepfulltextindexfile=N'true';
IF DB_ID(@TargetDatabase) IS NOT NULL THROW 51875,'Warehouse remains attached; do not copy its live files.',1;

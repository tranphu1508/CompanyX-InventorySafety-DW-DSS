-- 90_DongGoi: Master retained ADO.NET connection; session locks only.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @@TRANCOUNT<>0
 OR SERVERPROPERTY('InstanceName') IS NOT NULL
 OR CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>16
 OR ISNULL(HOST_NAME(),N'') COLLATE Latin1_General_100_CI_AS<>CONVERT(nvarchar(128),SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
 THROW 51870,'Packaging requires local default SQL Server 2022, Master, and no user transaction.',1;
IF @SourceDatabase IS NULL OR @TargetDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo')) COLLATE Latin1_General_100_BIN2<>N'InventorySafety_Demo'
 OR LEN(@SourceDatabase)>82 OR LEN(@TargetDatabase)>80
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 THROW 51870,'Only isolated demo database names may be packaged.',1;
DECLARE @r int,@pair nvarchar(255)=N'CompanyXDemo:'+@SourceDatabase+N':'+@TargetDatabase;
DECLARE @setup nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase;
EXEC @r=sys.sp_getapplock @Resource=@pair,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
IF @r<0 THROW 51871,'ETL, simulation or publication is using this database pair.',1;
EXEC @r=sys.sp_getapplock @Resource=@setup,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
IF @r<0 THROW 51871,'Warehouse setup or packaging is already active.',1;
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@TargetDatabase AND state_desc=N'ONLINE')
 THROW 51872,'Warehouse must be ONLINE; use 10_KhoiTao to attach a previously packaged warehouse.',1;
IF EXISTS(SELECT 1 FROM sys.dm_exec_sessions s LEFT JOIN sys.dm_exec_requests r ON r.session_id=s.session_id
 WHERE s.is_user_process=1 AND s.session_id<>@@SPID AND (s.database_id=DB_ID(@TargetDatabase) OR r.database_id=DB_ID(@TargetDatabase)))
 THROW 51871,'Another session is using the warehouse; close it normally before packaging.',1;
SELECT REPLACE(CONVERT(nvarchar(36),NEWID()),N'-',N'') AS PackageToken;

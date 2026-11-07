-- SSIS Execute SQL Task, ADO.NET Master connection.
-- Input parameter: @SourceDatabase (NVARCHAR). ResultSet: None.
-- This checks a source restored once during setup; it never restores or changes it.
SET NOCOUNT ON;
IF DB_NAME() <> N'master'
    THROW 51850, 'Run the source prerequisite check through the Master connection.', 1;
IF SERVERPROPERTY('InstanceName') IS NOT NULL
    THROW 51850, 'The demo supports the local default SQL Server instance.', 1;
IF ISNULL(HOST_NAME(), N'') COLLATE Latin1_General_100_CI_AS
    <> CONVERT(nvarchar(128), SERVERPROPERTY('MachineName')) COLLATE Latin1_General_100_CI_AS
    THROW 51850, 'Run demo setup from the SQL Server Windows machine.', 1;
IF @SourceDatabase IS NULL
 OR LEN(@SourceDatabase) < LEN(N'CompanyX_Demo')
 OR LEN(@SourceDatabase) > LEN(N'CompanyX_Demo') + 70
 OR LEFT(@SourceDatabase, LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2 <> N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51850, 'Only isolated CompanyX_Demo source names are allowed.', 1;
IF DB_ID(@SourceDatabase) IS NULL
    THROW 51851, 'Restore the demo source once using Database/Setup/Restore_Source_Once.sql before running SSIS.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = @SourceDatabase AND state_desc = N'ONLINE')
    THROW 51852, 'The restored demo source is not ONLINE.', 1;
DECLARE @SourceOwnerQuery nvarchar(max) = N'USE ' + QUOTENAME(@SourceDatabase) + N';
IF NOT EXISTS (SELECT 1 FROM sys.extended_properties
 WHERE class = 0 AND name = N''CompanyXDemoOwner''
 AND CONVERT(nvarchar(100), value) = N''CompanyX_Demo_20261103'')
 THROW 51853, ''The existing source is not owned by this demo; it will not be overwritten.'', 1;';
EXEC sys.sp_executesql @SourceOwnerQuery;

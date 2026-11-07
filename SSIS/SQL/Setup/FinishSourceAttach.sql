-- Final prerequisite check for either the existing-source or newly attached branch.
SET NOCOUNT ON;
IF DB_NAME()<>N'master' OR @SourceDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo')) COLLATE Latin1_General_100_BIN2<>N'CompanyX_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
    THROW 51850, 'Invalid source prerequisite context.', 1;
IF NOT EXISTS(SELECT 1 FROM sys.databases WHERE name=@SourceDatabase AND state_desc=N'ONLINE')
    THROW 51852, 'The source is not ONLINE.', 1;
DECLARE @Query nvarchar(max)=N'USE '+QUOTENAME(@SourceDatabase)+N';
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner''
 AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'')
 THROW 51853, ''The source does not belong to this demo.'', 1;';
EXEC sys.sp_executesql @Query;
DECLARE @Resource nvarchar(255)=N'CompanyXDemo:SourceAttach:'+@SourceDatabase;
DECLARE @Result int;
EXEC @Result=sys.sp_releaseapplock @Resource=@Resource,@LockOwner='Session';
IF @Result<0 THROW 51854, 'Could not release the source setup lock.', 1;

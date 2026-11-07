IF @SourceDatabase IS NULL OR @TargetDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo'))<>N'CompanyX_Demo'
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo'))<>N'InventorySafety_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase=@TargetDatabase
 THROW 51810,'Only isolated CompanyX_Demo / InventorySafety_Demo databases are allowed.',1;
DECLARE @r int,@resource nvarchar(255)=N'CompanyXDemo:'+@SourceDatabase+N':'+@TargetDatabase;
EXEC @r=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0;
IF @r<0 THROW 51813,'Another menu or SSIS task is using this pair of databases.',1;
IF DB_ID(@SourceDatabase) IS NULL THROW 51811,'Restore the demo source first.',1;
DECLARE @q nvarchar(max)=N'USE '+QUOTENAME(@SourceDatabase)+N'; IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'') THROW 51812,''Source is not owned by this demo package.'',1;';
EXEC sys.sp_executesql @q;

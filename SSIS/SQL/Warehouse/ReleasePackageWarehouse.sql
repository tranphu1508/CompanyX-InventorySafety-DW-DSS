-- Successful packaging only; failures release locks when the retained connection closes.
SET NOCOUNT ON;
DECLARE @r int,@pair nvarchar(255)=N'CompanyXDemo:'+@SourceDatabase+N':'+@TargetDatabase;
DECLARE @setup nvarchar(255)=N'CompanyXDemo:WarehouseSetup:'+@TargetDatabase;
EXEC @r=sys.sp_releaseapplock @Resource=@setup,@LockOwner='Session';
IF @r<0 THROW 51871,'Could not release warehouse setup lock.',1;
EXEC @r=sys.sp_releaseapplock @Resource=@pair,@LockOwner='Session';
IF @r<0 THROW 51871,'Could not release demo pair lock.',1;

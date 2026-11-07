SET NOCOUNT ON;
IF DB_NAME()<>N'CompanyX_DW_ACT_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)=N'companyx-split-20261107') THROW 51000,'Wrong isolated ACT database.',1;
IF SCHEMA_ID(N'act_export') IS NULL THROW 51000,'Build ACT input views first.',1;
GRANT SELECT ON SCHEMA::act_export TO [CompanyXMOLAPReader];

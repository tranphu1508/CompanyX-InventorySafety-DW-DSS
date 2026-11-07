IF DB_NAME()<>N'CompanyX_DW_ACT_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)=N'companyx-split-20261107')
 THROW 51814,'Only the isolated demo warehouse is allowed.',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXDemoOwner' AND CONVERT(nvarchar(100),value)=N'CompanyX_Demo_20261103')
 THROW 51815,'Warehouse is not owned by this demo package. Run initialization first.',1;
IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@SourceDatabase)
 THROW 51816,'Source binding does not match the warehouse.',1;

IF @SourceDatabase IS NULL OR @TargetDatabase IS NULL
 OR LEFT(@SourceDatabase,LEN(N'CompanyX_Demo'))<>N'CompanyX_Demo'
 OR LEFT(@TargetDatabase,LEN(N'InventorySafety_Demo'))<>N'InventorySafety_Demo'
 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @TargetDatabase COLLATE Latin1_General_100_BIN2 LIKE N'%[^A-Za-z0-9_]%'
 OR @SourceDatabase=@TargetDatabase
 THROW 51810,'Only isolated CompanyX_Demo / InventorySafety_Demo databases are allowed.',1;
IF DB_ID(@SourceDatabase) IS NULL THROW 51811,'Restore the demo source first.',1;
DECLARE @q nvarchar(max)=N'USE '+QUOTENAME(@SourceDatabase)+N'; IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N''CompanyXDemoOwner'' AND CONVERT(nvarchar(100),value)=N''CompanyX_Demo_20261103'') THROW 51812,''Source is not owned by this demo package.'',1;';
EXEC sys.sp_executesql @q;

DECLARE @ct nvarchar(max)=N'USE [__SOURCE_DB__];
ALTER DATABASE [__SOURCE_DB__] SET ALLOW_SNAPSHOT_ISOLATION ON;
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_databases WHERE database_id=DB_ID()) ALTER DATABASE [__SOURCE_DB__] SET CHANGE_TRACKING=ON (CHANGE_RETENTION=7 DAYS,AUTO_CLEANUP=ON);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.BillOfMaterials'')) ALTER TABLE Production.BillOfMaterials ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.Location'')) ALTER TABLE Production.Location ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.Product'')) ALTER TABLE Production.Product ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ProductCategory'')) ALTER TABLE Production.ProductCategory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ProductCostHistory'')) ALTER TABLE Production.ProductCostHistory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ProductInventory'')) ALTER TABLE Production.ProductInventory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ProductListPriceHistory'')) ALTER TABLE Production.ProductListPriceHistory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ProductSubcategory'')) ALTER TABLE Production.ProductSubcategory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.ScrapReason'')) ALTER TABLE Production.ScrapReason ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.TransactionHistory'')) ALTER TABLE Production.TransactionHistory ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.TransactionHistoryArchive'')) ALTER TABLE Production.TransactionHistoryArchive ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.UnitMeasure'')) ALTER TABLE Production.UnitMeasure ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.WorkOrder'')) ALTER TABLE Production.WorkOrder ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Production.WorkOrderRouting'')) ALTER TABLE Production.WorkOrderRouting ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Purchasing.ProductVendor'')) ALTER TABLE Purchasing.ProductVendor ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Purchasing.PurchaseOrderDetail'')) ALTER TABLE Purchasing.PurchaseOrderDetail ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Purchasing.PurchaseOrderHeader'')) ALTER TABLE Purchasing.PurchaseOrderHeader ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Purchasing.Vendor'')) ALTER TABLE Purchasing.Vendor ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Sales.Customer'')) ALTER TABLE Sales.Customer ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Sales.SalesOrderDetail'')) ALTER TABLE Sales.SalesOrderDetail ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Sales.SalesOrderHeader'')) ALTER TABLE Sales.SalesOrderHeader ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Sales.SpecialOffer'')) ALTER TABLE Sales.SpecialOffer ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);
IF NOT EXISTS(SELECT 1 FROM sys.change_tracking_tables WHERE object_id=OBJECT_ID(N''Sales.SpecialOfferProduct'')) ALTER TABLE Sales.SpecialOfferProduct ENABLE CHANGE_TRACKING WITH(TRACK_COLUMNS_UPDATED=OFF);';
SET @ct=REPLACE(@ct,N'__SOURCE_DB__',@SourceDatabase); EXEC sys.sp_executesql @ct;

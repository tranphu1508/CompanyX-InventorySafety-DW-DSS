IF DB_NAME() IN (N'InventorySafety',N'CompanyX',N'master',N'model',N'msdb',N'tempdb') THROW 51700,'Protected database',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE name=N'CompanyXSSISDeployment' AND CONVERT(nvarchar(100),value)=N'SSIS_20261029') THROW 51701,'Target is not this package deployment',1;
IF @SourceDatabase IS NULL OR LEN(@SourceDatabase)>100 OR @SourceDatabase COLLATE Latin1_General_100_BIN2 LIKE '%[^A-Za-z0-9_]%' OR DB_ID(@SourceDatabase) IS NULL OR @SourceDatabase=DB_NAME() THROW 51702,'Invalid source',1;
DECLARE @Install nvarchar(max)=N'SET NOCOUNT ON; SET XACT_ABORT ON;
IF SCHEMA_ID(''etl_v2'') IS NULL EXEC(''CREATE SCHEMA etl_v2'');
IF SCHEMA_ID(''etl_raw'') IS NULL EXEC(''CREATE SCHEMA etl_raw'');
IF SCHEMA_ID(''etl_calc'') IS NULL EXEC(''CREATE SCHEMA etl_calc'');
IF SCHEMA_ID(''etl_effective'') IS NULL EXEC(''CREATE SCHEMA etl_effective'');

IF OBJECT_ID(''etl_v2.State'') IS NULL CREATE TABLE etl_v2.State(Id int PRIMARY KEY CHECK(Id=1),SourceDatabase sysname NOT NULL,LastVersion bigint NULL,LastBatchID bigint NULL,RuleVersion nvarchar(50) NOT NULL);
IF NOT EXISTS(SELECT 1 FROM etl_v2.State) INSERT etl_v2.State VALUES(1,N''__SOURCE_DB__'',NULL,NULL,N''SAL-BACKFILL-v2'');
IF OBJECT_ID(''etl_v2.SourceChange'') IS NULL CREATE TABLE etl_v2.SourceChange(BatchID bigint NOT NULL,SourceTable sysname NOT NULL,Operation char(1) NOT NULL,ChangeVersion bigint NULL,KeyJson nvarchar(1500) NOT NULL,BeforeJson nvarchar(max) NULL);
IF OBJECT_ID(''etl_v2.TargetChange'') IS NULL CREATE TABLE etl_v2.TargetChange(ChangeID bigint IDENTITY PRIMARY KEY,BatchID bigint NOT NULL,TableName sysname NOT NULL,Operation char(1) NOT NULL,KeyJson nvarchar(1500) NOT NULL,BeforeJson nvarchar(max) NULL,AfterJson nvarchar(max) NULL);
IF OBJECT_ID(''etl_v2.SalesEvidence'') IS NULL CREATE TABLE etl_v2.SalesEvidence(BatchID bigint NOT NULL,SalesOrderDetailID int NOT NULL,FieldName sysname NOT NULL,OriginalValue decimal(28,8) NULL,EffectiveValue decimal(28,8) NULL,CandidateCount int NOT NULL,DistinctValueCount int NOT NULL,Resolution nvarchar(50) NOT NULL,EvidenceJson nvarchar(max) NULL,PRIMARY KEY(BatchID,SalesOrderDetailID,FieldName));
IF OBJECT_ID(''etl_v2.BatchState'') IS NULL CREATE TABLE etl_v2.BatchState(BatchID bigint PRIMARY KEY,PreviousVersion bigint NULL,CapturedVersion bigint NULL,CapturedAt datetime2 NOT NULL,SourceChangeCount bigint NULL,TargetChangeCount bigint NULL,Status nvarchar(30) NOT NULL,ErrorMessage nvarchar(max) NULL);
IF OBJECT_ID(''etl_v2.Validation'') IS NULL CREATE TABLE etl_v2.Validation(BatchID bigint NOT NULL,CheckName nvarchar(200) NOT NULL,Expected decimal(38,6) NOT NULL,Actual decimal(38,6) NOT NULL,PRIMARY KEY(BatchID,CheckName));
IF OBJECT_ID(N''etl_raw.[BillOfMaterials]'',''U'') IS NULL CREATE TABLE etl_raw.[BillOfMaterials] ([BillOfMaterialsID] int NOT NULL,[ProductAssemblyID] int NULL,[ComponentID] int NOT NULL,[StartDate] datetime NOT NULL,[EndDate] datetime NULL,[UnitMeasureCode] nchar(3) NOT NULL,[BOMLevel] smallint NOT NULL,[PerAssemblyQty] decimal(8,2) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([BillOfMaterialsID]));
IF OBJECT_ID(N''etl_raw.[Location]'',''U'') IS NULL CREATE TABLE etl_raw.[Location] ([LocationID] smallint NOT NULL,[Name] nvarchar(50) NOT NULL,[CostRate] smallmoney NOT NULL,[Availability] decimal(8,2) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([LocationID]));
IF OBJECT_ID(N''etl_raw.[Product]'',''U'') IS NULL CREATE TABLE etl_raw.[Product] ([ProductID] int NOT NULL,[Name] nvarchar(50) NOT NULL,[ProductNumber] nvarchar(25) NOT NULL,[MakeFlag] bit NOT NULL,[FinishedGoodsFlag] bit NOT NULL,[Color] nvarchar(15) NULL,[SafetyStockLevel] smallint NOT NULL,[ReorderPoint] smallint NOT NULL,[StandardCost] money NOT NULL,[ListPrice] money NOT NULL,[Size] nvarchar(5) NULL,[SizeUnitMeasureCode] nchar(3) NULL,[WeightUnitMeasureCode] nchar(3) NULL,[Weight] decimal(8,2) NULL,[DaysToManufacture] int NOT NULL,[ProductLine] nchar(2) NULL,[Class] nchar(2) NULL,[Style] nchar(2) NULL,[ProductSubcategoryID] int NULL,[ProductModelID] int NULL,[SellStartDate] datetime NOT NULL,[SellEndDate] datetime NULL,[DiscontinuedDate] datetime NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductID]));
IF OBJECT_ID(N''etl_raw.[ProductCategory]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductCategory] ([ProductCategoryID] int NOT NULL,[Name] nvarchar(50) NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductCategoryID]));
IF OBJECT_ID(N''etl_raw.[ProductCostHistory]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductCostHistory] ([ProductID] int NOT NULL,[StartDate] datetime NOT NULL,[EndDate] datetime NULL,[StandardCost] money NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductID],[StartDate]));
IF OBJECT_ID(N''etl_raw.[ProductInventory]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductInventory] ([ProductID] int NOT NULL,[LocationID] smallint NOT NULL,[Shelf] nvarchar(10) NOT NULL,[Bin] tinyint NOT NULL,[Quantity] smallint NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductID],[LocationID]));
IF OBJECT_ID(N''etl_raw.[ProductListPriceHistory]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductListPriceHistory] ([ProductID] int NOT NULL,[StartDate] datetime NOT NULL,[EndDate] datetime NULL,[ListPrice] money NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductID],[StartDate]));
IF OBJECT_ID(N''etl_raw.[ProductSubcategory]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductSubcategory] ([ProductSubcategoryID] int NOT NULL,[ProductCategoryID] int NOT NULL,[Name] nvarchar(50) NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductSubcategoryID]));
IF OBJECT_ID(N''etl_raw.[ScrapReason]'',''U'') IS NULL CREATE TABLE etl_raw.[ScrapReason] ([ScrapReasonID] smallint NOT NULL,[Name] nvarchar(50) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ScrapReasonID]));
IF OBJECT_ID(N''etl_raw.[TransactionHistory]'',''U'') IS NULL CREATE TABLE etl_raw.[TransactionHistory] ([TransactionID] int NOT NULL,[ProductID] int NOT NULL,[ReferenceOrderID] int NOT NULL,[ReferenceOrderLineID] int NOT NULL,[TransactionDate] datetime NOT NULL,[TransactionType] nchar(1) NOT NULL,[Quantity] int NULL,[ActualCost] money NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([TransactionID]));
IF OBJECT_ID(N''etl_raw.[TransactionHistoryArchive]'',''U'') IS NULL CREATE TABLE etl_raw.[TransactionHistoryArchive] ([TransactionID] int NOT NULL,[ProductID] int NOT NULL,[ReferenceOrderID] int NOT NULL,[ReferenceOrderLineID] int NOT NULL,[TransactionDate] datetime NOT NULL,[TransactionType] nchar(1) NOT NULL,[Quantity] int NOT NULL,[ActualCost] money NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([TransactionID]));
IF OBJECT_ID(N''etl_raw.[UnitMeasure]'',''U'') IS NULL CREATE TABLE etl_raw.[UnitMeasure] ([UnitMeasureCode] nchar(3) NOT NULL,[Name] nvarchar(50) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([UnitMeasureCode]));
IF OBJECT_ID(N''etl_raw.[WorkOrder]'',''U'') IS NULL CREATE TABLE etl_raw.[WorkOrder] ([WorkOrderID] int NOT NULL,[ProductID] int NOT NULL,[OrderQty] int NOT NULL,[StockedQty] int NOT NULL,[ScrappedQty] smallint NOT NULL,[StartDate] datetime NOT NULL,[EndDate] datetime NULL,[DueDate] datetime NOT NULL,[ScrapReasonID] smallint NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([WorkOrderID]));
IF OBJECT_ID(N''etl_raw.[WorkOrderRouting]'',''U'') IS NULL CREATE TABLE etl_raw.[WorkOrderRouting] ([WorkOrderID] int NOT NULL,[ProductID] int NOT NULL,[OperationSequence] smallint NOT NULL,[LocationID] smallint NOT NULL,[ScheduledStartDate] datetime NOT NULL,[ScheduledEndDate] datetime NOT NULL,[ActualStartDate] datetime NULL,[ActualEndDate] datetime NULL,[ActualResourceHrs] decimal(9,4) NULL,[PlannedCost] money NOT NULL,[ActualCost] money NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([WorkOrderID],[ProductID],[OperationSequence]));
IF OBJECT_ID(N''etl_raw.[ProductVendor]'',''U'') IS NULL CREATE TABLE etl_raw.[ProductVendor] ([ProductID] int NOT NULL,[BusinessEntityID] int NOT NULL,[AverageLeadTime] int NOT NULL,[StandardPrice] money NOT NULL,[LastReceiptCost] money NULL,[LastReceiptDate] datetime NULL,[MinOrderQty] int NOT NULL,[MaxOrderQty] int NOT NULL,[OnOrderQty] int NULL,[UnitMeasureCode] nchar(3) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([ProductID],[BusinessEntityID]));
IF OBJECT_ID(N''etl_raw.[PurchaseOrderDetail]'',''U'') IS NULL CREATE TABLE etl_raw.[PurchaseOrderDetail] ([PurchaseOrderID] int NOT NULL,[PurchaseOrderDetailID] int NOT NULL,[DueDate] datetime NOT NULL,[OrderQty] smallint NOT NULL,[ProductID] int NOT NULL,[UnitPrice] money NOT NULL,[LineTotal] money NOT NULL,[ReceivedQty] decimal(8,2) NOT NULL,[RejectedQty] decimal(8,2) NOT NULL,[StockedQty] decimal(9,2) NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([PurchaseOrderID],[PurchaseOrderDetailID]));
IF OBJECT_ID(N''etl_raw.[PurchaseOrderHeader]'',''U'') IS NULL CREATE TABLE etl_raw.[PurchaseOrderHeader] ([PurchaseOrderID] int NOT NULL,[RevisionNumber] tinyint NOT NULL,[Status] tinyint NOT NULL,[EmployeeID] int NOT NULL,[VendorID] int NOT NULL,[ShipMethodID] int NOT NULL,[OrderDate] datetime NOT NULL,[ShipDate] datetime NULL,[SubTotal] money NOT NULL,[TaxAmt] money NOT NULL,[Freight] money NOT NULL,[TotalDue] money NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([PurchaseOrderID]));
IF OBJECT_ID(N''etl_raw.[Vendor]'',''U'') IS NULL CREATE TABLE etl_raw.[Vendor] ([BusinessEntityID] int NOT NULL,[AccountNumber] nvarchar(15) NOT NULL,[Name] nvarchar(50) NOT NULL,[CreditRating] tinyint NOT NULL,[PreferredVendorStatus] bit NOT NULL,[ActiveFlag] bit NOT NULL,[PurchasingWebServiceURL] nvarchar(1024) NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([BusinessEntityID]));
IF OBJECT_ID(N''etl_raw.[Customer]'',''U'') IS NULL CREATE TABLE etl_raw.[Customer] ([CustomerID] int NOT NULL,[PersonID] int NULL,[StoreID] int NULL,[TerritoryID] int NULL,[AccountNumber] varchar(10) NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([CustomerID]));
IF OBJECT_ID(N''etl_raw.[SalesOrderDetail]'',''U'') IS NULL CREATE TABLE etl_raw.[SalesOrderDetail] ([SalesOrderID] int NOT NULL,[SalesOrderDetailID] int NOT NULL,[CarrierTrackingNumber] nvarchar(25) NULL,[OrderQty] smallint NULL,[ProductID] int NOT NULL,[SpecialOfferID] int NOT NULL,[UnitPrice] money NULL,[UnitPriceDiscount] money NOT NULL,[LineTotal] numeric(38,6) NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([SalesOrderID],[SalesOrderDetailID]));
IF OBJECT_ID(N''etl_raw.[SalesOrderHeader]'',''U'') IS NULL CREATE TABLE etl_raw.[SalesOrderHeader] ([SalesOrderID] int NOT NULL,[RevisionNumber] tinyint NOT NULL,[OrderDate] datetime NOT NULL,[DueDate] datetime NOT NULL,[ShipDate] datetime NULL,[Status] tinyint NOT NULL,[OnlineOrderFlag] bit NOT NULL,[SalesOrderNumber] nvarchar(25) NOT NULL,[PurchaseOrderNumber] nvarchar(25) NULL,[AccountNumber] nvarchar(15) NULL,[CustomerID] int NOT NULL,[SalesPersonID] int NULL,[TerritoryID] int NULL,[BillToAddressID] int NOT NULL,[ShipToAddressID] int NOT NULL,[ShipMethodID] int NOT NULL,[CreditCardID] int NULL,[CreditCardApprovalCode] varchar(15) NULL,[CurrencyRateID] int NULL,[SubTotal] money NOT NULL,[TaxAmt] money NOT NULL,[Freight] money NOT NULL,[TotalDue] money NOT NULL,[Comment] nvarchar(128) NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([SalesOrderID]));
IF OBJECT_ID(N''etl_raw.[SpecialOffer]'',''U'') IS NULL CREATE TABLE etl_raw.[SpecialOffer] ([SpecialOfferID] int NOT NULL,[Description] nvarchar(255) NOT NULL,[DiscountPct] smallmoney NOT NULL,[Type] nvarchar(50) NOT NULL,[Category] nvarchar(50) NOT NULL,[StartDate] datetime NOT NULL,[EndDate] datetime NOT NULL,[MinQty] int NOT NULL,[MaxQty] int NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([SpecialOfferID]));
IF OBJECT_ID(N''etl_raw.[SpecialOfferProduct]'',''U'') IS NULL CREATE TABLE etl_raw.[SpecialOfferProduct] ([SpecialOfferID] int NOT NULL,[ProductID] int NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([SpecialOfferID],[ProductID]));
IF OBJECT_ID(N''etl_calc.[Bridge_BillOfMaterials]'',''U'') IS NULL CREATE TABLE etl_calc.[Bridge_BillOfMaterials] ([BOMKey] int IDENTITY(1,1) NOT NULL,[BillOfMaterialsID] int NOT NULL,[AssemblyProductKey] int NOT NULL,[ComponentProductKey] int NOT NULL,[UnitMeasureKey] int NOT NULL,[BOMLevel] int NULL,[PerAssemblyQty] decimal(8,2) NULL,[StartDate] date NULL,[EndDate] date NULL,[IsStructureValid] bit NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([BOMKey]));
IF OBJECT_ID(N''etl_calc.[Bridge_ProductPromotion]'',''U'') IS NULL CREATE TABLE etl_calc.[Bridge_ProductPromotion] ([ProductKey] int NOT NULL,[PromotionKey] int NOT NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ProductKey],[PromotionKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Channel]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Channel] ([ChannelKey] int NOT NULL,[OnlineOrderFlag] bit NULL,[ChannelName] nvarchar(40) NULL,PRIMARY KEY([ChannelKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Customer]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Customer] ([CustomerKey] int IDENTITY(1,1) NOT NULL,[CustomerID] int NULL,[PersonID] int NULL,[StoreID] int NULL,[CustomerType] nvarchar(30) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([CustomerKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Date]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Date] ([DateKey] int NOT NULL,[CalendarDate] date NULL,[CalendarYear] int NULL,[CalendarQuarter] int NULL,[CalendarMonth] int NULL,[DayOfMonth] int NULL,[DayOfWeek] int NULL,[IsWeekend] bit NULL,[ISOWeek] int NULL,[ISOYear] int NULL,[WeekStartDate] date NULL,[MonthStartDate] date NULL,PRIMARY KEY([DateKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Location]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Location] ([LocationKey] int IDENTITY(1,1) NOT NULL,[LocationID] int NULL,[LocationName] nvarchar(100) NULL,[CostRate] decimal(10,4) NULL,[Availability] decimal(8,2) NULL,[LocationType] nvarchar(20) NULL,[HasProductionConflict] bit NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([LocationKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Product]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Product] ([ProductKey] int IDENTITY(1,1) NOT NULL,[ProductID] int NULL,[ProductNumber] nvarchar(25) NULL,[ProductName] nvarchar(100) NULL,[ProductSubcategoryID] int NULL,[SubcategoryName] nvarchar(100) NULL,[ProductCategoryID] int NULL,[CategoryName] nvarchar(100) NULL,[ProductModelID] int NULL,[MakeFlag] bit NULL,[FinishedGoodsFlag] bit NULL,[SupplyType] nvarchar(10) NULL,[ProductRole] nvarchar(30) NULL,[IsBOMAssembly] bit NULL,[IsBOMComponent] bit NULL,[Color] nvarchar(15) NULL,[Size] nvarchar(5) NULL,[SizeUnitName] nvarchar(50) NULL,[Weight] decimal(8,2) NULL,[WeightUnitName] nvarchar(50) NULL,[ProductLine] nchar(2) NULL,[ProductLineName] nvarchar(20) NULL,[Class] nchar(2) NULL,[ClassName] nvarchar(20) NULL,[Style] nchar(2) NULL,[StyleName] nvarchar(20) NULL,[DaysToManufacture] int NULL,[SafetyStockLevel] int NULL,[ReorderPoint] int NULL,[StandardCost] decimal(19,4) NULL,[ListPrice] decimal(19,4) NULL,[SellStartDate] date NULL,[SellEndDate] date NULL,[DiscontinuedDate] date NULL,[DQStatus] nvarchar(20) NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ProductKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Promotion]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Promotion] ([PromotionKey] int IDENTITY(1,1) NOT NULL,[SpecialOfferID] int NULL,[Description] nvarchar(255) NULL,[OfferType] nvarchar(100) NULL,[OfferCategory] nvarchar(100) NULL,[DiscountPct] decimal(9,6) NULL,[StartDate] datetime2(7) NULL,[EndDate] datetime2(7) NULL,[MinQty] int NULL,[MaxQty] int NULL,[IsNoDiscount] bit NULL,[IsScheduleValid] bit NULL,[IsDiscountValid] bit NULL,[IsQtyRangeValid] bit NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([PromotionKey]));
IF OBJECT_ID(N''etl_calc.[Dim_PurchaseStatus]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_PurchaseStatus] ([PurchaseStatusKey] int NOT NULL,[StatusCode] int NULL,[StatusName] nvarchar(40) NULL,[IsDocumented] bit NULL,PRIMARY KEY([PurchaseStatusKey]));
IF OBJECT_ID(N''etl_calc.[Dim_SalesStatus]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_SalesStatus] ([SalesStatusKey] int NOT NULL,[StatusCode] int NULL,[StatusName] nvarchar(40) NULL,[IsDocumented] bit NULL,[IsDemandEligible] bit NULL,PRIMARY KEY([SalesStatusKey]));
IF OBJECT_ID(N''etl_calc.[Dim_ScrapReason]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_ScrapReason] ([ScrapReasonKey] int IDENTITY(1,1) NOT NULL,[ScrapReasonID] int NULL,[ScrapReasonName] nvarchar(100) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ScrapReasonKey]));
IF OBJECT_ID(N''etl_calc.[Dim_UnitMeasure]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_UnitMeasure] ([UnitMeasureKey] int IDENTITY(1,1) NOT NULL,[UnitMeasureCode] nvarchar(3) NULL,[UnitMeasureName] nvarchar(100) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([UnitMeasureKey]));
IF OBJECT_ID(N''etl_calc.[Dim_Vendor]'',''U'') IS NULL CREATE TABLE etl_calc.[Dim_Vendor] ([VendorKey] int IDENTITY(1,1) NOT NULL,[VendorID] int NULL,[AccountNumber] nvarchar(15) NULL,[VendorName] nvarchar(100) NULL,[CreditRating] int NULL,[CreditRatingName] nvarchar(30) NULL,[PreferredVendorStatus] bit NULL,[ActiveFlag] bit NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([VendorKey]));
IF OBJECT_ID(N''etl_calc.[Fact_InventoryOnHand]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_InventoryOnHand] ([ProductKey] int NOT NULL,[LocationKey] int NOT NULL,[AsOfDateKey] int NOT NULL,[Shelf] nvarchar(10) NULL,[Bin] int NULL,[QuantityOnHand] int NULL,[UnitCostAsOf] decimal(19,4) NULL,[InventoryValue] decimal(28,6) NULL,[IsNegativeQty] bit NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ProductKey],[LocationKey],[AsOfDateKey]));
IF OBJECT_ID(N''etl_calc.[Fact_ProductVendorTerms]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_ProductVendorTerms] ([ProductKey] int NOT NULL,[VendorKey] int NOT NULL,[AsOfDateKey] int NOT NULL,[UnitMeasureKey] int NOT NULL,[AverageLeadTime] int NULL,[StandardPrice] decimal(19,4) NULL,[LastReceiptCost] decimal(19,4) NULL,[LastReceiptDateKey] int NOT NULL,[MinOrderQty] int NULL,[MaxOrderQty] int NULL,[OnOrderQty] int NULL,[IsOrderQtyRangeValid] bit NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ProductKey],[VendorKey],[AsOfDateKey]));
IF OBJECT_ID(N''etl_calc.[Fact_PurchaseOrderLine]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_PurchaseOrderLine] ([PurchaseOrderLineKey] bigint IDENTITY(1,1) NOT NULL,[PurchaseOrderID] int NOT NULL,[PurchaseOrderDetailID] int NOT NULL,[OrderDateKey] int NOT NULL,[ExpectedShipDateKey] int NOT NULL,[ExpectedReceiptDateKey] int NOT NULL,[VendorKey] int NOT NULL,[ProductKey] int NOT NULL,[PurchaseStatusKey] int NOT NULL,[OrderQty] int NULL,[ReceivedQty] decimal(19,4) NULL,[RejectedQty] decimal(19,4) NULL,[StockedQty] decimal(19,4) NULL,[UnitPrice] decimal(19,4) NULL,[LineTotal] decimal(28,6) NULL,[OrderAt] datetime2(7) NULL,[ExpectedShipAt] datetime2(7) NULL,[ExpectedReceiptAt] datetime2(7) NULL,[IsVendorProductDeclared] bit NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([PurchaseOrderLineKey]));
IF OBJECT_ID(N''etl_calc.[Fact_SalesOrderLine]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_SalesOrderLine] ([SalesOrderLineKey] bigint IDENTITY(1,1) NOT NULL,[SalesOrderID] int NOT NULL,[SalesOrderDetailID] int NOT NULL,[OrderDateKey] int NOT NULL,[DueDateKey] int NOT NULL,[ShipDateKey] int NOT NULL,[ProductKey] int NOT NULL,[PromotionKey] int NOT NULL,[SalesStatusKey] int NOT NULL,[CustomerKey] int NOT NULL,[ChannelKey] int NOT NULL,[OrderQty] int NULL,[UnitPrice] decimal(19,4) NULL,[UnitPriceDiscount] decimal(9,6) NULL,[LineTotal] decimal(28,6) NULL,[OrderAt] datetime2(7) NULL,[DueAt] datetime2(7) NULL,[ShippedAt] datetime2(7) NULL,[IsDemandEligible] bit NOT NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([SalesOrderLineKey]));
IF OBJECT_ID(N''etl_calc.[Fact_WorkOrder]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_WorkOrder] ([WorkOrderKey] bigint IDENTITY(1,1) NOT NULL,[WorkOrderID] int NOT NULL,[ProductKey] int NOT NULL,[ScrapReasonKey] int NOT NULL,[StartDateKey] int NOT NULL,[DueDateKey] int NOT NULL,[EndDateKey] int NOT NULL,[ActualStartDateKey] int NOT NULL,[ActualEndDateKey] int NOT NULL,[OrderQty] int NULL,[StockedQty] int NULL,[ScrappedQty] int NULL,[PlannedLeadTimeDays] int NULL,[RecordedLeadTimeDays] int NULL,[ActualLeadTimeDays] int NULL,[LateDays] int NULL,[OperationCount] int NULL,[TotalActualResourceHrs] decimal(19,4) NULL,[TotalPlannedCost] decimal(19,4) NULL,[TotalActualCost] decimal(19,4) NULL,[StartAt] datetime2(7) NULL,[DueAt] datetime2(7) NULL,[EndAt] datetime2(7) NULL,[ActualStartAt] datetime2(7) NULL,[ActualEndAt] datetime2(7) NULL,[IsComplete] bit NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([WorkOrderKey]));
IF OBJECT_ID(N''etl_calc.[Fact_WorkOrderOperation]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_WorkOrderOperation] ([WorkOrderOperationKey] bigint IDENTITY(1,1) NOT NULL,[WorkOrderID] int NOT NULL,[OperationSequence] int NOT NULL,[ProductKey] int NOT NULL,[LocationKey] int NOT NULL,[ScheduledStartDateKey] int NOT NULL,[ScheduledEndDateKey] int NOT NULL,[ActualStartDateKey] int NOT NULL,[ActualEndDateKey] int NOT NULL,[ScheduledDurationDays] int NULL,[ActualDurationDays] int NULL,[ActualResourceHrs] decimal(19,4) NULL,[PlannedCost] decimal(19,4) NULL,[ActualCost] decimal(19,4) NULL,[IsLastOperation] bit NULL,[DQReasonCode] nvarchar(200) NULL,[DQRuleVersion] nvarchar(50) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([WorkOrderOperationKey]));
IF OBJECT_ID(N''etl_calc.[Ref_ProductPriceHistory]'',''U'') IS NULL CREATE TABLE etl_calc.[Ref_ProductPriceHistory] ([ProductKey] int NOT NULL,[PriceType] nvarchar(20) NOT NULL,[StartDate] date NOT NULL,[EndDate] date NULL,[Amount] decimal(19,4) NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([ProductKey],[PriceType],[StartDate]));
IF OBJECT_ID(N''etl_calc.[Fact_DemandDaily]'',''U'') IS NULL CREATE TABLE etl_calc.[Fact_DemandDaily] ([DateKey] int NOT NULL,[ProductKey] int NOT NULL,[DemandRuleVersion] nvarchar(50) NOT NULL,[IndependentQty] decimal(19,4) NULL,[PromoIndependentQty] decimal(19,4) NULL,[DependentQty] decimal(19,4) NULL,[TotalDemandQty] decimal(19,4) NULL,[EligibleSalesLineCount] int NULL,[ExcludedSalesLineCount] int NULL,[ParentWorkOrderCount] int NULL,[IsInSellWindow] bit NULL,[LoadBatchID] bigint NOT NULL,[LoadedAt] datetime2(7) NULL,PRIMARY KEY([DateKey],[ProductKey],[DemandRuleVersion]));
IF OBJECT_ID(N''etl_effective.SalesOrderDetail'',''U'') IS NULL CREATE TABLE etl_effective.SalesOrderDetail ([SalesOrderID] int NOT NULL,[SalesOrderDetailID] int NOT NULL,[CarrierTrackingNumber] nvarchar(25) NULL,[OrderQty] smallint NULL,[ProductID] int NOT NULL,[SpecialOfferID] int NOT NULL,[UnitPrice] money NULL,[UnitPriceDiscount] money NOT NULL,[LineTotal] numeric(38,6) NOT NULL,[rowguid] uniqueidentifier NOT NULL,[ModifiedDate] datetime NOT NULL,[LoadBatchID] bigint NOT NULL,PRIMARY KEY([SalesOrderDetailID]));
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.CorrectSales @B bigint AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DELETE FROM etl_effective.SalesOrderDetail;
 INSERT etl_effective.SalesOrderDetail SELECT * FROM etl_raw.SalesOrderDetail;
 -- Legacy transactions have a per-order ordinal; recent trigger events use the
 -- real detail ID. Accept ordinal only for an unambiguous order/product pair.
 SELECT D.*,ROW_NUMBER() OVER(PARTITION BY SalesOrderID ORDER BY SalesOrderDetailID) LineOrdinal,
  COUNT(*) OVER(PARTITION BY SalesOrderID,ProductID) ProductLineCount
 INTO #Sales FROM etl_raw.SalesOrderDetail D;
 SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,UnitPrice,LineOrdinal,ProductLineCount
 INTO #Bad FROM #Sales WHERE OrderQty IS NULL OR OrderQty<=0 OR UnitPrice IS NULL OR UnitPrice<=0;

 SELECT ''''TransactionHistory'''' SourceTable,TransactionID,ReferenceOrderID,ReferenceOrderLineID,ProductID,
        TransactionDate,Quantity,ActualCost
 INTO #History FROM etl_raw.TransactionHistory WHERE TransactionType=''''S''''
 UNION ALL
 SELECT ''''TransactionHistoryArchive'''',TransactionID,ReferenceOrderID,ReferenceOrderLineID,ProductID,
        TransactionDate,Quantity,ActualCost
 FROM etl_raw.TransactionHistoryArchive WHERE TransactionType=''''S'''';

 SELECT B.SalesOrderDetailID,H.* INTO #Evidence
 FROM #Bad B JOIN #History H ON H.ReferenceOrderID=B.SalesOrderID AND H.ProductID=B.ProductID
 WHERE (H.ReferenceOrderLineID=B.SalesOrderDetailID OR (B.ProductLineCount=1 AND H.ReferenceOrderLineID=B.LineOrdinal))
 ;
 -- Multiple historical events are snapshots, never additive transactions here.
 -- Disagreement between positive candidates is unresolved, not guessed.
 INSERT etl_v2.SalesEvidence
 SELECT @B,B.SalesOrderDetailID,F.FieldName,F.OriginalValue,
   CASE WHEN X.DistinctValues=1 THEN X.Value END,X.CandidateCount,X.DistinctValues,
   CASE WHEN X.DistinctValues=1 THEN ''''CORRECTED'''' ELSE ''''UNRESOLVED'''' END,
   (SELECT E.SourceTable,E.TransactionID,E.ReferenceOrderID,E.ReferenceOrderLineID,E.ProductID,
      E.TransactionDate,E.Quantity,E.ActualCost FROM #Evidence E WHERE E.SalesOrderDetailID=B.SalesOrderDetailID
      AND ((F.FieldName=''''OrderQty'''' AND E.Quantity>0) OR (F.FieldName=''''UnitPrice'''' AND E.ActualCost>0))
      ORDER BY E.TransactionDate,E.TransactionID,E.SourceTable FOR JSON PATH)
 FROM #Bad B CROSS APPLY(VALUES(''''OrderQty'''',CONVERT(decimal(28,8),B.OrderQty)),(''''UnitPrice'''',CONVERT(decimal(28,8),B.UnitPrice))) F(FieldName,OriginalValue)
 CROSS APPLY(SELECT COUNT(*) CandidateCount,
   CASE WHEN F.FieldName=''''OrderQty'''' THEN COUNT(DISTINCT E.Quantity) ELSE COUNT(DISTINCT E.ActualCost) END DistinctValues,
   CONVERT(decimal(28,8),CASE WHEN F.FieldName=''''OrderQty'''' THEN MIN(E.Quantity) ELSE MIN(E.ActualCost) END) Value
   FROM #Evidence E WHERE E.SalesOrderDetailID=B.SalesOrderDetailID
    AND ((F.FieldName=''''OrderQty'''' AND E.Quantity>0) OR (F.FieldName=''''UnitPrice'''' AND E.ActualCost>0))) X
 WHERE F.OriginalValue IS NULL OR F.OriginalValue<=0;
 INSERT etl.Audit_DataCorrection(SourceSystem,SourceTable,SourceRecordKey,ColumnName,OriginalValue,CorrectedValue,SourceDataType,RuleID,RuleVersion,EvidenceTable,EvidenceRecordKey,LoadBatchID,CorrectedAt)
 SELECT ''''CompanyX'''',''''Sales.SalesOrderDetail'''',CONVERT(nvarchar(30),SalesOrderDetailID),FieldName,
   CONVERT(nvarchar(100),OriginalValue),CONVERT(nvarchar(100),EffectiveValue),''''decimal(28,8)'''',
   IIF(FieldName=''''OrderQty'''',''''SAL-10'''',''''SAL-11''''),''''SAL-BACKFILL-v2'''',''''etl_v2.SalesEvidence'''',
   CONCAT(@B,'''':'''',SalesOrderDetailID,'''':'''',FieldName),@B,SYSUTCDATETIME()
 FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution=''''CORRECTED'''';
 UPDATE D SET OrderQty=E.EffectiveValue FROM etl_effective.SalesOrderDetail D JOIN etl_v2.SalesEvidence E
 ON D.SalesOrderDetailID=E.SalesOrderDetailID WHERE E.BatchID=@B AND E.FieldName=''''OrderQty'''' AND E.Resolution=''''CORRECTED'''';
 UPDATE D SET UnitPrice=E.EffectiveValue FROM etl_effective.SalesOrderDetail D JOIN etl_v2.SalesEvidence E
 ON D.SalesOrderDetailID=E.SalesOrderDetailID WHERE E.BatchID=@B AND E.FieldName=''''UnitPrice'''' AND E.Resolution=''''CORRECTED'''';
 SELECT D.SalesOrderDetailID,D.LineTotal OldTotal,
   CONVERT(numeric(38,6),ISNULL((D.UnitPrice*(1.0-D.UnitPriceDiscount))*D.OrderQty,0)) NewTotal
 INTO #Totals FROM etl_effective.SalesOrderDetail D
 WHERE EXISTS(SELECT 1 FROM etl_v2.SalesEvidence E WHERE E.BatchID=@B AND E.SalesOrderDetailID=D.SalesOrderDetailID AND E.Resolution=''''CORRECTED'''');
 INSERT etl.Audit_DataCorrection(SourceSystem,SourceTable,SourceRecordKey,ColumnName,OriginalValue,CorrectedValue,SourceDataType,RuleID,RuleVersion,EvidenceTable,EvidenceRecordKey,LoadBatchID,CorrectedAt)
 SELECT ''''CompanyX'''',''''Sales.SalesOrderDetail'''',CONVERT(nvarchar(30),T.SalesOrderDetailID),''''LineTotal'''',CONVERT(nvarchar(100),T.OldTotal),CONVERT(nvarchar(100),T.NewTotal),''''numeric(38,6)'''',
  ''''SAL-12'''',''''SAL-BACKFILL-v2'''',''''etl_v2.SalesEvidence'''',CONCAT(@B,'''':'''',T.SalesOrderDetailID),@B,SYSUTCDATETIME()
 FROM #Totals T WHERE T.OldTotal IS NULL OR T.OldTotal<>T.NewTotal;
 UPDATE D SET LineTotal=T.NewTotal FROM etl_effective.SalesOrderDetail D JOIN #Totals T ON T.SalesOrderDetailID=D.SalesOrderDetailID;
END;
'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspSeedSystemMembers @B bigint AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING''''
 AND PipelineName IN (''''DWH_INCREMENTAL_V2'''',''''SYSTEM_SEED'''')) THROW 51200,''''A RUNNING seed or DWH batch is required.'''',1;
 BEGIN TRY
  BEGIN TRAN;
  IF EXISTS(SELECT 1 FROM etl_calc.Dim_Location WITH(UPDLOCK,HOLDLOCK) WHERE LocationKey=-1 AND LocationID IS NOT NULL)
   THROW 51201,''''LocationKey -1 is already assigned to a physical source location.'''',1;
  IF NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Location WITH(UPDLOCK,HOLDLOCK) WHERE LocationKey=-1)
  BEGIN
   SET IDENTITY_INSERT etl_calc.Dim_Location ON;
   INSERT etl_calc.Dim_Location(LocationKey,LocationName,LocationType,HasProductionConflict,LoadBatchID,LoadedAt)
   VALUES(-1,N''''Không áp dụng / toàn phạm vi'''',N''''NOT_APPLICABLE'''',0,@B,SYSUTCDATETIME());
   SET IDENTITY_INSERT etl_calc.Dim_Location OFF;
  END;
  COMMIT;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  SET IDENTITY_INSERT etl_calc.Dim_Location OFF;
  THROW;
 END CATCH;
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadDimensions @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #UnitMeasure FROM etl_raw.UnitMeasure;
SELECT * INTO #Location FROM etl_raw.Location;
SELECT * INTO #Product FROM etl_raw.Product;
SELECT * INTO #ScrapReason FROM etl_raw.ScrapReason;
SELECT * INTO #BillOfMaterials FROM etl_raw.BillOfMaterials;
SELECT * INTO #ProductCostHistory FROM etl_raw.ProductCostHistory;
SELECT * INTO #ProductListPriceHistory FROM etl_raw.ProductListPriceHistory;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #WorkOrderRouting FROM etl_raw.WorkOrderRouting;
SELECT * INTO #TransactionHistoryArchive FROM etl_raw.TransactionHistoryArchive;
SELECT * INTO #Vendor FROM etl_raw.Vendor;
SELECT * INTO #ProductVendor FROM etl_raw.ProductVendor;
SELECT * INTO #PurchaseOrderHeader FROM etl_raw.PurchaseOrderHeader;
SELECT * INTO #SpecialOffer FROM etl_raw.SpecialOffer;
SELECT * INTO #Customer FROM etl_raw.Customer;
SELECT * INTO #SalesOrderHeader FROM etl_raw.SalesOrderHeader;
BEGIN TRY
BEGIN TRAN;
EXEC etl_v2.Calc_uspSeedSystemMembers @B;
SET IDENTITY_INSERT etl_calc.Dim_UnitMeasure ON;
INSERT etl_calc.Dim_UnitMeasure ([UnitMeasureKey],[UnitMeasureName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_UnitMeasure WHERE [UnitMeasureKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_UnitMeasure OFF;
SET IDENTITY_INSERT etl_calc.Dim_Location ON;
INSERT etl_calc.Dim_Location ([LocationKey],[LocationName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Location WHERE [LocationKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_Location OFF;
SET IDENTITY_INSERT etl_calc.Dim_Vendor ON;
INSERT etl_calc.Dim_Vendor ([VendorKey],[VendorName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Vendor WHERE [VendorKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_Vendor OFF;
SET IDENTITY_INSERT etl_calc.Dim_Promotion ON;
INSERT etl_calc.Dim_Promotion ([PromotionKey],[Description],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Promotion WHERE [PromotionKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_Promotion OFF;
SET IDENTITY_INSERT etl_calc.Dim_Customer ON;
INSERT etl_calc.Dim_Customer ([CustomerKey],[CustomerType],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Customer WHERE [CustomerKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_Customer OFF;
SET IDENTITY_INSERT etl_calc.Dim_ScrapReason ON;
INSERT etl_calc.Dim_ScrapReason ([ScrapReasonKey],[ScrapReasonName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Không phế phẩm'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_ScrapReason WHERE [ScrapReasonKey]=0);
SET IDENTITY_INSERT etl_calc.Dim_ScrapReason OFF;
SET IDENTITY_INSERT etl_calc.Dim_Vendor ON;
INSERT etl_calc.Dim_Vendor ([VendorKey],[VendorName],[ActiveFlag],[LoadBatchID],[LoadedAt])
SELECT -1,
 N''''Không áp dụng (tự sản xuất)'''',
 0,
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Vendor WHERE [VendorKey]=-1);
SET IDENTITY_INSERT etl_calc.Dim_Vendor OFF;
SET IDENTITY_INSERT etl_calc.Dim_Product ON;
INSERT etl_calc.Dim_Product ([ProductKey],[ProductName],[DQStatus],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT 0,
 N''''Unknown'''',
 ''''EXCLUDED'''',
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Product WHERE [ProductKey]=0);
INSERT etl_calc.Dim_Product ([ProductKey],[ProductName],[DQStatus],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT -1,
 N''''Không áp dụng'''',
 ''''EXCLUDED'''',
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Product WHERE [ProductKey]=-1);
SET IDENTITY_INSERT etl_calc.Dim_Product OFF;
INSERT etl_calc.Dim_Date ([DateKey])
SELECT 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Date WHERE [DateKey]=0);
INSERT etl_calc.Dim_Date ([DateKey])
SELECT -1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Date WHERE [DateKey]=-1);
INSERT etl_calc.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 0,
 NULL,
 N''''Unknown''''
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Channel WHERE ChannelKey=0);
INSERT etl_calc.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 1,
 1,
 N''''Online''''
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Channel WHERE ChannelKey=1);
INSERT etl_calc.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 2,
 0,
 N''''Salesperson''''
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Channel WHERE ChannelKey=2);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 0,
 NULL,
 N''''Unknown'''',
 0,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=0);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 1,
 0,
 N''''Chưa có tài liệu (mã 0)'''',
 0,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=1);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 2,
 1,
 N''''In process'''',
 1,
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=2);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 3,
 2,
 N''''Approved'''',
 1,
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=3);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 4,
 3,
 N''''Backordered'''',
 1,
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=4);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 5,
 4,
 N''''Rejected'''',
 1,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=5);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 6,
 5,
 N''''Shipped'''',
 1,
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=6);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 7,
 6,
 N''''Cancelled'''',
 1,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=7);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 8,
 7,
 N''''Chưa có tài liệu (mã 7)'''',
 0,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=8);
INSERT etl_calc.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 9,
 8,
 N''''Chưa có tài liệu (mã 8)'''',
 0,
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_SalesStatus WHERE SalesStatusKey=9);
INSERT etl_calc.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 0,
 NULL,
 N''''Unknown'''',
 0
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_PurchaseStatus WHERE PurchaseStatusKey=0);
INSERT etl_calc.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 1,
 1,
 N''''Pending'''',
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_PurchaseStatus WHERE PurchaseStatusKey=1);
INSERT etl_calc.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 2,
 2,
 N''''Approved'''',
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_PurchaseStatus WHERE PurchaseStatusKey=2);
INSERT etl_calc.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 3,
 3,
 N''''Rejected'''',
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_PurchaseStatus WHERE PurchaseStatusKey=3);
INSERT etl_calc.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 4,
 4,
 N''''Complete'''',
 1
WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_PurchaseStatus WHERE PurchaseStatusKey=4);
DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
DECLARE @Min date=(SELECT MIN(d) FROM (SELECT MIN(SellStartDate) d FROM #Product UNION ALL SELECT MIN(StartDate) FROM #BillOfMaterials UNION ALL SELECT MIN(OrderDate) FROM #SalesOrderHeader UNION ALL SELECT MIN(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MIN(StartDate) FROM #WorkOrder UNION ALL SELECT MIN(StartDate) FROM #ProductCostHistory UNION ALL SELECT MIN(StartDate) FROM #ProductListPriceHistory UNION ALL SELECT MIN(LastReceiptDate) FROM #ProductVendor UNION ALL SELECT MIN(TransactionDate) FROM #TransactionHistoryArchive) X);
IF @AsOf IS NULL OR @Min IS NULL THROW 51000,''''Missing date coverage in source.'''',1;
;WITH Dates AS (SELECT @Min d UNION ALL SELECT DATEADD(day,1,d) FROM Dates WHERE d<DATEFROMPARTS(YEAR(@AsOf)+1,12,31))
INSERT etl_calc.Dim_Date(DateKey,CalendarDate,CalendarYear,CalendarQuarter,CalendarMonth,DayOfMonth,DayOfWeek,IsWeekend,ISOWeek,ISOYear,WeekStartDate,MonthStartDate)
SELECT etl.DateKey(d),d,YEAR(d),DATEPART(quarter,d),MONTH(d),DAY(d),DATEDIFF(day,''''19000101'''',d)%7+1,IIF(DATEDIFF(day,''''19000101'''',d)%7>=5,1,0),DATEPART(iso_week,d),YEAR(DATEADD(day,26-DATEPART(iso_week,d),d)),DATEADD(day,-(DATEDIFF(day,''''19000101'''',d)%7),d),DATEFROMPARTS(YEAR(d),MONTH(d),1)
FROM Dates WHERE NOT EXISTS(SELECT 1 FROM etl_calc.Dim_Date D WHERE D.DateKey=etl.DateKey(d)) OPTION(MAXRECURSION 0);
IF EXISTS(SELECT 1 FROM #SalesOrderHeader WHERE Status NOT BETWEEN 0 AND 8) THROW 51000,''''Undocumented sales status outside 0..8.'''',1;
MERGE etl_calc.Dim_UnitMeasure WITH(HOLDLOCK) AS D USING (SELECT RTRIM(UnitMeasureCode) AS [UnitMeasureCode],
 Name AS [UnitMeasureName],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #UnitMeasure) AS S ON D.[UnitMeasureCode]=S.[UnitMeasureCode]
WHEN MATCHED THEN UPDATE SET D.[UnitMeasureName]=S.[UnitMeasureName],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([UnitMeasureCode],[UnitMeasureName],[LoadBatchID],[LoadedAt]) VALUES (S.[UnitMeasureCode],S.[UnitMeasureName],S.[LoadBatchID],S.[LoadedAt]);
MERGE etl_calc.Dim_Location WITH(HOLDLOCK) AS D USING (SELECT L.LocationID AS [LocationID],
 L.Name AS [LocationName],
 L.CostRate AS [CostRate],
 L.Availability AS [Availability],
 IIF(L.Availability=0,''''STORAGE'''',''''PRODUCTION'''') AS [LocationType],
 IIF(L.Availability=0 AND EXISTS(SELECT 1 FROM #WorkOrderRouting R WHERE R.LocationID=L.LocationID),1,0) AS [HasProductionConflict],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Location L) AS S ON D.[LocationID]=S.[LocationID]
WHEN MATCHED THEN UPDATE SET D.[LocationName]=S.[LocationName],D.[CostRate]=S.[CostRate],D.[Availability]=S.[Availability],D.[LocationType]=S.[LocationType],D.[HasProductionConflict]=S.[HasProductionConflict],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict],[LoadBatchID],[LoadedAt]) VALUES (S.[LocationID],S.[LocationName],S.[CostRate],S.[Availability],S.[LocationType],S.[HasProductionConflict],S.[LoadBatchID],S.[LoadedAt]);
MERGE etl_calc.Dim_Vendor WITH(HOLDLOCK) AS D USING (SELECT BusinessEntityID AS [VendorID],
 AccountNumber AS [AccountNumber],
 Name AS [VendorName],
 CreditRating AS [CreditRating],
 CASE CreditRating WHEN 1 THEN N''''Xuất sắc'''' WHEN 2 THEN N''''Tốt'''' WHEN 3 THEN N''''Trên trung bình'''' WHEN 4 THEN N''''Trung bình'''' WHEN 5 THEN N''''Dưới trung bình'''' ELSE N''''Không xác định'''' END AS [CreditRatingName],
 PreferredVendorStatus AS [PreferredVendorStatus],
 ActiveFlag AS [ActiveFlag],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Vendor) AS S ON D.[VendorID]=S.[VendorID]
WHEN MATCHED THEN UPDATE SET D.[AccountNumber]=S.[AccountNumber],D.[VendorName]=S.[VendorName],D.[CreditRating]=S.[CreditRating],D.[CreditRatingName]=S.[CreditRatingName],D.[PreferredVendorStatus]=S.[PreferredVendorStatus],D.[ActiveFlag]=S.[ActiveFlag],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag],[LoadBatchID],[LoadedAt]) VALUES (S.[VendorID],S.[AccountNumber],S.[VendorName],S.[CreditRating],S.[CreditRatingName],S.[PreferredVendorStatus],S.[ActiveFlag],S.[LoadBatchID],S.[LoadedAt]);
MERGE etl_calc.Dim_Promotion WITH(HOLDLOCK) AS D USING (SELECT SpecialOfferID AS [SpecialOfferID],
 Description AS [Description],
 Type AS [OfferType],
 Category AS [OfferCategory],
 DiscountPct AS [DiscountPct],
 StartDate AS [StartDate],
 EndDate AS [EndDate],
 MinQty AS [MinQty],
 MaxQty AS [MaxQty],
 IIF(DiscountPct=0,1,0) AS [IsNoDiscount],
 IIF(StartDate IS NOT NULL AND EndDate IS NOT NULL AND StartDate<=EndDate,1,0) AS [IsScheduleValid],
 IIF(DiscountPct BETWEEN 0 AND 1,1,0) AS [IsDiscountValid],
 IIF(MaxQty IS NULL OR (MaxQty>=0 AND MaxQty>=MinQty),1,0) AS [IsQtyRangeValid],
 NULLIF(CONCAT_WS('''','''',CASE WHEN StartDate IS NULL OR EndDate IS NULL OR EndDate<StartDate THEN ''''PRM-01'''' END,CASE WHEN DiscountPct NOT BETWEEN 0 AND 1 THEN ''''PRM-02'''' END,CASE WHEN MaxQty<0 OR MaxQty<MinQty THEN ''''PRM-03'''' END),'''''''') AS [DQReasonCode],
 ''''DQ-v1'''' AS [DQRuleVersion],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #SpecialOffer) AS S ON D.[SpecialOfferID]=S.[SpecialOfferID]
WHEN MATCHED THEN UPDATE SET D.[Description]=S.[Description],D.[OfferType]=S.[OfferType],D.[OfferCategory]=S.[OfferCategory],D.[DiscountPct]=S.[DiscountPct],D.[StartDate]=S.[StartDate],D.[EndDate]=S.[EndDate],D.[MinQty]=S.[MinQty],D.[MaxQty]=S.[MaxQty],D.[IsNoDiscount]=S.[IsNoDiscount],D.[IsScheduleValid]=S.[IsScheduleValid],D.[IsDiscountValid]=S.[IsDiscountValid],D.[IsQtyRangeValid]=S.[IsQtyRangeValid],D.[DQReasonCode]=S.[DQReasonCode],D.[DQRuleVersion]=S.[DQRuleVersion],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) VALUES (S.[SpecialOfferID],S.[Description],S.[OfferType],S.[OfferCategory],S.[DiscountPct],S.[StartDate],S.[EndDate],S.[MinQty],S.[MaxQty],S.[IsNoDiscount],S.[IsScheduleValid],S.[IsDiscountValid],S.[IsQtyRangeValid],S.[DQReasonCode],S.[DQRuleVersion],S.[LoadBatchID],S.[LoadedAt]);
MERGE etl_calc.Dim_Customer WITH(HOLDLOCK) AS D USING (SELECT CustomerID AS [CustomerID],
 PersonID AS [PersonID],
 StoreID AS [StoreID],
 CASE WHEN StoreID IS NOT NULL THEN ''''Store'''' WHEN PersonID IS NOT NULL THEN ''''Individual'''' ELSE ''''Unknown'''' END AS [CustomerType],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Customer) AS S ON D.[CustomerID]=S.[CustomerID]
WHEN MATCHED THEN UPDATE SET D.[PersonID]=S.[PersonID],D.[StoreID]=S.[StoreID],D.[CustomerType]=S.[CustomerType],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([CustomerID],[PersonID],[StoreID],[CustomerType],[LoadBatchID],[LoadedAt]) VALUES (S.[CustomerID],S.[PersonID],S.[StoreID],S.[CustomerType],S.[LoadBatchID],S.[LoadedAt]);
MERGE etl_calc.Dim_ScrapReason WITH(HOLDLOCK) AS D USING (SELECT ScrapReasonID AS [ScrapReasonID],
 Name AS [ScrapReasonName],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #ScrapReason) AS S ON D.[ScrapReasonID]=S.[ScrapReasonID]
WHEN MATCHED THEN UPDATE SET D.[ScrapReasonName]=S.[ScrapReasonName],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([ScrapReasonID],[ScrapReasonName],[LoadBatchID],[LoadedAt]) VALUES (S.[ScrapReasonID],S.[ScrapReasonName],S.[LoadBatchID],S.[LoadedAt]);
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadProduct @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #UnitMeasure FROM etl_raw.UnitMeasure;
SELECT * INTO #Product FROM etl_raw.Product;
SELECT * INTO #ProductSubcategory FROM etl_raw.ProductSubcategory;
SELECT * INTO #ProductCategory FROM etl_raw.ProductCategory;
SELECT * INTO #BillOfMaterials FROM etl_raw.BillOfMaterials;
SELECT * INTO #ProductInventory FROM etl_raw.ProductInventory;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #PurchaseOrderDetail FROM etl_raw.PurchaseOrderDetail;
SELECT * INTO #SalesOrderDetail FROM etl_effective.SalesOrderDetail;
BEGIN TRY
BEGIN TRAN;
MERGE etl_calc.Dim_Product WITH(HOLDLOCK) AS D USING (SELECT P.ProductID AS [ProductID],
 P.ProductNumber AS [ProductNumber],
 P.Name AS [ProductName],
 P.ProductSubcategoryID AS [ProductSubcategoryID],
 S.Name AS [SubcategoryName],
 S.ProductCategoryID AS [ProductCategoryID],
 C.Name AS [CategoryName],
 P.ProductModelID AS [ProductModelID],
 P.MakeFlag AS [MakeFlag],
 P.FinishedGoodsFlag AS [FinishedGoodsFlag],
 IIF(P.MakeFlag=1,''''MAKE'''',''''BUY'''') AS [SupplyType],
 CASE WHEN P.FinishedGoodsFlag=1 THEN ''''FINISHED_GOOD'''' WHEN EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ProductAssemblyID=P.ProductID) AND EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN ''''SUBASSEMBLY'''' WHEN EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN ''''RAW_MATERIAL'''' WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) THEN ''''ISOLATED'''' ELSE ''''UNCLASSIFIED'''' END AS [ProductRole],
 IIF(EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ProductAssemblyID=P.ProductID),1,0) AS [IsBOMAssembly],
 IIF(EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL),1,0) AS [IsBOMComponent],
 P.Color AS [Color],
 P.Size AS [Size],
 US.Name AS [SizeUnitName],
 P.Weight AS [Weight],
 UW.Name AS [WeightUnitName],
 RTRIM(UPPER(P.ProductLine)) AS [ProductLine],
 CASE WHEN P.ProductLine IS NULL THEN NULL WHEN RTRIM(UPPER(P.ProductLine))=''''R'''' THEN N''''Road'''' WHEN RTRIM(UPPER(P.ProductLine))=''''M'''' THEN N''''Mountain'''' WHEN RTRIM(UPPER(P.ProductLine))=''''T'''' THEN N''''Touring'''' WHEN RTRIM(UPPER(P.ProductLine))=''''S'''' THEN N''''Standard'''' ELSE N''''Không xác định'''' END AS [ProductLineName],
 RTRIM(UPPER(P.Class)) AS [Class],
 CASE WHEN P.Class IS NULL THEN NULL WHEN RTRIM(UPPER(P.Class))=''''H'''' THEN N''''Cao cấp'''' WHEN RTRIM(UPPER(P.Class))=''''M'''' THEN N''''Trung bình'''' WHEN RTRIM(UPPER(P.Class))=''''L'''' THEN N''''Thấp'''' ELSE N''''Không xác định'''' END AS [ClassName],
 RTRIM(UPPER(P.Style)) AS [Style],
 CASE WHEN P.Style IS NULL THEN NULL WHEN RTRIM(UPPER(P.Style))=''''W'''' THEN N''''Nữ'''' WHEN RTRIM(UPPER(P.Style))=''''M'''' THEN N''''Nam'''' WHEN RTRIM(UPPER(P.Style))=''''U'''' THEN N''''Chung'''' ELSE N''''Không xác định'''' END AS [StyleName],
 P.DaysToManufacture AS [DaysToManufacture],
 P.SafetyStockLevel AS [SafetyStockLevel],
 P.ReorderPoint AS [ReorderPoint],
 P.StandardCost AS [StandardCost],
 P.ListPrice AS [ListPrice],
 P.SellStartDate AS [SellStartDate],
 P.SellEndDate AS [SellEndDate],
 P.DiscontinuedDate AS [DiscontinuedDate],
 CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN ''''EXCLUDED'''' WHEN NULLIF(CONCAT_WS('''','''',CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN ''''PRD-01'''' END,CASE WHEN P.MakeFlag=0 AND NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN ''''PRD-02'''' END,CASE WHEN P.SafetyStockLevel<=0 THEN ''''PRD-03'''' END,CASE WHEN P.ReorderPoint<=0 THEN ''''PRD-04'''' END,CASE WHEN P.SellEndDate<P.SellStartDate THEN ''''PRD-05'''' END),'''''''') IS NOT NULL THEN ''''WARNING'''' ELSE ''''OK'''' END AS [DQStatus],
 NULLIF(CONCAT_WS('''','''',CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN ''''PRD-01'''' END,CASE WHEN P.MakeFlag=0 AND NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN ''''PRD-02'''' END,CASE WHEN P.SafetyStockLevel<=0 THEN ''''PRD-03'''' END,CASE WHEN P.ReorderPoint<=0 THEN ''''PRD-04'''' END,CASE WHEN P.SellEndDate<P.SellStartDate THEN ''''PRD-05'''' END),'''''''') AS [DQReasonCode],
 ''''DQ-v1'''' AS [DQRuleVersion],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Product P LEFT JOIN #ProductSubcategory S ON S.ProductSubcategoryID=P.ProductSubcategoryID LEFT JOIN #ProductCategory C ON C.ProductCategoryID=S.ProductCategoryID LEFT JOIN #UnitMeasure US ON US.UnitMeasureCode=P.SizeUnitMeasureCode LEFT JOIN #UnitMeasure UW ON UW.UnitMeasureCode=P.WeightUnitMeasureCode) AS S ON D.[ProductID]=S.[ProductID]
WHEN MATCHED THEN UPDATE SET D.[ProductNumber]=S.[ProductNumber],D.[ProductName]=S.[ProductName],D.[ProductSubcategoryID]=S.[ProductSubcategoryID],D.[SubcategoryName]=S.[SubcategoryName],D.[ProductCategoryID]=S.[ProductCategoryID],D.[CategoryName]=S.[CategoryName],D.[ProductModelID]=S.[ProductModelID],D.[MakeFlag]=S.[MakeFlag],D.[FinishedGoodsFlag]=S.[FinishedGoodsFlag],D.[SupplyType]=S.[SupplyType],D.[ProductRole]=S.[ProductRole],D.[IsBOMAssembly]=S.[IsBOMAssembly],D.[IsBOMComponent]=S.[IsBOMComponent],D.[Color]=S.[Color],D.[Size]=S.[Size],D.[SizeUnitName]=S.[SizeUnitName],D.[Weight]=S.[Weight],D.[WeightUnitName]=S.[WeightUnitName],D.[ProductLine]=S.[ProductLine],D.[ProductLineName]=S.[ProductLineName],D.[Class]=S.[Class],D.[ClassName]=S.[ClassName],D.[Style]=S.[Style],D.[StyleName]=S.[StyleName],D.[DaysToManufacture]=S.[DaysToManufacture],D.[SafetyStockLevel]=S.[SafetyStockLevel],D.[ReorderPoint]=S.[ReorderPoint],D.[StandardCost]=S.[StandardCost],D.[ListPrice]=S.[ListPrice],D.[SellStartDate]=S.[SellStartDate],D.[SellEndDate]=S.[SellEndDate],D.[DiscontinuedDate]=S.[DiscontinuedDate],D.[DQStatus]=S.[DQStatus],D.[DQReasonCode]=S.[DQReasonCode],D.[DQRuleVersion]=S.[DQRuleVersion],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) VALUES (S.[ProductID],S.[ProductNumber],S.[ProductName],S.[ProductSubcategoryID],S.[SubcategoryName],S.[ProductCategoryID],S.[CategoryName],S.[ProductModelID],S.[MakeFlag],S.[FinishedGoodsFlag],S.[SupplyType],S.[ProductRole],S.[IsBOMAssembly],S.[IsBOMComponent],S.[Color],S.[Size],S.[SizeUnitName],S.[Weight],S.[WeightUnitName],S.[ProductLine],S.[ProductLineName],S.[Class],S.[ClassName],S.[Style],S.[StyleName],S.[DaysToManufacture],S.[SafetyStockLevel],S.[ReorderPoint],S.[StandardCost],S.[ListPrice],S.[SellStartDate],S.[SellEndDate],S.[DiscontinuedDate],S.[DQStatus],S.[DQReasonCode],S.[DQRuleVersion],S.[LoadBatchID],S.[LoadedAt]);
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadBridges @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #BillOfMaterials FROM etl_raw.BillOfMaterials;
SELECT * INTO #ProductCostHistory FROM etl_raw.ProductCostHistory;
SELECT * INTO #ProductListPriceHistory FROM etl_raw.ProductListPriceHistory;
SELECT * INTO #SpecialOfferProduct FROM etl_raw.SpecialOfferProduct;
BEGIN TRY
BEGIN TRAN;
DELETE FROM etl_calc.Bridge_ProductPromotion; DELETE FROM etl_calc.Bridge_BillOfMaterials; DELETE FROM etl_calc.Ref_ProductPriceHistory;
INSERT etl_calc.Bridge_ProductPromotion ([ProductKey],[PromotionKey],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(O.PromotionKey,0),
 @B,
 SYSUTCDATETIME()
FROM #SpecialOfferProduct B LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=B.ProductID LEFT JOIN etl_calc.Dim_Promotion O ON O.SpecialOfferID=B.SpecialOfferID;
INSERT etl_calc.Bridge_BillOfMaterials ([BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT B.BillOfMaterialsID,
 CASE WHEN B.ProductAssemblyID IS NULL THEN -1 ELSE COALESCE(A.ProductKey,0) END,
 COALESCE(C.ProductKey,0),
 COALESCE(U.UnitMeasureKey,0),
 B.BOMLevel,
 B.PerAssemblyQty,
 B.StartDate,
 B.EndDate,
 CASE WHEN (B.ComponentID=B.ProductAssemblyID) OR (B.ProductAssemblyID IS NULL AND (B.BOMLevel<>0 OR B.PerAssemblyQty<>1)) OR (B.ProductAssemblyID IS NOT NULL AND B.BOMLevel<1) THEN 0 ELSE 1 END,
 NULLIF(CONCAT_WS('''','''',CASE WHEN B.ComponentID=B.ProductAssemblyID THEN ''''BOM-01'''' END,CASE WHEN B.ProductAssemblyID IS NULL AND (B.BOMLevel<>0 OR B.PerAssemblyQty<>1) THEN ''''BOM-02'''' END,CASE WHEN B.ProductAssemblyID IS NOT NULL AND B.BOMLevel<1 THEN ''''BOM-03'''' END,CASE WHEN B.EndDate<=B.StartDate THEN ''''BOM-04'''' END),''''''''),
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
FROM #BillOfMaterials B LEFT JOIN etl_calc.Dim_Product A ON A.ProductID=B.ProductAssemblyID LEFT JOIN etl_calc.Dim_Product C ON C.ProductID=B.ComponentID LEFT JOIN etl_calc.Dim_UnitMeasure U ON U.UnitMeasureCode=RTRIM(B.UnitMeasureCode);
INSERT etl_calc.Ref_ProductPriceHistory ([ProductKey],[PriceType],[StartDate],[EndDate],[Amount],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 ''''STANDARD_COST'''',
 H.StartDate,
 H.EndDate,
 H.StandardCost,
 @B,
 SYSUTCDATETIME()
FROM #ProductCostHistory H LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=H.ProductID;
INSERT etl_calc.Ref_ProductPriceHistory ([ProductKey],[PriceType],[StartDate],[EndDate],[Amount],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 ''''LIST_PRICE'''',
 H.StartDate,
 H.EndDate,
 H.ListPrice,
 @B,
 SYSUTCDATETIME()
FROM #ProductListPriceHistory H LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=H.ProductID;
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadSales @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #SpecialOfferProduct FROM etl_raw.SpecialOfferProduct;
SELECT * INTO #SalesOrderHeader FROM etl_raw.SalesOrderHeader;
SELECT * INTO #SalesOrderDetail FROM etl_effective.SalesOrderDetail;
BEGIN TRY
BEGIN TRAN;
DELETE FROM etl_calc.Fact_SalesOrderLine;
INSERT etl_calc.Fact_SalesOrderLine ([SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT D.SalesOrderID,
 D.SalesOrderDetailID,
 etl.DateKey(H.OrderDate),
 etl.DateKey(H.DueDate),
 IIF(H.ShipDate IS NULL,-1,etl.DateKey(H.ShipDate)),
 COALESCE(P.ProductKey,0),
 COALESCE(O.PromotionKey,0),
 COALESCE(S.SalesStatusKey,0),
 COALESCE(C.CustomerKey,0),
 COALESCE(K.ChannelKey,0),
 D.OrderQty,
 D.UnitPrice,
 D.UnitPriceDiscount,
 D.LineTotal,
 H.OrderDate,
 H.DueDate,
 H.ShipDate,
 IIF(S.IsDemandEligible=1 AND D.OrderQty>0,1,0),
 NULLIF(CONCAT_WS('''','''',CASE WHEN D.OrderQty IS NULL THEN ''''SAL-01'''' END,CASE WHEN D.OrderQty<=0 THEN ''''SAL-02'''' END,CASE WHEN D.UnitPrice IS NULL THEN ''''SAL-03'''' END,CASE WHEN D.UnitPrice<0 THEN ''''SAL-04'''' END,CASE WHEN H.DueDate<H.OrderDate THEN ''''SAL-05'''' END,CASE WHEN H.ShipDate<H.OrderDate THEN ''''SAL-06'''' END,CASE WHEN S.IsDemandEligible=0 AND S.IsDocumented=1 THEN ''''SAL-07'''' END,CASE WHEN COALESCE(S.IsDocumented,0)=0 THEN ''''SAL-08'''' END,CASE WHEN NOT EXISTS(SELECT 1 FROM #SpecialOfferProduct X WHERE X.ProductID=D.ProductID AND X.SpecialOfferID=D.SpecialOfferID) THEN ''''SAL-09'''' END),''''''''),
 CASE WHEN EXISTS(SELECT 1 FROM etl_v2.SalesEvidence E WHERE E.BatchID=@B AND E.SalesOrderDetailID=D.SalesOrderDetailID) THEN ''''DQ-v2-SAL-BACKFILL'''' ELSE ''''DQ-v1'''' END,
 @B,
 SYSUTCDATETIME()
FROM #SalesOrderDetail D INNER JOIN #SalesOrderHeader H ON H.SalesOrderID=D.SalesOrderID LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=D.ProductID LEFT JOIN etl_calc.Dim_Promotion O ON O.SpecialOfferID=D.SpecialOfferID LEFT JOIN etl_calc.Dim_SalesStatus S ON S.StatusCode=H.Status LEFT JOIN etl_calc.Dim_Customer C ON C.CustomerID=H.CustomerID LEFT JOIN etl_calc.Dim_Channel K ON K.OnlineOrderFlag=H.OnlineOrderFlag;
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadPurchases @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #ProductVendor FROM etl_raw.ProductVendor;
SELECT * INTO #PurchaseOrderHeader FROM etl_raw.PurchaseOrderHeader;
SELECT * INTO #PurchaseOrderDetail FROM etl_raw.PurchaseOrderDetail;
BEGIN TRY
BEGIN TRAN;
DELETE FROM etl_calc.Fact_PurchaseOrderLine;
INSERT etl_calc.Fact_PurchaseOrderLine ([PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT D.PurchaseOrderID,
 D.PurchaseOrderDetailID,
 etl.DateKey(H.OrderDate),
 IIF(H.ShipDate IS NULL,-1,etl.DateKey(H.ShipDate)),
 etl.DateKey(D.DueDate),
 COALESCE(V.VendorKey,0),
 COALESCE(P.ProductKey,0),
 COALESCE(S.PurchaseStatusKey,0),
 D.OrderQty,
 D.ReceivedQty,
 D.RejectedQty,
 D.StockedQty,
 D.UnitPrice,
 CAST(D.OrderQty AS decimal(19,4))*CAST(D.UnitPrice AS decimal(19,4)),
 H.OrderDate,
 H.ShipDate,
 D.DueDate,
 IIF(PV.ProductID IS NULL,0,1),
 NULLIF(CONCAT_WS('''','''',CASE WHEN PV.ProductID IS NULL THEN ''''PUR-01'''' END,CASE WHEN D.RejectedQty>D.ReceivedQty THEN ''''PUR-02'''' END,CASE WHEN D.ReceivedQty>D.OrderQty THEN ''''PUR-03'''' END,CASE WHEN D.DueDate<H.OrderDate THEN ''''PUR-04'''' END),''''''''),
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
FROM #PurchaseOrderDetail D INNER JOIN #PurchaseOrderHeader H ON H.PurchaseOrderID=D.PurchaseOrderID LEFT JOIN #ProductVendor PV ON PV.ProductID=D.ProductID AND PV.BusinessEntityID=H.VendorID LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=D.ProductID LEFT JOIN etl_calc.Dim_Vendor V ON V.VendorID=H.VendorID LEFT JOIN etl_calc.Dim_PurchaseStatus S ON S.StatusCode=H.Status;
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadVendorTerms @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #ProductVendor FROM etl_raw.ProductVendor;
SELECT * INTO #PurchaseOrderHeader FROM etl_raw.PurchaseOrderHeader;
SELECT * INTO #SalesOrderHeader FROM etl_raw.SalesOrderHeader;
BEGIN TRY
BEGIN TRAN;
DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
DELETE FROM etl_calc.Fact_ProductVendorTerms;
INSERT etl_calc.Fact_ProductVendorTerms ([ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(V.VendorKey,0),
 etl.DateKey(@AsOf),
 COALESCE(U.UnitMeasureKey,0),
 PV.AverageLeadTime,
 PV.StandardPrice,
 PV.LastReceiptCost,
 IIF(PV.LastReceiptDate IS NULL,-1,etl.DateKey(PV.LastReceiptDate)),
 PV.MinOrderQty,
 PV.MaxOrderQty,
 PV.OnOrderQty,
 IIF(PV.MaxOrderQty>=PV.MinOrderQty,1,0),
 @B,
 SYSUTCDATETIME()
FROM #ProductVendor PV LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=PV.ProductID LEFT JOIN etl_calc.Dim_Vendor V ON V.VendorID=PV.BusinessEntityID LEFT JOIN etl_calc.Dim_UnitMeasure U ON U.UnitMeasureCode=RTRIM(PV.UnitMeasureCode);
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadOperations @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #WorkOrderRouting FROM etl_raw.WorkOrderRouting;
BEGIN TRY
BEGIN TRAN;
DELETE FROM etl_calc.Fact_WorkOrderOperation;
INSERT etl_calc.Fact_WorkOrderOperation ([WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT R.WorkOrderID,
 R.OperationSequence,
 COALESCE(P.ProductKey,0),
 COALESCE(L.LocationKey,0),
 etl.DateKey(R.ScheduledStartDate),
 etl.DateKey(R.ScheduledEndDate),
 IIF(R.ActualStartDate IS NULL,-1,etl.DateKey(R.ActualStartDate)),
 IIF(R.ActualEndDate IS NULL,-1,etl.DateKey(R.ActualEndDate)),
 DATEDIFF(day,R.ScheduledStartDate,R.ScheduledEndDate),
 DATEDIFF(day,R.ActualStartDate,R.ActualEndDate),
 R.ActualResourceHrs,
 R.PlannedCost,
 R.ActualCost,
 IIF(R.OperationSequence=MAX(R.OperationSequence) OVER(PARTITION BY R.WorkOrderID),1,0),
 NULLIF(CONCAT_WS('''','''',CASE WHEN L.Availability=0 THEN ''''OPR-01'''' END,CASE WHEN R.ActualEndDate<R.ActualStartDate THEN ''''OPR-02'''' END,CASE WHEN R.ProductID<>W.ProductID THEN ''''OPR-03'''' END),''''''''),
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
FROM #WorkOrderRouting R LEFT JOIN #WorkOrder W ON W.WorkOrderID=R.WorkOrderID LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=R.ProductID LEFT JOIN etl_calc.Dim_Location L ON L.LocationID=R.LocationID;
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadInventory @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #ProductInventory FROM etl_raw.ProductInventory;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #PurchaseOrderHeader FROM etl_raw.PurchaseOrderHeader;
SELECT * INTO #SalesOrderHeader FROM etl_raw.SalesOrderHeader;
BEGIN TRY
BEGIN TRAN;
DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
IF EXISTS(SELECT 1 FROM etl_calc.Ref_ProductPriceHistory A JOIN etl_calc.Ref_ProductPriceHistory B ON A.ProductKey=B.ProductKey AND A.PriceType=B.PriceType AND A.StartDate<B.StartDate AND COALESCE(A.EndDate,''''99991231'''')>=B.StartDate) THROW 51000,''''Overlapping price history requires review.'''',1;
DELETE FROM etl_calc.Fact_InventoryOnHand;
INSERT etl_calc.Fact_InventoryOnHand ([ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(L.LocationKey,0),
 etl.DateKey(@AsOf),
 I.Shelf,
 I.Bin,
 I.Quantity,
 COALESCE(C.Amount,P.StandardCost),
 CAST(I.Quantity AS decimal(19,4))*COALESCE(C.Amount,P.StandardCost),
 IIF(I.Quantity<0,1,0),
 @B,
 SYSUTCDATETIME()
FROM #ProductInventory I LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=I.ProductID LEFT JOIN etl_calc.Dim_Location L ON L.LocationID=I.LocationID LEFT JOIN etl_calc.Ref_ProductPriceHistory C ON C.ProductKey=P.ProductKey AND C.PriceType=''''STANDARD_COST'''' AND C.StartDate<=@AsOf AND (C.EndDate IS NULL OR C.EndDate>=@AsOf);
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadWorkOrders @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''') THROW 51000,''''Batch is not RUNNING.'''',1;
SELECT * INTO #WorkOrder FROM etl_raw.WorkOrder;
SELECT * INTO #WorkOrderRouting FROM etl_raw.WorkOrderRouting;
BEGIN TRY
BEGIN TRAN;
DELETE FROM etl_calc.Fact_WorkOrder;
INSERT etl_calc.Fact_WorkOrder ([WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT W.WorkOrderID,
 COALESCE(P.ProductKey,0),
 COALESCE(S.ScrapReasonKey,0),
 etl.DateKey(W.StartDate),
 etl.DateKey(W.DueDate),
 IIF(W.EndDate IS NULL,-1,etl.DateKey(W.EndDate)),
 IIF(A.ActualStart IS NULL,-1,etl.DateKey(A.ActualStart)),
 IIF(L.ActualEndDate IS NULL,-1,etl.DateKey(L.ActualEndDate)),
 W.OrderQty,
 W.StockedQty,
 W.ScrappedQty,
 DATEDIFF(day,W.StartDate,W.DueDate),
 DATEDIFF(day,W.StartDate,W.EndDate),
 DATEDIFF(day,A.ActualStart,L.ActualEndDate),
 DATEDIFF(day,W.DueDate,L.ActualEndDate),
 COALESCE(A.OpCount,0),
 A.ResourceHrs,
 A.PlannedCost,
 A.ActualCost,
 W.StartDate,
 W.DueDate,
 W.EndDate,
 A.ActualStart,
 L.ActualEndDate,
 IIF(L.ActualEndDate IS NOT NULL,1,0),
 NULLIF(CONCAT_WS('''','''',CASE WHEN A.WorkOrderID IS NULL THEN ''''WOR-01'''' END,CASE WHEN W.ScrappedQty>0 AND W.ScrapReasonID IS NULL THEN ''''WOR-02'''' END,CASE WHEN W.ScrappedQty=0 AND W.ScrapReasonID IS NOT NULL THEN ''''WOR-03'''' END,CASE WHEN W.EndDate<W.StartDate THEN ''''WOR-04'''' END,CASE WHEN L.ActualEndDate<A.ActualStart THEN ''''WOR-05'''' END),''''''''),
 ''''DQ-v1'''',
 @B,
 SYSUTCDATETIME()
FROM #WorkOrder W LEFT JOIN (SELECT WorkOrderID,MIN(ActualStartDate) ActualStart,COUNT(*) OpCount,SUM(ActualResourceHrs) ResourceHrs,SUM(PlannedCost) PlannedCost,SUM(ActualCost) ActualCost FROM #WorkOrderRouting GROUP BY WorkOrderID) A ON A.WorkOrderID=W.WorkOrderID OUTER APPLY(SELECT TOP(1) ActualEndDate FROM #WorkOrderRouting R WHERE R.WorkOrderID=W.WorkOrderID ORDER BY OperationSequence DESC) L LEFT JOIN etl_calc.Dim_Product P ON P.ProductID=W.ProductID LEFT JOIN etl_calc.Dim_ScrapReason S ON S.ScrapReasonID=W.ScrapReasonID;
COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Calc_uspLoadDemandDaily
 @B bigint, @DemandRuleVersion nvarchar(50)=N''''DEM-v1''''
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @DemandRuleVersion IS NULL OR @DemandRuleVersion<>N''''DEM-v1''''
  THROW 51210,''''Unsupported demand rule. Implement a new rule before assigning a new version.'''',1;
 IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status=''''RUNNING'''' AND PipelineName=''''DWH_INCREMENTAL_V2'''')
  THROW 51211,''''A RUNNING DWH_FULL batch is required for historical demand.'''',1;
 DECLARE @AsOf date=(SELECT MAX(d) FROM (
  SELECT MAX(OrderDate) d FROM etl_raw.SalesOrderHeader
  UNION ALL SELECT MAX(OrderDate) FROM etl_raw.PurchaseOrderHeader
  UNION ALL SELECT MAX(StartDate) FROM etl_raw.WorkOrder) D);
 IF @AsOf IS NULL THROW 51212,''''Cannot determine the existing G03 historical cutoff.'''',1;
 BEGIN TRY
  BEGIN TRAN;
  IF EXISTS(SELECT 1 FROM etl_calc.Fact_SalesOrderLine WHERE LoadBatchID<>@B)
   OR EXISTS(SELECT 1 FROM etl_calc.Fact_WorkOrder WHERE LoadBatchID<>@B)
   OR EXISTS(SELECT 1 FROM etl_calc.Bridge_BillOfMaterials WHERE LoadBatchID<>@B)
   THROW 51213,''''Refresh the historical facts/BOM in the same batch before loading demand.'''',1;
  SELECT ProductKey,SellStartDate,
    CASE WHEN SellEndDate IS NULL OR SellEndDate<SellStartDate OR SellEndDate>@AsOf THEN @AsOf ELSE SellEndDate END AS SellWindowEnd
  INTO #Products FROM etl_calc.Dim_Product
  WHERE ProductKey>0 AND COALESCE(DQStatus,N'''''''')<>N''''EXCLUDED'''';

  -- A zero-filled history must not silently skip calendar days.
  IF EXISTS(SELECT 1 FROM #Products P WHERE P.SellStartDate<=P.SellWindowEnd AND
   (SELECT COUNT_BIG(*) FROM etl_calc.Dim_Date D WHERE D.DateKey>0 AND D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd)
   <>DATEDIFF_BIG(day,P.SellStartDate,P.SellWindowEnd)+1)
   THROW 51214,''''Dim_Date does not cover the complete product history window.'''',1;
  IF EXISTS(SELECT 1 FROM etl_calc.Fact_SalesOrderLine S JOIN #Products P ON P.ProductKey=S.ProductKey
    LEFT JOIN etl_calc.Dim_Date D ON D.DateKey=S.OrderDateKey
    WHERE D.CalendarDate IS NULL OR D.CalendarDate>@AsOf)
   THROW 51215,''''Sales dates cannot be placed in the historical demand window.'''',1;
  IF EXISTS(SELECT 1 FROM etl_calc.Fact_SalesOrderLine S JOIN #Products P ON P.ProductKey=S.ProductKey
    WHERE S.IsDemandEligible=1 AND (S.OrderQty IS NULL OR S.OrderQty<=0))
   THROW 51216,''''Eligible sales quantity violates the existing DQ contract.'''',1;
  -- Aggregate sales and BOM separately to avoid fanout multiplication.
  SELECT S.OrderDateKey AS DateKey,S.ProductKey,
   SUM(CASE WHEN S.IsDemandEligible=1 THEN CONVERT(decimal(19,4),S.OrderQty) ELSE CONVERT(decimal(19,4),0) END) AS IndependentQty,
   SUM(CASE WHEN S.IsDemandEligible=1 AND M.IsNoDiscount=0 THEN CONVERT(decimal(19,4),S.OrderQty) ELSE CONVERT(decimal(19,4),0) END) AS PromoIndependentQty,
   COUNT(CASE WHEN S.IsDemandEligible=1 THEN 1 END) AS EligibleSalesLineCount,
   COUNT(CASE WHEN COALESCE(S.IsDemandEligible,0)=0 THEN 1 END) AS ExcludedSalesLineCount
  INTO #Sales FROM etl_calc.Fact_SalesOrderLine S
  JOIN #Products P ON P.ProductKey=S.ProductKey
  LEFT JOIN etl_calc.Dim_Promotion M ON M.PromotionKey=S.PromotionKey
  GROUP BY S.OrderDateKey,S.ProductKey;

  SELECT W.StartDateKey AS DateKey,B.ComponentProductKey AS ProductKey,W.WorkOrderID,
   CONVERT(decimal(19,4),W.OrderQty)*CONVERT(decimal(8,2),B.PerAssemblyQty) AS Qty
  INTO #Requirements
  FROM etl_calc.Fact_WorkOrder W JOIN #Products A ON A.ProductKey=W.ProductKey
  JOIN etl_calc.Bridge_BillOfMaterials B ON B.AssemblyProductKey=W.ProductKey
  JOIN #Products C ON C.ProductKey=B.ComponentProductKey
  WHERE B.IsStructureValid=1 AND B.StartDate<=W.StartAt
    AND (B.EndDate IS NULL OR B.EndDate>W.StartAt);
  IF EXISTS(SELECT 1 FROM #Requirements R LEFT JOIN etl_calc.Dim_Date D ON D.DateKey=R.DateKey
    WHERE R.Qty IS NULL OR R.Qty<0 OR D.CalendarDate IS NULL OR D.CalendarDate>@AsOf)
   THROW 51217,''''Historical BOM demand has invalid quantity or date; no silent zero substitution.'''',1;
  SELECT DateKey,ProductKey,SUM(Qty) AS DependentQty,COUNT(DISTINCT WorkOrderID) AS ParentWorkOrderCount
  INTO #Dependent FROM #Requirements GROUP BY DateKey,ProductKey;

  SELECT D.DateKey,P.ProductKey INTO #Grid
  FROM #Products P JOIN etl_calc.Dim_Date D ON D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd
  WHERE D.DateKey>0 AND D.CalendarDate<=@AsOf
  UNION SELECT DateKey,ProductKey FROM #Sales
  UNION SELECT DateKey,ProductKey FROM #Dependent;

  DELETE etl_calc.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion;
  INSERT etl_calc.Fact_DemandDaily(DateKey,ProductKey,DemandRuleVersion,IndependentQty,PromoIndependentQty,
    DependentQty,TotalDemandQty,EligibleSalesLineCount,ExcludedSalesLineCount,ParentWorkOrderCount,IsInSellWindow,LoadBatchID,LoadedAt)
  SELECT G.DateKey,G.ProductKey,@DemandRuleVersion,COALESCE(S.IndependentQty,0),COALESCE(S.PromoIndependentQty,0),
    COALESCE(R.DependentQty,0),COALESCE(S.IndependentQty,0)+COALESCE(R.DependentQty,0),
    COALESCE(S.EligibleSalesLineCount,0),COALESCE(S.ExcludedSalesLineCount,0),COALESCE(R.ParentWorkOrderCount,0),
    CONVERT(bit,CASE WHEN D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd THEN 1 ELSE 0 END),@B,SYSUTCDATETIME()
  FROM #Grid G JOIN #Products P ON P.ProductKey=G.ProductKey JOIN etl_calc.Dim_Date D ON D.DateKey=G.DateKey
  LEFT JOIN #Sales S ON S.DateKey=G.DateKey AND S.ProductKey=G.ProductKey
  LEFT JOIN #Dependent R ON R.DateKey=G.DateKey AND R.ProductKey=G.ProductKey;
  IF (SELECT COUNT_BIG(*) FROM #Grid)<>(SELECT COUNT_BIG(*) FROM etl_calc.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion)
    OR COALESCE((SELECT SUM(IndependentQty) FROM #Sales),0)<>COALESCE((SELECT SUM(IndependentQty) FROM etl_calc.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion),0)
    OR COALESCE((SELECT SUM(DependentQty) FROM #Dependent),0)<>COALESCE((SELECT SUM(DependentQty) FROM etl_calc.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion),0)
   THROW 51218,''''Daily demand reconciliation failed.'''',1;
  COMMIT;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Capture @B bigint,@Previous bigint,@Next bigint AS BEGIN SET NOCOUNT ON;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[BillOfMaterials]([BillOfMaterialsID],[ProductAssemblyID],[ComponentID],[StartDate],[EndDate],[UnitMeasureCode],[BOMLevel],[PerAssemblyQty],[ModifiedDate],LoadBatchID) SELECT S.[BillOfMaterialsID],S.[ProductAssemblyID],S.[ComponentID],S.[StartDate],S.[EndDate],S.[UnitMeasureCode],S.[BOMLevel],S.[PerAssemblyQty],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[BillOfMaterials] S;
INSERT stg.[BillOfMaterials]([BillOfMaterialsID],[ProductAssemblyID],[ComponentID],[StartDate],[EndDate],[UnitMeasureCode],[BOMLevel],[PerAssemblyQty],[ModifiedDate],LoadBatchID) SELECT [BillOfMaterialsID],[ProductAssemblyID],[ComponentID],[StartDate],[EndDate],[UnitMeasureCode],[BOMLevel],[PerAssemblyQty],[ModifiedDate],@B FROM etl_raw.[BillOfMaterials];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.BillOfMaterials'''',''''I'''',@Next,(SELECT R.[BillOfMaterialsID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[BillOfMaterials] R;
END ELSE BEGIN
CREATE TABLE #CT_BillOfMaterials([BillOfMaterialsID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_BillOfMaterials EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[BillOfMaterialsID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.BillOfMaterials,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.BillOfMaterials'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[BillOfMaterialsID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_BillOfMaterials C LEFT JOIN etl_raw.[BillOfMaterials] R ON R.[BillOfMaterialsID]=C.[BillOfMaterialsID];
DELETE R FROM etl_raw.[BillOfMaterials] R JOIN #CT_BillOfMaterials C ON R.[BillOfMaterialsID]=C.[BillOfMaterialsID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[ProductAssemblyID]=S.[ProductAssemblyID],R.[ComponentID]=S.[ComponentID],R.[StartDate]=S.[StartDate],R.[EndDate]=S.[EndDate],R.[UnitMeasureCode]=S.[UnitMeasureCode],R.[BOMLevel]=S.[BOMLevel],R.[PerAssemblyQty]=S.[PerAssemblyQty],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[BillOfMaterials] R JOIN #CT_BillOfMaterials C ON R.[BillOfMaterialsID]=C.[BillOfMaterialsID] JOIN [__SOURCE_DB__].[Production].[BillOfMaterials] S ON S.[BillOfMaterialsID]=C.[BillOfMaterialsID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[BillOfMaterials]([BillOfMaterialsID],[ProductAssemblyID],[ComponentID],[StartDate],[EndDate],[UnitMeasureCode],[BOMLevel],[PerAssemblyQty],[ModifiedDate],LoadBatchID) SELECT S.[BillOfMaterialsID],S.[ProductAssemblyID],S.[ComponentID],S.[StartDate],S.[EndDate],S.[UnitMeasureCode],S.[BOMLevel],S.[PerAssemblyQty],S.[ModifiedDate],@B FROM #CT_BillOfMaterials C JOIN [__SOURCE_DB__].[Production].[BillOfMaterials] S ON S.[BillOfMaterialsID]=C.[BillOfMaterialsID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[BillOfMaterials] R WHERE R.[BillOfMaterialsID]=S.[BillOfMaterialsID]);
INSERT stg.[BillOfMaterials]([BillOfMaterialsID],[ProductAssemblyID],[ComponentID],[StartDate],[EndDate],[UnitMeasureCode],[BOMLevel],[PerAssemblyQty],[ModifiedDate],LoadBatchID) SELECT R.[BillOfMaterialsID],R.[ProductAssemblyID],R.[ComponentID],R.[StartDate],R.[EndDate],R.[UnitMeasureCode],R.[BOMLevel],R.[PerAssemblyQty],R.[ModifiedDate],@B FROM etl_raw.[BillOfMaterials] R JOIN #CT_BillOfMaterials C ON R.[BillOfMaterialsID]=C.[BillOfMaterialsID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT S.[LocationID],S.[Name],S.[CostRate],S.[Availability],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[Location] S;
INSERT stg.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT [LocationID],[Name],[CostRate],[Availability],[ModifiedDate],@B FROM etl_raw.[Location];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.Location'''',''''I'''',@Next,(SELECT R.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[Location] R;
END ELSE BEGIN
CREATE TABLE #CT_Location([LocationID] smallint NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_Location EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[LocationID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.Location,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.Location'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_Location C LEFT JOIN etl_raw.[Location] R ON R.[LocationID]=C.[LocationID];
DELETE R FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Name]=S.[Name],R.[CostRate]=S.[CostRate],R.[Availability]=S.[Availability],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] JOIN [__SOURCE_DB__].[Production].[Location] S ON S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT S.[LocationID],S.[Name],S.[CostRate],S.[Availability],S.[ModifiedDate],@B FROM #CT_Location C JOIN [__SOURCE_DB__].[Production].[Location] S ON S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[Location] R WHERE R.[LocationID]=S.[LocationID]);
INSERT stg.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT R.[LocationID],R.[Name],R.[CostRate],R.[Availability],R.[ModifiedDate],@B FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[Product]([ProductID],[Name],[ProductNumber],[MakeFlag],[FinishedGoodsFlag],[Color],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[Size],[SizeUnitMeasureCode],[WeightUnitMeasureCode],[Weight],[DaysToManufacture],[ProductLine],[Class],[Style],[ProductSubcategoryID],[ProductModelID],[SellStartDate],[SellEndDate],[DiscontinuedDate],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[Name],S.[ProductNumber],S.[MakeFlag],S.[FinishedGoodsFlag],S.[Color],S.[SafetyStockLevel],S.[ReorderPoint],S.[StandardCost],S.[ListPrice],S.[Size],S.[SizeUnitMeasureCode],S.[WeightUnitMeasureCode],S.[Weight],S.[DaysToManufacture],S.[ProductLine],S.[Class],S.[Style],S.[ProductSubcategoryID],S.[ProductModelID],S.[SellStartDate],S.[SellEndDate],S.[DiscontinuedDate],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[Product] S;
INSERT stg.[Product]([ProductID],[Name],[ProductNumber],[MakeFlag],[FinishedGoodsFlag],[Color],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[Size],[SizeUnitMeasureCode],[WeightUnitMeasureCode],[Weight],[DaysToManufacture],[ProductLine],[Class],[Style],[ProductSubcategoryID],[ProductModelID],[SellStartDate],[SellEndDate],[DiscontinuedDate],[rowguid],[ModifiedDate],LoadBatchID) SELECT [ProductID],[Name],[ProductNumber],[MakeFlag],[FinishedGoodsFlag],[Color],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[Size],[SizeUnitMeasureCode],[WeightUnitMeasureCode],[Weight],[DaysToManufacture],[ProductLine],[Class],[Style],[ProductSubcategoryID],[ProductModelID],[SellStartDate],[SellEndDate],[DiscontinuedDate],[rowguid],[ModifiedDate],@B FROM etl_raw.[Product];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.Product'''',''''I'''',@Next,(SELECT R.[ProductID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[Product] R;
END ELSE BEGIN
CREATE TABLE #CT_Product([ProductID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_Product EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.Product,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.Product'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_Product C LEFT JOIN etl_raw.[Product] R ON R.[ProductID]=C.[ProductID];
DELETE R FROM etl_raw.[Product] R JOIN #CT_Product C ON R.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Name]=S.[Name],R.[ProductNumber]=S.[ProductNumber],R.[MakeFlag]=S.[MakeFlag],R.[FinishedGoodsFlag]=S.[FinishedGoodsFlag],R.[Color]=S.[Color],R.[SafetyStockLevel]=S.[SafetyStockLevel],R.[ReorderPoint]=S.[ReorderPoint],R.[StandardCost]=S.[StandardCost],R.[ListPrice]=S.[ListPrice],R.[Size]=S.[Size],R.[SizeUnitMeasureCode]=S.[SizeUnitMeasureCode],R.[WeightUnitMeasureCode]=S.[WeightUnitMeasureCode],R.[Weight]=S.[Weight],R.[DaysToManufacture]=S.[DaysToManufacture],R.[ProductLine]=S.[ProductLine],R.[Class]=S.[Class],R.[Style]=S.[Style],R.[ProductSubcategoryID]=S.[ProductSubcategoryID],R.[ProductModelID]=S.[ProductModelID],R.[SellStartDate]=S.[SellStartDate],R.[SellEndDate]=S.[SellEndDate],R.[DiscontinuedDate]=S.[DiscontinuedDate],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[Product] R JOIN #CT_Product C ON R.[ProductID]=C.[ProductID] JOIN [__SOURCE_DB__].[Production].[Product] S ON S.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[Product]([ProductID],[Name],[ProductNumber],[MakeFlag],[FinishedGoodsFlag],[Color],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[Size],[SizeUnitMeasureCode],[WeightUnitMeasureCode],[Weight],[DaysToManufacture],[ProductLine],[Class],[Style],[ProductSubcategoryID],[ProductModelID],[SellStartDate],[SellEndDate],[DiscontinuedDate],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[Name],S.[ProductNumber],S.[MakeFlag],S.[FinishedGoodsFlag],S.[Color],S.[SafetyStockLevel],S.[ReorderPoint],S.[StandardCost],S.[ListPrice],S.[Size],S.[SizeUnitMeasureCode],S.[WeightUnitMeasureCode],S.[Weight],S.[DaysToManufacture],S.[ProductLine],S.[Class],S.[Style],S.[ProductSubcategoryID],S.[ProductModelID],S.[SellStartDate],S.[SellEndDate],S.[DiscontinuedDate],S.[rowguid],S.[ModifiedDate],@B FROM #CT_Product C JOIN [__SOURCE_DB__].[Production].[Product] S ON S.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[Product] R WHERE R.[ProductID]=S.[ProductID]);
INSERT stg.[Product]([ProductID],[Name],[ProductNumber],[MakeFlag],[FinishedGoodsFlag],[Color],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[Size],[SizeUnitMeasureCode],[WeightUnitMeasureCode],[Weight],[DaysToManufacture],[ProductLine],[Class],[Style],[ProductSubcategoryID],[ProductModelID],[SellStartDate],[SellEndDate],[DiscontinuedDate],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[ProductID],R.[Name],R.[ProductNumber],R.[MakeFlag],R.[FinishedGoodsFlag],R.[Color],R.[SafetyStockLevel],R.[ReorderPoint],R.[StandardCost],R.[ListPrice],R.[Size],R.[SizeUnitMeasureCode],R.[WeightUnitMeasureCode],R.[Weight],R.[DaysToManufacture],R.[ProductLine],R.[Class],R.[Style],R.[ProductSubcategoryID],R.[ProductModelID],R.[SellStartDate],R.[SellEndDate],R.[DiscontinuedDate],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[Product] R JOIN #CT_Product C ON R.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductCategory]([ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductCategoryID],S.[Name],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ProductCategory] S;
INSERT stg.[ProductCategory]([ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT [ProductCategoryID],[Name],[rowguid],[ModifiedDate],@B FROM etl_raw.[ProductCategory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductCategory'''',''''I'''',@Next,(SELECT R.[ProductCategoryID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductCategory] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductCategory([ProductCategoryID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductCategory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductCategoryID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ProductCategory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductCategory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductCategoryID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductCategory C LEFT JOIN etl_raw.[ProductCategory] R ON R.[ProductCategoryID]=C.[ProductCategoryID];
DELETE R FROM etl_raw.[ProductCategory] R JOIN #CT_ProductCategory C ON R.[ProductCategoryID]=C.[ProductCategoryID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Name]=S.[Name],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductCategory] R JOIN #CT_ProductCategory C ON R.[ProductCategoryID]=C.[ProductCategoryID] JOIN [__SOURCE_DB__].[Production].[ProductCategory] S ON S.[ProductCategoryID]=C.[ProductCategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductCategory]([ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductCategoryID],S.[Name],S.[rowguid],S.[ModifiedDate],@B FROM #CT_ProductCategory C JOIN [__SOURCE_DB__].[Production].[ProductCategory] S ON S.[ProductCategoryID]=C.[ProductCategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductCategory] R WHERE R.[ProductCategoryID]=S.[ProductCategoryID]);
INSERT stg.[ProductCategory]([ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[ProductCategoryID],R.[Name],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[ProductCategory] R JOIN #CT_ProductCategory C ON R.[ProductCategoryID]=C.[ProductCategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductCostHistory]([ProductID],[StartDate],[EndDate],[StandardCost],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[StartDate],S.[EndDate],S.[StandardCost],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ProductCostHistory] S;
INSERT stg.[ProductCostHistory]([ProductID],[StartDate],[EndDate],[StandardCost],[ModifiedDate],LoadBatchID) SELECT [ProductID],[StartDate],[EndDate],[StandardCost],[ModifiedDate],@B FROM etl_raw.[ProductCostHistory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductCostHistory'''',''''I'''',@Next,(SELECT R.[ProductID],R.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductCostHistory] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductCostHistory([ProductID] int NOT NULL,[StartDate] datetime NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductCostHistory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductID],C.[StartDate],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ProductCostHistory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductCostHistory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductID],C.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductCostHistory C LEFT JOIN etl_raw.[ProductCostHistory] R ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate];
DELETE R FROM etl_raw.[ProductCostHistory] R JOIN #CT_ProductCostHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[EndDate]=S.[EndDate],R.[StandardCost]=S.[StandardCost],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductCostHistory] R JOIN #CT_ProductCostHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] JOIN [__SOURCE_DB__].[Production].[ProductCostHistory] S ON S.[ProductID]=C.[ProductID] AND S.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductCostHistory]([ProductID],[StartDate],[EndDate],[StandardCost],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[StartDate],S.[EndDate],S.[StandardCost],S.[ModifiedDate],@B FROM #CT_ProductCostHistory C JOIN [__SOURCE_DB__].[Production].[ProductCostHistory] S ON S.[ProductID]=C.[ProductID] AND S.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductCostHistory] R WHERE R.[ProductID]=S.[ProductID] AND R.[StartDate]=S.[StartDate]);
INSERT stg.[ProductCostHistory]([ProductID],[StartDate],[EndDate],[StandardCost],[ModifiedDate],LoadBatchID) SELECT R.[ProductID],R.[StartDate],R.[EndDate],R.[StandardCost],R.[ModifiedDate],@B FROM etl_raw.[ProductCostHistory] R JOIN #CT_ProductCostHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductInventory]([ProductID],[LocationID],[Shelf],[Bin],[Quantity],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[LocationID],S.[Shelf],S.[Bin],S.[Quantity],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ProductInventory] S;
INSERT stg.[ProductInventory]([ProductID],[LocationID],[Shelf],[Bin],[Quantity],[rowguid],[ModifiedDate],LoadBatchID) SELECT [ProductID],[LocationID],[Shelf],[Bin],[Quantity],[rowguid],[ModifiedDate],@B FROM etl_raw.[ProductInventory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductInventory'''',''''I'''',@Next,(SELECT R.[ProductID],R.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductInventory] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductInventory([ProductID] int NOT NULL,[LocationID] smallint NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductInventory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductID],C.[LocationID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ProductInventory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductInventory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductID],C.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductInventory C LEFT JOIN etl_raw.[ProductInventory] R ON R.[ProductID]=C.[ProductID] AND R.[LocationID]=C.[LocationID];
DELETE R FROM etl_raw.[ProductInventory] R JOIN #CT_ProductInventory C ON R.[ProductID]=C.[ProductID] AND R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Shelf]=S.[Shelf],R.[Bin]=S.[Bin],R.[Quantity]=S.[Quantity],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductInventory] R JOIN #CT_ProductInventory C ON R.[ProductID]=C.[ProductID] AND R.[LocationID]=C.[LocationID] JOIN [__SOURCE_DB__].[Production].[ProductInventory] S ON S.[ProductID]=C.[ProductID] AND S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductInventory]([ProductID],[LocationID],[Shelf],[Bin],[Quantity],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[LocationID],S.[Shelf],S.[Bin],S.[Quantity],S.[rowguid],S.[ModifiedDate],@B FROM #CT_ProductInventory C JOIN [__SOURCE_DB__].[Production].[ProductInventory] S ON S.[ProductID]=C.[ProductID] AND S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductInventory] R WHERE R.[ProductID]=S.[ProductID] AND R.[LocationID]=S.[LocationID]);
INSERT stg.[ProductInventory]([ProductID],[LocationID],[Shelf],[Bin],[Quantity],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[ProductID],R.[LocationID],R.[Shelf],R.[Bin],R.[Quantity],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[ProductInventory] R JOIN #CT_ProductInventory C ON R.[ProductID]=C.[ProductID] AND R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductListPriceHistory]([ProductID],[StartDate],[EndDate],[ListPrice],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[StartDate],S.[EndDate],S.[ListPrice],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ProductListPriceHistory] S;
INSERT stg.[ProductListPriceHistory]([ProductID],[StartDate],[EndDate],[ListPrice],[ModifiedDate],LoadBatchID) SELECT [ProductID],[StartDate],[EndDate],[ListPrice],[ModifiedDate],@B FROM etl_raw.[ProductListPriceHistory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductListPriceHistory'''',''''I'''',@Next,(SELECT R.[ProductID],R.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductListPriceHistory] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductListPriceHistory([ProductID] int NOT NULL,[StartDate] datetime NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductListPriceHistory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductID],C.[StartDate],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ProductListPriceHistory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductListPriceHistory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductID],C.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductListPriceHistory C LEFT JOIN etl_raw.[ProductListPriceHistory] R ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate];
DELETE R FROM etl_raw.[ProductListPriceHistory] R JOIN #CT_ProductListPriceHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[EndDate]=S.[EndDate],R.[ListPrice]=S.[ListPrice],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductListPriceHistory] R JOIN #CT_ProductListPriceHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] JOIN [__SOURCE_DB__].[Production].[ProductListPriceHistory] S ON S.[ProductID]=C.[ProductID] AND S.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductListPriceHistory]([ProductID],[StartDate],[EndDate],[ListPrice],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[StartDate],S.[EndDate],S.[ListPrice],S.[ModifiedDate],@B FROM #CT_ProductListPriceHistory C JOIN [__SOURCE_DB__].[Production].[ProductListPriceHistory] S ON S.[ProductID]=C.[ProductID] AND S.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductListPriceHistory] R WHERE R.[ProductID]=S.[ProductID] AND R.[StartDate]=S.[StartDate]);
INSERT stg.[ProductListPriceHistory]([ProductID],[StartDate],[EndDate],[ListPrice],[ModifiedDate],LoadBatchID) SELECT R.[ProductID],R.[StartDate],R.[EndDate],R.[ListPrice],R.[ModifiedDate],@B FROM etl_raw.[ProductListPriceHistory] R JOIN #CT_ProductListPriceHistory C ON R.[ProductID]=C.[ProductID] AND R.[StartDate]=C.[StartDate] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductSubcategory]([ProductSubcategoryID],[ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductSubcategoryID],S.[ProductCategoryID],S.[Name],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ProductSubcategory] S;
INSERT stg.[ProductSubcategory]([ProductSubcategoryID],[ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT [ProductSubcategoryID],[ProductCategoryID],[Name],[rowguid],[ModifiedDate],@B FROM etl_raw.[ProductSubcategory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductSubcategory'''',''''I'''',@Next,(SELECT R.[ProductSubcategoryID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductSubcategory] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductSubcategory([ProductSubcategoryID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductSubcategory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductSubcategoryID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ProductSubcategory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ProductSubcategory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductSubcategoryID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductSubcategory C LEFT JOIN etl_raw.[ProductSubcategory] R ON R.[ProductSubcategoryID]=C.[ProductSubcategoryID];
DELETE R FROM etl_raw.[ProductSubcategory] R JOIN #CT_ProductSubcategory C ON R.[ProductSubcategoryID]=C.[ProductSubcategoryID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[ProductCategoryID]=S.[ProductCategoryID],R.[Name]=S.[Name],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductSubcategory] R JOIN #CT_ProductSubcategory C ON R.[ProductSubcategoryID]=C.[ProductSubcategoryID] JOIN [__SOURCE_DB__].[Production].[ProductSubcategory] S ON S.[ProductSubcategoryID]=C.[ProductSubcategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductSubcategory]([ProductSubcategoryID],[ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[ProductSubcategoryID],S.[ProductCategoryID],S.[Name],S.[rowguid],S.[ModifiedDate],@B FROM #CT_ProductSubcategory C JOIN [__SOURCE_DB__].[Production].[ProductSubcategory] S ON S.[ProductSubcategoryID]=C.[ProductSubcategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductSubcategory] R WHERE R.[ProductSubcategoryID]=S.[ProductSubcategoryID]);
INSERT stg.[ProductSubcategory]([ProductSubcategoryID],[ProductCategoryID],[Name],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[ProductSubcategoryID],R.[ProductCategoryID],R.[Name],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[ProductSubcategory] R JOIN #CT_ProductSubcategory C ON R.[ProductSubcategoryID]=C.[ProductSubcategoryID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT S.[ScrapReasonID],S.[Name],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[ScrapReason] S;
INSERT stg.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT [ScrapReasonID],[Name],[ModifiedDate],@B FROM etl_raw.[ScrapReason];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ScrapReason'''',''''I'''',@Next,(SELECT R.[ScrapReasonID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ScrapReason] R;
END ELSE BEGIN
CREATE TABLE #CT_ScrapReason([ScrapReasonID] smallint NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ScrapReason EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ScrapReasonID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.ScrapReason,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.ScrapReason'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ScrapReasonID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ScrapReason C LEFT JOIN etl_raw.[ScrapReason] R ON R.[ScrapReasonID]=C.[ScrapReasonID];
DELETE R FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Name]=S.[Name],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] JOIN [__SOURCE_DB__].[Production].[ScrapReason] S ON S.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT S.[ScrapReasonID],S.[Name],S.[ModifiedDate],@B FROM #CT_ScrapReason C JOIN [__SOURCE_DB__].[Production].[ScrapReason] S ON S.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ScrapReason] R WHERE R.[ScrapReasonID]=S.[ScrapReasonID]);
INSERT stg.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT R.[ScrapReasonID],R.[Name],R.[ModifiedDate],@B FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[TransactionHistory]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[TransactionID],S.[ProductID],S.[ReferenceOrderID],S.[ReferenceOrderLineID],S.[TransactionDate],S.[TransactionType],S.[Quantity],S.[ActualCost],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[TransactionHistory] S;
INSERT stg.[TransactionHistory]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT [TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],@B FROM etl_raw.[TransactionHistory];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.TransactionHistory'''',''''I'''',@Next,(SELECT R.[TransactionID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[TransactionHistory] R;
END ELSE BEGIN
CREATE TABLE #CT_TransactionHistory([TransactionID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_TransactionHistory EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[TransactionID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.TransactionHistory,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.TransactionHistory'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[TransactionID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_TransactionHistory C LEFT JOIN etl_raw.[TransactionHistory] R ON R.[TransactionID]=C.[TransactionID];
DELETE R FROM etl_raw.[TransactionHistory] R JOIN #CT_TransactionHistory C ON R.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[ProductID]=S.[ProductID],R.[ReferenceOrderID]=S.[ReferenceOrderID],R.[ReferenceOrderLineID]=S.[ReferenceOrderLineID],R.[TransactionDate]=S.[TransactionDate],R.[TransactionType]=S.[TransactionType],R.[Quantity]=S.[Quantity],R.[ActualCost]=S.[ActualCost],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[TransactionHistory] R JOIN #CT_TransactionHistory C ON R.[TransactionID]=C.[TransactionID] JOIN [__SOURCE_DB__].[Production].[TransactionHistory] S ON S.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[TransactionHistory]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[TransactionID],S.[ProductID],S.[ReferenceOrderID],S.[ReferenceOrderLineID],S.[TransactionDate],S.[TransactionType],S.[Quantity],S.[ActualCost],S.[ModifiedDate],@B FROM #CT_TransactionHistory C JOIN [__SOURCE_DB__].[Production].[TransactionHistory] S ON S.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[TransactionHistory] R WHERE R.[TransactionID]=S.[TransactionID]);
INSERT stg.[TransactionHistory]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT R.[TransactionID],R.[ProductID],R.[ReferenceOrderID],R.[ReferenceOrderLineID],R.[TransactionDate],R.[TransactionType],R.[Quantity],R.[ActualCost],R.[ModifiedDate],@B FROM etl_raw.[TransactionHistory] R JOIN #CT_TransactionHistory C ON R.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[TransactionHistoryArchive]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[TransactionID],S.[ProductID],S.[ReferenceOrderID],S.[ReferenceOrderLineID],S.[TransactionDate],S.[TransactionType],S.[Quantity],S.[ActualCost],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[TransactionHistoryArchive] S;
INSERT stg.[TransactionHistoryArchive]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT [TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],@B FROM etl_raw.[TransactionHistoryArchive];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.TransactionHistoryArchive'''',''''I'''',@Next,(SELECT R.[TransactionID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[TransactionHistoryArchive] R;
END ELSE BEGIN
CREATE TABLE #CT_TransactionHistoryArchive([TransactionID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_TransactionHistoryArchive EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[TransactionID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.TransactionHistoryArchive,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.TransactionHistoryArchive'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[TransactionID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_TransactionHistoryArchive C LEFT JOIN etl_raw.[TransactionHistoryArchive] R ON R.[TransactionID]=C.[TransactionID];
DELETE R FROM etl_raw.[TransactionHistoryArchive] R JOIN #CT_TransactionHistoryArchive C ON R.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[ProductID]=S.[ProductID],R.[ReferenceOrderID]=S.[ReferenceOrderID],R.[ReferenceOrderLineID]=S.[ReferenceOrderLineID],R.[TransactionDate]=S.[TransactionDate],R.[TransactionType]=S.[TransactionType],R.[Quantity]=S.[Quantity],R.[ActualCost]=S.[ActualCost],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[TransactionHistoryArchive] R JOIN #CT_TransactionHistoryArchive C ON R.[TransactionID]=C.[TransactionID] JOIN [__SOURCE_DB__].[Production].[TransactionHistoryArchive] S ON S.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[TransactionHistoryArchive]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[TransactionID],S.[ProductID],S.[ReferenceOrderID],S.[ReferenceOrderLineID],S.[TransactionDate],S.[TransactionType],S.[Quantity],S.[ActualCost],S.[ModifiedDate],@B FROM #CT_TransactionHistoryArchive C JOIN [__SOURCE_DB__].[Production].[TransactionHistoryArchive] S ON S.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[TransactionHistoryArchive] R WHERE R.[TransactionID]=S.[TransactionID]);
INSERT stg.[TransactionHistoryArchive]([TransactionID],[ProductID],[ReferenceOrderID],[ReferenceOrderLineID],[TransactionDate],[TransactionType],[Quantity],[ActualCost],[ModifiedDate],LoadBatchID) SELECT R.[TransactionID],R.[ProductID],R.[ReferenceOrderID],R.[ReferenceOrderLineID],R.[TransactionDate],R.[TransactionType],R.[Quantity],R.[ActualCost],R.[ModifiedDate],@B FROM etl_raw.[TransactionHistoryArchive] R JOIN #CT_TransactionHistoryArchive C ON R.[TransactionID]=C.[TransactionID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT S.[UnitMeasureCode],S.[Name],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[UnitMeasure] S;
INSERT stg.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT [UnitMeasureCode],[Name],[ModifiedDate],@B FROM etl_raw.[UnitMeasure];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.UnitMeasure'''',''''I'''',@Next,(SELECT R.[UnitMeasureCode] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[UnitMeasure] R;
END ELSE BEGIN
CREATE TABLE #CT_UnitMeasure([UnitMeasureCode] nchar(3) NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_UnitMeasure EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[UnitMeasureCode],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.UnitMeasure,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.UnitMeasure'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[UnitMeasureCode] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_UnitMeasure C LEFT JOIN etl_raw.[UnitMeasure] R ON R.[UnitMeasureCode]=C.[UnitMeasureCode];
DELETE R FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Name]=S.[Name],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] JOIN [__SOURCE_DB__].[Production].[UnitMeasure] S ON S.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT S.[UnitMeasureCode],S.[Name],S.[ModifiedDate],@B FROM #CT_UnitMeasure C JOIN [__SOURCE_DB__].[Production].[UnitMeasure] S ON S.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[UnitMeasure] R WHERE R.[UnitMeasureCode]=S.[UnitMeasureCode]);
INSERT stg.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT R.[UnitMeasureCode],R.[Name],R.[ModifiedDate],@B FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[WorkOrder]([WorkOrderID],[ProductID],[OrderQty],[StockedQty],[ScrappedQty],[StartDate],[EndDate],[DueDate],[ScrapReasonID],[ModifiedDate],LoadBatchID) SELECT S.[WorkOrderID],S.[ProductID],S.[OrderQty],S.[StockedQty],S.[ScrappedQty],S.[StartDate],S.[EndDate],S.[DueDate],S.[ScrapReasonID],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[WorkOrder] S;
INSERT stg.[WorkOrder]([WorkOrderID],[ProductID],[OrderQty],[StockedQty],[ScrappedQty],[StartDate],[EndDate],[DueDate],[ScrapReasonID],[ModifiedDate],LoadBatchID) SELECT [WorkOrderID],[ProductID],[OrderQty],[StockedQty],[ScrappedQty],[StartDate],[EndDate],[DueDate],[ScrapReasonID],[ModifiedDate],@B FROM etl_raw.[WorkOrder];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.WorkOrder'''',''''I'''',@Next,(SELECT R.[WorkOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[WorkOrder] R;
END ELSE BEGIN
CREATE TABLE #CT_WorkOrder([WorkOrderID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_WorkOrder EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[WorkOrderID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.WorkOrder,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.WorkOrder'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[WorkOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_WorkOrder C LEFT JOIN etl_raw.[WorkOrder] R ON R.[WorkOrderID]=C.[WorkOrderID];
DELETE R FROM etl_raw.[WorkOrder] R JOIN #CT_WorkOrder C ON R.[WorkOrderID]=C.[WorkOrderID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[ProductID]=S.[ProductID],R.[OrderQty]=S.[OrderQty],R.[StockedQty]=S.[StockedQty],R.[ScrappedQty]=S.[ScrappedQty],R.[StartDate]=S.[StartDate],R.[EndDate]=S.[EndDate],R.[DueDate]=S.[DueDate],R.[ScrapReasonID]=S.[ScrapReasonID],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[WorkOrder] R JOIN #CT_WorkOrder C ON R.[WorkOrderID]=C.[WorkOrderID] JOIN [__SOURCE_DB__].[Production].[WorkOrder] S ON S.[WorkOrderID]=C.[WorkOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[WorkOrder]([WorkOrderID],[ProductID],[OrderQty],[StockedQty],[ScrappedQty],[StartDate],[EndDate],[DueDate],[ScrapReasonID],[ModifiedDate],LoadBatchID) SELECT S.[WorkOrderID],S.[ProductID],S.[OrderQty],S.[StockedQty],S.[ScrappedQty],S.[StartDate],S.[EndDate],S.[DueDate],S.[ScrapReasonID],S.[ModifiedDate],@B FROM #CT_WorkOrder C JOIN [__SOURCE_DB__].[Production].[WorkOrder] S ON S.[WorkOrderID]=C.[WorkOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[WorkOrder] R WHERE R.[WorkOrderID]=S.[WorkOrderID]);
INSERT stg.[WorkOrder]([WorkOrderID],[ProductID],[OrderQty],[StockedQty],[ScrappedQty],[StartDate],[EndDate],[DueDate],[ScrapReasonID],[ModifiedDate],LoadBatchID) SELECT R.[WorkOrderID],R.[ProductID],R.[OrderQty],R.[StockedQty],R.[ScrappedQty],R.[StartDate],R.[EndDate],R.[DueDate],R.[ScrapReasonID],R.[ModifiedDate],@B FROM etl_raw.[WorkOrder] R JOIN #CT_WorkOrder C ON R.[WorkOrderID]=C.[WorkOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[WorkOrderRouting]([WorkOrderID],[ProductID],[OperationSequence],[LocationID],[ScheduledStartDate],[ScheduledEndDate],[ActualStartDate],[ActualEndDate],[ActualResourceHrs],[PlannedCost],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[WorkOrderID],S.[ProductID],S.[OperationSequence],S.[LocationID],S.[ScheduledStartDate],S.[ScheduledEndDate],S.[ActualStartDate],S.[ActualEndDate],S.[ActualResourceHrs],S.[PlannedCost],S.[ActualCost],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Production].[WorkOrderRouting] S;
INSERT stg.[WorkOrderRouting]([WorkOrderID],[ProductID],[OperationSequence],[LocationID],[ScheduledStartDate],[ScheduledEndDate],[ActualStartDate],[ActualEndDate],[ActualResourceHrs],[PlannedCost],[ActualCost],[ModifiedDate],LoadBatchID) SELECT [WorkOrderID],[ProductID],[OperationSequence],[LocationID],[ScheduledStartDate],[ScheduledEndDate],[ActualStartDate],[ActualEndDate],[ActualResourceHrs],[PlannedCost],[ActualCost],[ModifiedDate],@B FROM etl_raw.[WorkOrderRouting];
INSERT etl_v2.SourceChange SELECT @B,N''''Production.WorkOrderRouting'''',''''I'''',@Next,(SELECT R.[WorkOrderID],R.[ProductID],R.[OperationSequence] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[WorkOrderRouting] R;
END ELSE BEGIN
CREATE TABLE #CT_WorkOrderRouting([WorkOrderID] int NOT NULL,[ProductID] int NOT NULL,[OperationSequence] smallint NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_WorkOrderRouting EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[WorkOrderID],C.[ProductID],C.[OperationSequence],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Production.WorkOrderRouting,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Production.WorkOrderRouting'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[WorkOrderID],C.[ProductID],C.[OperationSequence] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_WorkOrderRouting C LEFT JOIN etl_raw.[WorkOrderRouting] R ON R.[WorkOrderID]=C.[WorkOrderID] AND R.[ProductID]=C.[ProductID] AND R.[OperationSequence]=C.[OperationSequence];
DELETE R FROM etl_raw.[WorkOrderRouting] R JOIN #CT_WorkOrderRouting C ON R.[WorkOrderID]=C.[WorkOrderID] AND R.[ProductID]=C.[ProductID] AND R.[OperationSequence]=C.[OperationSequence] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[LocationID]=S.[LocationID],R.[ScheduledStartDate]=S.[ScheduledStartDate],R.[ScheduledEndDate]=S.[ScheduledEndDate],R.[ActualStartDate]=S.[ActualStartDate],R.[ActualEndDate]=S.[ActualEndDate],R.[ActualResourceHrs]=S.[ActualResourceHrs],R.[PlannedCost]=S.[PlannedCost],R.[ActualCost]=S.[ActualCost],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[WorkOrderRouting] R JOIN #CT_WorkOrderRouting C ON R.[WorkOrderID]=C.[WorkOrderID] AND R.[ProductID]=C.[ProductID] AND R.[OperationSequence]=C.[OperationSequence] JOIN [__SOURCE_DB__].[Production].[WorkOrderRouting] S ON S.[WorkOrderID]=C.[WorkOrderID] AND S.[ProductID]=C.[ProductID] AND S.[OperationSequence]=C.[OperationSequence] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[WorkOrderRouting]([WorkOrderID],[ProductID],[OperationSequence],[LocationID],[ScheduledStartDate],[ScheduledEndDate],[ActualStartDate],[ActualEndDate],[ActualResourceHrs],[PlannedCost],[ActualCost],[ModifiedDate],LoadBatchID) SELECT S.[WorkOrderID],S.[ProductID],S.[OperationSequence],S.[LocationID],S.[ScheduledStartDate],S.[ScheduledEndDate],S.[ActualStartDate],S.[ActualEndDate],S.[ActualResourceHrs],S.[PlannedCost],S.[ActualCost],S.[ModifiedDate],@B FROM #CT_WorkOrderRouting C JOIN [__SOURCE_DB__].[Production].[WorkOrderRouting] S ON S.[WorkOrderID]=C.[WorkOrderID] AND S.[ProductID]=C.[ProductID] AND S.[OperationSequence]=C.[OperationSequence] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[WorkOrderRouting] R WHERE R.[WorkOrderID]=S.[WorkOrderID] AND R.[ProductID]=S.[ProductID] AND R.[OperationSequence]=S.[OperationSequence]);
INSERT stg.[WorkOrderRouting]([WorkOrderID],[ProductID],[OperationSequence],[LocationID],[ScheduledStartDate],[ScheduledEndDate],[ActualStartDate],[ActualEndDate],[ActualResourceHrs],[PlannedCost],[ActualCost],[ModifiedDate],LoadBatchID) SELECT R.[WorkOrderID],R.[ProductID],R.[OperationSequence],R.[LocationID],R.[ScheduledStartDate],R.[ScheduledEndDate],R.[ActualStartDate],R.[ActualEndDate],R.[ActualResourceHrs],R.[PlannedCost],R.[ActualCost],R.[ModifiedDate],@B FROM etl_raw.[WorkOrderRouting] R JOIN #CT_WorkOrderRouting C ON R.[WorkOrderID]=C.[WorkOrderID] AND R.[ProductID]=C.[ProductID] AND R.[OperationSequence]=C.[OperationSequence] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ProductVendor]([ProductID],[BusinessEntityID],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDate],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[UnitMeasureCode],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[BusinessEntityID],S.[AverageLeadTime],S.[StandardPrice],S.[LastReceiptCost],S.[LastReceiptDate],S.[MinOrderQty],S.[MaxOrderQty],S.[OnOrderQty],S.[UnitMeasureCode],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Purchasing].[ProductVendor] S;
INSERT stg.[ProductVendor]([ProductID],[BusinessEntityID],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDate],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[UnitMeasureCode],[ModifiedDate],LoadBatchID) SELECT [ProductID],[BusinessEntityID],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDate],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[UnitMeasureCode],[ModifiedDate],@B FROM etl_raw.[ProductVendor];
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.ProductVendor'''',''''I'''',@Next,(SELECT R.[ProductID],R.[BusinessEntityID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ProductVendor] R;
END ELSE BEGIN
CREATE TABLE #CT_ProductVendor([ProductID] int NOT NULL,[BusinessEntityID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_ProductVendor EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[ProductID],C.[BusinessEntityID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Purchasing.ProductVendor,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.ProductVendor'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ProductID],C.[BusinessEntityID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ProductVendor C LEFT JOIN etl_raw.[ProductVendor] R ON R.[ProductID]=C.[ProductID] AND R.[BusinessEntityID]=C.[BusinessEntityID];
DELETE R FROM etl_raw.[ProductVendor] R JOIN #CT_ProductVendor C ON R.[ProductID]=C.[ProductID] AND R.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[AverageLeadTime]=S.[AverageLeadTime],R.[StandardPrice]=S.[StandardPrice],R.[LastReceiptCost]=S.[LastReceiptCost],R.[LastReceiptDate]=S.[LastReceiptDate],R.[MinOrderQty]=S.[MinOrderQty],R.[MaxOrderQty]=S.[MaxOrderQty],R.[OnOrderQty]=S.[OnOrderQty],R.[UnitMeasureCode]=S.[UnitMeasureCode],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ProductVendor] R JOIN #CT_ProductVendor C ON R.[ProductID]=C.[ProductID] AND R.[BusinessEntityID]=C.[BusinessEntityID] JOIN [__SOURCE_DB__].[Purchasing].[ProductVendor] S ON S.[ProductID]=C.[ProductID] AND S.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[ProductVendor]([ProductID],[BusinessEntityID],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDate],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[UnitMeasureCode],[ModifiedDate],LoadBatchID) SELECT S.[ProductID],S.[BusinessEntityID],S.[AverageLeadTime],S.[StandardPrice],S.[LastReceiptCost],S.[LastReceiptDate],S.[MinOrderQty],S.[MaxOrderQty],S.[OnOrderQty],S.[UnitMeasureCode],S.[ModifiedDate],@B FROM #CT_ProductVendor C JOIN [__SOURCE_DB__].[Purchasing].[ProductVendor] S ON S.[ProductID]=C.[ProductID] AND S.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ProductVendor] R WHERE R.[ProductID]=S.[ProductID] AND R.[BusinessEntityID]=S.[BusinessEntityID]);
INSERT stg.[ProductVendor]([ProductID],[BusinessEntityID],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDate],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[UnitMeasureCode],[ModifiedDate],LoadBatchID) SELECT R.[ProductID],R.[BusinessEntityID],R.[AverageLeadTime],R.[StandardPrice],R.[LastReceiptCost],R.[LastReceiptDate],R.[MinOrderQty],R.[MaxOrderQty],R.[OnOrderQty],R.[UnitMeasureCode],R.[ModifiedDate],@B FROM etl_raw.[ProductVendor] R JOIN #CT_ProductVendor C ON R.[ProductID]=C.[ProductID] AND R.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[PurchaseOrderDetail]([PurchaseOrderID],[PurchaseOrderDetailID],[DueDate],[OrderQty],[ProductID],[UnitPrice],[LineTotal],[ReceivedQty],[RejectedQty],[StockedQty],[ModifiedDate],LoadBatchID) SELECT S.[PurchaseOrderID],S.[PurchaseOrderDetailID],S.[DueDate],S.[OrderQty],S.[ProductID],S.[UnitPrice],S.[LineTotal],S.[ReceivedQty],S.[RejectedQty],S.[StockedQty],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Purchasing].[PurchaseOrderDetail] S;
INSERT stg.[PurchaseOrderDetail]([PurchaseOrderID],[PurchaseOrderDetailID],[DueDate],[OrderQty],[ProductID],[UnitPrice],[LineTotal],[ReceivedQty],[RejectedQty],[StockedQty],[ModifiedDate],LoadBatchID) SELECT [PurchaseOrderID],[PurchaseOrderDetailID],[DueDate],[OrderQty],[ProductID],[UnitPrice],[LineTotal],[ReceivedQty],[RejectedQty],[StockedQty],[ModifiedDate],@B FROM etl_raw.[PurchaseOrderDetail];
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.PurchaseOrderDetail'''',''''I'''',@Next,(SELECT R.[PurchaseOrderID],R.[PurchaseOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[PurchaseOrderDetail] R;
END ELSE BEGIN
CREATE TABLE #CT_PurchaseOrderDetail([PurchaseOrderID] int NOT NULL,[PurchaseOrderDetailID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_PurchaseOrderDetail EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[PurchaseOrderID],C.[PurchaseOrderDetailID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Purchasing.PurchaseOrderDetail,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.PurchaseOrderDetail'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[PurchaseOrderID],C.[PurchaseOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_PurchaseOrderDetail C LEFT JOIN etl_raw.[PurchaseOrderDetail] R ON R.[PurchaseOrderID]=C.[PurchaseOrderID] AND R.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID];
DELETE R FROM etl_raw.[PurchaseOrderDetail] R JOIN #CT_PurchaseOrderDetail C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] AND R.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[DueDate]=S.[DueDate],R.[OrderQty]=S.[OrderQty],R.[ProductID]=S.[ProductID],R.[UnitPrice]=S.[UnitPrice],R.[LineTotal]=S.[LineTotal],R.[ReceivedQty]=S.[ReceivedQty],R.[RejectedQty]=S.[RejectedQty],R.[StockedQty]=S.[StockedQty],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[PurchaseOrderDetail] R JOIN #CT_PurchaseOrderDetail C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] AND R.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID] JOIN [__SOURCE_DB__].[Purchasing].[PurchaseOrderDetail] S ON S.[PurchaseOrderID]=C.[PurchaseOrderID] AND S.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[PurchaseOrderDetail]([PurchaseOrderID],[PurchaseOrderDetailID],[DueDate],[OrderQty],[ProductID],[UnitPrice],[LineTotal],[ReceivedQty],[RejectedQty],[StockedQty],[ModifiedDate],LoadBatchID) SELECT S.[PurchaseOrderID],S.[PurchaseOrderDetailID],S.[DueDate],S.[OrderQty],S.[ProductID],S.[UnitPrice],S.[LineTotal],S.[ReceivedQty],S.[RejectedQty],S.[StockedQty],S.[ModifiedDate],@B FROM #CT_PurchaseOrderDetail C JOIN [__SOURCE_DB__].[Purchasing].[PurchaseOrderDetail] S ON S.[PurchaseOrderID]=C.[PurchaseOrderID] AND S.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[PurchaseOrderDetail] R WHERE R.[PurchaseOrderID]=S.[PurchaseOrderID] AND R.[PurchaseOrderDetailID]=S.[PurchaseOrderDetailID]);
INSERT stg.[PurchaseOrderDetail]([PurchaseOrderID],[PurchaseOrderDetailID],[DueDate],[OrderQty],[ProductID],[UnitPrice],[LineTotal],[ReceivedQty],[RejectedQty],[StockedQty],[ModifiedDate],LoadBatchID) SELECT R.[PurchaseOrderID],R.[PurchaseOrderDetailID],R.[DueDate],R.[OrderQty],R.[ProductID],R.[UnitPrice],R.[LineTotal],R.[ReceivedQty],R.[RejectedQty],R.[StockedQty],R.[ModifiedDate],@B FROM etl_raw.[PurchaseOrderDetail] R JOIN #CT_PurchaseOrderDetail C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] AND R.[PurchaseOrderDetailID]=C.[PurchaseOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[PurchaseOrderHeader]([PurchaseOrderID],[RevisionNumber],[Status],[EmployeeID],[VendorID],[ShipMethodID],[OrderDate],[ShipDate],[SubTotal],[TaxAmt],[Freight],[TotalDue],[ModifiedDate],LoadBatchID) SELECT S.[PurchaseOrderID],S.[RevisionNumber],S.[Status],S.[EmployeeID],S.[VendorID],S.[ShipMethodID],S.[OrderDate],S.[ShipDate],S.[SubTotal],S.[TaxAmt],S.[Freight],S.[TotalDue],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Purchasing].[PurchaseOrderHeader] S;
INSERT stg.[PurchaseOrderHeader]([PurchaseOrderID],[RevisionNumber],[Status],[EmployeeID],[VendorID],[ShipMethodID],[OrderDate],[ShipDate],[SubTotal],[TaxAmt],[Freight],[TotalDue],[ModifiedDate],LoadBatchID) SELECT [PurchaseOrderID],[RevisionNumber],[Status],[EmployeeID],[VendorID],[ShipMethodID],[OrderDate],[ShipDate],[SubTotal],[TaxAmt],[Freight],[TotalDue],[ModifiedDate],@B FROM etl_raw.[PurchaseOrderHeader];
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.PurchaseOrderHeader'''',''''I'''',@Next,(SELECT R.[PurchaseOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[PurchaseOrderHeader] R;
END ELSE BEGIN
CREATE TABLE #CT_PurchaseOrderHeader([PurchaseOrderID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_PurchaseOrderHeader EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[PurchaseOrderID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Purchasing.PurchaseOrderHeader,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.PurchaseOrderHeader'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[PurchaseOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_PurchaseOrderHeader C LEFT JOIN etl_raw.[PurchaseOrderHeader] R ON R.[PurchaseOrderID]=C.[PurchaseOrderID];
DELETE R FROM etl_raw.[PurchaseOrderHeader] R JOIN #CT_PurchaseOrderHeader C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[RevisionNumber]=S.[RevisionNumber],R.[Status]=S.[Status],R.[EmployeeID]=S.[EmployeeID],R.[VendorID]=S.[VendorID],R.[ShipMethodID]=S.[ShipMethodID],R.[OrderDate]=S.[OrderDate],R.[ShipDate]=S.[ShipDate],R.[SubTotal]=S.[SubTotal],R.[TaxAmt]=S.[TaxAmt],R.[Freight]=S.[Freight],R.[TotalDue]=S.[TotalDue],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[PurchaseOrderHeader] R JOIN #CT_PurchaseOrderHeader C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] JOIN [__SOURCE_DB__].[Purchasing].[PurchaseOrderHeader] S ON S.[PurchaseOrderID]=C.[PurchaseOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[PurchaseOrderHeader]([PurchaseOrderID],[RevisionNumber],[Status],[EmployeeID],[VendorID],[ShipMethodID],[OrderDate],[ShipDate],[SubTotal],[TaxAmt],[Freight],[TotalDue],[ModifiedDate],LoadBatchID) SELECT S.[PurchaseOrderID],S.[RevisionNumber],S.[Status],S.[EmployeeID],S.[VendorID],S.[ShipMethodID],S.[OrderDate],S.[ShipDate],S.[SubTotal],S.[TaxAmt],S.[Freight],S.[TotalDue],S.[ModifiedDate],@B FROM #CT_PurchaseOrderHeader C JOIN [__SOURCE_DB__].[Purchasing].[PurchaseOrderHeader] S ON S.[PurchaseOrderID]=C.[PurchaseOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[PurchaseOrderHeader] R WHERE R.[PurchaseOrderID]=S.[PurchaseOrderID]);
INSERT stg.[PurchaseOrderHeader]([PurchaseOrderID],[RevisionNumber],[Status],[EmployeeID],[VendorID],[ShipMethodID],[OrderDate],[ShipDate],[SubTotal],[TaxAmt],[Freight],[TotalDue],[ModifiedDate],LoadBatchID) SELECT R.[PurchaseOrderID],R.[RevisionNumber],R.[Status],R.[EmployeeID],R.[VendorID],R.[ShipMethodID],R.[OrderDate],R.[ShipDate],R.[SubTotal],R.[TaxAmt],R.[Freight],R.[TotalDue],R.[ModifiedDate],@B FROM etl_raw.[PurchaseOrderHeader] R JOIN #CT_PurchaseOrderHeader C ON R.[PurchaseOrderID]=C.[PurchaseOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[Vendor]([BusinessEntityID],[AccountNumber],[Name],[CreditRating],[PreferredVendorStatus],[ActiveFlag],[PurchasingWebServiceURL],[ModifiedDate],LoadBatchID) SELECT S.[BusinessEntityID],S.[AccountNumber],S.[Name],S.[CreditRating],S.[PreferredVendorStatus],S.[ActiveFlag],S.[PurchasingWebServiceURL],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Purchasing].[Vendor] S;
INSERT stg.[Vendor]([BusinessEntityID],[AccountNumber],[Name],[CreditRating],[PreferredVendorStatus],[ActiveFlag],[PurchasingWebServiceURL],[ModifiedDate],LoadBatchID) SELECT [BusinessEntityID],[AccountNumber],[Name],[CreditRating],[PreferredVendorStatus],[ActiveFlag],[PurchasingWebServiceURL],[ModifiedDate],@B FROM etl_raw.[Vendor];
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.Vendor'''',''''I'''',@Next,(SELECT R.[BusinessEntityID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[Vendor] R;
END ELSE BEGIN
CREATE TABLE #CT_Vendor([BusinessEntityID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_Vendor EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[BusinessEntityID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Purchasing.Vendor,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Purchasing.Vendor'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[BusinessEntityID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_Vendor C LEFT JOIN etl_raw.[Vendor] R ON R.[BusinessEntityID]=C.[BusinessEntityID];
DELETE R FROM etl_raw.[Vendor] R JOIN #CT_Vendor C ON R.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[AccountNumber]=S.[AccountNumber],R.[Name]=S.[Name],R.[CreditRating]=S.[CreditRating],R.[PreferredVendorStatus]=S.[PreferredVendorStatus],R.[ActiveFlag]=S.[ActiveFlag],R.[PurchasingWebServiceURL]=S.[PurchasingWebServiceURL],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[Vendor] R JOIN #CT_Vendor C ON R.[BusinessEntityID]=C.[BusinessEntityID] JOIN [__SOURCE_DB__].[Purchasing].[Vendor] S ON S.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[Vendor]([BusinessEntityID],[AccountNumber],[Name],[CreditRating],[PreferredVendorStatus],[ActiveFlag],[PurchasingWebServiceURL],[ModifiedDate],LoadBatchID) SELECT S.[BusinessEntityID],S.[AccountNumber],S.[Name],S.[CreditRating],S.[PreferredVendorStatus],S.[ActiveFlag],S.[PurchasingWebServiceURL],S.[ModifiedDate],@B FROM #CT_Vendor C JOIN [__SOURCE_DB__].[Purchasing].[Vendor] S ON S.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[Vendor] R WHERE R.[BusinessEntityID]=S.[BusinessEntityID]);
INSERT stg.[Vendor]([BusinessEntityID],[AccountNumber],[Name],[CreditRating],[PreferredVendorStatus],[ActiveFlag],[PurchasingWebServiceURL],[ModifiedDate],LoadBatchID) SELECT R.[BusinessEntityID],R.[AccountNumber],R.[Name],R.[CreditRating],R.[PreferredVendorStatus],R.[ActiveFlag],R.[PurchasingWebServiceURL],R.[ModifiedDate],@B FROM etl_raw.[Vendor] R JOIN #CT_Vendor C ON R.[BusinessEntityID]=C.[BusinessEntityID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[Customer]([CustomerID],[PersonID],[StoreID],[TerritoryID],[AccountNumber],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[CustomerID],S.[PersonID],S.[StoreID],S.[TerritoryID],S.[AccountNumber],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Sales].[Customer] S;
INSERT stg.[Customer]([CustomerID],[PersonID],[StoreID],[TerritoryID],[AccountNumber],[rowguid],[ModifiedDate],LoadBatchID) SELECT [CustomerID],[PersonID],[StoreID],[TerritoryID],[AccountNumber],[rowguid],[ModifiedDate],@B FROM etl_raw.[Customer];
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.Customer'''',''''I'''',@Next,(SELECT R.[CustomerID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[Customer] R;
END ELSE BEGIN
CREATE TABLE #CT_Customer([CustomerID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_Customer EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[CustomerID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Sales.Customer,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.Customer'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[CustomerID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_Customer C LEFT JOIN etl_raw.[Customer] R ON R.[CustomerID]=C.[CustomerID];
DELETE R FROM etl_raw.[Customer] R JOIN #CT_Customer C ON R.[CustomerID]=C.[CustomerID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[PersonID]=S.[PersonID],R.[StoreID]=S.[StoreID],R.[TerritoryID]=S.[TerritoryID],R.[AccountNumber]=S.[AccountNumber],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[Customer] R JOIN #CT_Customer C ON R.[CustomerID]=C.[CustomerID] JOIN [__SOURCE_DB__].[Sales].[Customer] S ON S.[CustomerID]=C.[CustomerID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[Customer]([CustomerID],[PersonID],[StoreID],[TerritoryID],[AccountNumber],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[CustomerID],S.[PersonID],S.[StoreID],S.[TerritoryID],S.[AccountNumber],S.[rowguid],S.[ModifiedDate],@B FROM #CT_Customer C JOIN [__SOURCE_DB__].[Sales].[Customer] S ON S.[CustomerID]=C.[CustomerID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[Customer] R WHERE R.[CustomerID]=S.[CustomerID]);
INSERT stg.[Customer]([CustomerID],[PersonID],[StoreID],[TerritoryID],[AccountNumber],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[CustomerID],R.[PersonID],R.[StoreID],R.[TerritoryID],R.[AccountNumber],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[Customer] R JOIN #CT_Customer C ON R.[CustomerID]=C.[CustomerID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[SalesOrderDetail]([SalesOrderID],[SalesOrderDetailID],[CarrierTrackingNumber],[OrderQty],[ProductID],[SpecialOfferID],[UnitPrice],[UnitPriceDiscount],[LineTotal],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SalesOrderID],S.[SalesOrderDetailID],S.[CarrierTrackingNumber],S.[OrderQty],S.[ProductID],S.[SpecialOfferID],S.[UnitPrice],S.[UnitPriceDiscount],S.[LineTotal],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Sales].[SalesOrderDetail] S;
INSERT stg.[SalesOrderDetail]([SalesOrderID],[SalesOrderDetailID],[CarrierTrackingNumber],[OrderQty],[ProductID],[SpecialOfferID],[UnitPrice],[UnitPriceDiscount],[LineTotal],[rowguid],[ModifiedDate],LoadBatchID) SELECT [SalesOrderID],[SalesOrderDetailID],[CarrierTrackingNumber],[OrderQty],[ProductID],[SpecialOfferID],[UnitPrice],[UnitPriceDiscount],[LineTotal],[rowguid],[ModifiedDate],@B FROM etl_raw.[SalesOrderDetail];
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SalesOrderDetail'''',''''I'''',@Next,(SELECT R.[SalesOrderID],R.[SalesOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[SalesOrderDetail] R;
END ELSE BEGIN
CREATE TABLE #CT_SalesOrderDetail([SalesOrderID] int NOT NULL,[SalesOrderDetailID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_SalesOrderDetail EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[SalesOrderID],C.[SalesOrderDetailID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Sales.SalesOrderDetail,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SalesOrderDetail'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[SalesOrderID],C.[SalesOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_SalesOrderDetail C LEFT JOIN etl_raw.[SalesOrderDetail] R ON R.[SalesOrderID]=C.[SalesOrderID] AND R.[SalesOrderDetailID]=C.[SalesOrderDetailID];
DELETE R FROM etl_raw.[SalesOrderDetail] R JOIN #CT_SalesOrderDetail C ON R.[SalesOrderID]=C.[SalesOrderID] AND R.[SalesOrderDetailID]=C.[SalesOrderDetailID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[CarrierTrackingNumber]=S.[CarrierTrackingNumber],R.[OrderQty]=S.[OrderQty],R.[ProductID]=S.[ProductID],R.[SpecialOfferID]=S.[SpecialOfferID],R.[UnitPrice]=S.[UnitPrice],R.[UnitPriceDiscount]=S.[UnitPriceDiscount],R.[LineTotal]=S.[LineTotal],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[SalesOrderDetail] R JOIN #CT_SalesOrderDetail C ON R.[SalesOrderID]=C.[SalesOrderID] AND R.[SalesOrderDetailID]=C.[SalesOrderDetailID] JOIN [__SOURCE_DB__].[Sales].[SalesOrderDetail] S ON S.[SalesOrderID]=C.[SalesOrderID] AND S.[SalesOrderDetailID]=C.[SalesOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[SalesOrderDetail]([SalesOrderID],[SalesOrderDetailID],[CarrierTrackingNumber],[OrderQty],[ProductID],[SpecialOfferID],[UnitPrice],[UnitPriceDiscount],[LineTotal],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SalesOrderID],S.[SalesOrderDetailID],S.[CarrierTrackingNumber],S.[OrderQty],S.[ProductID],S.[SpecialOfferID],S.[UnitPrice],S.[UnitPriceDiscount],S.[LineTotal],S.[rowguid],S.[ModifiedDate],@B FROM #CT_SalesOrderDetail C JOIN [__SOURCE_DB__].[Sales].[SalesOrderDetail] S ON S.[SalesOrderID]=C.[SalesOrderID] AND S.[SalesOrderDetailID]=C.[SalesOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[SalesOrderDetail] R WHERE R.[SalesOrderID]=S.[SalesOrderID] AND R.[SalesOrderDetailID]=S.[SalesOrderDetailID]);
INSERT stg.[SalesOrderDetail]([SalesOrderID],[SalesOrderDetailID],[CarrierTrackingNumber],[OrderQty],[ProductID],[SpecialOfferID],[UnitPrice],[UnitPriceDiscount],[LineTotal],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[SalesOrderID],R.[SalesOrderDetailID],R.[CarrierTrackingNumber],R.[OrderQty],R.[ProductID],R.[SpecialOfferID],R.[UnitPrice],R.[UnitPriceDiscount],R.[LineTotal],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[SalesOrderDetail] R JOIN #CT_SalesOrderDetail C ON R.[SalesOrderID]=C.[SalesOrderID] AND R.[SalesOrderDetailID]=C.[SalesOrderDetailID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[SalesOrderHeader]([SalesOrderID],[RevisionNumber],[OrderDate],[DueDate],[ShipDate],[Status],[OnlineOrderFlag],[SalesOrderNumber],[PurchaseOrderNumber],[AccountNumber],[CustomerID],[SalesPersonID],[TerritoryID],[BillToAddressID],[ShipToAddressID],[ShipMethodID],[CreditCardID],[CreditCardApprovalCode],[CurrencyRateID],[SubTotal],[TaxAmt],[Freight],[TotalDue],[Comment],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SalesOrderID],S.[RevisionNumber],S.[OrderDate],S.[DueDate],S.[ShipDate],S.[Status],S.[OnlineOrderFlag],S.[SalesOrderNumber],S.[PurchaseOrderNumber],S.[AccountNumber],S.[CustomerID],S.[SalesPersonID],S.[TerritoryID],S.[BillToAddressID],S.[ShipToAddressID],S.[ShipMethodID],S.[CreditCardID],S.[CreditCardApprovalCode],S.[CurrencyRateID],S.[SubTotal],S.[TaxAmt],S.[Freight],S.[TotalDue],S.[Comment],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Sales].[SalesOrderHeader] S;
INSERT stg.[SalesOrderHeader]([SalesOrderID],[RevisionNumber],[OrderDate],[DueDate],[ShipDate],[Status],[OnlineOrderFlag],[SalesOrderNumber],[PurchaseOrderNumber],[AccountNumber],[CustomerID],[SalesPersonID],[TerritoryID],[BillToAddressID],[ShipToAddressID],[ShipMethodID],[CreditCardID],[CreditCardApprovalCode],[CurrencyRateID],[SubTotal],[TaxAmt],[Freight],[TotalDue],[Comment],[rowguid],[ModifiedDate],LoadBatchID) SELECT [SalesOrderID],[RevisionNumber],[OrderDate],[DueDate],[ShipDate],[Status],[OnlineOrderFlag],[SalesOrderNumber],[PurchaseOrderNumber],[AccountNumber],[CustomerID],[SalesPersonID],[TerritoryID],[BillToAddressID],[ShipToAddressID],[ShipMethodID],[CreditCardID],[CreditCardApprovalCode],[CurrencyRateID],[SubTotal],[TaxAmt],[Freight],[TotalDue],[Comment],[rowguid],[ModifiedDate],@B FROM etl_raw.[SalesOrderHeader];
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SalesOrderHeader'''',''''I'''',@Next,(SELECT R.[SalesOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[SalesOrderHeader] R;
END ELSE BEGIN
CREATE TABLE #CT_SalesOrderHeader([SalesOrderID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_SalesOrderHeader EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[SalesOrderID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Sales.SalesOrderHeader,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SalesOrderHeader'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[SalesOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_SalesOrderHeader C LEFT JOIN etl_raw.[SalesOrderHeader] R ON R.[SalesOrderID]=C.[SalesOrderID];
DELETE R FROM etl_raw.[SalesOrderHeader] R JOIN #CT_SalesOrderHeader C ON R.[SalesOrderID]=C.[SalesOrderID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[RevisionNumber]=S.[RevisionNumber],R.[OrderDate]=S.[OrderDate],R.[DueDate]=S.[DueDate],R.[ShipDate]=S.[ShipDate],R.[Status]=S.[Status],R.[OnlineOrderFlag]=S.[OnlineOrderFlag],R.[SalesOrderNumber]=S.[SalesOrderNumber],R.[PurchaseOrderNumber]=S.[PurchaseOrderNumber],R.[AccountNumber]=S.[AccountNumber],R.[CustomerID]=S.[CustomerID],R.[SalesPersonID]=S.[SalesPersonID],R.[TerritoryID]=S.[TerritoryID],R.[BillToAddressID]=S.[BillToAddressID],R.[ShipToAddressID]=S.[ShipToAddressID],R.[ShipMethodID]=S.[ShipMethodID],R.[CreditCardID]=S.[CreditCardID],R.[CreditCardApprovalCode]=S.[CreditCardApprovalCode],R.[CurrencyRateID]=S.[CurrencyRateID],R.[SubTotal]=S.[SubTotal],R.[TaxAmt]=S.[TaxAmt],R.[Freight]=S.[Freight],R.[TotalDue]=S.[TotalDue],R.[Comment]=S.[Comment],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[SalesOrderHeader] R JOIN #CT_SalesOrderHeader C ON R.[SalesOrderID]=C.[SalesOrderID] JOIN [__SOURCE_DB__].[Sales].[SalesOrderHeader] S ON S.[SalesOrderID]=C.[SalesOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[SalesOrderHeader]([SalesOrderID],[RevisionNumber],[OrderDate],[DueDate],[ShipDate],[Status],[OnlineOrderFlag],[SalesOrderNumber],[PurchaseOrderNumber],[AccountNumber],[CustomerID],[SalesPersonID],[TerritoryID],[BillToAddressID],[ShipToAddressID],[ShipMethodID],[CreditCardID],[CreditCardApprovalCode],[CurrencyRateID],[SubTotal],[TaxAmt],[Freight],[TotalDue],[Comment],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SalesOrderID],S.[RevisionNumber],S.[OrderDate],S.[DueDate],S.[ShipDate],S.[Status],S.[OnlineOrderFlag],S.[SalesOrderNumber],S.[PurchaseOrderNumber],S.[AccountNumber],S.[CustomerID],S.[SalesPersonID],S.[TerritoryID],S.[BillToAddressID],S.[ShipToAddressID],S.[ShipMethodID],S.[CreditCardID],S.[CreditCardApprovalCode],S.[CurrencyRateID],S.[SubTotal],S.[TaxAmt],S.[Freight],S.[TotalDue],S.[Comment],S.[rowguid],S.[ModifiedDate],@B FROM #CT_SalesOrderHeader C JOIN [__SOURCE_DB__].[Sales].[SalesOrderHeader] S ON S.[SalesOrderID]=C.[SalesOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[SalesOrderHeader] R WHERE R.[SalesOrderID]=S.[SalesOrderID]);
INSERT stg.[SalesOrderHeader]([SalesOrderID],[RevisionNumber],[OrderDate],[DueDate],[ShipDate],[Status],[OnlineOrderFlag],[SalesOrderNumber],[PurchaseOrderNumber],[AccountNumber],[CustomerID],[SalesPersonID],[TerritoryID],[BillToAddressID],[ShipToAddressID],[ShipMethodID],[CreditCardID],[CreditCardApprovalCode],[CurrencyRateID],[SubTotal],[TaxAmt],[Freight],[TotalDue],[Comment],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[SalesOrderID],R.[RevisionNumber],R.[OrderDate],R.[DueDate],R.[ShipDate],R.[Status],R.[OnlineOrderFlag],R.[SalesOrderNumber],R.[PurchaseOrderNumber],R.[AccountNumber],R.[CustomerID],R.[SalesPersonID],R.[TerritoryID],R.[BillToAddressID],R.[ShipToAddressID],R.[ShipMethodID],R.[CreditCardID],R.[CreditCardApprovalCode],R.[CurrencyRateID],R.[SubTotal],R.[TaxAmt],R.[Freight],R.[TotalDue],R.[Comment],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[SalesOrderHeader] R JOIN #CT_SalesOrderHeader C ON R.[SalesOrderID]=C.[SalesOrderID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[SpecialOffer]([SpecialOfferID],[Description],[DiscountPct],[Type],[Category],[StartDate],[EndDate],[MinQty],[MaxQty],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SpecialOfferID],S.[Description],S.[DiscountPct],S.[Type],S.[Category],S.[StartDate],S.[EndDate],S.[MinQty],S.[MaxQty],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Sales].[SpecialOffer] S;
INSERT stg.[SpecialOffer]([SpecialOfferID],[Description],[DiscountPct],[Type],[Category],[StartDate],[EndDate],[MinQty],[MaxQty],[rowguid],[ModifiedDate],LoadBatchID) SELECT [SpecialOfferID],[Description],[DiscountPct],[Type],[Category],[StartDate],[EndDate],[MinQty],[MaxQty],[rowguid],[ModifiedDate],@B FROM etl_raw.[SpecialOffer];
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SpecialOffer'''',''''I'''',@Next,(SELECT R.[SpecialOfferID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[SpecialOffer] R;
END ELSE BEGIN
CREATE TABLE #CT_SpecialOffer([SpecialOfferID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_SpecialOffer EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[SpecialOfferID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Sales.SpecialOffer,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SpecialOffer'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[SpecialOfferID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_SpecialOffer C LEFT JOIN etl_raw.[SpecialOffer] R ON R.[SpecialOfferID]=C.[SpecialOfferID];
DELETE R FROM etl_raw.[SpecialOffer] R JOIN #CT_SpecialOffer C ON R.[SpecialOfferID]=C.[SpecialOfferID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[Description]=S.[Description],R.[DiscountPct]=S.[DiscountPct],R.[Type]=S.[Type],R.[Category]=S.[Category],R.[StartDate]=S.[StartDate],R.[EndDate]=S.[EndDate],R.[MinQty]=S.[MinQty],R.[MaxQty]=S.[MaxQty],R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[SpecialOffer] R JOIN #CT_SpecialOffer C ON R.[SpecialOfferID]=C.[SpecialOfferID] JOIN [__SOURCE_DB__].[Sales].[SpecialOffer] S ON S.[SpecialOfferID]=C.[SpecialOfferID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[SpecialOffer]([SpecialOfferID],[Description],[DiscountPct],[Type],[Category],[StartDate],[EndDate],[MinQty],[MaxQty],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SpecialOfferID],S.[Description],S.[DiscountPct],S.[Type],S.[Category],S.[StartDate],S.[EndDate],S.[MinQty],S.[MaxQty],S.[rowguid],S.[ModifiedDate],@B FROM #CT_SpecialOffer C JOIN [__SOURCE_DB__].[Sales].[SpecialOffer] S ON S.[SpecialOfferID]=C.[SpecialOfferID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[SpecialOffer] R WHERE R.[SpecialOfferID]=S.[SpecialOfferID]);
INSERT stg.[SpecialOffer]([SpecialOfferID],[Description],[DiscountPct],[Type],[Category],[StartDate],[EndDate],[MinQty],[MaxQty],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[SpecialOfferID],R.[Description],R.[DiscountPct],R.[Type],R.[Category],R.[StartDate],R.[EndDate],R.[MinQty],R.[MaxQty],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[SpecialOffer] R JOIN #CT_SpecialOffer C ON R.[SpecialOfferID]=C.[SpecialOfferID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
IF @Previous IS NULL BEGIN
INSERT etl_raw.[SpecialOfferProduct]([SpecialOfferID],[ProductID],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SpecialOfferID],S.[ProductID],S.[rowguid],S.[ModifiedDate],@B FROM [__SOURCE_DB__].[Sales].[SpecialOfferProduct] S;
INSERT stg.[SpecialOfferProduct]([SpecialOfferID],[ProductID],[rowguid],[ModifiedDate],LoadBatchID) SELECT [SpecialOfferID],[ProductID],[rowguid],[ModifiedDate],@B FROM etl_raw.[SpecialOfferProduct];
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SpecialOfferProduct'''',''''I'''',@Next,(SELECT R.[SpecialOfferID],R.[ProductID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[SpecialOfferProduct] R;
END ELSE BEGIN
CREATE TABLE #CT_SpecialOfferProduct([SpecialOfferID] int NOT NULL,[ProductID] int NOT NULL,SYS_CHANGE_OPERATION char(1),SYS_CHANGE_VERSION bigint);
INSERT #CT_SpecialOfferProduct EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT C.[SpecialOfferID],C.[ProductID],C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION FROM CHANGETABLE(CHANGES Sales.SpecialOfferProduct,@Previous) C WHERE C.SYS_CHANGE_VERSION<=@Next'''',N''''@Previous bigint,@Next bigint'''',@Previous,@Next;
INSERT etl_v2.SourceChange SELECT @B,N''''Sales.SpecialOfferProduct'''',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[SpecialOfferID],C.[ProductID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_SpecialOfferProduct C LEFT JOIN etl_raw.[SpecialOfferProduct] R ON R.[SpecialOfferID]=C.[SpecialOfferID] AND R.[ProductID]=C.[ProductID];
DELETE R FROM etl_raw.[SpecialOfferProduct] R JOIN #CT_SpecialOfferProduct C ON R.[SpecialOfferID]=C.[SpecialOfferID] AND R.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION=''''D'''';
UPDATE R SET R.[rowguid]=S.[rowguid],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[SpecialOfferProduct] R JOIN #CT_SpecialOfferProduct C ON R.[SpecialOfferID]=C.[SpecialOfferID] AND R.[ProductID]=C.[ProductID] JOIN [__SOURCE_DB__].[Sales].[SpecialOfferProduct] S ON S.[SpecialOfferID]=C.[SpecialOfferID] AND S.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
INSERT etl_raw.[SpecialOfferProduct]([SpecialOfferID],[ProductID],[rowguid],[ModifiedDate],LoadBatchID) SELECT S.[SpecialOfferID],S.[ProductID],S.[rowguid],S.[ModifiedDate],@B FROM #CT_SpecialOfferProduct C JOIN [__SOURCE_DB__].[Sales].[SpecialOfferProduct] S ON S.[SpecialOfferID]=C.[SpecialOfferID] AND S.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''' AND NOT EXISTS(SELECT 1 FROM etl_raw.[SpecialOfferProduct] R WHERE R.[SpecialOfferID]=S.[SpecialOfferID] AND R.[ProductID]=S.[ProductID]);
INSERT stg.[SpecialOfferProduct]([SpecialOfferID],[ProductID],[rowguid],[ModifiedDate],LoadBatchID) SELECT R.[SpecialOfferID],R.[ProductID],R.[rowguid],R.[ModifiedDate],@B FROM etl_raw.[SpecialOfferProduct] R JOIN #CT_SpecialOfferProduct C ON R.[SpecialOfferID]=C.[SpecialOfferID] AND R.[ProductID]=C.[ProductID] WHERE C.SYS_CHANGE_OPERATION<>''''D'''';
END;
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Project @B bigint AS BEGIN SET NOCOUNT ON;
DELETE FROM etl_calc.[Bridge_BillOfMaterials];
DELETE FROM etl_calc.[Bridge_ProductPromotion];
DELETE FROM etl_calc.[Dim_Channel];
INSERT etl_calc.[Dim_Channel]([ChannelKey],[OnlineOrderFlag],[ChannelName]) SELECT [ChannelKey],[OnlineOrderFlag],[ChannelName] FROM dw.Dim_Channel;
DELETE FROM etl_calc.[Dim_Customer];
SET IDENTITY_INSERT etl_calc.[Dim_Customer] ON;
INSERT etl_calc.[Dim_Customer]([CustomerKey],[CustomerID],[PersonID],[StoreID],[CustomerType],[LoadBatchID],[LoadedAt]) SELECT [CustomerKey],[CustomerID],[PersonID],[StoreID],[CustomerType],[LoadBatchID],[LoadedAt] FROM dw.Dim_Customer;
SET IDENTITY_INSERT etl_calc.[Dim_Customer] OFF;
DELETE FROM etl_calc.[Dim_Date];
INSERT etl_calc.[Dim_Date]([DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate]) SELECT [DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate] FROM dw.Dim_Date;
DELETE FROM etl_calc.[Dim_Location];
SET IDENTITY_INSERT etl_calc.[Dim_Location] ON;
INSERT etl_calc.[Dim_Location]([LocationKey],[LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict],[LoadBatchID],[LoadedAt]) SELECT [LocationKey],[LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict],[LoadBatchID],[LoadedAt] FROM dw.Dim_Location;
SET IDENTITY_INSERT etl_calc.[Dim_Location] OFF;
DELETE FROM etl_calc.[Dim_Product];
SET IDENTITY_INSERT etl_calc.[Dim_Product] ON;
INSERT etl_calc.[Dim_Product]([ProductKey],[ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT [ProductKey],[ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt] FROM dw.Dim_Product;
SET IDENTITY_INSERT etl_calc.[Dim_Product] OFF;
DELETE FROM etl_calc.[Dim_Promotion];
SET IDENTITY_INSERT etl_calc.[Dim_Promotion] ON;
INSERT etl_calc.[Dim_Promotion]([PromotionKey],[SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT [PromotionKey],[SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt] FROM dw.Dim_Promotion;
SET IDENTITY_INSERT etl_calc.[Dim_Promotion] OFF;
DELETE FROM etl_calc.[Dim_PurchaseStatus];
INSERT etl_calc.[Dim_PurchaseStatus]([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented]) SELECT [PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented] FROM dw.Dim_PurchaseStatus;
DELETE FROM etl_calc.[Dim_SalesStatus];
INSERT etl_calc.[Dim_SalesStatus]([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible]) SELECT [SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible] FROM dw.Dim_SalesStatus;
DELETE FROM etl_calc.[Dim_ScrapReason];
SET IDENTITY_INSERT etl_calc.[Dim_ScrapReason] ON;
INSERT etl_calc.[Dim_ScrapReason]([ScrapReasonKey],[ScrapReasonID],[ScrapReasonName],[LoadBatchID],[LoadedAt]) SELECT [ScrapReasonKey],[ScrapReasonID],[ScrapReasonName],[LoadBatchID],[LoadedAt] FROM dw.Dim_ScrapReason;
SET IDENTITY_INSERT etl_calc.[Dim_ScrapReason] OFF;
DELETE FROM etl_calc.[Dim_UnitMeasure];
SET IDENTITY_INSERT etl_calc.[Dim_UnitMeasure] ON;
INSERT etl_calc.[Dim_UnitMeasure]([UnitMeasureKey],[UnitMeasureCode],[UnitMeasureName],[LoadBatchID],[LoadedAt]) SELECT [UnitMeasureKey],[UnitMeasureCode],[UnitMeasureName],[LoadBatchID],[LoadedAt] FROM dw.Dim_UnitMeasure;
SET IDENTITY_INSERT etl_calc.[Dim_UnitMeasure] OFF;
DELETE FROM etl_calc.[Dim_Vendor];
SET IDENTITY_INSERT etl_calc.[Dim_Vendor] ON;
INSERT etl_calc.[Dim_Vendor]([VendorKey],[VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag],[LoadBatchID],[LoadedAt]) SELECT [VendorKey],[VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag],[LoadBatchID],[LoadedAt] FROM dw.Dim_Vendor;
SET IDENTITY_INSERT etl_calc.[Dim_Vendor] OFF;
DELETE FROM etl_calc.[Fact_InventoryOnHand];
DELETE FROM etl_calc.[Fact_ProductVendorTerms];
DELETE FROM etl_calc.[Fact_PurchaseOrderLine];
DELETE FROM etl_calc.[Fact_SalesOrderLine];
DELETE FROM etl_calc.[Fact_WorkOrder];
DELETE FROM etl_calc.[Fact_WorkOrderOperation];
DELETE FROM etl_calc.[Ref_ProductPriceHistory];
DELETE FROM etl_calc.[Fact_DemandDaily];
EXEC etl_v2.CorrectSales @B;
EXEC etl_v2.Calc_uspLoadDimensions @B;
EXEC etl_v2.Calc_uspLoadProduct @B;
EXEC etl_v2.Calc_uspLoadBridges @B;
EXEC etl_v2.Calc_uspLoadSales @B;
EXEC etl_v2.Calc_uspLoadPurchases @B;
EXEC etl_v2.Calc_uspLoadVendorTerms @B;
EXEC etl_v2.Calc_uspLoadOperations @B;
EXEC etl_v2.Calc_uspLoadInventory @B;
EXEC etl_v2.Calc_uspLoadWorkOrders @B;
EXEC etl_v2.Calc_uspLoadDemandDaily @B;
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Publish @B bigint AS BEGIN SET NOCOUNT ON;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Channel'''',''''U'''',(SELECT D.[ChannelKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Channel D JOIN etl_calc.[Dim_Channel] P ON P.[ChannelKey]=D.[ChannelKey] WHERE EXISTS(SELECT P.[OnlineOrderFlag],P.[ChannelName] EXCEPT SELECT D.[OnlineOrderFlag],D.[ChannelName]);
UPDATE D SET D.[OnlineOrderFlag]=P.[OnlineOrderFlag],D.[ChannelName]=P.[ChannelName] FROM dw.Dim_Channel D JOIN etl_calc.[Dim_Channel] P ON P.[ChannelKey]=D.[ChannelKey] WHERE EXISTS(SELECT P.[OnlineOrderFlag],P.[ChannelName] EXCEPT SELECT D.[OnlineOrderFlag],D.[ChannelName]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Channel'''',''''I'''',(SELECT P.[ChannelKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Channel] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Channel D WHERE P.[ChannelKey]=D.[ChannelKey]);
INSERT dw.Dim_Channel([ChannelKey],[OnlineOrderFlag],[ChannelName]) SELECT P.[ChannelKey],P.[OnlineOrderFlag],P.[ChannelName] FROM etl_calc.[Dim_Channel] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Channel D WHERE P.[ChannelKey]=D.[ChannelKey]);
IF EXISTS(SELECT [ChannelKey],[OnlineOrderFlag],[ChannelName] FROM etl_calc.[Dim_Channel] EXCEPT SELECT [ChannelKey],[OnlineOrderFlag],[ChannelName] FROM dw.Dim_Channel) OR EXISTS(SELECT [ChannelKey],[OnlineOrderFlag],[ChannelName] FROM dw.Dim_Channel EXCEPT SELECT [ChannelKey],[OnlineOrderFlag],[ChannelName] FROM etl_calc.[Dim_Channel]) THROW 51940,N''''Projected target mismatch: dw.Dim_Channel'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Customer'''',''''U'''',(SELECT D.[CustomerKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Customer D JOIN etl_calc.[Dim_Customer] P ON P.[CustomerKey]=D.[CustomerKey] WHERE EXISTS(SELECT P.[CustomerID],P.[PersonID],P.[StoreID],P.[CustomerType] EXCEPT SELECT D.[CustomerID],D.[PersonID],D.[StoreID],D.[CustomerType]);
UPDATE D SET D.[CustomerID]=P.[CustomerID],D.[PersonID]=P.[PersonID],D.[StoreID]=P.[StoreID],D.[CustomerType]=P.[CustomerType],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_Customer D JOIN etl_calc.[Dim_Customer] P ON P.[CustomerKey]=D.[CustomerKey] WHERE EXISTS(SELECT P.[CustomerID],P.[PersonID],P.[StoreID],P.[CustomerType] EXCEPT SELECT D.[CustomerID],D.[PersonID],D.[StoreID],D.[CustomerType]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Customer'''',''''I'''',(SELECT P.[CustomerKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Customer] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Customer D WHERE P.[CustomerKey]=D.[CustomerKey]);
SET IDENTITY_INSERT dw.Dim_Customer ON;
INSERT dw.Dim_Customer([CustomerKey],[CustomerID],[PersonID],[StoreID],[CustomerType],[LoadBatchID],[LoadedAt]) SELECT P.[CustomerKey],P.[CustomerID],P.[PersonID],P.[StoreID],P.[CustomerType],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_Customer] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Customer D WHERE P.[CustomerKey]=D.[CustomerKey]);
SET IDENTITY_INSERT dw.Dim_Customer OFF;
IF EXISTS(SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM etl_calc.[Dim_Customer] EXCEPT SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM dw.Dim_Customer) OR EXISTS(SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM dw.Dim_Customer EXCEPT SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM etl_calc.[Dim_Customer]) THROW 51940,N''''Projected target mismatch: dw.Dim_Customer'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Date'''',''''U'''',(SELECT D.[DateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Date D JOIN etl_calc.[Dim_Date] P ON P.[DateKey]=D.[DateKey] WHERE EXISTS(SELECT P.[CalendarDate],P.[CalendarYear],P.[CalendarQuarter],P.[CalendarMonth],P.[DayOfMonth],P.[DayOfWeek],P.[IsWeekend],P.[ISOWeek],P.[ISOYear],P.[WeekStartDate],P.[MonthStartDate] EXCEPT SELECT D.[CalendarDate],D.[CalendarYear],D.[CalendarQuarter],D.[CalendarMonth],D.[DayOfMonth],D.[DayOfWeek],D.[IsWeekend],D.[ISOWeek],D.[ISOYear],D.[WeekStartDate],D.[MonthStartDate]);
UPDATE D SET D.[CalendarDate]=P.[CalendarDate],D.[CalendarYear]=P.[CalendarYear],D.[CalendarQuarter]=P.[CalendarQuarter],D.[CalendarMonth]=P.[CalendarMonth],D.[DayOfMonth]=P.[DayOfMonth],D.[DayOfWeek]=P.[DayOfWeek],D.[IsWeekend]=P.[IsWeekend],D.[ISOWeek]=P.[ISOWeek],D.[ISOYear]=P.[ISOYear],D.[WeekStartDate]=P.[WeekStartDate],D.[MonthStartDate]=P.[MonthStartDate] FROM dw.Dim_Date D JOIN etl_calc.[Dim_Date] P ON P.[DateKey]=D.[DateKey] WHERE EXISTS(SELECT P.[CalendarDate],P.[CalendarYear],P.[CalendarQuarter],P.[CalendarMonth],P.[DayOfMonth],P.[DayOfWeek],P.[IsWeekend],P.[ISOWeek],P.[ISOYear],P.[WeekStartDate],P.[MonthStartDate] EXCEPT SELECT D.[CalendarDate],D.[CalendarYear],D.[CalendarQuarter],D.[CalendarMonth],D.[DayOfMonth],D.[DayOfWeek],D.[IsWeekend],D.[ISOWeek],D.[ISOYear],D.[WeekStartDate],D.[MonthStartDate]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Date'''',''''I'''',(SELECT P.[DateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Date] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Date D WHERE P.[DateKey]=D.[DateKey]);
INSERT dw.Dim_Date([DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate]) SELECT P.[DateKey],P.[CalendarDate],P.[CalendarYear],P.[CalendarQuarter],P.[CalendarMonth],P.[DayOfMonth],P.[DayOfWeek],P.[IsWeekend],P.[ISOWeek],P.[ISOYear],P.[WeekStartDate],P.[MonthStartDate] FROM etl_calc.[Dim_Date] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Date D WHERE P.[DateKey]=D.[DateKey]);
IF EXISTS(SELECT [DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate] FROM etl_calc.[Dim_Date] EXCEPT SELECT [DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate] FROM dw.Dim_Date) OR EXISTS(SELECT [DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate] FROM dw.Dim_Date EXCEPT SELECT [DateKey],[CalendarDate],[CalendarYear],[CalendarQuarter],[CalendarMonth],[DayOfMonth],[DayOfWeek],[IsWeekend],[ISOWeek],[ISOYear],[WeekStartDate],[MonthStartDate] FROM etl_calc.[Dim_Date]) THROW 51940,N''''Projected target mismatch: dw.Dim_Date'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Location'''',''''U'''',(SELECT D.[LocationKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Location D JOIN etl_calc.[Dim_Location] P ON P.[LocationKey]=D.[LocationKey] WHERE EXISTS(SELECT P.[LocationID],P.[LocationName],P.[CostRate],P.[Availability],P.[LocationType],P.[HasProductionConflict] EXCEPT SELECT D.[LocationID],D.[LocationName],D.[CostRate],D.[Availability],D.[LocationType],D.[HasProductionConflict]);
UPDATE D SET D.[LocationID]=P.[LocationID],D.[LocationName]=P.[LocationName],D.[CostRate]=P.[CostRate],D.[Availability]=P.[Availability],D.[LocationType]=P.[LocationType],D.[HasProductionConflict]=P.[HasProductionConflict],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_Location D JOIN etl_calc.[Dim_Location] P ON P.[LocationKey]=D.[LocationKey] WHERE EXISTS(SELECT P.[LocationID],P.[LocationName],P.[CostRate],P.[Availability],P.[LocationType],P.[HasProductionConflict] EXCEPT SELECT D.[LocationID],D.[LocationName],D.[CostRate],D.[Availability],D.[LocationType],D.[HasProductionConflict]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Location'''',''''I'''',(SELECT P.[LocationKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Location] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Location D WHERE P.[LocationKey]=D.[LocationKey]);
SET IDENTITY_INSERT dw.Dim_Location ON;
INSERT dw.Dim_Location([LocationKey],[LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict],[LoadBatchID],[LoadedAt]) SELECT P.[LocationKey],P.[LocationID],P.[LocationName],P.[CostRate],P.[Availability],P.[LocationType],P.[HasProductionConflict],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_Location] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Location D WHERE P.[LocationKey]=D.[LocationKey]);
SET IDENTITY_INSERT dw.Dim_Location OFF;
IF EXISTS(SELECT [LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict] FROM etl_calc.[Dim_Location] EXCEPT SELECT [LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict] FROM dw.Dim_Location) OR EXISTS(SELECT [LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict] FROM dw.Dim_Location EXCEPT SELECT [LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict] FROM etl_calc.[Dim_Location]) THROW 51940,N''''Projected target mismatch: dw.Dim_Location'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Product'''',''''U'''',(SELECT D.[ProductKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Product D JOIN etl_calc.[Dim_Product] P ON P.[ProductKey]=D.[ProductKey] WHERE EXISTS(SELECT P.[ProductID],P.[ProductNumber],P.[ProductName],P.[ProductSubcategoryID],P.[SubcategoryName],P.[ProductCategoryID],P.[CategoryName],P.[ProductModelID],P.[MakeFlag],P.[FinishedGoodsFlag],P.[SupplyType],P.[ProductRole],P.[IsBOMAssembly],P.[IsBOMComponent],P.[Color],P.[Size],P.[SizeUnitName],P.[Weight],P.[WeightUnitName],P.[ProductLine],P.[ProductLineName],P.[Class],P.[ClassName],P.[Style],P.[StyleName],P.[DaysToManufacture],P.[SafetyStockLevel],P.[ReorderPoint],P.[StandardCost],P.[ListPrice],P.[SellStartDate],P.[SellEndDate],P.[DiscontinuedDate],P.[DQStatus],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[ProductID],D.[ProductNumber],D.[ProductName],D.[ProductSubcategoryID],D.[SubcategoryName],D.[ProductCategoryID],D.[CategoryName],D.[ProductModelID],D.[MakeFlag],D.[FinishedGoodsFlag],D.[SupplyType],D.[ProductRole],D.[IsBOMAssembly],D.[IsBOMComponent],D.[Color],D.[Size],D.[SizeUnitName],D.[Weight],D.[WeightUnitName],D.[ProductLine],D.[ProductLineName],D.[Class],D.[ClassName],D.[Style],D.[StyleName],D.[DaysToManufacture],D.[SafetyStockLevel],D.[ReorderPoint],D.[StandardCost],D.[ListPrice],D.[SellStartDate],D.[SellEndDate],D.[DiscontinuedDate],D.[DQStatus],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[ProductID]=P.[ProductID],D.[ProductNumber]=P.[ProductNumber],D.[ProductName]=P.[ProductName],D.[ProductSubcategoryID]=P.[ProductSubcategoryID],D.[SubcategoryName]=P.[SubcategoryName],D.[ProductCategoryID]=P.[ProductCategoryID],D.[CategoryName]=P.[CategoryName],D.[ProductModelID]=P.[ProductModelID],D.[MakeFlag]=P.[MakeFlag],D.[FinishedGoodsFlag]=P.[FinishedGoodsFlag],D.[SupplyType]=P.[SupplyType],D.[ProductRole]=P.[ProductRole],D.[IsBOMAssembly]=P.[IsBOMAssembly],D.[IsBOMComponent]=P.[IsBOMComponent],D.[Color]=P.[Color],D.[Size]=P.[Size],D.[SizeUnitName]=P.[SizeUnitName],D.[Weight]=P.[Weight],D.[WeightUnitName]=P.[WeightUnitName],D.[ProductLine]=P.[ProductLine],D.[ProductLineName]=P.[ProductLineName],D.[Class]=P.[Class],D.[ClassName]=P.[ClassName],D.[Style]=P.[Style],D.[StyleName]=P.[StyleName],D.[DaysToManufacture]=P.[DaysToManufacture],D.[SafetyStockLevel]=P.[SafetyStockLevel],D.[ReorderPoint]=P.[ReorderPoint],D.[StandardCost]=P.[StandardCost],D.[ListPrice]=P.[ListPrice],D.[SellStartDate]=P.[SellStartDate],D.[SellEndDate]=P.[SellEndDate],D.[DiscontinuedDate]=P.[DiscontinuedDate],D.[DQStatus]=P.[DQStatus],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_Product D JOIN etl_calc.[Dim_Product] P ON P.[ProductKey]=D.[ProductKey] WHERE EXISTS(SELECT P.[ProductID],P.[ProductNumber],P.[ProductName],P.[ProductSubcategoryID],P.[SubcategoryName],P.[ProductCategoryID],P.[CategoryName],P.[ProductModelID],P.[MakeFlag],P.[FinishedGoodsFlag],P.[SupplyType],P.[ProductRole],P.[IsBOMAssembly],P.[IsBOMComponent],P.[Color],P.[Size],P.[SizeUnitName],P.[Weight],P.[WeightUnitName],P.[ProductLine],P.[ProductLineName],P.[Class],P.[ClassName],P.[Style],P.[StyleName],P.[DaysToManufacture],P.[SafetyStockLevel],P.[ReorderPoint],P.[StandardCost],P.[ListPrice],P.[SellStartDate],P.[SellEndDate],P.[DiscontinuedDate],P.[DQStatus],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[ProductID],D.[ProductNumber],D.[ProductName],D.[ProductSubcategoryID],D.[SubcategoryName],D.[ProductCategoryID],D.[CategoryName],D.[ProductModelID],D.[MakeFlag],D.[FinishedGoodsFlag],D.[SupplyType],D.[ProductRole],D.[IsBOMAssembly],D.[IsBOMComponent],D.[Color],D.[Size],D.[SizeUnitName],D.[Weight],D.[WeightUnitName],D.[ProductLine],D.[ProductLineName],D.[Class],D.[ClassName],D.[Style],D.[StyleName],D.[DaysToManufacture],D.[SafetyStockLevel],D.[ReorderPoint],D.[StandardCost],D.[ListPrice],D.[SellStartDate],D.[SellEndDate],D.[DiscontinuedDate],D.[DQStatus],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Product'''',''''I'''',(SELECT P.[ProductKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Product] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Product D WHERE P.[ProductKey]=D.[ProductKey]);
SET IDENTITY_INSERT dw.Dim_Product ON;
INSERT dw.Dim_Product([ProductKey],[ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[ProductKey],P.[ProductID],P.[ProductNumber],P.[ProductName],P.[ProductSubcategoryID],P.[SubcategoryName],P.[ProductCategoryID],P.[CategoryName],P.[ProductModelID],P.[MakeFlag],P.[FinishedGoodsFlag],P.[SupplyType],P.[ProductRole],P.[IsBOMAssembly],P.[IsBOMComponent],P.[Color],P.[Size],P.[SizeUnitName],P.[Weight],P.[WeightUnitName],P.[ProductLine],P.[ProductLineName],P.[Class],P.[ClassName],P.[Style],P.[StyleName],P.[DaysToManufacture],P.[SafetyStockLevel],P.[ReorderPoint],P.[StandardCost],P.[ListPrice],P.[SellStartDate],P.[SellEndDate],P.[DiscontinuedDate],P.[DQStatus],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_Product] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Product D WHERE P.[ProductKey]=D.[ProductKey]);
SET IDENTITY_INSERT dw.Dim_Product OFF;
IF EXISTS(SELECT [ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Dim_Product] EXCEPT SELECT [ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion] FROM dw.Dim_Product) OR EXISTS(SELECT [ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion] FROM dw.Dim_Product EXCEPT SELECT [ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Dim_Product]) THROW 51940,N''''Projected target mismatch: dw.Dim_Product'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Promotion'''',''''U'''',(SELECT D.[PromotionKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Promotion D JOIN etl_calc.[Dim_Promotion] P ON P.[PromotionKey]=D.[PromotionKey] WHERE EXISTS(SELECT P.[SpecialOfferID],P.[Description],P.[OfferType],P.[OfferCategory],P.[DiscountPct],P.[StartDate],P.[EndDate],P.[MinQty],P.[MaxQty],P.[IsNoDiscount],P.[IsScheduleValid],P.[IsDiscountValid],P.[IsQtyRangeValid],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[SpecialOfferID],D.[Description],D.[OfferType],D.[OfferCategory],D.[DiscountPct],D.[StartDate],D.[EndDate],D.[MinQty],D.[MaxQty],D.[IsNoDiscount],D.[IsScheduleValid],D.[IsDiscountValid],D.[IsQtyRangeValid],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[SpecialOfferID]=P.[SpecialOfferID],D.[Description]=P.[Description],D.[OfferType]=P.[OfferType],D.[OfferCategory]=P.[OfferCategory],D.[DiscountPct]=P.[DiscountPct],D.[StartDate]=P.[StartDate],D.[EndDate]=P.[EndDate],D.[MinQty]=P.[MinQty],D.[MaxQty]=P.[MaxQty],D.[IsNoDiscount]=P.[IsNoDiscount],D.[IsScheduleValid]=P.[IsScheduleValid],D.[IsDiscountValid]=P.[IsDiscountValid],D.[IsQtyRangeValid]=P.[IsQtyRangeValid],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_Promotion D JOIN etl_calc.[Dim_Promotion] P ON P.[PromotionKey]=D.[PromotionKey] WHERE EXISTS(SELECT P.[SpecialOfferID],P.[Description],P.[OfferType],P.[OfferCategory],P.[DiscountPct],P.[StartDate],P.[EndDate],P.[MinQty],P.[MaxQty],P.[IsNoDiscount],P.[IsScheduleValid],P.[IsDiscountValid],P.[IsQtyRangeValid],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[SpecialOfferID],D.[Description],D.[OfferType],D.[OfferCategory],D.[DiscountPct],D.[StartDate],D.[EndDate],D.[MinQty],D.[MaxQty],D.[IsNoDiscount],D.[IsScheduleValid],D.[IsDiscountValid],D.[IsQtyRangeValid],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Promotion'''',''''I'''',(SELECT P.[PromotionKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Promotion] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Promotion D WHERE P.[PromotionKey]=D.[PromotionKey]);
SET IDENTITY_INSERT dw.Dim_Promotion ON;
INSERT dw.Dim_Promotion([PromotionKey],[SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[PromotionKey],P.[SpecialOfferID],P.[Description],P.[OfferType],P.[OfferCategory],P.[DiscountPct],P.[StartDate],P.[EndDate],P.[MinQty],P.[MaxQty],P.[IsNoDiscount],P.[IsScheduleValid],P.[IsDiscountValid],P.[IsQtyRangeValid],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_Promotion] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Promotion D WHERE P.[PromotionKey]=D.[PromotionKey]);
SET IDENTITY_INSERT dw.Dim_Promotion OFF;
IF EXISTS(SELECT [SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Dim_Promotion] EXCEPT SELECT [SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion] FROM dw.Dim_Promotion) OR EXISTS(SELECT [SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion] FROM dw.Dim_Promotion EXCEPT SELECT [SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Dim_Promotion]) THROW 51940,N''''Projected target mismatch: dw.Dim_Promotion'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_PurchaseStatus'''',''''U'''',(SELECT D.[PurchaseStatusKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_PurchaseStatus D JOIN etl_calc.[Dim_PurchaseStatus] P ON P.[PurchaseStatusKey]=D.[PurchaseStatusKey] WHERE EXISTS(SELECT P.[StatusCode],P.[StatusName],P.[IsDocumented] EXCEPT SELECT D.[StatusCode],D.[StatusName],D.[IsDocumented]);
UPDATE D SET D.[StatusCode]=P.[StatusCode],D.[StatusName]=P.[StatusName],D.[IsDocumented]=P.[IsDocumented] FROM dw.Dim_PurchaseStatus D JOIN etl_calc.[Dim_PurchaseStatus] P ON P.[PurchaseStatusKey]=D.[PurchaseStatusKey] WHERE EXISTS(SELECT P.[StatusCode],P.[StatusName],P.[IsDocumented] EXCEPT SELECT D.[StatusCode],D.[StatusName],D.[IsDocumented]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_PurchaseStatus'''',''''I'''',(SELECT P.[PurchaseStatusKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_PurchaseStatus] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus D WHERE P.[PurchaseStatusKey]=D.[PurchaseStatusKey]);
INSERT dw.Dim_PurchaseStatus([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented]) SELECT P.[PurchaseStatusKey],P.[StatusCode],P.[StatusName],P.[IsDocumented] FROM etl_calc.[Dim_PurchaseStatus] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus D WHERE P.[PurchaseStatusKey]=D.[PurchaseStatusKey]);
IF EXISTS(SELECT [PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented] FROM etl_calc.[Dim_PurchaseStatus] EXCEPT SELECT [PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented] FROM dw.Dim_PurchaseStatus) OR EXISTS(SELECT [PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented] FROM dw.Dim_PurchaseStatus EXCEPT SELECT [PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented] FROM etl_calc.[Dim_PurchaseStatus]) THROW 51940,N''''Projected target mismatch: dw.Dim_PurchaseStatus'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_SalesStatus'''',''''U'''',(SELECT D.[SalesStatusKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_SalesStatus D JOIN etl_calc.[Dim_SalesStatus] P ON P.[SalesStatusKey]=D.[SalesStatusKey] WHERE EXISTS(SELECT P.[StatusCode],P.[StatusName],P.[IsDocumented],P.[IsDemandEligible] EXCEPT SELECT D.[StatusCode],D.[StatusName],D.[IsDocumented],D.[IsDemandEligible]);
UPDATE D SET D.[StatusCode]=P.[StatusCode],D.[StatusName]=P.[StatusName],D.[IsDocumented]=P.[IsDocumented],D.[IsDemandEligible]=P.[IsDemandEligible] FROM dw.Dim_SalesStatus D JOIN etl_calc.[Dim_SalesStatus] P ON P.[SalesStatusKey]=D.[SalesStatusKey] WHERE EXISTS(SELECT P.[StatusCode],P.[StatusName],P.[IsDocumented],P.[IsDemandEligible] EXCEPT SELECT D.[StatusCode],D.[StatusName],D.[IsDocumented],D.[IsDemandEligible]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_SalesStatus'''',''''I'''',(SELECT P.[SalesStatusKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_SalesStatus] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus D WHERE P.[SalesStatusKey]=D.[SalesStatusKey]);
INSERT dw.Dim_SalesStatus([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible]) SELECT P.[SalesStatusKey],P.[StatusCode],P.[StatusName],P.[IsDocumented],P.[IsDemandEligible] FROM etl_calc.[Dim_SalesStatus] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus D WHERE P.[SalesStatusKey]=D.[SalesStatusKey]);
IF EXISTS(SELECT [SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible] FROM etl_calc.[Dim_SalesStatus] EXCEPT SELECT [SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible] FROM dw.Dim_SalesStatus) OR EXISTS(SELECT [SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible] FROM dw.Dim_SalesStatus EXCEPT SELECT [SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible] FROM etl_calc.[Dim_SalesStatus]) THROW 51940,N''''Projected target mismatch: dw.Dim_SalesStatus'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_ScrapReason'''',''''U'''',(SELECT D.[ScrapReasonKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_ScrapReason D JOIN etl_calc.[Dim_ScrapReason] P ON P.[ScrapReasonKey]=D.[ScrapReasonKey] WHERE EXISTS(SELECT P.[ScrapReasonID],P.[ScrapReasonName] EXCEPT SELECT D.[ScrapReasonID],D.[ScrapReasonName]);
UPDATE D SET D.[ScrapReasonID]=P.[ScrapReasonID],D.[ScrapReasonName]=P.[ScrapReasonName],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_ScrapReason D JOIN etl_calc.[Dim_ScrapReason] P ON P.[ScrapReasonKey]=D.[ScrapReasonKey] WHERE EXISTS(SELECT P.[ScrapReasonID],P.[ScrapReasonName] EXCEPT SELECT D.[ScrapReasonID],D.[ScrapReasonName]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_ScrapReason'''',''''I'''',(SELECT P.[ScrapReasonKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_ScrapReason] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_ScrapReason D WHERE P.[ScrapReasonKey]=D.[ScrapReasonKey]);
SET IDENTITY_INSERT dw.Dim_ScrapReason ON;
INSERT dw.Dim_ScrapReason([ScrapReasonKey],[ScrapReasonID],[ScrapReasonName],[LoadBatchID],[LoadedAt]) SELECT P.[ScrapReasonKey],P.[ScrapReasonID],P.[ScrapReasonName],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_ScrapReason] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_ScrapReason D WHERE P.[ScrapReasonKey]=D.[ScrapReasonKey]);
SET IDENTITY_INSERT dw.Dim_ScrapReason OFF;
IF EXISTS(SELECT [ScrapReasonID],[ScrapReasonName] FROM etl_calc.[Dim_ScrapReason] EXCEPT SELECT [ScrapReasonID],[ScrapReasonName] FROM dw.Dim_ScrapReason) OR EXISTS(SELECT [ScrapReasonID],[ScrapReasonName] FROM dw.Dim_ScrapReason EXCEPT SELECT [ScrapReasonID],[ScrapReasonName] FROM etl_calc.[Dim_ScrapReason]) THROW 51940,N''''Projected target mismatch: dw.Dim_ScrapReason'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_UnitMeasure'''',''''U'''',(SELECT D.[UnitMeasureKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_UnitMeasure D JOIN etl_calc.[Dim_UnitMeasure] P ON P.[UnitMeasureKey]=D.[UnitMeasureKey] WHERE EXISTS(SELECT P.[UnitMeasureCode],P.[UnitMeasureName] EXCEPT SELECT D.[UnitMeasureCode],D.[UnitMeasureName]);
UPDATE D SET D.[UnitMeasureCode]=P.[UnitMeasureCode],D.[UnitMeasureName]=P.[UnitMeasureName],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_UnitMeasure D JOIN etl_calc.[Dim_UnitMeasure] P ON P.[UnitMeasureKey]=D.[UnitMeasureKey] WHERE EXISTS(SELECT P.[UnitMeasureCode],P.[UnitMeasureName] EXCEPT SELECT D.[UnitMeasureCode],D.[UnitMeasureName]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_UnitMeasure'''',''''I'''',(SELECT P.[UnitMeasureKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_UnitMeasure] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_UnitMeasure D WHERE P.[UnitMeasureKey]=D.[UnitMeasureKey]);
SET IDENTITY_INSERT dw.Dim_UnitMeasure ON;
INSERT dw.Dim_UnitMeasure([UnitMeasureKey],[UnitMeasureCode],[UnitMeasureName],[LoadBatchID],[LoadedAt]) SELECT P.[UnitMeasureKey],P.[UnitMeasureCode],P.[UnitMeasureName],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_UnitMeasure] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_UnitMeasure D WHERE P.[UnitMeasureKey]=D.[UnitMeasureKey]);
SET IDENTITY_INSERT dw.Dim_UnitMeasure OFF;
IF EXISTS(SELECT [UnitMeasureCode],[UnitMeasureName] FROM etl_calc.[Dim_UnitMeasure] EXCEPT SELECT [UnitMeasureCode],[UnitMeasureName] FROM dw.Dim_UnitMeasure) OR EXISTS(SELECT [UnitMeasureCode],[UnitMeasureName] FROM dw.Dim_UnitMeasure EXCEPT SELECT [UnitMeasureCode],[UnitMeasureName] FROM etl_calc.[Dim_UnitMeasure]) THROW 51940,N''''Projected target mismatch: dw.Dim_UnitMeasure'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Vendor'''',''''U'''',(SELECT D.[VendorKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Dim_Vendor D JOIN etl_calc.[Dim_Vendor] P ON P.[VendorKey]=D.[VendorKey] WHERE EXISTS(SELECT P.[VendorID],P.[AccountNumber],P.[VendorName],P.[CreditRating],P.[CreditRatingName],P.[PreferredVendorStatus],P.[ActiveFlag] EXCEPT SELECT D.[VendorID],D.[AccountNumber],D.[VendorName],D.[CreditRating],D.[CreditRatingName],D.[PreferredVendorStatus],D.[ActiveFlag]);
UPDATE D SET D.[VendorID]=P.[VendorID],D.[AccountNumber]=P.[AccountNumber],D.[VendorName]=P.[VendorName],D.[CreditRating]=P.[CreditRating],D.[CreditRatingName]=P.[CreditRatingName],D.[PreferredVendorStatus]=P.[PreferredVendorStatus],D.[ActiveFlag]=P.[ActiveFlag],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Dim_Vendor D JOIN etl_calc.[Dim_Vendor] P ON P.[VendorKey]=D.[VendorKey] WHERE EXISTS(SELECT P.[VendorID],P.[AccountNumber],P.[VendorName],P.[CreditRating],P.[CreditRatingName],P.[PreferredVendorStatus],P.[ActiveFlag] EXCEPT SELECT D.[VendorID],D.[AccountNumber],D.[VendorName],D.[CreditRating],D.[CreditRatingName],D.[PreferredVendorStatus],D.[ActiveFlag]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Dim_Vendor'''',''''I'''',(SELECT P.[VendorKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Dim_Vendor] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Vendor D WHERE P.[VendorKey]=D.[VendorKey]);
SET IDENTITY_INSERT dw.Dim_Vendor ON;
INSERT dw.Dim_Vendor([VendorKey],[VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag],[LoadBatchID],[LoadedAt]) SELECT P.[VendorKey],P.[VendorID],P.[AccountNumber],P.[VendorName],P.[CreditRating],P.[CreditRatingName],P.[PreferredVendorStatus],P.[ActiveFlag],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Dim_Vendor] P WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Vendor D WHERE P.[VendorKey]=D.[VendorKey]);
SET IDENTITY_INSERT dw.Dim_Vendor OFF;
IF EXISTS(SELECT [VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag] FROM etl_calc.[Dim_Vendor] EXCEPT SELECT [VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag] FROM dw.Dim_Vendor) OR EXISTS(SELECT [VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag] FROM dw.Dim_Vendor EXCEPT SELECT [VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag] FROM etl_calc.[Dim_Vendor]) THROW 51940,N''''Projected target mismatch: dw.Dim_Vendor'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_BillOfMaterials'''',''''U'''',(SELECT D.[BillOfMaterialsID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Bridge_BillOfMaterials D JOIN etl_calc.[Bridge_BillOfMaterials] P ON P.[BillOfMaterialsID]=D.[BillOfMaterialsID] WHERE EXISTS(SELECT P.[AssemblyProductKey],P.[ComponentProductKey],P.[UnitMeasureKey],P.[BOMLevel],P.[PerAssemblyQty],P.[StartDate],P.[EndDate],P.[IsStructureValid],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[AssemblyProductKey],D.[ComponentProductKey],D.[UnitMeasureKey],D.[BOMLevel],D.[PerAssemblyQty],D.[StartDate],D.[EndDate],D.[IsStructureValid],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[AssemblyProductKey]=P.[AssemblyProductKey],D.[ComponentProductKey]=P.[ComponentProductKey],D.[UnitMeasureKey]=P.[UnitMeasureKey],D.[BOMLevel]=P.[BOMLevel],D.[PerAssemblyQty]=P.[PerAssemblyQty],D.[StartDate]=P.[StartDate],D.[EndDate]=P.[EndDate],D.[IsStructureValid]=P.[IsStructureValid],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Bridge_BillOfMaterials D JOIN etl_calc.[Bridge_BillOfMaterials] P ON P.[BillOfMaterialsID]=D.[BillOfMaterialsID] WHERE EXISTS(SELECT P.[AssemblyProductKey],P.[ComponentProductKey],P.[UnitMeasureKey],P.[BOMLevel],P.[PerAssemblyQty],P.[StartDate],P.[EndDate],P.[IsStructureValid],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[AssemblyProductKey],D.[ComponentProductKey],D.[UnitMeasureKey],D.[BOMLevel],D.[PerAssemblyQty],D.[StartDate],D.[EndDate],D.[IsStructureValid],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_BillOfMaterials'''',''''I'''',(SELECT P.[BillOfMaterialsID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Bridge_BillOfMaterials] P WHERE NOT EXISTS(SELECT 1 FROM dw.Bridge_BillOfMaterials D WHERE P.[BillOfMaterialsID]=D.[BillOfMaterialsID]);
INSERT dw.Bridge_BillOfMaterials([BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[BillOfMaterialsID],P.[AssemblyProductKey],P.[ComponentProductKey],P.[UnitMeasureKey],P.[BOMLevel],P.[PerAssemblyQty],P.[StartDate],P.[EndDate],P.[IsStructureValid],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Bridge_BillOfMaterials] P WHERE NOT EXISTS(SELECT 1 FROM dw.Bridge_BillOfMaterials D WHERE P.[BillOfMaterialsID]=D.[BillOfMaterialsID]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_BillOfMaterials'''',''''D'''',(SELECT D.[BillOfMaterialsID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Bridge_BillOfMaterials D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Bridge_BillOfMaterials] P WHERE P.[BillOfMaterialsID]=D.[BillOfMaterialsID]);
DELETE D FROM dw.Bridge_BillOfMaterials D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Bridge_BillOfMaterials] P WHERE P.[BillOfMaterialsID]=D.[BillOfMaterialsID]);
IF EXISTS(SELECT [BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Bridge_BillOfMaterials] EXCEPT SELECT [BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion] FROM dw.Bridge_BillOfMaterials) OR EXISTS(SELECT [BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion] FROM dw.Bridge_BillOfMaterials EXCEPT SELECT [BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Bridge_BillOfMaterials]) THROW 51940,N''''Projected target mismatch: dw.Bridge_BillOfMaterials'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_ProductPromotion'''',''''U'''',(SELECT D.[ProductKey],D.[PromotionKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Bridge_ProductPromotion D JOIN etl_calc.[Bridge_ProductPromotion] P ON P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey] WHERE 1=0;
UPDATE D SET D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Bridge_ProductPromotion D JOIN etl_calc.[Bridge_ProductPromotion] P ON P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey] WHERE 1=0;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_ProductPromotion'''',''''I'''',(SELECT P.[ProductKey],P.[PromotionKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Bridge_ProductPromotion] P WHERE NOT EXISTS(SELECT 1 FROM dw.Bridge_ProductPromotion D WHERE P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey]);
INSERT dw.Bridge_ProductPromotion([ProductKey],[PromotionKey],[LoadBatchID],[LoadedAt]) SELECT P.[ProductKey],P.[PromotionKey],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Bridge_ProductPromotion] P WHERE NOT EXISTS(SELECT 1 FROM dw.Bridge_ProductPromotion D WHERE P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Bridge_ProductPromotion'''',''''D'''',(SELECT D.[ProductKey],D.[PromotionKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Bridge_ProductPromotion D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Bridge_ProductPromotion] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey]);
DELETE D FROM dw.Bridge_ProductPromotion D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Bridge_ProductPromotion] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[PromotionKey]=D.[PromotionKey]);
IF EXISTS(SELECT [ProductKey],[PromotionKey] FROM etl_calc.[Bridge_ProductPromotion] EXCEPT SELECT [ProductKey],[PromotionKey] FROM dw.Bridge_ProductPromotion) OR EXISTS(SELECT [ProductKey],[PromotionKey] FROM dw.Bridge_ProductPromotion EXCEPT SELECT [ProductKey],[PromotionKey] FROM etl_calc.[Bridge_ProductPromotion]) THROW 51940,N''''Projected target mismatch: dw.Bridge_ProductPromotion'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_InventoryOnHand'''',''''U'''',(SELECT D.[ProductKey],D.[LocationKey],D.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_InventoryOnHand D JOIN etl_calc.[Fact_InventoryOnHand] P ON P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey] WHERE EXISTS(SELECT P.[Shelf],P.[Bin],P.[QuantityOnHand],P.[UnitCostAsOf],P.[InventoryValue],P.[IsNegativeQty] EXCEPT SELECT D.[Shelf],D.[Bin],D.[QuantityOnHand],D.[UnitCostAsOf],D.[InventoryValue],D.[IsNegativeQty]);
UPDATE D SET D.[Shelf]=P.[Shelf],D.[Bin]=P.[Bin],D.[QuantityOnHand]=P.[QuantityOnHand],D.[UnitCostAsOf]=P.[UnitCostAsOf],D.[InventoryValue]=P.[InventoryValue],D.[IsNegativeQty]=P.[IsNegativeQty],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_InventoryOnHand D JOIN etl_calc.[Fact_InventoryOnHand] P ON P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey] WHERE EXISTS(SELECT P.[Shelf],P.[Bin],P.[QuantityOnHand],P.[UnitCostAsOf],P.[InventoryValue],P.[IsNegativeQty] EXCEPT SELECT D.[Shelf],D.[Bin],D.[QuantityOnHand],D.[UnitCostAsOf],D.[InventoryValue],D.[IsNegativeQty]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_InventoryOnHand'''',''''I'''',(SELECT P.[ProductKey],P.[LocationKey],P.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_InventoryOnHand] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_InventoryOnHand D WHERE P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
INSERT dw.Fact_InventoryOnHand([ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty],[LoadBatchID],[LoadedAt]) SELECT P.[ProductKey],P.[LocationKey],P.[AsOfDateKey],P.[Shelf],P.[Bin],P.[QuantityOnHand],P.[UnitCostAsOf],P.[InventoryValue],P.[IsNegativeQty],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_InventoryOnHand] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_InventoryOnHand D WHERE P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_InventoryOnHand'''',''''D'''',(SELECT D.[ProductKey],D.[LocationKey],D.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_InventoryOnHand D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_InventoryOnHand] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
DELETE D FROM dw.Fact_InventoryOnHand D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_InventoryOnHand] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[LocationKey]=D.[LocationKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
IF EXISTS(SELECT [ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty] FROM etl_calc.[Fact_InventoryOnHand] EXCEPT SELECT [ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty] FROM dw.Fact_InventoryOnHand) OR EXISTS(SELECT [ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty] FROM dw.Fact_InventoryOnHand EXCEPT SELECT [ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty] FROM etl_calc.[Fact_InventoryOnHand]) THROW 51940,N''''Projected target mismatch: dw.Fact_InventoryOnHand'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_ProductVendorTerms'''',''''U'''',(SELECT D.[ProductKey],D.[VendorKey],D.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_ProductVendorTerms D JOIN etl_calc.[Fact_ProductVendorTerms] P ON P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey] WHERE EXISTS(SELECT P.[UnitMeasureKey],P.[AverageLeadTime],P.[StandardPrice],P.[LastReceiptCost],P.[LastReceiptDateKey],P.[MinOrderQty],P.[MaxOrderQty],P.[OnOrderQty],P.[IsOrderQtyRangeValid] EXCEPT SELECT D.[UnitMeasureKey],D.[AverageLeadTime],D.[StandardPrice],D.[LastReceiptCost],D.[LastReceiptDateKey],D.[MinOrderQty],D.[MaxOrderQty],D.[OnOrderQty],D.[IsOrderQtyRangeValid]);
UPDATE D SET D.[UnitMeasureKey]=P.[UnitMeasureKey],D.[AverageLeadTime]=P.[AverageLeadTime],D.[StandardPrice]=P.[StandardPrice],D.[LastReceiptCost]=P.[LastReceiptCost],D.[LastReceiptDateKey]=P.[LastReceiptDateKey],D.[MinOrderQty]=P.[MinOrderQty],D.[MaxOrderQty]=P.[MaxOrderQty],D.[OnOrderQty]=P.[OnOrderQty],D.[IsOrderQtyRangeValid]=P.[IsOrderQtyRangeValid],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_ProductVendorTerms D JOIN etl_calc.[Fact_ProductVendorTerms] P ON P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey] WHERE EXISTS(SELECT P.[UnitMeasureKey],P.[AverageLeadTime],P.[StandardPrice],P.[LastReceiptCost],P.[LastReceiptDateKey],P.[MinOrderQty],P.[MaxOrderQty],P.[OnOrderQty],P.[IsOrderQtyRangeValid] EXCEPT SELECT D.[UnitMeasureKey],D.[AverageLeadTime],D.[StandardPrice],D.[LastReceiptCost],D.[LastReceiptDateKey],D.[MinOrderQty],D.[MaxOrderQty],D.[OnOrderQty],D.[IsOrderQtyRangeValid]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_ProductVendorTerms'''',''''I'''',(SELECT P.[ProductKey],P.[VendorKey],P.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_ProductVendorTerms] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_ProductVendorTerms D WHERE P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
INSERT dw.Fact_ProductVendorTerms([ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid],[LoadBatchID],[LoadedAt]) SELECT P.[ProductKey],P.[VendorKey],P.[AsOfDateKey],P.[UnitMeasureKey],P.[AverageLeadTime],P.[StandardPrice],P.[LastReceiptCost],P.[LastReceiptDateKey],P.[MinOrderQty],P.[MaxOrderQty],P.[OnOrderQty],P.[IsOrderQtyRangeValid],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_ProductVendorTerms] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_ProductVendorTerms D WHERE P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_ProductVendorTerms'''',''''D'''',(SELECT D.[ProductKey],D.[VendorKey],D.[AsOfDateKey] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_ProductVendorTerms D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_ProductVendorTerms] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
DELETE D FROM dw.Fact_ProductVendorTerms D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_ProductVendorTerms] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[VendorKey]=D.[VendorKey] AND P.[AsOfDateKey]=D.[AsOfDateKey]);
IF EXISTS(SELECT [ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid] FROM etl_calc.[Fact_ProductVendorTerms] EXCEPT SELECT [ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid] FROM dw.Fact_ProductVendorTerms) OR EXISTS(SELECT [ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid] FROM dw.Fact_ProductVendorTerms EXCEPT SELECT [ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid] FROM etl_calc.[Fact_ProductVendorTerms]) THROW 51940,N''''Projected target mismatch: dw.Fact_ProductVendorTerms'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_PurchaseOrderLine'''',''''U'''',(SELECT D.[PurchaseOrderID],D.[PurchaseOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_PurchaseOrderLine D JOIN etl_calc.[Fact_PurchaseOrderLine] P ON P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID] WHERE EXISTS(SELECT P.[OrderDateKey],P.[ExpectedShipDateKey],P.[ExpectedReceiptDateKey],P.[VendorKey],P.[ProductKey],P.[PurchaseStatusKey],P.[OrderQty],P.[ReceivedQty],P.[RejectedQty],P.[StockedQty],P.[UnitPrice],P.[LineTotal],P.[OrderAt],P.[ExpectedShipAt],P.[ExpectedReceiptAt],P.[IsVendorProductDeclared],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[OrderDateKey],D.[ExpectedShipDateKey],D.[ExpectedReceiptDateKey],D.[VendorKey],D.[ProductKey],D.[PurchaseStatusKey],D.[OrderQty],D.[ReceivedQty],D.[RejectedQty],D.[StockedQty],D.[UnitPrice],D.[LineTotal],D.[OrderAt],D.[ExpectedShipAt],D.[ExpectedReceiptAt],D.[IsVendorProductDeclared],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[OrderDateKey]=P.[OrderDateKey],D.[ExpectedShipDateKey]=P.[ExpectedShipDateKey],D.[ExpectedReceiptDateKey]=P.[ExpectedReceiptDateKey],D.[VendorKey]=P.[VendorKey],D.[ProductKey]=P.[ProductKey],D.[PurchaseStatusKey]=P.[PurchaseStatusKey],D.[OrderQty]=P.[OrderQty],D.[ReceivedQty]=P.[ReceivedQty],D.[RejectedQty]=P.[RejectedQty],D.[StockedQty]=P.[StockedQty],D.[UnitPrice]=P.[UnitPrice],D.[LineTotal]=P.[LineTotal],D.[OrderAt]=P.[OrderAt],D.[ExpectedShipAt]=P.[ExpectedShipAt],D.[ExpectedReceiptAt]=P.[ExpectedReceiptAt],D.[IsVendorProductDeclared]=P.[IsVendorProductDeclared],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_PurchaseOrderLine D JOIN etl_calc.[Fact_PurchaseOrderLine] P ON P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID] WHERE EXISTS(SELECT P.[OrderDateKey],P.[ExpectedShipDateKey],P.[ExpectedReceiptDateKey],P.[VendorKey],P.[ProductKey],P.[PurchaseStatusKey],P.[OrderQty],P.[ReceivedQty],P.[RejectedQty],P.[StockedQty],P.[UnitPrice],P.[LineTotal],P.[OrderAt],P.[ExpectedShipAt],P.[ExpectedReceiptAt],P.[IsVendorProductDeclared],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[OrderDateKey],D.[ExpectedShipDateKey],D.[ExpectedReceiptDateKey],D.[VendorKey],D.[ProductKey],D.[PurchaseStatusKey],D.[OrderQty],D.[ReceivedQty],D.[RejectedQty],D.[StockedQty],D.[UnitPrice],D.[LineTotal],D.[OrderAt],D.[ExpectedShipAt],D.[ExpectedReceiptAt],D.[IsVendorProductDeclared],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_PurchaseOrderLine'''',''''I'''',(SELECT P.[PurchaseOrderID],P.[PurchaseOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_PurchaseOrderLine] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_PurchaseOrderLine D WHERE P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID]);
INSERT dw.Fact_PurchaseOrderLine([PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[PurchaseOrderID],P.[PurchaseOrderDetailID],P.[OrderDateKey],P.[ExpectedShipDateKey],P.[ExpectedReceiptDateKey],P.[VendorKey],P.[ProductKey],P.[PurchaseStatusKey],P.[OrderQty],P.[ReceivedQty],P.[RejectedQty],P.[StockedQty],P.[UnitPrice],P.[LineTotal],P.[OrderAt],P.[ExpectedShipAt],P.[ExpectedReceiptAt],P.[IsVendorProductDeclared],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_PurchaseOrderLine] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_PurchaseOrderLine D WHERE P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_PurchaseOrderLine'''',''''D'''',(SELECT D.[PurchaseOrderID],D.[PurchaseOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_PurchaseOrderLine D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_PurchaseOrderLine] P WHERE P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID]);
DELETE D FROM dw.Fact_PurchaseOrderLine D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_PurchaseOrderLine] P WHERE P.[PurchaseOrderID]=D.[PurchaseOrderID] AND P.[PurchaseOrderDetailID]=D.[PurchaseOrderDetailID]);
IF EXISTS(SELECT [PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_PurchaseOrderLine] EXCEPT SELECT [PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_PurchaseOrderLine) OR EXISTS(SELECT [PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_PurchaseOrderLine EXCEPT SELECT [PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_PurchaseOrderLine]) THROW 51940,N''''Projected target mismatch: dw.Fact_PurchaseOrderLine'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_SalesOrderLine'''',''''U'''',(SELECT D.[SalesOrderID],D.[SalesOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_SalesOrderLine D JOIN etl_calc.[Fact_SalesOrderLine] P ON P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID] WHERE EXISTS(SELECT P.[OrderDateKey],P.[DueDateKey],P.[ShipDateKey],P.[ProductKey],P.[PromotionKey],P.[SalesStatusKey],P.[CustomerKey],P.[ChannelKey],P.[OrderQty],P.[UnitPrice],P.[UnitPriceDiscount],P.[LineTotal],P.[OrderAt],P.[DueAt],P.[ShippedAt],P.[IsDemandEligible],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[OrderDateKey],D.[DueDateKey],D.[ShipDateKey],D.[ProductKey],D.[PromotionKey],D.[SalesStatusKey],D.[CustomerKey],D.[ChannelKey],D.[OrderQty],D.[UnitPrice],D.[UnitPriceDiscount],D.[LineTotal],D.[OrderAt],D.[DueAt],D.[ShippedAt],D.[IsDemandEligible],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[OrderDateKey]=P.[OrderDateKey],D.[DueDateKey]=P.[DueDateKey],D.[ShipDateKey]=P.[ShipDateKey],D.[ProductKey]=P.[ProductKey],D.[PromotionKey]=P.[PromotionKey],D.[SalesStatusKey]=P.[SalesStatusKey],D.[CustomerKey]=P.[CustomerKey],D.[ChannelKey]=P.[ChannelKey],D.[OrderQty]=P.[OrderQty],D.[UnitPrice]=P.[UnitPrice],D.[UnitPriceDiscount]=P.[UnitPriceDiscount],D.[LineTotal]=P.[LineTotal],D.[OrderAt]=P.[OrderAt],D.[DueAt]=P.[DueAt],D.[ShippedAt]=P.[ShippedAt],D.[IsDemandEligible]=P.[IsDemandEligible],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_SalesOrderLine D JOIN etl_calc.[Fact_SalesOrderLine] P ON P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID] WHERE EXISTS(SELECT P.[OrderDateKey],P.[DueDateKey],P.[ShipDateKey],P.[ProductKey],P.[PromotionKey],P.[SalesStatusKey],P.[CustomerKey],P.[ChannelKey],P.[OrderQty],P.[UnitPrice],P.[UnitPriceDiscount],P.[LineTotal],P.[OrderAt],P.[DueAt],P.[ShippedAt],P.[IsDemandEligible],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[OrderDateKey],D.[DueDateKey],D.[ShipDateKey],D.[ProductKey],D.[PromotionKey],D.[SalesStatusKey],D.[CustomerKey],D.[ChannelKey],D.[OrderQty],D.[UnitPrice],D.[UnitPriceDiscount],D.[LineTotal],D.[OrderAt],D.[DueAt],D.[ShippedAt],D.[IsDemandEligible],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_SalesOrderLine'''',''''I'''',(SELECT P.[SalesOrderID],P.[SalesOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_SalesOrderLine] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_SalesOrderLine D WHERE P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID]);
INSERT dw.Fact_SalesOrderLine([SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[SalesOrderID],P.[SalesOrderDetailID],P.[OrderDateKey],P.[DueDateKey],P.[ShipDateKey],P.[ProductKey],P.[PromotionKey],P.[SalesStatusKey],P.[CustomerKey],P.[ChannelKey],P.[OrderQty],P.[UnitPrice],P.[UnitPriceDiscount],P.[LineTotal],P.[OrderAt],P.[DueAt],P.[ShippedAt],P.[IsDemandEligible],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_SalesOrderLine] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_SalesOrderLine D WHERE P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_SalesOrderLine'''',''''D'''',(SELECT D.[SalesOrderID],D.[SalesOrderDetailID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_SalesOrderLine D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_SalesOrderLine] P WHERE P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID]);
DELETE D FROM dw.Fact_SalesOrderLine D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_SalesOrderLine] P WHERE P.[SalesOrderID]=D.[SalesOrderID] AND P.[SalesOrderDetailID]=D.[SalesOrderDetailID]);
IF EXISTS(SELECT [SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_SalesOrderLine] EXCEPT SELECT [SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_SalesOrderLine) OR EXISTS(SELECT [SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_SalesOrderLine EXCEPT SELECT [SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_SalesOrderLine]) THROW 51940,N''''Projected target mismatch: dw.Fact_SalesOrderLine'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrder'''',''''U'''',(SELECT D.[WorkOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_WorkOrder D JOIN etl_calc.[Fact_WorkOrder] P ON P.[WorkOrderID]=D.[WorkOrderID] WHERE EXISTS(SELECT P.[ProductKey],P.[ScrapReasonKey],P.[StartDateKey],P.[DueDateKey],P.[EndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[OrderQty],P.[StockedQty],P.[ScrappedQty],P.[PlannedLeadTimeDays],P.[RecordedLeadTimeDays],P.[ActualLeadTimeDays],P.[LateDays],P.[OperationCount],P.[TotalActualResourceHrs],P.[TotalPlannedCost],P.[TotalActualCost],P.[StartAt],P.[DueAt],P.[EndAt],P.[ActualStartAt],P.[ActualEndAt],P.[IsComplete],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[ProductKey],D.[ScrapReasonKey],D.[StartDateKey],D.[DueDateKey],D.[EndDateKey],D.[ActualStartDateKey],D.[ActualEndDateKey],D.[OrderQty],D.[StockedQty],D.[ScrappedQty],D.[PlannedLeadTimeDays],D.[RecordedLeadTimeDays],D.[ActualLeadTimeDays],D.[LateDays],D.[OperationCount],D.[TotalActualResourceHrs],D.[TotalPlannedCost],D.[TotalActualCost],D.[StartAt],D.[DueAt],D.[EndAt],D.[ActualStartAt],D.[ActualEndAt],D.[IsComplete],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[ProductKey]=P.[ProductKey],D.[ScrapReasonKey]=P.[ScrapReasonKey],D.[StartDateKey]=P.[StartDateKey],D.[DueDateKey]=P.[DueDateKey],D.[EndDateKey]=P.[EndDateKey],D.[ActualStartDateKey]=P.[ActualStartDateKey],D.[ActualEndDateKey]=P.[ActualEndDateKey],D.[OrderQty]=P.[OrderQty],D.[StockedQty]=P.[StockedQty],D.[ScrappedQty]=P.[ScrappedQty],D.[PlannedLeadTimeDays]=P.[PlannedLeadTimeDays],D.[RecordedLeadTimeDays]=P.[RecordedLeadTimeDays],D.[ActualLeadTimeDays]=P.[ActualLeadTimeDays],D.[LateDays]=P.[LateDays],D.[OperationCount]=P.[OperationCount],D.[TotalActualResourceHrs]=P.[TotalActualResourceHrs],D.[TotalPlannedCost]=P.[TotalPlannedCost],D.[TotalActualCost]=P.[TotalActualCost],D.[StartAt]=P.[StartAt],D.[DueAt]=P.[DueAt],D.[EndAt]=P.[EndAt],D.[ActualStartAt]=P.[ActualStartAt],D.[ActualEndAt]=P.[ActualEndAt],D.[IsComplete]=P.[IsComplete],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_WorkOrder D JOIN etl_calc.[Fact_WorkOrder] P ON P.[WorkOrderID]=D.[WorkOrderID] WHERE EXISTS(SELECT P.[ProductKey],P.[ScrapReasonKey],P.[StartDateKey],P.[DueDateKey],P.[EndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[OrderQty],P.[StockedQty],P.[ScrappedQty],P.[PlannedLeadTimeDays],P.[RecordedLeadTimeDays],P.[ActualLeadTimeDays],P.[LateDays],P.[OperationCount],P.[TotalActualResourceHrs],P.[TotalPlannedCost],P.[TotalActualCost],P.[StartAt],P.[DueAt],P.[EndAt],P.[ActualStartAt],P.[ActualEndAt],P.[IsComplete],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[ProductKey],D.[ScrapReasonKey],D.[StartDateKey],D.[DueDateKey],D.[EndDateKey],D.[ActualStartDateKey],D.[ActualEndDateKey],D.[OrderQty],D.[StockedQty],D.[ScrappedQty],D.[PlannedLeadTimeDays],D.[RecordedLeadTimeDays],D.[ActualLeadTimeDays],D.[LateDays],D.[OperationCount],D.[TotalActualResourceHrs],D.[TotalPlannedCost],D.[TotalActualCost],D.[StartAt],D.[DueAt],D.[EndAt],D.[ActualStartAt],D.[ActualEndAt],D.[IsComplete],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrder'''',''''I'''',(SELECT P.[WorkOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_WorkOrder] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_WorkOrder D WHERE P.[WorkOrderID]=D.[WorkOrderID]);
INSERT dw.Fact_WorkOrder([WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[WorkOrderID],P.[ProductKey],P.[ScrapReasonKey],P.[StartDateKey],P.[DueDateKey],P.[EndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[OrderQty],P.[StockedQty],P.[ScrappedQty],P.[PlannedLeadTimeDays],P.[RecordedLeadTimeDays],P.[ActualLeadTimeDays],P.[LateDays],P.[OperationCount],P.[TotalActualResourceHrs],P.[TotalPlannedCost],P.[TotalActualCost],P.[StartAt],P.[DueAt],P.[EndAt],P.[ActualStartAt],P.[ActualEndAt],P.[IsComplete],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_WorkOrder] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_WorkOrder D WHERE P.[WorkOrderID]=D.[WorkOrderID]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrder'''',''''D'''',(SELECT D.[WorkOrderID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_WorkOrder D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_WorkOrder] P WHERE P.[WorkOrderID]=D.[WorkOrderID]);
DELETE D FROM dw.Fact_WorkOrder D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_WorkOrder] P WHERE P.[WorkOrderID]=D.[WorkOrderID]);
IF EXISTS(SELECT [WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_WorkOrder] EXCEPT SELECT [WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_WorkOrder) OR EXISTS(SELECT [WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_WorkOrder EXCEPT SELECT [WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_WorkOrder]) THROW 51940,N''''Projected target mismatch: dw.Fact_WorkOrder'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrderOperation'''',''''U'''',(SELECT D.[WorkOrderID],D.[ProductKey],D.[OperationSequence] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Fact_WorkOrderOperation D JOIN etl_calc.[Fact_WorkOrderOperation] P ON P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence] WHERE EXISTS(SELECT P.[LocationKey],P.[ScheduledStartDateKey],P.[ScheduledEndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[ScheduledDurationDays],P.[ActualDurationDays],P.[ActualResourceHrs],P.[PlannedCost],P.[ActualCost],P.[IsLastOperation],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[LocationKey],D.[ScheduledStartDateKey],D.[ScheduledEndDateKey],D.[ActualStartDateKey],D.[ActualEndDateKey],D.[ScheduledDurationDays],D.[ActualDurationDays],D.[ActualResourceHrs],D.[PlannedCost],D.[ActualCost],D.[IsLastOperation],D.[DQReasonCode],D.[DQRuleVersion]);
UPDATE D SET D.[LocationKey]=P.[LocationKey],D.[ScheduledStartDateKey]=P.[ScheduledStartDateKey],D.[ScheduledEndDateKey]=P.[ScheduledEndDateKey],D.[ActualStartDateKey]=P.[ActualStartDateKey],D.[ActualEndDateKey]=P.[ActualEndDateKey],D.[ScheduledDurationDays]=P.[ScheduledDurationDays],D.[ActualDurationDays]=P.[ActualDurationDays],D.[ActualResourceHrs]=P.[ActualResourceHrs],D.[PlannedCost]=P.[PlannedCost],D.[ActualCost]=P.[ActualCost],D.[IsLastOperation]=P.[IsLastOperation],D.[DQReasonCode]=P.[DQReasonCode],D.[DQRuleVersion]=P.[DQRuleVersion],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Fact_WorkOrderOperation D JOIN etl_calc.[Fact_WorkOrderOperation] P ON P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence] WHERE EXISTS(SELECT P.[LocationKey],P.[ScheduledStartDateKey],P.[ScheduledEndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[ScheduledDurationDays],P.[ActualDurationDays],P.[ActualResourceHrs],P.[PlannedCost],P.[ActualCost],P.[IsLastOperation],P.[DQReasonCode],P.[DQRuleVersion] EXCEPT SELECT D.[LocationKey],D.[ScheduledStartDateKey],D.[ScheduledEndDateKey],D.[ActualStartDateKey],D.[ActualEndDateKey],D.[ScheduledDurationDays],D.[ActualDurationDays],D.[ActualResourceHrs],D.[PlannedCost],D.[ActualCost],D.[IsLastOperation],D.[DQReasonCode],D.[DQRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrderOperation'''',''''I'''',(SELECT P.[WorkOrderID],P.[ProductKey],P.[OperationSequence] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_WorkOrderOperation] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_WorkOrderOperation D WHERE P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence]);
INSERT dw.Fact_WorkOrderOperation([WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) SELECT P.[WorkOrderID],P.[OperationSequence],P.[ProductKey],P.[LocationKey],P.[ScheduledStartDateKey],P.[ScheduledEndDateKey],P.[ActualStartDateKey],P.[ActualEndDateKey],P.[ScheduledDurationDays],P.[ActualDurationDays],P.[ActualResourceHrs],P.[PlannedCost],P.[ActualCost],P.[IsLastOperation],P.[DQReasonCode],P.[DQRuleVersion],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_WorkOrderOperation] P WHERE NOT EXISTS(SELECT 1 FROM dw.Fact_WorkOrderOperation D WHERE P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Fact_WorkOrderOperation'''',''''D'''',(SELECT D.[WorkOrderID],D.[ProductKey],D.[OperationSequence] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Fact_WorkOrderOperation D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_WorkOrderOperation] P WHERE P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence]);
DELETE D FROM dw.Fact_WorkOrderOperation D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_WorkOrderOperation] P WHERE P.[WorkOrderID]=D.[WorkOrderID] AND P.[ProductKey]=D.[ProductKey] AND P.[OperationSequence]=D.[OperationSequence]);
IF EXISTS(SELECT [WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_WorkOrderOperation] EXCEPT SELECT [WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_WorkOrderOperation) OR EXISTS(SELECT [WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion] FROM dw.Fact_WorkOrderOperation EXCEPT SELECT [WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion] FROM etl_calc.[Fact_WorkOrderOperation]) THROW 51940,N''''Projected target mismatch: dw.Fact_WorkOrderOperation'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Ref_ProductPriceHistory'''',''''U'''',(SELECT D.[ProductKey],D.[PriceType],D.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dw.Ref_ProductPriceHistory D JOIN etl_calc.[Ref_ProductPriceHistory] P ON P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate] WHERE EXISTS(SELECT P.[EndDate],P.[Amount] EXCEPT SELECT D.[EndDate],D.[Amount]);
UPDATE D SET D.[EndDate]=P.[EndDate],D.[Amount]=P.[Amount],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dw.Ref_ProductPriceHistory D JOIN etl_calc.[Ref_ProductPriceHistory] P ON P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate] WHERE EXISTS(SELECT P.[EndDate],P.[Amount] EXCEPT SELECT D.[EndDate],D.[Amount]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Ref_ProductPriceHistory'''',''''I'''',(SELECT P.[ProductKey],P.[PriceType],P.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Ref_ProductPriceHistory] P WHERE NOT EXISTS(SELECT 1 FROM dw.Ref_ProductPriceHistory D WHERE P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate]);
INSERT dw.Ref_ProductPriceHistory([ProductKey],[PriceType],[StartDate],[EndDate],[Amount],[LoadBatchID],[LoadedAt]) SELECT P.[ProductKey],P.[PriceType],P.[StartDate],P.[EndDate],P.[Amount],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Ref_ProductPriceHistory] P WHERE NOT EXISTS(SELECT 1 FROM dw.Ref_ProductPriceHistory D WHERE P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dw.Ref_ProductPriceHistory'''',''''D'''',(SELECT D.[ProductKey],D.[PriceType],D.[StartDate] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dw.Ref_ProductPriceHistory D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Ref_ProductPriceHistory] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate]);
DELETE D FROM dw.Ref_ProductPriceHistory D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Ref_ProductPriceHistory] P WHERE P.[ProductKey]=D.[ProductKey] AND P.[PriceType]=D.[PriceType] AND P.[StartDate]=D.[StartDate]);
IF EXISTS(SELECT [ProductKey],[PriceType],[StartDate],[EndDate],[Amount] FROM etl_calc.[Ref_ProductPriceHistory] EXCEPT SELECT [ProductKey],[PriceType],[StartDate],[EndDate],[Amount] FROM dw.Ref_ProductPriceHistory) OR EXISTS(SELECT [ProductKey],[PriceType],[StartDate],[EndDate],[Amount] FROM dw.Ref_ProductPriceHistory EXCEPT SELECT [ProductKey],[PriceType],[StartDate],[EndDate],[Amount] FROM etl_calc.[Ref_ProductPriceHistory]) THROW 51940,N''''Projected target mismatch: dw.Ref_ProductPriceHistory'''',1;
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dss.Fact_DemandDaily'''',''''U'''',(SELECT D.[DateKey],D.[ProductKey],D.[DemandRuleVersion] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM dss.Fact_DemandDaily D JOIN etl_calc.[Fact_DemandDaily] P ON P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion] WHERE EXISTS(SELECT P.[IndependentQty],P.[PromoIndependentQty],P.[DependentQty],P.[TotalDemandQty],P.[EligibleSalesLineCount],P.[ExcludedSalesLineCount],P.[ParentWorkOrderCount],P.[IsInSellWindow] EXCEPT SELECT D.[IndependentQty],D.[PromoIndependentQty],D.[DependentQty],D.[TotalDemandQty],D.[EligibleSalesLineCount],D.[ExcludedSalesLineCount],D.[ParentWorkOrderCount],D.[IsInSellWindow]);
UPDATE D SET D.[IndependentQty]=P.[IndependentQty],D.[PromoIndependentQty]=P.[PromoIndependentQty],D.[DependentQty]=P.[DependentQty],D.[TotalDemandQty]=P.[TotalDemandQty],D.[EligibleSalesLineCount]=P.[EligibleSalesLineCount],D.[ExcludedSalesLineCount]=P.[ExcludedSalesLineCount],D.[ParentWorkOrderCount]=P.[ParentWorkOrderCount],D.[IsInSellWindow]=P.[IsInSellWindow],D.[LoadBatchID]=P.[LoadBatchID],D.[LoadedAt]=P.[LoadedAt] FROM dss.Fact_DemandDaily D JOIN etl_calc.[Fact_DemandDaily] P ON P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion] WHERE EXISTS(SELECT P.[IndependentQty],P.[PromoIndependentQty],P.[DependentQty],P.[TotalDemandQty],P.[EligibleSalesLineCount],P.[ExcludedSalesLineCount],P.[ParentWorkOrderCount],P.[IsInSellWindow] EXCEPT SELECT D.[IndependentQty],D.[PromoIndependentQty],D.[DependentQty],D.[TotalDemandQty],D.[EligibleSalesLineCount],D.[ExcludedSalesLineCount],D.[ParentWorkOrderCount],D.[IsInSellWindow]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dss.Fact_DemandDaily'''',''''I'''',(SELECT P.[DateKey],P.[ProductKey],P.[DemandRuleVersion] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL,(SELECT P.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM etl_calc.[Fact_DemandDaily] P WHERE NOT EXISTS(SELECT 1 FROM dss.Fact_DemandDaily D WHERE P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion]);
INSERT dss.Fact_DemandDaily([DateKey],[ProductKey],[DemandRuleVersion],[IndependentQty],[PromoIndependentQty],[DependentQty],[TotalDemandQty],[EligibleSalesLineCount],[ExcludedSalesLineCount],[ParentWorkOrderCount],[IsInSellWindow],[LoadBatchID],[LoadedAt]) SELECT P.[DateKey],P.[ProductKey],P.[DemandRuleVersion],P.[IndependentQty],P.[PromoIndependentQty],P.[DependentQty],P.[TotalDemandQty],P.[EligibleSalesLineCount],P.[ExcludedSalesLineCount],P.[ParentWorkOrderCount],P.[IsInSellWindow],P.[LoadBatchID],P.[LoadedAt] FROM etl_calc.[Fact_DemandDaily] P WHERE NOT EXISTS(SELECT 1 FROM dss.Fact_DemandDaily D WHERE P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion]);
INSERT etl_v2.TargetChange(BatchID,TableName,Operation,KeyJson,BeforeJson,AfterJson) SELECT @B,N''''dss.Fact_DemandDaily'''',''''D'''',(SELECT D.[DateKey],D.[ProductKey],D.[DemandRuleVersion] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),(SELECT D.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES),NULL FROM dss.Fact_DemandDaily D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_DemandDaily] P WHERE P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion]);
DELETE D FROM dss.Fact_DemandDaily D WHERE NOT EXISTS(SELECT 1 FROM etl_calc.[Fact_DemandDaily] P WHERE P.[DateKey]=D.[DateKey] AND P.[ProductKey]=D.[ProductKey] AND P.[DemandRuleVersion]=D.[DemandRuleVersion]);
IF EXISTS(SELECT [DateKey],[ProductKey],[DemandRuleVersion],[IndependentQty],[PromoIndependentQty],[DependentQty],[TotalDemandQty],[EligibleSalesLineCount],[ExcludedSalesLineCount],[ParentWorkOrderCount],[IsInSellWindow] FROM etl_calc.[Fact_DemandDaily] EXCEPT SELECT [DateKey],[ProductKey],[DemandRuleVersion],[IndependentQty],[PromoIndependentQty],[DependentQty],[TotalDemandQty],[EligibleSalesLineCount],[ExcludedSalesLineCount],[ParentWorkOrderCount],[IsInSellWindow] FROM dss.Fact_DemandDaily) OR EXISTS(SELECT [DateKey],[ProductKey],[DemandRuleVersion],[IndependentQty],[PromoIndependentQty],[DependentQty],[TotalDemandQty],[EligibleSalesLineCount],[ExcludedSalesLineCount],[ParentWorkOrderCount],[IsInSellWindow] FROM dss.Fact_DemandDaily EXCEPT SELECT [DateKey],[ProductKey],[DemandRuleVersion],[IndependentQty],[PromoIndependentQty],[DependentQty],[TotalDemandQty],[EligibleSalesLineCount],[ExcludedSalesLineCount],[ParentWorkOrderCount],[IsInSellWindow] FROM etl_calc.[Fact_DemandDaily]) THROW 51940,N''''Projected target mismatch: dss.Fact_DemandDaily'''',1;
END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Validate @B bigint AS BEGIN SET NOCOUNT ON;
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_BillOfMaterials'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.BillOfMaterials),(SELECT COUNT_BIG(*) FROM etl_raw.[BillOfMaterials]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_Location'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.Location),(SELECT COUNT_BIG(*) FROM etl_raw.[Location]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_Product'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.Product),(SELECT COUNT_BIG(*) FROM etl_raw.[Product]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductCategory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ProductCategory),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductCategory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductCostHistory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ProductCostHistory),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductCostHistory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductInventory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ProductInventory),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductInventory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductListPriceHistory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ProductListPriceHistory),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductListPriceHistory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductSubcategory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ProductSubcategory),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductSubcategory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ScrapReason'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.ScrapReason),(SELECT COUNT_BIG(*) FROM etl_raw.[ScrapReason]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_TransactionHistory'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.TransactionHistory),(SELECT COUNT_BIG(*) FROM etl_raw.[TransactionHistory]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_TransactionHistoryArchive'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.TransactionHistoryArchive),(SELECT COUNT_BIG(*) FROM etl_raw.[TransactionHistoryArchive]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_UnitMeasure'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.UnitMeasure),(SELECT COUNT_BIG(*) FROM etl_raw.[UnitMeasure]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_WorkOrder'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.WorkOrder),(SELECT COUNT_BIG(*) FROM etl_raw.[WorkOrder]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_WorkOrderRouting'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Production.WorkOrderRouting),(SELECT COUNT_BIG(*) FROM etl_raw.[WorkOrderRouting]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_ProductVendor'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Purchasing.ProductVendor),(SELECT COUNT_BIG(*) FROM etl_raw.[ProductVendor]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_PurchaseOrderDetail'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Purchasing.PurchaseOrderDetail),(SELECT COUNT_BIG(*) FROM etl_raw.[PurchaseOrderDetail]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_PurchaseOrderHeader'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Purchasing.PurchaseOrderHeader),(SELECT COUNT_BIG(*) FROM etl_raw.[PurchaseOrderHeader]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_Vendor'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Purchasing.Vendor),(SELECT COUNT_BIG(*) FROM etl_raw.[Vendor]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_Customer'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Sales.Customer),(SELECT COUNT_BIG(*) FROM etl_raw.[Customer]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_SalesOrderDetail'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Sales.SalesOrderDetail),(SELECT COUNT_BIG(*) FROM etl_raw.[SalesOrderDetail]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_SalesOrderHeader'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Sales.SalesOrderHeader),(SELECT COUNT_BIG(*) FROM etl_raw.[SalesOrderHeader]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_SpecialOffer'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Sales.SpecialOffer),(SELECT COUNT_BIG(*) FROM etl_raw.[SpecialOffer]));
INSERT etl_v2.Validation VALUES(@B,N''''RawCount_SpecialOfferProduct'''',(SELECT COUNT_BIG(*) FROM [__SOURCE_DB__].Sales.SpecialOfferProduct),(SELECT COUNT_BIG(*) FROM etl_raw.[SpecialOfferProduct]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Bridge_BillOfMaterials'''',(SELECT COUNT_BIG(*) FROM etl_raw.[BillOfMaterials]),(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_BillOfMaterials]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Bridge_ProductPromotion'''',(SELECT COUNT_BIG(*) FROM etl_raw.[SpecialOfferProduct]),(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_ProductPromotion]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_SalesOrderLine'''',(SELECT COUNT_BIG(*) FROM etl_raw.[SalesOrderDetail]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_PurchaseOrderLine'''',(SELECT COUNT_BIG(*) FROM etl_raw.[PurchaseOrderDetail]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_ProductVendorTerms'''',(SELECT COUNT_BIG(*) FROM etl_raw.[ProductVendor]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_WorkOrder'''',(SELECT COUNT_BIG(*) FROM etl_raw.[WorkOrder]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_WorkOrderOperation'''',(SELECT COUNT_BIG(*) FROM etl_raw.[WorkOrderRouting]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation]));
INSERT etl_v2.Validation VALUES(@B,N''''ProjectionCount_Fact_InventoryOnHand'''',(SELECT COUNT_BIG(*) FROM etl_raw.[ProductInventory]),(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_InventoryOnHand]));
INSERT etl_v2.Validation VALUES(@B,N''''SalesQty'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_effective.SalesOrderDetail),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_calc.[Fact_SalesOrderLine]));
INSERT etl_v2.Validation VALUES(@B,N''''SalesAmount'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[LineTotal])),0) FROM etl_effective.SalesOrderDetail),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[LineTotal])),0) FROM etl_calc.[Fact_SalesOrderLine]));
INSERT etl_v2.Validation VALUES(@B,N''''PurchaseQty'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_raw.PurchaseOrderDetail),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_calc.[Fact_PurchaseOrderLine]));
INSERT etl_v2.Validation VALUES(@B,N''''WorkQty'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_raw.WorkOrder),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[OrderQty])),0) FROM etl_calc.[Fact_WorkOrder]));
INSERT etl_v2.Validation VALUES(@B,N''''ScrapQty'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[ScrappedQty])),0) FROM etl_raw.WorkOrder),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[ScrappedQty])),0) FROM etl_calc.[Fact_WorkOrder]));
INSERT etl_v2.Validation VALUES(@B,N''''InventoryQty'''',(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[Quantity])),0) FROM etl_raw.ProductInventory),(SELECT COALESCE(SUM(CONVERT(decimal(38,6),[QuantityOnHand])),0) FROM etl_calc.[Fact_InventoryOnHand]));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dss_Fact_DemandDaily_DateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_DemandDaily] F WHERE F.[DateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[DateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dss_Fact_DemandDaily_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_DemandDaily] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Bridge_BillOfMaterials_AssemblyProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_BillOfMaterials] F WHERE F.[AssemblyProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[AssemblyProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Bridge_BillOfMaterials_ComponentProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_BillOfMaterials] F WHERE F.[ComponentProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ComponentProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Bridge_BillOfMaterials_UnitMeasureKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_BillOfMaterials] F WHERE F.[UnitMeasureKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_UnitMeasure] D WHERE F.[UnitMeasureKey]=D.[UnitMeasureKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Bridge_ProductPromotion_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_ProductPromotion] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Bridge_ProductPromotion_PromotionKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Bridge_ProductPromotion] F WHERE F.[PromotionKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Promotion] D WHERE F.[PromotionKey]=D.[PromotionKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_InventoryOnHand_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_InventoryOnHand] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_InventoryOnHand_LocationKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_InventoryOnHand] F WHERE F.[LocationKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Location] D WHERE F.[LocationKey]=D.[LocationKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_InventoryOnHand_AsOfDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_InventoryOnHand] F WHERE F.[AsOfDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[AsOfDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_ProductVendorTerms_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_ProductVendorTerms_VendorKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms] F WHERE F.[VendorKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Vendor] D WHERE F.[VendorKey]=D.[VendorKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_ProductVendorTerms_AsOfDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms] F WHERE F.[AsOfDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[AsOfDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_ProductVendorTerms_UnitMeasureKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms] F WHERE F.[UnitMeasureKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_UnitMeasure] D WHERE F.[UnitMeasureKey]=D.[UnitMeasureKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_ProductVendorTerms_LastReceiptDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_ProductVendorTerms] F WHERE F.[LastReceiptDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[LastReceiptDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_OrderDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[OrderDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[OrderDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_ExpectedShipDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[ExpectedShipDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ExpectedShipDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_ExpectedReceiptDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[ExpectedReceiptDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ExpectedReceiptDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_VendorKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[VendorKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Vendor] D WHERE F.[VendorKey]=D.[VendorKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_PurchaseOrderLine_PurchaseStatusKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_PurchaseOrderLine] F WHERE F.[PurchaseStatusKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_PurchaseStatus] D WHERE F.[PurchaseStatusKey]=D.[PurchaseStatusKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_OrderDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[OrderDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[OrderDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_DueDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[DueDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[DueDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_ShipDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[ShipDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ShipDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_PromotionKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[PromotionKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Promotion] D WHERE F.[PromotionKey]=D.[PromotionKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_SalesStatusKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[SalesStatusKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_SalesStatus] D WHERE F.[SalesStatusKey]=D.[SalesStatusKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_CustomerKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[CustomerKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Customer] D WHERE F.[CustomerKey]=D.[CustomerKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_SalesOrderLine_ChannelKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_SalesOrderLine] F WHERE F.[ChannelKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Channel] D WHERE F.[ChannelKey]=D.[ChannelKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_ScrapReasonKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[ScrapReasonKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_ScrapReason] D WHERE F.[ScrapReasonKey]=D.[ScrapReasonKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_StartDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[StartDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[StartDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_DueDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[DueDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[DueDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_EndDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[EndDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[EndDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_ActualStartDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[ActualStartDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ActualStartDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrder_ActualEndDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrder] F WHERE F.[ActualEndDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ActualEndDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_LocationKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[LocationKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Location] D WHERE F.[LocationKey]=D.[LocationKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_ScheduledStartDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[ScheduledStartDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ScheduledStartDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_ScheduledEndDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[ScheduledEndDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ScheduledEndDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_ActualStartDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[ActualStartDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ActualStartDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Fact_WorkOrderOperation_ActualEndDateKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Fact_WorkOrderOperation] F WHERE F.[ActualEndDateKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Date] D WHERE F.[ActualEndDateKey]=D.[DateKey])));
INSERT etl_v2.Validation VALUES(@B,N''''FK_dw_Ref_ProductPriceHistory_ProductKey'''',0,(SELECT COUNT_BIG(*) FROM etl_calc.[Ref_ProductPriceHistory] F WHERE F.[ProductKey] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM etl_calc.[Dim_Product] D WHERE F.[ProductKey]=D.[ProductKey])));
IF EXISTS(SELECT 1 FROM etl_v2.Validation WHERE BatchID=@B AND Expected<>Actual) THROW 51941,''''Independent ETL reconciliation failed; transaction rolled back.'''',1; END;'');
EXEC(N''CREATE OR ALTER PROCEDURE etl_v2.Run @FailAfterCapture bit=0 AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Lock int,@B bigint=NULL,@Previous bigint,@Next bigint,@Changes bigint,@Targets bigint,@Summary nvarchar(max);
 EXEC @Lock=sys.sp_getapplock @Resource=N''''DSS_RESULT'''',@LockMode=''''Exclusive'''',@LockOwner=''''Session'''',@LockTimeout=0;
 IF @Lock<0 THROW 51901,''''DW publication/ETL is busy; no changes made.'''',1;
 BEGIN TRY
  EXEC @Lock=sys.sp_getapplock @Resource=N''''InventorySafety_FullLoad'''',@LockMode=''''Exclusive'''',@LockOwner=''''Session'''',@LockTimeout=0;
  IF @Lock<0 THROW 51902,''''Another ETL load is busy.'''',1;
  IF EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE Status=''''RUNNING'''') THROW 51903,''''A batch is already RUNNING; inspect it before loading.'''',1;
  SELECT @Previous=LastVersion FROM etl_v2.State WHERE Id=1;
  INSERT etl.ETL_LoadBatch(SourceSystem,PipelineName,ExtractionMode,LoadMode,ExtractStartedAt,RuleSetVersion,Status,ValidationStatus,SourceSnapshotReference)
   VALUES(N''''CompanyX SQL Server'''',N''''DWH_INCREMENTAL_V2'''',IIF(@Previous IS NULL,N''''FULL'''',N''''INCREMENTAL''''),IIF(@Previous IS NULL,N''''INITIAL_FULL'''',N''''INCREMENTAL''''),SYSUTCDATETIME(),N''''S2T-V6;SAL-BACKFILL-v2;CT-v1'''',N''''RUNNING'''',N''''NOT_RUN'''',N''''Change Tracking: atomic source version, retained raw deltas and row before-images'''');
  SET @B=SCOPE_IDENTITY();
  INSERT etl_v2.BatchState VALUES(@B,@Previous,NULL,SYSUTCDATETIME(),NULL,NULL,''''RUNNING'''',NULL);
  SET TRANSACTION ISOLATION LEVEL SNAPSHOT;
  BEGIN TRAN;
  EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_CURRENT_VERSION()'''',N''''@V bigint OUTPUT'''',@Next OUTPUT;
  IF @Next IS NULL THROW 51904,''''Source Change Tracking is not enabled.'''',1;
  IF @Previous>@Next THROW 51905,''''Source watermark moved backwards; explicit recovery required.'''',1;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_BillOfMaterials bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.BillOfMaterials''''''''))'''',N''''@V bigint OUTPUT'''',@Min_BillOfMaterials OUTPUT; IF @Min_BillOfMaterials IS NULL OR @Previous<@Min_BillOfMaterials THROW 51905,N''''Expired or reset Change Tracking watermark: Production.BillOfMaterials; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_Location bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.Location''''''''))'''',N''''@V bigint OUTPUT'''',@Min_Location OUTPUT; IF @Min_Location IS NULL OR @Previous<@Min_Location THROW 51905,N''''Expired or reset Change Tracking watermark: Production.Location; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_Product bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.Product''''''''))'''',N''''@V bigint OUTPUT'''',@Min_Product OUTPUT; IF @Min_Product IS NULL OR @Previous<@Min_Product THROW 51905,N''''Expired or reset Change Tracking watermark: Production.Product; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductCategory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ProductCategory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductCategory OUTPUT; IF @Min_ProductCategory IS NULL OR @Previous<@Min_ProductCategory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ProductCategory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductCostHistory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ProductCostHistory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductCostHistory OUTPUT; IF @Min_ProductCostHistory IS NULL OR @Previous<@Min_ProductCostHistory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ProductCostHistory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductInventory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ProductInventory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductInventory OUTPUT; IF @Min_ProductInventory IS NULL OR @Previous<@Min_ProductInventory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ProductInventory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductListPriceHistory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ProductListPriceHistory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductListPriceHistory OUTPUT; IF @Min_ProductListPriceHistory IS NULL OR @Previous<@Min_ProductListPriceHistory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ProductListPriceHistory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductSubcategory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ProductSubcategory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductSubcategory OUTPUT; IF @Min_ProductSubcategory IS NULL OR @Previous<@Min_ProductSubcategory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ProductSubcategory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ScrapReason bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.ScrapReason''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ScrapReason OUTPUT; IF @Min_ScrapReason IS NULL OR @Previous<@Min_ScrapReason THROW 51905,N''''Expired or reset Change Tracking watermark: Production.ScrapReason; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_TransactionHistory bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.TransactionHistory''''''''))'''',N''''@V bigint OUTPUT'''',@Min_TransactionHistory OUTPUT; IF @Min_TransactionHistory IS NULL OR @Previous<@Min_TransactionHistory THROW 51905,N''''Expired or reset Change Tracking watermark: Production.TransactionHistory; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_TransactionHistoryArchive bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.TransactionHistoryArchive''''''''))'''',N''''@V bigint OUTPUT'''',@Min_TransactionHistoryArchive OUTPUT; IF @Min_TransactionHistoryArchive IS NULL OR @Previous<@Min_TransactionHistoryArchive THROW 51905,N''''Expired or reset Change Tracking watermark: Production.TransactionHistoryArchive; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_UnitMeasure bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.UnitMeasure''''''''))'''',N''''@V bigint OUTPUT'''',@Min_UnitMeasure OUTPUT; IF @Min_UnitMeasure IS NULL OR @Previous<@Min_UnitMeasure THROW 51905,N''''Expired or reset Change Tracking watermark: Production.UnitMeasure; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_WorkOrder bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.WorkOrder''''''''))'''',N''''@V bigint OUTPUT'''',@Min_WorkOrder OUTPUT; IF @Min_WorkOrder IS NULL OR @Previous<@Min_WorkOrder THROW 51905,N''''Expired or reset Change Tracking watermark: Production.WorkOrder; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_WorkOrderRouting bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Production.WorkOrderRouting''''''''))'''',N''''@V bigint OUTPUT'''',@Min_WorkOrderRouting OUTPUT; IF @Min_WorkOrderRouting IS NULL OR @Previous<@Min_WorkOrderRouting THROW 51905,N''''Expired or reset Change Tracking watermark: Production.WorkOrderRouting; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_ProductVendor bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Purchasing.ProductVendor''''''''))'''',N''''@V bigint OUTPUT'''',@Min_ProductVendor OUTPUT; IF @Min_ProductVendor IS NULL OR @Previous<@Min_ProductVendor THROW 51905,N''''Expired or reset Change Tracking watermark: Purchasing.ProductVendor; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_PurchaseOrderDetail bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Purchasing.PurchaseOrderDetail''''''''))'''',N''''@V bigint OUTPUT'''',@Min_PurchaseOrderDetail OUTPUT; IF @Min_PurchaseOrderDetail IS NULL OR @Previous<@Min_PurchaseOrderDetail THROW 51905,N''''Expired or reset Change Tracking watermark: Purchasing.PurchaseOrderDetail; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_PurchaseOrderHeader bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Purchasing.PurchaseOrderHeader''''''''))'''',N''''@V bigint OUTPUT'''',@Min_PurchaseOrderHeader OUTPUT; IF @Min_PurchaseOrderHeader IS NULL OR @Previous<@Min_PurchaseOrderHeader THROW 51905,N''''Expired or reset Change Tracking watermark: Purchasing.PurchaseOrderHeader; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_Vendor bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Purchasing.Vendor''''''''))'''',N''''@V bigint OUTPUT'''',@Min_Vendor OUTPUT; IF @Min_Vendor IS NULL OR @Previous<@Min_Vendor THROW 51905,N''''Expired or reset Change Tracking watermark: Purchasing.Vendor; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_Customer bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Sales.Customer''''''''))'''',N''''@V bigint OUTPUT'''',@Min_Customer OUTPUT; IF @Min_Customer IS NULL OR @Previous<@Min_Customer THROW 51905,N''''Expired or reset Change Tracking watermark: Sales.Customer; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_SalesOrderDetail bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Sales.SalesOrderDetail''''''''))'''',N''''@V bigint OUTPUT'''',@Min_SalesOrderDetail OUTPUT; IF @Min_SalesOrderDetail IS NULL OR @Previous<@Min_SalesOrderDetail THROW 51905,N''''Expired or reset Change Tracking watermark: Sales.SalesOrderDetail; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_SalesOrderHeader bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Sales.SalesOrderHeader''''''''))'''',N''''@V bigint OUTPUT'''',@Min_SalesOrderHeader OUTPUT; IF @Min_SalesOrderHeader IS NULL OR @Previous<@Min_SalesOrderHeader THROW 51905,N''''Expired or reset Change Tracking watermark: Sales.SalesOrderHeader; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_SpecialOffer bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Sales.SpecialOffer''''''''))'''',N''''@V bigint OUTPUT'''',@Min_SpecialOffer OUTPUT; IF @Min_SpecialOffer IS NULL OR @Previous<@Min_SpecialOffer THROW 51905,N''''Expired or reset Change Tracking watermark: Sales.SpecialOffer; explicit rebaseline required.'''',1; END;
IF @Previous IS NOT NULL BEGIN DECLARE @Min_SpecialOfferProduct bigint; EXEC [__SOURCE_DB__].sys.sp_executesql N''''SELECT @V=CHANGE_TRACKING_MIN_VALID_VERSION(OBJECT_ID(N''''''''Sales.SpecialOfferProduct''''''''))'''',N''''@V bigint OUTPUT'''',@Min_SpecialOfferProduct OUTPUT; IF @Min_SpecialOfferProduct IS NULL OR @Previous<@Min_SpecialOfferProduct THROW 51905,N''''Expired or reset Change Tracking watermark: Sales.SpecialOfferProduct; explicit rebaseline required.'''',1; END;

  EXEC etl_v2.Capture @B,@Previous,@Next;
  SELECT @Changes=COUNT_BIG(*) FROM etl_v2.SourceChange WHERE BatchID=@B;
  IF @FailAfterCapture=1 THROW 51906,''''TEST injected failure after source capture.'''',1;
  UPDATE etl.ETL_LoadBatch SET ExtractCompletedAt=SYSUTCDATETIME(),LoadStartedAt=SYSUTCDATETIME() WHERE LoadBatchID=@B;
  IF @Previous IS NULL OR @Changes>0 BEGIN
   EXEC etl_v2.Project @B;
   EXEC etl_v2.Validate @B;
   EXEC etl_v2.Publish @B;
  END;
  SELECT @Targets=COUNT_BIG(*) FROM etl_v2.TargetChange WHERE BatchID=@B;
  SET @Summary=(SELECT @Previous PreviousVersion,@Next CapturedVersion,@Changes SourceChanges,@Targets TargetChanges,(SELECT COUNT(*) FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution=''''UNRESOLVED'''') UnresolvedCorrections FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
  UPDATE etl_v2.State SET LastVersion=@Next,LastBatchID=@B WHERE Id=1;
  UPDATE etl_v2.BatchState SET CapturedVersion=@Next,SourceChangeCount=@Changes,TargetChangeCount=@Targets,Status=''''SUCCEEDED'''' WHERE BatchID=@B;
  UPDATE etl.ETL_LoadBatch SET Status=''''SUCCEEDED'''',ValidationStatus=IIF(EXISTS(SELECT 1 FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution=''''UNRESOLVED''''),''''PASSED_WITH_WARNINGS'''',''''PASSED''''),LoadCompletedAt=SYSUTCDATETIME(),ValidationSummary=@Summary WHERE LoadBatchID=@B;
  COMMIT;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  EXEC sys.sp_releaseapplock @Resource=N''''InventorySafety_FullLoad'''',@LockOwner=''''Session'''';
  EXEC sys.sp_releaseapplock @Resource=N''''DSS_RESULT'''',@LockOwner=''''Session'''';
  SELECT * FROM etl_v2.BatchState WHERE BatchID=@B;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  DECLARE @Error nvarchar(max)=CONCAT(ERROR_NUMBER(),'''': '''',ERROR_MESSAGE());
  IF @B IS NOT NULL BEGIN
   UPDATE etl.ETL_LoadBatch SET Status=''''FAILED'''',ValidationStatus=''''FAILED'''',LoadCompletedAt=SYSUTCDATETIME(),ErrorMessage=@Error WHERE LoadBatchID=@B;
   UPDATE etl_v2.BatchState SET Status=''''FAILED'''',ErrorMessage=@Error WHERE BatchID=@B;
  END;
  EXEC sys.sp_releaseapplock @Resource=N''''InventorySafety_FullLoad'''',@LockOwner=''''Session'''';
  EXEC sys.sp_releaseapplock @Resource=N''''DSS_RESULT'''',@LockOwner=''''Session'''';
  THROW;
 END CATCH;
END;
'');
';
SET @Install=REPLACE(@Install,N'__SOURCE_DB__',@SourceDatabase); EXEC sys.sp_executesql @Install;

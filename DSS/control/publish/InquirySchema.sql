-- Additive inquiry metadata in the owned copied warehouse. No old view changes.
SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF SCHEMA_ID('cxcontrol') IS NULL EXEC('CREATE SCHEMA cxcontrol AUTHORIZATION dbo');
IF OBJECT_ID('cxcontrol.Inquiry','U') IS NULL
CREATE TABLE cxcontrol.Inquiry(
 InquiryKey bigint IDENTITY PRIMARY KEY, InquiryID nvarchar(100) NOT NULL UNIQUE,
 KnownAt date NOT NULL, AnalysisEnd date NOT NULL, BaseRunCode uniqueidentifier NOT NULL,
 SourceSnapshotHash char(64) NOT NULL, RequestHash char(64) NOT NULL,
 RequestJSON nvarchar(max) NOT NULL CHECK(ISJSON(RequestJSON)=1), CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CHECK(AnalysisEnd>=KnownAt));
IF OBJECT_ID('cxcontrol.Candidate','U') IS NULL
CREATE TABLE cxcontrol.Candidate(
 CandidateKey bigint IDENTITY PRIMARY KEY, InquiryKey bigint NOT NULL REFERENCES cxcontrol.Inquiry(InquiryKey),
 CandidateID nvarchar(100) NOT NULL, CandidateKind varchar(20) NOT NULL CHECK(CandidateKind IN('BASELINE','FULL','STAGED')),
 PlanningRunKey int NOT NULL UNIQUE REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 ScopeFileHash char(64) NOT NULL, ScopeJSON nvarchar(max) NOT NULL CHECK(ISJSON(ScopeJSON)=1),
 SharedStateHash char(64) NOT NULL, PrefixProofHash char(64) NOT NULL,
 CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(), UNIQUE(InquiryKey,CandidateID));
IF OBJECT_ID('cxcontrol.Tranche','U') IS NULL
CREATE TABLE cxcontrol.Tranche(
 TrancheKey bigint IDENTITY PRIMARY KEY, CandidateKey bigint NOT NULL REFERENCES cxcontrol.Candidate(CandidateKey),
 TrancheNumber int NOT NULL CHECK(TrancheNumber>0), SourceSalesOrderID int NOT NULL,
 DueDate date NOT NULL, UNIQUE(CandidateKey,TrancheNumber), UNIQUE(CandidateKey,SourceSalesOrderID));
IF OBJECT_ID('cxcontrol.InquiryLine','U') IS NULL
CREATE TABLE cxcontrol.InquiryLine(
 InquiryLineKey bigint IDENTITY PRIMARY KEY, TrancheKey bigint NOT NULL REFERENCES cxcontrol.Tranche(TrancheKey),
 SourceSalesOrderDetailID int NOT NULL, ProductKey int NOT NULL REFERENCES dw.Dim_Product(ProductKey),
 RequestedQty decimal(28,8) NOT NULL CHECK(RequestedQty>0),
 UNIQUE(TrancheKey,SourceSalesOrderDetailID), UNIQUE(TrancheKey,ProductKey));
GO
CREATE OR ALTER VIEW cxcontrol.DimInquiry AS
SELECT InquiryKey,InquiryID,KnownAt,AnalysisEnd,CONVERT(nvarchar(36),BaseRunCode) BaseRunCode,
 CONVERT(nvarchar(160),CONCAT(InquiryID,N' | known ',CONVERT(nvarchar(10),KnownAt,23))) InquiryName,
 CONVERT(int,CONVERT(char(8),KnownAt,112)) KnownDateKey,
 CONVERT(int,CONVERT(char(8),AnalysisEnd,112)) AnalysisEndDateKey
FROM cxcontrol.Inquiry;
GO
CREATE OR ALTER VIEW cxcontrol.DimCandidate AS
SELECT c.CandidateKey,c.InquiryKey,c.CandidateID,c.CandidateKind,c.PlanningRunKey,
 CONVERT(nvarchar(180),CONCAT(c.CandidateKind,N' | ',c.CandidateID)) CandidateName,
 i.InquiryID,i.KnownAt,i.AnalysisEnd,c.SharedStateHash,c.PrefixProofHash
FROM cxcontrol.Candidate c JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey;
GO
CREATE OR ALTER VIEW cxcontrol.DimTranche AS
SELECT t.TrancheKey,t.CandidateKey,c.InquiryKey,t.TrancheNumber,t.SourceSalesOrderID,t.DueDate,
 CONVERT(nvarchar(180),CONCAT(c.CandidateID,N' / tranche ',t.TrancheNumber,N' / ',CONVERT(nvarchar(10),t.DueDate,23))) TrancheName
FROM cxcontrol.Tranche t JOIN cxcontrol.Candidate c ON c.CandidateKey=t.CandidateKey;
GO
CREATE OR ALTER VIEW cxcontrol.FactInquiryLineDelivery AS
WITH Delivery AS(
 SELECT c.PlanningRunKey,l.InquiryLineKey,
 SUM(CASE WHEN e.EventCode='SHIP_ON_TIME' THEN e.Quantity ELSE 0 END) OnTimeQty,
 SUM(CASE WHEN e.EventCode='SHIP_LATE' THEN e.Quantity ELSE 0 END) LateQty,
 SUM(CASE WHEN e.EventCode='LOST_SALE' THEN e.Quantity ELSE 0 END) LostQty,
 MAX(CASE WHEN e.EventCode IN('SHIP_ON_TIME','SHIP_LATE') THEN e.EventAt END) LastShipmentAt
 FROM cxcontrol.InquiryLine l JOIN cxcontrol.Tranche t ON t.TrancheKey=l.TrancheKey
 JOIN cxcontrol.Candidate c ON c.CandidateKey=t.CandidateKey
 JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
 LEFT JOIN dss.Fact_SimulationEvent e ON e.PlanningRunKey=c.PlanningRunKey
 AND e.EntityCode=CONCAT('SO_LINE:',l.SourceSalesOrderDetailID)
 AND e.EventCode IN('SHIP_ON_TIME','SHIP_LATE','LOST_SALE')
 AND CONVERT(date,e.EventAt) BETWEEN i.KnownAt AND i.AnalysisEnd
 GROUP BY c.PlanningRunKey,l.InquiryLineKey
)
SELECT l.InquiryLineKey,i.InquiryKey,c.CandidateKey,t.TrancheKey,c.PlanningRunKey,
 l.ProductKey,sp.StockUnitMeasureKey,CONVERT(int,CONVERT(char(8),i.KnownAt,112)) KnownDateKey,
 CONVERT(int,CONVERT(char(8),t.DueDate,112)) DueDateKey,
 CASE WHEN d.OnTimeQty+d.LateQty>=l.RequestedQty THEN COALESCE(CONVERT(int,CONVERT(char(8),d.LastShipmentAt,112)),0) ELSE 0 END CompletionDateKey,
 l.RequestedQty,d.OnTimeQty,d.LateQty,CONVERT(decimal(28,8),d.OnTimeQty+d.LateQty) FilledQty,d.LostQty,
 CONVERT(decimal(28,8),l.RequestedQty-d.OnTimeQty-d.LateQty-d.LostQty) EndingBacklogQty,
 CONVERT(bigint,1) InquiryLineCount,
 CONVERT(bigint,CASE WHEN d.OnTimeQty+d.LateQty>=l.RequestedQty THEN 1 ELSE 0 END) CompletedLineCount,
 CONVERT(bigint,CASE WHEN d.OnTimeQty>=l.RequestedQty THEN 1 ELSE 0 END) OnTimeCompleteLineCount
FROM cxcontrol.InquiryLine l JOIN cxcontrol.Tranche t ON t.TrancheKey=l.TrancheKey
JOIN cxcontrol.Candidate c ON c.CandidateKey=t.CandidateKey
JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
JOIN dss.RunEntity re ON re.PlanningRunKey=c.PlanningRunKey AND re.EntityCode=CONCAT('SO_LINE:',l.SourceSalesOrderDetailID)
 AND re.ProductKey=l.ProductKey AND re.EntityType='CUSTOMER_ORDER_LINE'
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=l.ProductKey
JOIN Delivery d ON d.InquiryLineKey=l.InquiryLineKey AND d.PlanningRunKey=c.PlanningRunKey;
GO
CREATE OR ALTER VIEW cxcontrol.FactInquiryTranche AS
SELECT i.InquiryKey,c.CandidateKey,t.TrancheKey,c.PlanningRunKey,
 CONVERT(int,CONVERT(char(8),i.KnownAt,112)) KnownDateKey,
 CONVERT(int,CONVERT(char(8),t.DueDate,112)) DueDateKey,
 COALESCE(CONVERT(int,CONVERT(char(8),f.CompletedAt,112)),0) CompletionDateKey,
 f.OrderStatus,CONVERT(bigint,1) TrancheCount,
 CONVERT(bigint,CASE WHEN f.OrderStatus='FULFILLED' AND CONVERT(date,f.CompletedAt)<=i.AnalysisEnd THEN 1 ELSE 0 END) CompletedTrancheCount,
 CONVERT(bigint,CASE WHEN f.OrderStatus='FULFILLED' AND CONVERT(date,f.CompletedAt)<=t.DueDate THEN 1 ELSE 0 END) OnTimeCompleteTrancheCount,
 CONVERT(bigint,CASE WHEN f.OrderStatus='LOST' THEN 1 ELSE 0 END) LostTrancheCount,
 CONVERT(bigint,f.ExpectedLineCount) RequestedLineCount
FROM cxcontrol.Tranche t JOIN cxcontrol.Candidate c ON c.CandidateKey=t.CandidateKey
JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
JOIN dss.Fact_SimulationOrder f ON f.PlanningRunKey=c.PlanningRunKey AND f.CustomerOrderCode=CONCAT('SO:',t.SourceSalesOrderID);
GO
CREATE OR ALTER VIEW cxcontrol.DimActivity AS
SELECT EventCode,EventName,QuantityMeaning FROM dss.Dim_EventType
WHERE EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER');
GO
CREATE OR ALTER VIEW cxcontrol.FactProductionActivity AS
SELECT c.InquiryKey,c.CandidateKey,f.PlanningRunKey,f.DateKey,f.ProductKey,sp.StockUnitMeasureKey,
 f.EventCode,f.Quantity,CONVERT(bigint,1) ActivityCount
FROM dss.Fact_SimulationEvent f JOIN cxcontrol.Candidate c ON c.PlanningRunKey=f.PlanningRunKey
JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=f.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey
WHERE f.EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER')
AND CONVERT(date,f.EventAt) BETWEEN i.KnownAt AND i.AnalysisEnd;
GO
GRANT SELECT ON SCHEMA::cxcontrol TO [CompanyXMOLAPReader];
GO

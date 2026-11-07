-- Requested intervals are separate from immutable source simulations.
SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF OBJECT_ID('cxcontrol.RequestedWindow','U') IS NULL
CREATE TABLE cxcontrol.RequestedWindow(
 WindowKey bigint IDENTITY PRIMARY KEY,WindowID nvarchar(80) NOT NULL UNIQUE,
 FamilyHash char(64) NOT NULL,KnownAt date NOT NULL,AnalysisEnd date NOT NULL,
 Purpose varchar(20) NOT NULL CHECK(Purpose IN('ORDER_INQUIRY','PIPELINE_SMOKE')),
 CacheAction varchar(10) NOT NULL CHECK(CacheAction IN('NEW','EXTEND','REUSE')),
 RequestHash char(64) NOT NULL,RequestJSON nvarchar(max) NOT NULL CHECK(ISJSON(RequestJSON)=1),
 CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),CHECK(KnownAt<=AnalysisEnd));
IF OBJECT_ID('cxcontrol.WindowCandidate','U') IS NULL
CREATE TABLE cxcontrol.WindowCandidate(
 WindowKey bigint NOT NULL REFERENCES cxcontrol.RequestedWindow(WindowKey),
 CandidateKey bigint NOT NULL REFERENCES cxcontrol.Candidate(CandidateKey),
 PlanningRunKey int NOT NULL REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 CandidateID nvarchar(100) NOT NULL,CacheAction varchar(10) NOT NULL CHECK(CacheAction IN('NEW','EXTEND','REUSE')),
 SourceEnd date NOT NULL,
 PRIMARY KEY(WindowKey,CandidateID),UNIQUE(WindowKey,PlanningRunKey));
GO
CREATE OR ALTER VIEW cxcontrol.DimRequestedWindow AS
SELECT WindowKey,WindowID,FamilyHash,KnownAt,AnalysisEnd,Purpose,CacheAction,
 CONVERT(nvarchar(200),CONCAT(WindowID,N' | ',CONVERT(nvarchar(10),KnownAt,23),N'..',CONVERT(nvarchar(10),AnalysisEnd,23))) WindowName
FROM cxcontrol.RequestedWindow;
GO
CREATE OR ALTER VIEW cxcontrol.FactRequestedWindowSummary AS
SELECT w.WindowKey,c.CandidateKey,c.PlanningRunKey,
 CONVERT(int,CONVERT(char(8),w.KnownAt,112)) WindowStartDateKey,
 CONVERT(int,CONVERT(char(8),w.AnalysisEnd,112)) WindowEndDateKey,
 TRY_CONVERT(int,JSON_VALUE(w.RequestJSON,'$.base_run_key')) ReferenceRunKey,
 d.CalendarDays WindowDays,CONVERT(float,d.InventoryValueDaySum)/NULLIF(d.CalendarDays,0) WindowAverageInventoryValue,
 o.DueOrderCount WindowDueOrderCount,o.OnTimeFullOrderCount WindowOnTimeFullOrderCount,
 CONVERT(float,o.OnTimeFullOrderCount)/NULLIF(o.DueOrderCount,0) WindowOTIF,
 rd.CalendarDays ReferenceROPDays,CONVERT(float,rd.InventoryValueDaySum)/NULLIF(rd.CalendarDays,0) ReferenceROPAverageInventoryValue,
 ro.DueOrderCount ReferenceROPDueOrderCount,ro.OnTimeFullOrderCount ReferenceROPOnTimeFullOrderCount,
 CONVERT(float,ro.OnTimeFullOrderCount)/NULLIF(ro.DueOrderCount,0) ReferenceROPOTIF
FROM cxcontrol.RequestedWindow w JOIN cxcontrol.WindowCandidate c ON c.WindowKey=w.WindowKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
OUTER APPLY(SELECT COUNT(DISTINCT f.DateKey) CalendarDays,SUM(f.InventoryValueDaySum) InventoryValueDaySum
 FROM cxcontrol.FactSimulationDaily f WHERE f.PlanningRunKey=c.PlanningRunKey
 AND f.DateKey BETWEEN CONVERT(int,CONVERT(char(8),w.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),w.AnalysisEnd,112))) d
OUTER APPLY(SELECT COUNT_BIG(*) DueOrderCount,
 COALESCE(SUM(CONVERT(bigint,CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=CONVERT(date,f.DueAt) THEN 1 ELSE 0 END)),0) OnTimeFullOrderCount
 FROM dss.Fact_SimulationOrder f WHERE f.PlanningRunKey=c.PlanningRunKey
 AND CONVERT(date,f.DueAt) BETWEEN w.KnownAt AND w.AnalysisEnd AND CONVERT(date,f.KnownAt)<=w.AnalysisEnd) o
OUTER APPLY(SELECT COUNT(DISTINCT f.DateKey) CalendarDays,SUM(f.InventoryValueDaySum) InventoryValueDaySum
 FROM cxcontrol.FactSimulationDaily f WHERE f.PlanningRunKey=TRY_CONVERT(int,JSON_VALUE(w.RequestJSON,'$.base_run_key'))
 AND f.DateKey BETWEEN CONVERT(int,CONVERT(char(8),w.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),w.AnalysisEnd,112))) rd
OUTER APPLY(SELECT COUNT_BIG(*) DueOrderCount,
 COALESCE(SUM(CONVERT(bigint,CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=CONVERT(date,f.DueAt) THEN 1 ELSE 0 END)),0) OnTimeFullOrderCount
 FROM dss.Fact_SimulationOrder f WHERE f.PlanningRunKey=TRY_CONVERT(int,JSON_VALUE(w.RequestJSON,'$.base_run_key'))
 AND CONVERT(date,f.DueAt) BETWEEN w.KnownAt AND w.AnalysisEnd AND CONVERT(date,f.KnownAt)<=w.AnalysisEnd) ro;
GO
CREATE OR ALTER VIEW cxcontrol.FactRequestedWindowLine AS
SELECT w.WindowKey,c.CandidateKey,c.PlanningRunKey,t.TrancheKey,l.InquiryLineKey,l.ProductKey,sp.StockUnitMeasureKey,
 CONVERT(int,CONVERT(char(8),w.KnownAt,112)) KnownDateKey,
 CONVERT(int,CONVERT(char(8),t.DueDate,112)) DueDateKey,
 CASE WHEN d.FilledQty>=l.RequestedQty THEN COALESCE(CONVERT(int,CONVERT(char(8),d.LastShipmentAt,112)),0) ELSE 0 END CompletionDateKey,
 l.RequestedQty,d.OnTimeQty,d.LateQty,d.FilledQty,d.LostQty,
 CONVERT(decimal(28,8),l.RequestedQty-d.FilledQty-d.LostQty) EndingBacklogQty,
 CONVERT(bigint,1) InquiryLineCount,
 CONVERT(bigint,CASE WHEN d.FilledQty>=l.RequestedQty THEN 1 ELSE 0 END) CompletedLineCount,
 CONVERT(bigint,CASE WHEN d.OnTimeQty>=l.RequestedQty THEN 1 ELSE 0 END) OnTimeCompleteLineCount
FROM cxcontrol.RequestedWindow w JOIN cxcontrol.WindowCandidate c ON c.WindowKey=w.WindowKey
JOIN cxcontrol.Tranche t ON t.CandidateKey=c.CandidateKey JOIN cxcontrol.InquiryLine l ON l.TrancheKey=t.TrancheKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=l.ProductKey
OUTER APPLY(SELECT
 COALESCE(SUM(CASE WHEN e.EventCode='SHIP_ON_TIME' THEN e.Quantity ELSE 0 END),0) OnTimeQty,
 COALESCE(SUM(CASE WHEN e.EventCode='SHIP_LATE' THEN e.Quantity ELSE 0 END),0) LateQty,
 COALESCE(SUM(CASE WHEN e.EventCode IN('SHIP_ON_TIME','SHIP_LATE') THEN e.Quantity ELSE 0 END),0) FilledQty,
 COALESCE(SUM(CASE WHEN e.EventCode='LOST_SALE' THEN e.Quantity ELSE 0 END),0) LostQty,
 MAX(CASE WHEN e.EventCode IN('SHIP_ON_TIME','SHIP_LATE') THEN e.EventAt END) LastShipmentAt
 FROM dss.Fact_SimulationEvent e WHERE e.PlanningRunKey=c.PlanningRunKey
 AND e.EntityCode=CONCAT('SO_LINE:',l.SourceSalesOrderDetailID)
 AND e.EventCode IN('SHIP_ON_TIME','SHIP_LATE','LOST_SALE')
 AND CONVERT(date,e.EventAt) BETWEEN w.KnownAt AND w.AnalysisEnd) d;
GO
CREATE OR ALTER VIEW cxcontrol.FactRequestedWindowTranche AS
SELECT w.WindowKey,c.CandidateKey,c.PlanningRunKey,t.TrancheKey,
 CONVERT(int,CONVERT(char(8),w.KnownAt,112)) KnownDateKey,
 CONVERT(int,CONVERT(char(8),t.DueDate,112)) DueDateKey,
 CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=w.AnalysisEnd THEN CONVERT(int,CONVERT(char(8),f.CompletedAt,112)) ELSE 0 END CompletionDateKey,
 CONVERT(nvarchar(20),CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=w.AnalysisEnd THEN 'FULFILLED'
 WHEN f.CancelledAt IS NOT NULL AND CONVERT(date,f.CancelledAt)<=w.AnalysisEnd THEN 'LOST' ELSE 'OPEN' END) OrderStatus,
 CONVERT(bigint,1) TrancheCount,
 CONVERT(bigint,CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=w.AnalysisEnd THEN 1 ELSE 0 END) CompletedTrancheCount,
 CONVERT(bigint,CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=w.AnalysisEnd AND CONVERT(date,f.CompletedAt)<=t.DueDate THEN 1 ELSE 0 END) OnTimeCompleteTrancheCount,
 CONVERT(bigint,CASE WHEN f.CancelledAt IS NOT NULL AND CONVERT(date,f.CancelledAt)<=w.AnalysisEnd THEN 1 ELSE 0 END) LostTrancheCount,
 CONVERT(bigint,f.ExpectedLineCount) RequestedLineCount
FROM cxcontrol.RequestedWindow w JOIN cxcontrol.WindowCandidate c ON c.WindowKey=w.WindowKey
JOIN cxcontrol.Tranche t ON t.CandidateKey=c.CandidateKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
JOIN dss.Fact_SimulationOrder f ON f.PlanningRunKey=c.PlanningRunKey AND f.CustomerOrderCode=CONCAT('SO:',t.SourceSalesOrderID);
GO
GRANT SELECT ON SCHEMA::cxcontrol TO [CompanyXMOLAPReader];
GO

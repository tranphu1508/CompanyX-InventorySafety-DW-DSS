SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Requires owned source copy',1;
IF OBJECT_ID('cxcontrol.InquiryPublication','U') IS NULL
CREATE TABLE cxcontrol.InquiryPublication(
 PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES cxcontrol.Candidate(PlanningRunKey),
 ProjectionHash char(64) NOT NULL,ProjectionJSON nvarchar(max) NOT NULL CHECK(ISJSON(ProjectionJSON)=1),
 ArchiveHash char(64) NOT NULL,ArtifactFolder nvarchar(2000) NOT NULL,
 PublicationMode varchar(60) NOT NULL CHECK(PublicationMode='ANALYTICAL_PROJECTION_FULL_RAW_ARCHIVE'),
 PublishedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
IF OBJECT_ID('cxcontrol.InquiryActivity','U') IS NULL
CREATE TABLE cxcontrol.InquiryActivity(
 PlanningRunKey int NOT NULL REFERENCES cxcontrol.Candidate(PlanningRunKey),
 DateKey int NOT NULL REFERENCES dw.Dim_Date(DateKey),ProductKey int NOT NULL REFERENCES dw.Dim_Product(ProductKey),
 EventCode nvarchar(40) NOT NULL REFERENCES dss.Dim_EventType(EventCode),Quantity decimal(28,8) NOT NULL CHECK(Quantity>0),
 EventCount bigint NOT NULL CHECK(EventCount>0),PRIMARY KEY(PlanningRunKey,DateKey,ProductKey,EventCode));
GO
CREATE OR ALTER VIEW cxcontrol.FactProductionActivity AS
SELECT c.InquiryKey,c.CandidateKey,f.PlanningRunKey,f.DateKey,f.ProductKey,sp.StockUnitMeasureKey,
 f.EventCode,f.Quantity,CONVERT(bigint,1) ActivityCount
FROM dss.Fact_SimulationEvent f JOIN cxcontrol.Candidate c ON c.PlanningRunKey=f.PlanningRunKey
JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=f.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=f.ProductKey
WHERE f.EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER')
AND CONVERT(date,f.EventAt) BETWEEN i.KnownAt AND i.AnalysisEnd
AND JSON_VALUE(c.ScopeJSON,'$.schema')<>'companyx.inquiry.scope.v2'
UNION ALL
SELECT c.InquiryKey,c.CandidateKey,a.PlanningRunKey,a.DateKey,a.ProductKey,sp.StockUnitMeasureKey,
 a.EventCode,a.Quantity,a.EventCount ActivityCount
FROM cxcontrol.InquiryActivity a JOIN cxcontrol.Candidate c ON c.PlanningRunKey=a.PlanningRunKey
JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=a.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=a.ProductKey
WHERE JSON_VALUE(c.ScopeJSON,'$.schema')='companyx.inquiry.scope.v2'
AND a.EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER')
AND a.DateKey BETWEEN CONVERT(int,CONVERT(char(8),i.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112));
GO
GRANT SELECT ON SCHEMA::cxcontrol TO [CompanyXMOLAPReader];
GO

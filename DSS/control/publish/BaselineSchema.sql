-- Additive full-history baseline analytical catalog. Original DSS objects unchanged.
SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF SCHEMA_ID('cxcontrol') IS NULL EXEC('CREATE SCHEMA cxcontrol AUTHORIZATION dbo');
IF OBJECT_ID('cxcontrol.Baseline','U') IS NULL
CREATE TABLE cxcontrol.Baseline(
 BaselineKey bigint IDENTITY PRIMARY KEY, BaselineID nvarchar(100) NOT NULL UNIQUE,
 PlanningRunKey int NOT NULL UNIQUE REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 RunCode uniqueidentifier NOT NULL UNIQUE, SourceMatrixIndex int NOT NULL CHECK(SourceMatrixIndex BETWEEN 17 AND 24),
 ScenarioIndex int NOT NULL CHECK(ScenarioIndex BETWEEN 1 AND 8),StartDate date NOT NULL,EndDate date NOT NULL,
 InitialStateRule nvarchar(50) NOT NULL, Interpretation nvarchar(1000) NOT NULL,
 ArtifactFolder nvarchar(2000) NOT NULL, InputSnapshotHash char(64) NOT NULL, SourceExtractHash char(64) NOT NULL,
 ScopeFileHash char(64) NOT NULL, ProjectionHash char(64) NOT NULL, ProjectionJSON nvarchar(max) NOT NULL CHECK(ISJSON(ProjectionJSON)=1),
 PublicationMode varchar(60) NOT NULL CHECK(PublicationMode='ANALYTICAL_PROJECTION_FULL_RAW_ARTIFACT'),
 RawStochasticDrawRows bigint NOT NULL, RawStochasticDrawHash char(64) NOT NULL,
 CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
IF OBJECT_ID('cxcontrol.BaselineActivity','U') IS NULL
CREATE TABLE cxcontrol.BaselineActivity(
 PlanningRunKey int NOT NULL REFERENCES cxcontrol.Baseline(PlanningRunKey),
 DateKey int NOT NULL REFERENCES dw.Dim_Date(DateKey),ProductKey int NOT NULL REFERENCES dw.Dim_Product(ProductKey),
 EventCode nvarchar(40) NOT NULL REFERENCES dss.Dim_EventType(EventCode),
 Quantity decimal(28,8) NOT NULL CHECK(Quantity>0), EventCount bigint NOT NULL CHECK(EventCount>0),
 PRIMARY KEY(PlanningRunKey,DateKey,ProductKey,EventCode));
GO
CREATE OR ALTER VIEW cxcontrol.DimBaseline AS
SELECT b.BaselineKey,b.BaselineID,b.PlanningRunKey,CONVERT(nvarchar(36),b.RunCode) RunCode,
 b.SourceMatrixIndex,b.ScenarioIndex,b.StartDate,b.EndDate,b.InitialStateRule,b.Interpretation,
 b.PublicationMode,b.RawStochasticDrawRows,b.ArtifactFolder
FROM cxcontrol.Baseline b JOIN cxolap.DimRun r ON r.PlanningRunKey=b.PlanningRunKey;
GO
CREATE OR ALTER VIEW cxcontrol.FactBaselineActivity AS
SELECT a.*,sp.StockUnitMeasureKey FROM cxcontrol.BaselineActivity a
JOIN cxolap.DimRun r ON r.PlanningRunKey=a.PlanningRunKey
JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=a.ProductKey;
GO
GRANT SELECT ON SCHEMA::cxcontrol TO [CompanyXMOLAPReader];
GO

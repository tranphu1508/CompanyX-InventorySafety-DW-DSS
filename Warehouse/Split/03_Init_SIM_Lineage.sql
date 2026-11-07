-- Run only after the one-time split, on the explicitly owned SIM database.
-- Does not contact or modify the original warehouse/cube.
SET XACT_ABORT ON; SET NOCOUNT ON;
IF DB_NAME()<>N'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name=N'CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)=N'companyx-split-20261107') THROW 51000,'Wrong isolated SIM database.',1;
IF SCHEMA_ID(N'cxsim') IS NULL EXEC(N'CREATE SCHEMA cxsim');
IF SCHEMA_ID(N'sim_etl') IS NULL EXEC(N'CREATE SCHEMA sim_etl');
IF OBJECT_ID(N'sim_etl.LoadBatch',N'U') IS NULL THROW 51000,'Apply the one-time split first; SIM publication audit must be preserved.',1;
IF OBJECT_ID(N'cxsim.RunInputSnapshot',N'U') IS NULL
CREATE TABLE cxsim.RunInputSnapshot(
 PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 InputOrigin varchar(40) NOT NULL,
 ACTSnapshotID char(64) NULL,
 BindingJSON nvarchar(max) NOT NULL,
 RecordedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME()
);
-- Historical provenance is explicit; never relabel migrated runs as ACT_CUBE.
INSERT cxsim.RunInputSnapshot(PlanningRunKey,InputOrigin,BindingJSON)
SELECT r.PlanningRunKey,'MIGRATED_PRE_SPLIT',N'{"origin":"MIGRATED_PRE_SPLIT","source":"CompanyX_MOLAP_Source_20261105"}'
FROM dss.Dim_PlanningRun r
WHERE NOT EXISTS(SELECT 1 FROM cxsim.RunInputSnapshot s WHERE s.PlanningRunKey=r.PlanningRunKey);
GO
CREATE OR ALTER VIEW cxsim.DimRunBase AS
SELECT r.*,
 CONVERT(nvarchar(100),CASE WHEN r.PolicyCode=N'ROP' THEN N'ROP_ORIGINAL' ELSE COALESCE(JSON_VALUE(c.ScopeJSON,'$.optimizer_release.version'),N'LEGACY_PRE_V3') END) OptimizerVersion,
 CONVERT(nvarchar(100),CASE WHEN r.PolicyCode=N'ROP' THEN N'NOT_APPLICABLE' ELSE COALESCE(JSON_VALUE(c.ScopeJSON,'$.optimizer_release.sha256'),N'LEGACY') END) OptimizerHash,
 CONVERT(nvarchar(100),CASE WHEN r.PolicyCode=N'ROP' THEN N'ROP_SIMULATED_BASELINE' WHEN JSON_VALUE(c.ScopeJSON,'$.optimizer_release.version') IS NOT NULL THEN N'CORRECTED_MILP' ELSE N'HISTORICAL_MILP' END) ResultModelStatus
FROM cxactive.DimRun r LEFT JOIN cxcontrol.Candidate c ON c.PlanningRunKey=r.PlanningRunKey;
GO
CREATE OR ALTER VIEW cxsim.DimRun AS SELECT r.*,CONVERT(nvarchar(40),COALESCE(s.InputOrigin,'UNBOUND')) InputOrigin,CONVERT(nvarchar(64),COALESCE(s.ACTSnapshotID,'LEGACY_NOT_RECORDED')) ACTSnapshotID FROM cxsim.DimRunBase r LEFT JOIN cxsim.RunInputSnapshot s ON s.PlanningRunKey=r.PlanningRunKey
GO
GRANT SELECT ON SCHEMA::cxsim TO [CompanyXMOLAPReader];

-- Additive registry only. Existing ROP facts and planning runs are never copied.
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner'
              AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
    THROW 51000,'Unowned warehouse',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitRole'
              AND CONVERT(nvarchar(100),value)='SIM')
    THROW 51000,'Checkpoint registry requires SIM',1;
IF SCHEMA_ID('cxsim') IS NULL EXEC('CREATE SCHEMA cxsim');
IF OBJECT_ID('cxsim.ROPDecisionCheckpoint','U') IS NULL
CREATE TABLE cxsim.ROPDecisionCheckpoint (
    BaseRunKey int NOT NULL REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
    DecisionDate date NOT NULL,
    InputIdentity char(64) NOT NULL,
    CheckpointPath nvarchar(1024) NOT NULL,
    FileSHA256 char(64) NOT NULL,
    ManifestSHA256 char(64) NOT NULL,
    CONSTRAINT PK_ROPDecisionCheckpoint PRIMARY KEY(BaseRunKey,InputIdentity,DecisionDate)
);

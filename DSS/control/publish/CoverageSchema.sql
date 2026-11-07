SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF OBJECT_ID('cxcontrol.CoverageExecution','U') IS NULL
CREATE TABLE cxcontrol.CoverageExecution(
 PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 FamilyHash char(64) NOT NULL,
 CandidateID nvarchar(100) NOT NULL,
 SourceRequestID nvarchar(100) NOT NULL,
 ArtifactFolder nvarchar(2000) NOT NULL,
 KnownAt date NOT NULL,
 CoveredEnd date NOT NULL,
 CheckpointHash char(64) NULL,
 ExecutorHash char(64) NOT NULL,
 FamilyJSON nvarchar(max) NOT NULL CHECK(ISJSON(FamilyJSON)=1),
 Purpose varchar(20) NOT NULL CHECK(Purpose IN('ORDER_INQUIRY','PIPELINE_SMOKE')),
 ParentRunKey int NULL REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 VerificationHash char(64) NOT NULL,
 CanExtend AS CONVERT(bit,CASE WHEN CheckpointHash IS NULL THEN 0 ELSE 1 END),
 VerifiedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 CONSTRAINT CK_CoverageExecution_Dates CHECK(CoveredEnd>=KnownAt),
 CONSTRAINT CK_CoverageExecution_Parent CHECK(ParentRunKey IS NULL OR ParentRunKey<>PlanningRunKey));
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('cxcontrol.CoverageExecution') AND name='IX_CoverageExecution_Lookup')
CREATE INDEX IX_CoverageExecution_Lookup ON cxcontrol.CoverageExecution(FamilyHash,CandidateID,KnownAt,CoveredEnd)
INCLUDE(PlanningRunKey,ExecutorHash,Purpose,ParentRunKey,CheckpointHash,SourceRequestID);
GO
CREATE OR ALTER VIEW cxcontrol.VerifiedCoverageExecution AS
SELECT e.*
FROM cxcontrol.CoverageExecution e
JOIN cxolap.DimRun r ON r.PlanningRunKey=e.PlanningRunKey
JOIN cxcontrol.Candidate c ON c.PlanningRunKey=e.PlanningRunKey AND c.CandidateID=e.CandidateID
JOIN cxcontrol.InquiryPurpose p ON p.InquiryKey=c.InquiryKey AND p.Purpose=e.Purpose
JOIN cxcontrol.InquiryPublication ip ON ip.PlanningRunKey=e.PlanningRunKey;
GO
GRANT SELECT ON cxcontrol.CoverageExecution TO [CompanyXMOLAPReader];
GRANT SELECT ON cxcontrol.VerifiedCoverageExecution TO [CompanyXMOLAPReader];
GO

SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF OBJECT_ID('cxcontrol.CandidateRequestIdentity','U') IS NULL
CREATE TABLE cxcontrol.CandidateRequestIdentity(
 PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 InquiryKey bigint NOT NULL REFERENCES cxcontrol.Inquiry(InquiryKey),
 RequestFileHash char(64) NOT NULL,
 CanonicalRequestHash char(64) NOT NULL,
 PurposeBindingHash char(64) NOT NULL,
 MetadataHash char(64) NOT NULL,
 BindingJSON nvarchar(max) NOT NULL CHECK(ISJSON(BindingJSON)=1),
 CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
GRANT SELECT ON cxcontrol.CandidateRequestIdentity TO [CompanyXMOLAPReader];

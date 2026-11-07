SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
IF OBJECT_ID('cxcontrol.InquiryPurpose','U') IS NULL
CREATE TABLE cxcontrol.InquiryPurpose(
 InquiryKey bigint NOT NULL PRIMARY KEY REFERENCES cxcontrol.Inquiry(InquiryKey),
 Purpose varchar(40) NOT NULL CHECK(Purpose IN('ORDER_INQUIRY','PIPELINE_SMOKE')),
 RequestHash char(64) NOT NULL,
 MetadataHash char(64) NOT NULL,
 BindingHash char(64) NOT NULL,
 BindingJSON nvarchar(max) NOT NULL CHECK(ISJSON(BindingJSON)=1),
 PurposeSource varchar(40) NOT NULL CHECK(PurposeSource='OWNED_JOB_METADATA_V2'),
 PublishedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
GRANT SELECT ON cxcontrol.InquiryPurpose TO [CompanyXMOLAPReader];

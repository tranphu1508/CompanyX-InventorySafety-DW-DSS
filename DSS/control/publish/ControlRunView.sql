SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
GO
CREATE OR ALTER VIEW cxcontrol.DimControlRun AS
SELECT r.*,
 CONVERT(nvarchar(40),CASE WHEN b.BaselineKey IS NOT NULL THEN 'ROP_BASELINE'
  WHEN ip.Purpose='ORDER_INQUIRY' THEN 'SELECTED_MILP_INQUIRY'
  WHEN ip.Purpose='PIPELINE_SMOKE' THEN 'PIPELINE_SMOKE'
  WHEN JSON_VALUE(i.RequestJSON,'$.schema')='companyx.inquiry.request.v2' THEN 'UNCLASSIFIED_INQUIRY'
  ELSE 'PIPELINE_SMOKE' END) RunPurpose,
 CONVERT(nvarchar(40),CASE WHEN b.BaselineKey IS NOT NULL THEN 'FIXED_PRESET'
  ELSE COALESCE(JSON_VALUE(i.RequestJSON,'$.initialization_mode'),'LEGACY_SMOKE') END) InitializationMode,
 CONVERT(nvarchar(100),COALESCE(b.BaselineID,ref.BaselineID,'NOT_APPLICABLE')) ReferenceBaselineID,
 CONVERT(int,COALESCE(b.ScenarioIndex,ref.ScenarioIndex,0)) PhysicalScenarioIndex,
 CONVERT(nvarchar(50),CASE WHEN b.BaselineKey IS NOT NULL THEN b.InitialStateRule
  ELSE COALESCE(JSON_VALUE(i.RequestJSON,'$.initial_stock_rule'),'LEGACY') END) RequestedInitialStockRule
FROM cxolap.DimRun r
LEFT JOIN cxcontrol.Baseline b ON b.PlanningRunKey=r.PlanningRunKey
LEFT JOIN cxcontrol.Candidate c ON c.PlanningRunKey=r.PlanningRunKey
LEFT JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
LEFT JOIN cxcontrol.InquiryPurpose ip ON ip.InquiryKey=i.InquiryKey
LEFT JOIN cxcontrol.Baseline ref ON ref.PlanningRunKey=TRY_CONVERT(int,JSON_VALUE(i.RequestJSON,'$.base_run_key'));
GO
GRANT SELECT ON cxcontrol.DimControlRun TO [CompanyXMOLAPReader];
GO

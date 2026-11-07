SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned MOLAP source copy',1;
GO
CREATE OR ALTER VIEW cxcontrol.FactInquiryWindowSummary AS
SELECT c.PlanningRunKey,c.InquiryKey,c.CandidateKey,
 CONVERT(int,CONVERT(char(8),i.KnownAt,112)) WindowStartDateKey,
 CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112)) WindowEndDateKey,
 TRY_CONVERT(int,JSON_VALUE(i.RequestJSON,'$.base_run_key')) ReferenceRunKey,
 d.CalendarDays WindowDays,d.InventoryValueDaySum WindowInventoryValueDaySum,
 CONVERT(float,d.InventoryValueDaySum)/NULLIF(d.CalendarDays,0) WindowAverageInventoryValue,
 o.DueOrderCount WindowDueOrderCount,o.OnTimeFullOrderCount WindowOnTimeFullOrderCount,
 CONVERT(float,o.OnTimeFullOrderCount)/NULLIF(o.DueOrderCount,0) WindowOTIF,
 rd.CalendarDays ReferenceROPDays,
 CONVERT(float,rd.InventoryValueDaySum)/NULLIF(rd.CalendarDays,0) ReferenceROPAverageInventoryValue,
 ro.DueOrderCount ReferenceROPDueOrderCount,ro.OnTimeFullOrderCount ReferenceROPOnTimeFullOrderCount,
 CONVERT(float,ro.OnTimeFullOrderCount)/NULLIF(ro.DueOrderCount,0) ReferenceROPOTIF
FROM cxcontrol.Candidate c JOIN cxcontrol.Inquiry i ON i.InquiryKey=c.InquiryKey
JOIN cxolap.DimRun r ON r.PlanningRunKey=c.PlanningRunKey
OUTER APPLY(SELECT COUNT(DISTINCT f.DateKey) CalendarDays,SUM(f.InventoryValueDaySum) InventoryValueDaySum
 FROM cxcontrol.FactSimulationDaily f WHERE f.PlanningRunKey=c.PlanningRunKey
 AND f.DateKey BETWEEN CONVERT(int,CONVERT(char(8),i.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112))) d
OUTER APPLY(SELECT SUM(f.DueOrderCount) DueOrderCount,SUM(f.OnTimeFullOrderCount) OnTimeFullOrderCount
 FROM cxolap.FactOrderService f WHERE f.PlanningRunKey=c.PlanningRunKey
 AND f.DueDateKey BETWEEN CONVERT(int,CONVERT(char(8),i.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112))) o
OUTER APPLY(SELECT COUNT(DISTINCT f.DateKey) CalendarDays,SUM(f.InventoryValueDaySum) InventoryValueDaySum
 FROM cxcontrol.FactSimulationDaily f WHERE f.PlanningRunKey=TRY_CONVERT(int,JSON_VALUE(i.RequestJSON,'$.base_run_key'))
 AND f.DateKey BETWEEN CONVERT(int,CONVERT(char(8),i.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112))) rd
OUTER APPLY(SELECT SUM(f.DueOrderCount) DueOrderCount,SUM(f.OnTimeFullOrderCount) OnTimeFullOrderCount
 FROM cxolap.FactOrderService f WHERE f.PlanningRunKey=TRY_CONVERT(int,JSON_VALUE(i.RequestJSON,'$.base_run_key'))
 AND f.DueDateKey BETWEEN CONVERT(int,CONVERT(char(8),i.KnownAt,112)) AND CONVERT(int,CONVERT(char(8),i.AnalysisEnd,112))) ro;
GO
GRANT SELECT ON cxcontrol.FactInquiryWindowSummary TO [CompanyXMOLAPReader];
GO

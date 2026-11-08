from pathlib import Path
try:
    from .derive_publish import build_inquiry
except ImportError:
    from derive_publish import build_inquiry


def build_inquiry_v2(project):
    sql=build_inquiry(project)
    def change(old,new,count=1):
        nonlocal sql
        if sql.count(old)!=count:raise ValueError('Inquiry V2 derivation point changed: '+old[:100])
        sql=sql.replace(old,new)
    change('dw_source_proof.json|scope.json|','dw_source_proof.json|scope.json|inquiry_projection.json|inquiry_archive_manifest.json|')
    change("@scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='scope.json');", "@scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='scope.json'),@projection nvarchar(max)=(SELECT Json FROM #files WHERE Name='inquiry_projection.json');")
    change("'companyx.inquiry.scope.v1'","'companyx.inquiry.scope.v2'")
    change("ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'')<>'REPLAY_SAVED_RUN_TO_X'", "ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'') NOT IN('FIXED_PRESET','BASELINE_AT_START')")
    change("CONCAT('HYBRID_ROP_THEN_MILP; REPLAY_SAVED_RUN_TO_X; '", "CONCAT(JSON_VALUE(@scope,'$.policy_mode'),'; ',JSON_VALUE(@scope,'$.initial_state_mode'),'; ANALYTICAL PROJECTION; '")
    change("JSON_VALUE(@scope,'$.original_base_start')","JSON_VALUE(@scope,'$.bom_source_asof')",count=2)
    change(" -- Compare JSON trees", """ IF OBJECT_ID('cxcontrol.InquiryPublication','U') IS NULL OR OBJECT_ID('cxcontrol.InquiryActivity','U') IS NULL THROW 51000,'Install inquiry V2 schema first',1;
 IF JSON_VALUE(@projection,'$.schema')<>'companyx.inquiry.projection.v1'
 OR JSON_VALUE(@projection,'$.RunCode')<>CONVERT(nvarchar(36),@runCode)
 OR JSON_VALUE(@projection,'$.source_table_manifest_sha256')<>(SELECT Hash FROM #files WHERE Name='table_manifest.json')
 OR JSON_VALUE(@export,'$.projection_sha256')<>(SELECT Hash FROM #files WHERE Name='inquiry_projection.json')
 OR JSON_VALUE(@export,'$.archive_manifest_sha256')<>(SELECT Hash FROM #files WHERE Name='inquiry_archive_manifest.json')
 THROW 51000,'Invalid inquiry V2 archive/projection identity',1;
 -- Compare JSON trees""")
    change("FROM OPENJSON(@manifest,'$.tables');","FROM OPENJSON(@projection,'$.tables');")
    change("SET @path=@folder+'\\tables\\'+@name;","SET @path=@folder+'\\sql_projection\\tables\\'+@name;")
    change('CREATE UNIQUE INDEX IX_Fact_SimulationOrder',"""
 SELECT r.TableName,@runKey PlanningRunKey,CONVERT(int,REPLACE(j.[Date],'-','')) DateKey,p.ProductKey,j.EventCode,
 j.Quantity,j.EventCount INTO #InquiryFlows
 FROM #payload r CROSS APPLY OPENJSON(r.Payload) WITH([Date] char(10),ProductID int,EventCode nvarchar(40),Quantity decimal(28,8),EventCount bigint) j
 JOIN dw.Dim_Product p ON p.ProductID=j.ProductID AND p.ProductKey>0 WHERE r.TableName IN('InquiryActivity','InquiryFlowAudit');
 IF (SELECT COUNT_BIG(*) FROM #InquiryFlows)<>(SELECT COUNT_BIG(*) FROM #payload WHERE TableName IN('InquiryActivity','InquiryFlowAudit'))
 OR EXISTS(SELECT 1 FROM #InquiryFlows f LEFT JOIN dw.Dim_Date d ON d.DateKey=f.DateKey WHERE d.DateKey IS NULL OR f.Quantity<=0 OR f.EventCount<=0)
 THROW 51000,'Invalid inquiry activity aggregate',1;
 SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount INTO #InquiryActivity FROM #InquiryFlows WHERE TableName='InquiryActivity';
 SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount INTO #InquiryFlowAudit FROM #InquiryFlows WHERE TableName='InquiryFlowAudit';
 CREATE UNIQUE INDEX IX_InquiryActivity ON #InquiryActivity(PlanningRunKey,DateKey,ProductKey,EventCode);
 CREATE UNIQUE INDEX IX_InquiryFlowAudit ON #InquiryFlowAudit(PlanningRunKey,DateKey,ProductKey,EventCode);
 IF EXISTS(SELECT * FROM #InquiryActivity EXCEPT SELECT * FROM #InquiryFlowAudit WHERE DateKey BETWEEN CONVERT(int,REPLACE(JSON_VALUE(@scope,'$.known_at'),'-','')) AND CONVERT(int,REPLACE(JSON_VALUE(@scope,'$.analysis_end'),'-','')) AND EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER'))
 OR EXISTS(SELECT * FROM #InquiryFlowAudit WHERE DateKey BETWEEN CONVERT(int,REPLACE(JSON_VALUE(@scope,'$.known_at'),'-','')) AND CONVERT(int,REPLACE(JSON_VALUE(@scope,'$.analysis_end'),'-','')) AND EventCode IN('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER') EXCEPT SELECT * FROM #InquiryActivity)
 THROW 51000,'Public inquiry activity differs from its full-period flow audit',1;
 CREATE UNIQUE INDEX IX_Fact_SimulationOrder""")
    change('CREATE TABLE #event_types', '''CREATE INDEX IX_RunEntity_Order ON #RunEntity(PlanningRunKey,CustomerOrderCode,EntityType) INCLUDE(EntityCode,OriginalQty,ProductKey);
CREATE INDEX IX_Event_Entity ON #Fact_SimulationEvent(PlanningRunKey,EntityCode,EventCode) INCLUDE(Quantity,OrderActionCode,DateKey,ProductKey);
CREATE INDEX IX_Event_DayProduct ON #Fact_SimulationEvent(PlanningRunKey,DateKey,ProductKey,EventCode) INCLUDE(Quantity);
CREATE INDEX IX_Daily_ProductDate ON #Fact_SimulationDaily(PlanningRunKey,ProductKey,DateKey) INCLUDE(OpenPurchaseQty,OnHandQty,ProductionWIPQty,OnHandValue,WIPValue,CustomerBacklogQty);
CREATE TABLE #event_types''')
    change("            FROM #Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')", "            FROM #InquiryFlowAudit WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')")
    change("IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN\n            (SELECT PlanningRunKey,AVG(total)", """IF EXISTS(SELECT 1 FROM #Fact_SimulationDaily d LEFT JOIN
 (SELECT PlanningRunKey,DateKey,ProductKey,
 SUM(CASE WHEN EventCode='BUY_RECEIVE_GOOD' THEN Quantity ELSE 0 END) good,
 SUM(CASE WHEN EventCode='BUY_REJECT' THEN Quantity ELSE 0 END) rejected,
 SUM(CASE WHEN EventCode='PRODUCTION_GOOD' THEN Quantity ELSE 0 END) produced,
 SUM(CASE WHEN EventCode='BOM_ISSUE' THEN Quantity ELSE 0 END) consumed
 FROM #InquiryFlowAudit GROUP BY PlanningRunKey,DateKey,ProductKey) a
 ON a.PlanningRunKey=d.PlanningRunKey AND a.DateKey=d.DateKey AND a.ProductKey=d.ProductKey
 WHERE ABS(d.PurchaseAcceptedQty-COALESCE(a.good,0))>0.00001 OR ABS(d.PurchaseRejectedQty-COALESCE(a.rejected,0))>0.00001
 OR ABS(d.ProductionGoodQty-COALESCE(a.produced,0))>0.00001 OR ABS(d.BOMConsumedQty-COALESCE(a.consumed,0))>0.00001)
 THROW 51000,'Inquiry full-period flow audit differs from daily facts',1;
 IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN
            (SELECT PlanningRunKey,AVG(total)""")
    change("N'Atomic native SSIS publication with relational/event/KPI reconciliation and SQL FK checks'", "N'Inquiry V2 analytical projection with complete verified raw ZIP; retained customer service and daily facts plus exact activity aggregates; full-period purchase balance and canonical KPI reconciliation.'")
    change('IF (SELECT COUNT(*) n FROM dss.Fact_PolicySimulation p LEFT JOIN','SELECT @checkCount=COUNT(*) FROM dss.Fact_PolicySimulation p LEFT JOIN')
    change("ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001))<>0 THROW 51000,'SQL view KPI reconciliation failed',1;", "ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001) OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE); IF @checkCount<>0 THROW 51000,'SQL view KPI reconciliation failed',1;")
    change(' DECLARE @proof nvarchar(max)=',"""
 DECLARE @projectionHash char(64)=(SELECT Hash FROM #files WHERE Name='inquiry_projection.json'),@archiveHash char(64)=JSON_VALUE((SELECT Json FROM #files WHERE Name='inquiry_archive_manifest.json'),'$.archive_sha256');
 IF @existing=0 BEGIN
  INSERT cxcontrol.InquiryPublication(PlanningRunKey,ProjectionHash,ProjectionJSON,ArchiveHash,ArtifactFolder,PublicationMode)
  VALUES(@runKey,@projectionHash,@projection,@archiveHash,@folder,'ANALYTICAL_PROJECTION_FULL_RAW_ARCHIVE');
  INSERT cxcontrol.InquiryActivity SELECT * FROM #InquiryActivity;
 END;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.InquiryPublication WHERE PlanningRunKey=@runKey AND ProjectionHash=@projectionHash AND ArchiveHash=@archiveHash)
 THROW 51000,'Existing inquiry projection/archive differs',1;
 IF EXISTS(SELECT * FROM #InquiryActivity EXCEPT SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount FROM cxcontrol.InquiryActivity WHERE PlanningRunKey=@runKey)
 OR EXISTS(SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount FROM cxcontrol.InquiryActivity WHERE PlanningRunKey=@runKey EXCEPT SELECT * FROM #InquiryActivity)
 THROW 51000,'Published inquiry activity differs',1;
 DECLARE @proof nvarchar(max)=""")
    change("'SSIS_CONTROL_NATIVE_SQL_V1' implementation","'INQUIRY_V2_ANALYTICAL_PROJECTION' implementation")
    change("'EXACT_TYPED_BIDIRECTIONAL_COMPARE' database_verification","'EXACT_TYPED_RETAINED_ROWS_AND_ACTIVITY' database_verification,@projectionHash projection_sha256,@archiveHash archive_sha256")
    change('inquiry_projection.json|inquiry_archive_manifest.json|','inquiry_projection.json|inquiry_archive_manifest.json|publication_purpose.json|')
    change(" IF OBJECT_ID('cxcontrol.InquiryPublication','U') IS NULL", """ DECLARE @publicationPurpose nvarchar(max)=(SELECT Json FROM #files WHERE Name='publication_purpose.json');
 IF OBJECT_ID('cxcontrol.InquiryPurpose','U') IS NULL THROW 51000,'Install inquiry purpose schema first',1;
 IF ISNULL(JSON_VALUE(@publicationPurpose,'$.schema'),'')<>'companyx.inquiry.publication_purpose.v1'
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.purpose'),'') NOT IN('ORDER_INQUIRY','PIPELINE_SMOKE')
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.purpose_source'),'')<>'OWNED_JOB_METADATA_V2'
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.request_id'),'')<>JSON_VALUE(@scope,'$.request_id')
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.inquiry_id'),'')<>JSON_VALUE(@scope,'$.inquiry_id')
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.request_file_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='request.json')
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.metadata.schema'),'')<>'companyx.inquiry.metadata.v2'
 OR ISNULL(JSON_VALUE(@publicationPurpose,'$.metadata.purpose'),'')<>JSON_VALUE(@publicationPurpose,'$.purpose')
 OR ISNULL(LEN(JSON_VALUE(@publicationPurpose,'$.metadata_file_sha256')),0)<>64
 OR ISNULL(JSON_VALUE(@export,'$.publication_purpose_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='publication_purpose.json')
 THROW 51000,'Invalid or unbound owned inquiry purpose metadata',1;
 IF OBJECT_ID('cxcontrol.InquiryPublication','U') IS NULL""")
    change(" IF EXISTS(SELECT 1 FROM cxcontrol.Candidate WHERE InquiryKey=@inquiryKey AND SharedStateHash<>@stateHash)", """ DECLARE @purposeValue varchar(40)=JSON_VALUE(@publicationPurpose,'$.purpose'),
 @purposeMetadataHash char(64)=JSON_VALUE(@publicationPurpose,'$.metadata_file_sha256'),
 @purposeBindingHash char(64)=(SELECT Hash FROM #files WHERE Name='publication_purpose.json');
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.InquiryPurpose WHERE InquiryKey=@inquiryKey)
  INSERT cxcontrol.InquiryPurpose(InquiryKey,Purpose,RequestHash,MetadataHash,BindingHash,BindingJSON,PurposeSource)
  VALUES(@inquiryKey,@purposeValue,@requestHash,@purposeMetadataHash,@purposeBindingHash,@publicationPurpose,'OWNED_JOB_METADATA_V2');
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.InquiryPurpose WHERE InquiryKey=@inquiryKey AND Purpose=@purposeValue
  AND RequestHash=@requestHash AND MetadataHash=@purposeMetadataHash AND BindingHash=@purposeBindingHash)
  THROW 51000,'Existing inquiry purpose metadata differs',1;
 IF EXISTS(SELECT 1 FROM cxcontrol.Candidate WHERE InquiryKey=@inquiryKey AND SharedStateHash<>@stateHash)""")
    change('@archiveHash archive_sha256 FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);',
           '@archiveHash archive_sha256,@purposeValue inquiry_purpose,@purposeBindingHash publication_purpose_sha256 FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);')
    return sql


if __name__=='__main__':
    project=Path(__file__).resolve().parents[3]
    Path(__file__).with_name('PublishInquiryV2.sql').write_text(build_inquiry_v2(project),encoding='utf-8',newline='\n')
    print('Built PublishInquiryV2.sql')

"""Separate, explicit analytical projection of the SHA-pinned native publisher."""
from pathlib import Path
try:
    from .derive_publish import build
except ImportError:
    from derive_publish import build


def build_baseline(project):
    sql=build(project)
    def change(old,new,count=1):
        nonlocal sql
        if sql.count(old)!=count:raise ValueError('Baseline derivation point changed: '+old[:100])
        sql=sql.replace(old,new)
    sql=sql.replace('scope.json','baseline_publication_scope.json')
    change('dw_source_proof.json|baseline_publication_scope.json|','dw_source_proof.json|baseline_publication_scope.json|baseline_projection.json|')
    change("@scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='baseline_publication_scope.json');",
           "@scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='baseline_publication_scope.json'), @projection nvarchar(max)=(SELECT Json FROM #files WHERE Name='baseline_projection.json');")
    change("'companyx.control.scope.v1'","'companyx.baseline.publication_scope.v1'")
    change("CONCAT('NEW_EXPERIMENT; '","CONCAT('RETROSPECTIVE FIXED-PARAMETER ROP; SAFETY STOCK; ANALYTICAL PROJECTION; '")
    change(" -- Compare JSON trees", """ IF OBJECT_ID('cxcontrol.Baseline','U') IS NULL OR OBJECT_ID('cxcontrol.BaselineActivity','U') IS NULL THROW 51000,'Install baseline catalog first',1;
 IF @policy<>'ROP' OR JSON_VALUE(@scope,'$.initial_state_rule')<>'SAFETY_STOCK_LEVEL'
 OR TRY_CONVERT(int,JSON_VALUE(@scope,'$.source_matrix_index')) NOT BETWEEN 17 AND 24
 OR JSON_VALUE(@projection,'$.schema')<>'companyx.baseline.projection.v1'
 OR JSON_VALUE(@projection,'$.source_table_manifest_sha256')<>(SELECT Hash FROM #files WHERE Name='table_manifest.json')
 OR JSON_VALUE(@projection,'$.RunCode')<>CONVERT(nvarchar(36),@runCode)
 OR JSON_VALUE(@export,'$.projection_sha256')<>(SELECT Hash FROM #files WHERE Name='baseline_projection.json')
 THROW 51000,'Invalid baseline analytical projection',1;
 -- Compare JSON trees""")
    change("FROM OPENJSON(@manifest,'$.tables');", "FROM OPENJSON(@projection,'$.tables');")
    change("SET @path=@folder+'\\tables\\'+@name;", "SET @path=@folder+'\\sql_projection\\tables\\'+@name;")
    change("JSON_VALUE(@scope,'$.base_snapshot_content_sha256')", "JSON_VALUE((SELECT Json FROM #files WHERE Name='dw_source_proof.json'),'$.frozen_lead_input_hash')")
    change("CREATE UNIQUE INDEX IX_Fact_SimulationOrder", """
 SELECT @runKey PlanningRunKey,CONVERT(int,REPLACE(j.[Date],'-','')) DateKey,p.ProductKey,j.EventCode,
 CONVERT(decimal(28,8),j.Quantity) Quantity,j.EventCount INTO #BaselineActivity
 FROM #payload r CROSS APPLY OPENJSON(r.Payload) WITH([Date] char(10),ProductID int,EventCode nvarchar(40),Quantity decimal(28,8),EventCount bigint) j
 JOIN dw.Dim_Product p ON p.ProductID=j.ProductID AND p.ProductKey>0 WHERE r.TableName='BaselineActivity';
 IF (SELECT COUNT_BIG(*) FROM #BaselineActivity)<>(SELECT COUNT_BIG(*) FROM #payload WHERE TableName='BaselineActivity')
 OR EXISTS(SELECT 1 FROM #BaselineActivity a LEFT JOIN dw.Dim_Date d ON d.DateKey=a.DateKey WHERE d.DateKey IS NULL OR a.Quantity<=0 OR a.EventCount<=0)
 THROW 51000,'Invalid baseline activity aggregate',1;
 CREATE UNIQUE INDEX IX_BaselineActivity ON #BaselineActivity(PlanningRunKey,DateKey,ProductKey,EventCode);
 CREATE UNIQUE INDEX IX_Fact_SimulationOrder""")
    change('CREATE TABLE #event_types', '''-- Exact-semantics access paths for large full-history customer cohorts.
CREATE INDEX IX_RunEntity_Order ON #RunEntity(PlanningRunKey,CustomerOrderCode,EntityType) INCLUDE(EntityCode,OriginalQty,ProductKey);
CREATE INDEX IX_Event_Entity ON #Fact_SimulationEvent(PlanningRunKey,EntityCode,EventCode) INCLUDE(Quantity,OrderActionCode,DateKey,ProductKey);
CREATE INDEX IX_Event_DayProduct ON #Fact_SimulationEvent(PlanningRunKey,DateKey,ProductKey,EventCode) INCLUDE(Quantity);
CREATE INDEX IX_Daily_ProductDate ON #Fact_SimulationDaily(PlanningRunKey,ProductKey,DateKey) INCLUDE(OpenPurchaseQty,OnHandQty,ProductionWIPQty,OnHandValue,WIPValue,CustomerBacklogQty);
CREATE TABLE #event_types''')
    change("            FROM #Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')", "            FROM #BaselineActivity WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')")
    change("IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN", """
 IF EXISTS(SELECT 1 FROM #Fact_SimulationDaily d LEFT JOIN
  (SELECT PlanningRunKey,DateKey,ProductKey,
   SUM(CASE WHEN EventCode='BUY_RECEIVE_GOOD' THEN Quantity ELSE 0 END) good,
   SUM(CASE WHEN EventCode='BUY_REJECT' THEN Quantity ELSE 0 END) rejected,
   SUM(CASE WHEN EventCode='PRODUCTION_GOOD' THEN Quantity ELSE 0 END) produced,
   SUM(CASE WHEN EventCode='BOM_ISSUE' THEN Quantity ELSE 0 END) consumed
   FROM #BaselineActivity GROUP BY PlanningRunKey,DateKey,ProductKey) a
  ON a.PlanningRunKey=d.PlanningRunKey AND a.DateKey=d.DateKey AND a.ProductKey=d.ProductKey
  WHERE ABS(d.PurchaseAcceptedQty-COALESCE(a.good,0))>0.00001 OR ABS(d.PurchaseRejectedQty-COALESCE(a.rejected,0))>0.00001
  OR ABS(d.ProductionGoodQty-COALESCE(a.produced,0))>0.00001 OR ABS(d.BOMConsumedQty-COALESCE(a.consumed,0))>0.00001)
 THROW 51000,'Daily inventory flows differ from full-raw activity aggregates',1;
 IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN""",count=2)
    # Inserted the same aggregate check at both native summary reconciliation points.
    change("N'Atomic native SSIS publication with relational/event/KPI reconciliation and SQL FK checks'",
           "N'Analytical projection: full daily/order/customer service and exact activity aggregates; all original detailed entities, events, relations and draws retained in verified raw artifacts/ZIP. Typed retained rows, service KPIs and daily flows reconciled.'")
    change('IF (SELECT COUNT(*) n FROM dss.Fact_PolicySimulation p LEFT JOIN',
           'SELECT @checkCount=COUNT(*) FROM dss.Fact_PolicySimulation p LEFT JOIN')
    change("ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001))<>0 THROW 51000,'SQL view KPI reconciliation failed',1;",
           "ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001) OPTION(MAXDOP 2,HASH JOIN,LOOP JOIN,RECOMPILE); IF @checkCount<>0 THROW 51000,'SQL view KPI reconciliation failed',1;")
    start=sql.index(" IF OBJECT_ID('cxolap.ControlRunScope','U') IS NULL")
    end=sql.index(' DECLARE @proof nvarchar(max)=',start)
    sql=sql[:start]+"""
 DECLARE @baselineID nvarchar(100)=JSON_VALUE(@scope,'$.baseline_id'),@projectionHash char(64)=(SELECT Hash FROM #files WHERE Name='baseline_projection.json');
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.Baseline WHERE BaselineID=@baselineID) BEGIN
  INSERT cxcontrol.Baseline(BaselineID,PlanningRunKey,RunCode,SourceMatrixIndex,ScenarioIndex,StartDate,EndDate,InitialStateRule,Interpretation,ArtifactFolder,InputSnapshotHash,SourceExtractHash,ScopeFileHash,ProjectionHash,ProjectionJSON,PublicationMode,RawStochasticDrawRows,RawStochasticDrawHash)
  VALUES(@baselineID,@runKey,@runCode,JSON_VALUE(@scope,'$.source_matrix_index'),JSON_VALUE(@scope,'$.scenario_index'),JSON_VALUE(@scope,'$.start'),JSON_VALUE(@scope,'$.end'),JSON_VALUE(@scope,'$.initial_state_rule'),JSON_VALUE(@scope,'$.interpretation'),@folder,(SELECT Hash FROM #files WHERE Name='input.json.canonical'),JSON_VALUE(@scope,'$.source_extract_hash'),(SELECT Hash FROM #files WHERE Name='baseline_publication_scope.json'),@projectionHash,@projection,'ANALYTICAL_PROJECTION_FULL_RAW_ARTIFACT',JSON_VALUE(@manifest,'$.tables."Fact_StochasticDraw.jsonl".rows'),JSON_VALUE(@manifest,'$.tables."Fact_StochasticDraw.jsonl".sha256'));
 END;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.Baseline WHERE BaselineID=@baselineID AND PlanningRunKey=@runKey AND RunCode=@runCode AND ProjectionHash=@projectionHash)
 THROW 51000,'Existing baseline identity or projection differs',1;
 IF @existing=0 INSERT cxcontrol.BaselineActivity SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount FROM #BaselineActivity;
 IF EXISTS(SELECT * FROM #BaselineActivity EXCEPT SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount FROM cxcontrol.BaselineActivity WHERE PlanningRunKey=@runKey)
 OR EXISTS(SELECT PlanningRunKey,DateKey,ProductKey,EventCode,Quantity,EventCount FROM cxcontrol.BaselineActivity WHERE PlanningRunKey=@runKey EXCEPT SELECT * FROM #BaselineActivity)
 THROW 51000,'Published baseline activity aggregate differs',1;
"""+sql[end:]
    change("'SSIS_CONTROL_NATIVE_SQL_V1' implementation", "'BASELINE_ANALYTICAL_PROJECTION_V1' implementation")
    change("'EXACT_TYPED_BIDIRECTIONAL_COMPARE' database_verification", "'EXACT_TYPED_RETAINED_ROWS_AND_ACTIVITY_AGGREGATES' database_verification,@projectionHash projection_sha256,'ANALYTICAL_PROJECTION_FULL_RAW_ARTIFACT' publication_mode")
    # Projection JSON can exceed 4k; do not truncate the native receipt.
    change('CONVERT(nvarchar(4000),(SELECT CASE WHEN @existing=1', 'CONVERT(nvarchar(max),(SELECT CASE WHEN @existing=1')
    return sql


if __name__=='__main__':
    project=Path(__file__).resolve().parents[3]
    Path(__file__).with_name('PublishBaseline.sql').write_text(build_baseline(project),encoding='utf-8',newline='\n')
    print('Built PublishBaseline.sql')

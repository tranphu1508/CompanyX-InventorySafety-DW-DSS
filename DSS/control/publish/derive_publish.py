"""Derive the scoped publisher from the immutable, audited native SQL adapter."""
from pathlib import Path
import hashlib

SOURCE_SHA256 = '8e963bc188d295016b855df605e7a7347d01677b0ce9e312c92b9b63279bbd85'
FACTS = ('Fact_SimulationOrder', 'RunEntity', 'Bridge_RunEntityRelation',
         'Fact_OptimizationSolve', 'Fact_SimulationDaily', 'Fact_SimulationEvent',
         'Fact_StochasticDraw', 'Fact_PolicySimulation', 'Fact_RunSummary')


def build(project):
    from common import demo_folder
    source = demo_folder(project) / 'SSIS/SQL/Results/Publish.sql'
    raw = source.read_bytes()
    if hashlib.sha256(raw).hexdigest() != SOURCE_SHA256:
        raise ValueError('Frozen native publisher changed; review required.')
    sql = raw.decode('utf-8-sig').replace('\r\n', '\n')

    def change(old, new, count=1):
        nonlocal sql
        if sql.count(old) != count:
            raise ValueError('Unexpected native SQL contract: ' + old[:100])
        sql = sql.replace(old, new)

    change('-- No permanent objects/columns are created. Original warehouse/ETL/core remain intact.',
           '-- Derived scoped publisher: only the owned copied warehouse; original core remains intact.')
    change("IF DB_NAME() NOT LIKE 'InventorySafety[_]Demo%' OR @source NOT LIKE 'CompanyX[_]Demo%'",
           "IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR @source<>'CompanyX_Demo'")
    change("IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@source)",
           "IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Missing MOLAP copy ownership marker',1;\nIF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@source)")
    change("dw_source_proof.json|run.json.canonical", "dw_source_proof.json|scope.json|run.json.canonical")
    change("@selection nvarchar(max)=(SELECT Json FROM #files WHERE Name='simulation_selection.json');",
           "@selection nvarchar(max)=(SELECT Json FROM #files WHERE Name='simulation_selection.json'),\n @scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='scope.json');")
    change("@version nvarchar(50)='companyx.ssis.native.v1'", "@version nvarchar(50)='companyx.control.v1'")
    change(" -- Compare JSON trees", """ IF ISNULL(JSON_VALUE(@scope,'$.schema'),'')<>'companyx.control.scope.v1'
 OR ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'')<>'NEW_EXPERIMENT'
 OR ISNULL(JSON_VALUE(@scope,'$.product_scope_mode'),'') NOT IN ('SELECTED_LINES','WHOLE_ORDERS')
 OR JSON_VALUE(@scope,'$.start')<>JSON_VALUE(@run,'$.start') OR JSON_VALUE(@scope,'$.end')<>JSON_VALUE(@run,'$.end')
 OR ISNULL(JSON_VALUE(@export,'$.scope_file_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='scope.json')
 THROW 51000,'Scope contract mismatch',1;
 DECLARE @evaluation nvarchar(1000)=CONCAT('NEW_EXPERIMENT; ',JSON_VALUE(@scope,'$.evaluation_scope'),'; manufactured due-date service cohort; inventory includes selected roots and BOM dependencies; fixed historical assumptions; ',JSON_VALUE(@scope,'$.start'),'..',JSON_VALUE(@scope,'$.end'));
 -- Compare JSON trees""")
    change("WHERE f.SalesOrderID IN(SELECT SalesOrderID FROM #sales);",
           "WHERE (JSON_VALUE(@scope,'$.product_scope_mode')='WHOLE_ORDERS' AND f.SalesOrderID IN(SELECT SalesOrderID FROM #sales)) OR (JSON_VALUE(@scope,'$.product_scope_mode')='SELECTED_LINES' AND f.SalesOrderDetailID IN(SELECT SalesOrderDetailID FROM #sales));")
    change("JSON_VALUE(@original,'$.start')", "JSON_VALUE(@scope,'$.original_base_start')", count=2)
    change("@code nvarchar(100)='SSIS_'", "@code nvarchar(100)='CONTROL_'")
    change("N'Approved input checked against demo DW by native SSIS IO; full-order cohort'", "@evaluation")
    change("N'Service: manufactured due-date cohort; whole-order all siblings; inventory all finite stock and WIP/calendar day.'", "@evaluation")
    change("ISNULL(JSON_VALUE(@v03,'$.input_hash'),'')<>SUBSTRING(@inputRef,11,64)",
           "ISNULL(JSON_VALUE(@v03,'$.input_hash'),'')<>JSON_VALUE(@scope,'$.base_snapshot_content_sha256')")
    change("j LEFT JOIN dw.Dim_Product p ON p.ProductID=j.ProductID AND p.ProductKey>0;",
           "j LEFT JOIN dw.Dim_Product p ON p.ProductID=j.ProductID AND p.ProductKey>0 WHERE j.ProductID IN(SELECT ProductID FROM OPENJSON(@original,'$.products') WITH(ProductID int,IsManufactured bit) WHERE IsManufactured=1);")
    # Preserve every pre-existing run; comparison is performed inside the same transaction.
    guard = '\n CREATE TABLE #oldFacts(TableName sysname PRIMARY KEY,RowsBefore bigint,ChecksumBefore int);\n'
    for table in FACTS:
        guard += f" INSERT #oldFacts SELECT '{table}',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.{table} WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);\n"
    change(" IF @runKey IS NOT NULL BEGIN", guard + " IF @runKey IS NOT NULL BEGIN")
    end_guard = '\n'
    for table in FACTS:
        end_guard += f" IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.{table} WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='{table}') THROW 51000,'Existing run changed: {table}',1;\n"
    sidecar = """
 IF OBJECT_ID('cxolap.ControlRunScope','U') IS NULL
 CREATE TABLE cxolap.ControlRunScope(
   PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
   RunCode uniqueidentifier NOT NULL UNIQUE, RequestID nvarchar(100) NOT NULL UNIQUE,
   ScopeFileSHA256 char(64) NOT NULL, ScopeJSON nvarchar(max) NOT NULL CHECK(ISJSON(ScopeJSON)=1),
   ProductScopeMode varchar(30) NOT NULL, InitialStateMode varchar(30) NOT NULL,
   StartDate date NOT NULL, EndDate date NOT NULL, PublishedAt datetime2 NOT NULL);
 IF @existing=0 INSERT cxolap.ControlRunScope
 SELECT @runKey,@runCode,JSON_VALUE(@scope,'$.request_id'),(SELECT Hash FROM #files WHERE Name='scope.json'),@scope,
 JSON_VALUE(@scope,'$.product_scope_mode'),JSON_VALUE(@scope,'$.initial_state_mode'),JSON_VALUE(@scope,'$.start'),JSON_VALUE(@scope,'$.end'),SYSUTCDATETIME();
 IF NOT EXISTS(SELECT 1 FROM cxolap.ControlRunScope WHERE PlanningRunKey=@runKey AND RunCode=@runCode AND ScopeFileSHA256=(SELECT Hash FROM #files WHERE Name='scope.json'))
 THROW 51000,'Existing scoped publication provenance mismatch',1;
"""
    change(" DECLARE @proof nvarchar(max)=", end_guard + sidecar + " DECLARE @proof nvarchar(max)=")
    change("'SSIS_EXECUTE_SQL_V1' implementation", "'SSIS_CONTROL_NATIVE_SQL_V1' implementation")
    sql=sql.replace("IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@source)",
        "IF NOT EXISTS(SELECT 1 FROM act_input.SnapshotManifest WHERE IsCurrent=1 AND ACTCube=N'CompanyX_ACT_20261107')")
    sql=sql.replace("IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE PipelineName='DWH_INCREMENTAL_V2' AND Status='SUCCEEDED' AND ValidationStatus IN ('PASSED','PASSED_WITH_WARNINGS'))",
        "IF NOT EXISTS(SELECT 1 FROM act_input.SnapshotManifest WHERE IsCurrent=1)")
    sql=sql.replace('etl.ETL_LoadBatch','sim_etl.LoadBatch')
    return sql


def build_inquiry(project):
    sql = build(project)
    def change(old, new, count=1):
        nonlocal sql
        if sql.count(old) != count:
            raise ValueError('Unexpected inquiry derivation point: ' + old[:100])
        sql = sql.replace(old, new)
    change('dw_source_proof.json|scope.json|', 'dw_source_proof.json|scope.json|request.json|prefix_proof.json|branch_state.json|')
    change("ISNULL(JSON_VALUE(@scope,'$.schema'),'')<>'companyx.control.scope.v1'", "ISNULL(JSON_VALUE(@scope,'$.schema'),'')<>'companyx.inquiry.scope.v1'")
    change("ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'')<>'NEW_EXPERIMENT'", "ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'')<>'REPLAY_SAVED_RUN_TO_X'")
    change("ISNULL(JSON_VALUE(@scope,'$.product_scope_mode'),'') NOT IN ('SELECTED_LINES','WHOLE_ORDERS')", "ISNULL(JSON_VALUE(@scope,'$.product_scope_mode'),'')<>'FULL_ORIGINAL_NETWORK'")
    change("CONCAT('NEW_EXPERIMENT; '", "CONCAT('HYBRID_ROP_THEN_MILP; REPLAY_SAVED_RUN_TO_X; '")
    change(" -- Compare JSON trees", """ IF OBJECT_ID('cxcontrol.Inquiry','U') IS NULL OR OBJECT_ID('cxcontrol.InquiryLine','U') IS NULL THROW 51000,'Install owned inquiry schema first',1;
 IF ISNULL(JSON_VALUE((SELECT Json FROM #files WHERE Name='prefix_proof.json'),'$.status'),'')<>'PASSED'
 OR ISNULL(JSON_VALUE(@export,'$.prefix_proof_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='prefix_proof.json')
 OR ISNULL(JSON_VALUE(@export,'$.branch_state_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='branch_state.json')
 THROW 51000,'Missing replay prefix or branch state verification',1;
 -- Compare JSON trees""")
    change("WHERE (JSON_VALUE(@scope,'$.product_scope_mode')='WHOLE_ORDERS' AND f.SalesOrderID IN(SELECT SalesOrderID FROM #sales)) OR (JSON_VALUE(@scope,'$.product_scope_mode')='SELECTED_LINES' AND f.SalesOrderDetailID IN(SELECT SalesOrderDetailID FROM #sales));",
           "WHERE f.SalesOrderID IN(SELECT SalesOrderID FROM #sales WHERE SalesOrderDetailID NOT IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')));")
    change('SELECT * FROM #sales EXCEPT SELECT SalesOrderDetailID', "SELECT * FROM #sales WHERE SalesOrderDetailID NOT IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')) EXCEPT SELECT SalesOrderDetailID")
    change('FROM #actualSales EXCEPT SELECT * FROM #sales)', "FROM #actualSales EXCEPT SELECT * FROM #sales WHERE SalesOrderDetailID NOT IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')))")
    change('(SELECT COUNT(*) FROM #sales)<>(SELECT COUNT(*) FROM #actualSales)', "(SELECT COUNT(*) FROM #sales WHERE SalesOrderDetailID NOT IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')))<>(SELECT COUNT(*) FROM #actualSales)")
    change(' SELECT * INTO #bom', """
 SELECT o.tranche_number,o.sales_order_id,o.due_date,o.source_reference,l.* INTO #hypothetical
 FROM OPENJSON(@scope,'$.synthetic_orders') WITH(tranche_number int,sales_order_id int,due_date date,source_reference nvarchar(500),lines nvarchar(max) AS JSON) o
 CROSS APPLY OPENJSON(o.lines) WITH(SalesOrderDetailID int,SalesOrderID int,ProductID int,OrderQty decimal(28,8),OrderDate date,DueDate date) l;
 IF EXISTS(SELECT 1 FROM #hypothetical h JOIN dw.Fact_SalesOrderLine f ON h.SalesOrderDetailID=f.SalesOrderDetailID OR h.SalesOrderID=f.SalesOrderID)
 OR EXISTS(SELECT 1 FROM #hypothetical WHERE SalesOrderID<>sales_order_id OR DueDate<>due_date OR OrderDate<>CONVERT(date,JSON_VALUE(@scope,'$.known_at')) OR OrderQty<=0 OR SalesOrderDetailID<2000000000 OR SalesOrderID<2000000000)
 OR EXISTS(SELECT SalesOrderDetailID FROM #hypothetical GROUP BY SalesOrderDetailID HAVING COUNT(*)<>1)
 THROW 51000,'Hypothetical identity conflicts with observed data or inquiry',1;
 IF EXISTS(SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,OrderDate,DueDate FROM #hypothetical EXCEPT SELECT * FROM #sales WHERE SalesOrderDetailID IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')))
 OR EXISTS(SELECT * FROM #sales WHERE SalesOrderDetailID IN(SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')) EXCEPT SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,OrderDate,DueDate FROM #hypothetical)
 THROW 51000,'Hypothetical source rows do not match exact inquiry scope',1;
 SELECT * INTO #bom""")
    change("JSON_VALUE(@scope,'$.base_snapshot_content_sha256')", "JSON_VALUE((SELECT Json FROM #files WHERE Name='dw_source_proof.json'),'$.frozen_lead_input_hash')")
    start = sql.index(" IF OBJECT_ID('cxolap.ControlRunScope','U') IS NULL")
    end = sql.index(' DECLARE @proof nvarchar(max)=', start)
    sidecar = """
 DECLARE @inquiryKey bigint,@candidateKey bigint,
 @inquiryID nvarchar(100)=JSON_VALUE(@scope,'$.inquiry_id'),@candidateID nvarchar(100)=JSON_VALUE(@scope,'$.candidate_id'),
 @requestHash char(64)=(SELECT Hash FROM #files WHERE Name='request.json'),
 @scopeHash char(64)=(SELECT Hash FROM #files WHERE Name='scope.json'),
 @stateHash char(64)=JSON_VALUE((SELECT Json FROM #files WHERE Name='branch_state.json'),'$.common_state_sha256');
 SELECT @inquiryKey=InquiryKey FROM cxcontrol.Inquiry WHERE InquiryID=@inquiryID;
 IF @inquiryKey IS NULL BEGIN
  INSERT cxcontrol.Inquiry(InquiryID,KnownAt,AnalysisEnd,BaseRunCode,SourceSnapshotHash,RequestHash,RequestJSON)
  SELECT @inquiryID,JSON_VALUE(@scope,'$.known_at'),JSON_VALUE(@scope,'$.analysis_end'),JSON_VALUE(@scope,'$.base_run_code'),JSON_VALUE(@scope,'$.base_snapshot_sha256'),@requestHash,Json FROM #files WHERE Name='request.json';
  SET @inquiryKey=SCOPE_IDENTITY();
 END;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.Inquiry WHERE InquiryKey=@inquiryKey AND RequestHash=@requestHash AND BaseRunCode=CONVERT(uniqueidentifier,JSON_VALUE(@scope,'$.base_run_code')))
 THROW 51000,'Existing inquiry manifest differs',1;
 IF EXISTS(SELECT 1 FROM cxcontrol.Candidate WHERE InquiryKey=@inquiryKey AND SharedStateHash<>@stateHash)
 THROW 51000,'Candidate branch state differs from its comparison set',1;
 SELECT @candidateKey=CandidateKey FROM cxcontrol.Candidate WHERE InquiryKey=@inquiryKey AND CandidateID=@candidateID;
 IF @candidateKey IS NULL BEGIN
  INSERT cxcontrol.Candidate(InquiryKey,CandidateID,CandidateKind,PlanningRunKey,ScopeFileHash,ScopeJSON,SharedStateHash,PrefixProofHash)
  VALUES(@inquiryKey,@candidateID,JSON_VALUE(@scope,'$.candidate_kind'),@runKey,@scopeHash,@scope,@stateHash,(SELECT Hash FROM #files WHERE Name='prefix_proof.json'));
  SET @candidateKey=SCOPE_IDENTITY();
  INSERT cxcontrol.Tranche(CandidateKey,TrancheNumber,SourceSalesOrderID,DueDate)
  SELECT DISTINCT @candidateKey,tranche_number,sales_order_id,due_date FROM #hypothetical;
  INSERT cxcontrol.InquiryLine(TrancheKey,SourceSalesOrderDetailID,ProductKey,RequestedQty)
  SELECT t.TrancheKey,h.SalesOrderDetailID,p.ProductKey,h.OrderQty FROM #hypothetical h
  JOIN cxcontrol.Tranche t ON t.CandidateKey=@candidateKey AND t.TrancheNumber=h.tranche_number
  JOIN dw.Dim_Product p ON p.ProductID=h.ProductID AND p.ProductKey>0;
 END;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.Candidate WHERE CandidateKey=@candidateKey AND InquiryKey=@inquiryKey AND PlanningRunKey=@runKey AND ScopeFileHash=@scopeHash)
 THROW 51000,'Existing inquiry candidate differs',1;
 IF EXISTS(SELECT h.SalesOrderDetailID,h.ProductID,h.OrderQty,h.sales_order_id,h.due_date,h.tranche_number FROM #hypothetical h
 EXCEPT SELECT l.SourceSalesOrderDetailID,p.ProductID,l.RequestedQty,t.SourceSalesOrderID,t.DueDate,t.TrancheNumber FROM cxcontrol.InquiryLine l JOIN cxcontrol.Tranche t ON t.TrancheKey=l.TrancheKey JOIN dw.Dim_Product p ON p.ProductKey=l.ProductKey WHERE t.CandidateKey=@candidateKey)
 OR EXISTS(SELECT l.SourceSalesOrderDetailID,p.ProductID,l.RequestedQty,t.SourceSalesOrderID,t.DueDate,t.TrancheNumber FROM cxcontrol.InquiryLine l JOIN cxcontrol.Tranche t ON t.TrancheKey=l.TrancheKey JOIN dw.Dim_Product p ON p.ProductKey=l.ProductKey WHERE t.CandidateKey=@candidateKey
 EXCEPT SELECT h.SalesOrderDetailID,h.ProductID,h.OrderQty,h.sales_order_id,h.due_date,h.tranche_number FROM #hypothetical h)
 THROW 51000,'Published inquiry line mapping differs',1;
 IF EXISTS(SELECT 1 FROM #hypothetical h LEFT JOIN dss.RunEntity e ON e.PlanningRunKey=@runKey AND e.EntityCode=CONCAT('SO_LINE:',h.SalesOrderDetailID)
 LEFT JOIN dss.Fact_SimulationOrder o ON o.PlanningRunKey=@runKey AND o.CustomerOrderCode=CONCAT('SO:',h.SalesOrderID)
 WHERE e.EntityCode IS NULL OR e.SourceRecordReference<>h.source_reference OR e.OriginalQty<>h.OrderQty OR o.SourceRecordReference<>h.source_reference)
 THROW 51000,'Inquiry entity provenance mismatch',1;
"""
    sql = sql[:start] + sidecar + sql[end:]
    return sql


if __name__ == '__main__':
    project = Path(__file__).resolve().parents[3]
    output = Path(__file__).with_name('PublishScoped.sql')
    output.write_text(build(project), encoding='utf-8', newline='\n')
    output.with_name('PublishInquiry.sql').write_text(build_inquiry(project), encoding='utf-8', newline='\n')
    print(output)

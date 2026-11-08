"""Explicit lean analytical publication of verified full-history SafetyStock ROP.

Full raw engine outputs remain authoritative and are archived separately. SQL
contains daily facts, full customer service detail, policy/run summaries and
exact activity aggregates, not millions of individual purchase/receipt records.
"""
from __future__ import annotations
from collections import defaultdict
from datetime import datetime,timezone
from decimal import Decimal
import hashlib,json,math,os,re,shutil,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.environ['PYTHONDONTWRITEBYTECODE']='1'
from .publisher import read,sha,canonical,immutable_write,CONNECTION,DATABASE,SOURCE
from .derive_baseline import build_baseline

CUSTOMER_EVENTS={'CUSTOMER_ORDER_CREATED','CUSTOMER_DUE','SHIP_ON_TIME','SHIP_LATE','LOST_SALE'}
ACTIVITY_EVENTS={'PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT'}
FULL_TABLES={'Fact_SimulationDaily','Fact_SimulationOrder','Fact_PolicySimulation','RunSummary','ProductScope','ValuationBasis','ExternalSupplyDraw','Fact_OptimizationSolve'}
SQL_FACTS={'Fact_SimulationDaily','Fact_SimulationOrder','Fact_PolicySimulation','Fact_OptimizationSolve','RunEntity','Fact_SimulationEvent','Bridge_RunEntityRelation','Fact_StochasticDraw'}
AVERAGE_BYTES={'Fact_SimulationDaily':285,'Fact_SimulationOrder':165,'Fact_PolicySimulation':274,'RunEntity':393,'Fact_SimulationEvent':275,'Bridge_RunEntityRelation':120,'Fact_OptimizationSolve':800,'BaselineActivity':100}


def _folder(artifact_folder,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    folder=Path(artifact_folder).resolve()
    if not folder.is_relative_to(project/'_local') or folder==project/'_local':raise ValueError('Baseline publication requires a dedicated Project/GPT folder.')
    return project,folder


def _header(folder,project):
    sys.path.insert(0,str(project/'DSS/control'))
    from simulation.adapter import runtime
    from simulation.baseline_inputs import build_scenario,verify_snapshot
    _,demo,config,inputs,legacy,run,valuation=runtime(project)
    prepared=read(folder/'prepared_baseline.json');snapshot=read(folder/'input.json');spec=read(folder/'execution_spec.json')
    receipt=read(folder/'baseline_execution_receipt.json');scope=read(folder/'baseline_scope.json')
    provenance=read(folder/'input_provenance.json');run_doc=read(folder/'run.json')
    completion=read(folder/'completion.json');manifest=read(folder/'table_manifest.json')
    if (folder/'stream_storage_manifest.json').exists():
        from .baseline_gzip_storage import verify_storage_header
        verify_storage_header(folder)
    if receipt.get('schema')!='companyx.baseline.execution.v1' or receipt.get('status')!='COMPLETE' or prepared.get('prepared_schema')!='companyx.baseline.prepared.v1':raise ValueError('Completed baseline execution receipt required.')
    if spec['policy']!='ROP' or scope['initial_state_rule']!='SAFETY_STOCK_LEVEL' or scope['scenario_index'] not in range(17,25):raise ValueError('Only approved SafetyStock ROP scenarios 17-24 are accepted.')
    if prepared!=build_scenario(scope['scenario_index'],project):raise ValueError('Baseline preparation no longer reproduces from its audited source.')
    verify_snapshot(snapshot,provenance,project)
    if snapshot!=prepared['snapshot'] or snapshot!=read(folder/'input_source.json') or spec!=prepared['spec'] or scope!=prepared['scope']:raise ValueError('Executed input/spec/scope differs from prepared baseline.')
    if (receipt['prepared_file_sha256']!=sha(folder/'prepared_baseline.json') or receipt['scope_sha256']!=legacy.digest(scope)
        or receipt['core_sha256']!=run.code_hash() or receipt['RunCode']!=run_doc['RunCode'] or run_doc['code_sha256']!=run.code_hash()
        or run_doc['input_sha256']!=legacy.digest(snapshot) or run_doc['execution_spec_sha256']!=legacy.digest(spec)
        or completion['status']!='COMPLETE' or completion['RunCode']!=run_doc['RunCode'] or manifest['RunCode']!=run_doc['RunCode']
        or completion['table_manifest_sha256']!=sha(folder/'table_manifest.json') or completion['metrics_sha256']!=sha(folder/'metrics.json')):
        raise ValueError('Baseline execution identity/checksum mismatch.')
    from companyx_unified_v2.integration_contract import validate_profile
    validate_profile(read(folder/'execution_profile.json'),snapshot,spec,inputs.prepare(snapshot,spec))
    if valuation.validate(snapshot)!=run_doc['valuation_sha256'] or read(folder/'valuation_basis.json')!=snapshot['metadata']['valuation']:raise ValueError('Frozen valuation basis changed.')
    for relative,expected in read(demo/'SSIS/core_hashes.json').items():
        path=(demo/relative).resolve()
        if not path.is_relative_to(demo) or sha(path)!=expected:raise ValueError('Protected core changed: '+relative)
    return demo,prepared,receipt,run_doc,manifest


def _projection(folder,prepared,run_doc,manifest):
    from .baseline_gzip_storage import open_raw_binary,raw_sha
    existing=folder/'baseline_projection.json'
    if existing.exists():
        projection=read(existing)
        if projection['source_table_manifest_sha256']!=sha(folder/'table_manifest.json') or projection['RunCode']!=run_doc['RunCode']:raise ValueError('Existing projection source differs.')
        for name,entry in manifest['tables'].items():
            if raw_sha(folder,name)!=entry['sha256']:raise ValueError('Raw artifact hash changed: '+name)
        for name,entry in projection['tables'].items():
            if sha(folder/'sql_projection/tables'/name)!=entry['sha256']:raise ValueError('Analytical projection changed: '+name)
        return projection
    output=folder/'sql_projection/tables'
    if output.exists() and any(output.iterdir()):raise ValueError('Incomplete existing projection requires inspection; no files will be overwritten.')
    output.mkdir(parents=True,exist_ok=True)
    customer={f"SO_LINE:{line['SalesOrderDetailID']}" for line in prepared['snapshot']['sales_order_lines']}
    observed_customers=set();activity=defaultdict(lambda:[Decimal(0),0]);tables={};raw_tables={}
    draw_seen={'lead':bytearray(),'quality':bytearray()};draw_counts={'lead':0,'quality':0}
    required=FULL_TABLES|{'RunEntity','Fact_SimulationEvent','Bridge_RunEntityRelation','Fact_StochasticDraw'}
    if not required<={Path(name).stem for name in manifest['tables']}:raise ValueError('Incomplete original raw table contract.')
    for name,entry in manifest['tables'].items():
        if Path(name).name!=name or not name.endswith('.jsonl'):raise ValueError('Unsafe original table path.')
        stem=Path(name).stem;source=folder/'tables'/name;target=output/name
        raw_hash=hashlib.sha256();projected_hash=hashlib.sha256();raw_rows=0;kept=0;size=0
        with open_raw_binary(folder,name) as src,target.open('xb') as dst:
            for line in src:
                raw_hash.update(line);size+=len(line)
                if not line.strip():continue
                row=json.loads(line);raw_rows+=1
                if row.get('RunCode')!=run_doc['RunCode']:raise ValueError('Cross-run raw row: '+name)
                keep=stem in FULL_TABLES
                if stem=='RunEntity':
                    keep=row['EntityType']=='CUSTOMER_ORDER_LINE'
                    if keep:
                        if row['EntityCode'] not in customer or row['EntityCode'] in observed_customers:raise ValueError('Unexpected/duplicate customer entity.')
                        observed_customers.add(row['EntityCode'])
                elif stem=='Fact_SimulationEvent':
                    keep=row['EventCode'] in CUSTOMER_EVENTS and row['EntityCode'] in customer
                    if row['EventCode'] in ACTIVITY_EVENTS:
                        qty=Decimal(str(row['Quantity']))
                        if not qty.is_finite() or qty<=0:raise ValueError('Invalid full-raw activity quantity.')
                        value=activity[(row['EventAt'][:10],row['ProductID'],row['EventCode'])];value[0]+=qty;value[1]+=1
                    if row['EventCode'] in CUSTOMER_EVENTS and row['EntityCode'] not in customer:raise ValueError('Customer event is outside the exact input cohort.')
                elif stem=='Bridge_RunEntityRelation':keep=row['ParentEntityCode'] in customer and row['ChildEntityCode'] in customer
                elif stem=='Fact_StochasticDraw':
                    keep=False;stream=row['StreamCode'];match=re.fullmatch(r'PO:([1-9][0-9]*)',row['DrawKey'])
                    if stream not in draw_seen or not match or row.get('EntityCode')!=row['DrawKey']:raise ValueError('Unsupported stochastic identity.')
                    identifier=int(match[1])
                    if identifier>entry['rows'] or not 0<float(row['UniformValue'])<1 or not math.isfinite(float(row['AppliedValue'])):raise ValueError('Invalid stochastic draw value or range.')
                    byte,bit=divmod(identifier,8);seen=draw_seen[stream]
                    if len(seen)<=byte:seen.extend(b'\0'*max(byte+1-len(seen),min(max(len(seen),1024),entry['rows']//8+2)))
                    if seen[byte]&(1<<bit):raise ValueError('Duplicate stochastic (stream,PO) key.')
                    seen[byte]|=1<<bit;draw_counts[stream]+=1
                if keep:dst.write(line);projected_hash.update(line);kept+=1
        if raw_hash.hexdigest()!=entry['sha256'] or raw_rows!=entry['rows']:raise ValueError('Raw hash/row count mismatch: '+name)
        raw_tables[name]=dict(rows=raw_rows,sha256=entry['sha256'],bytes=size)
        tables[name]=dict(rows=kept,sha256=projected_hash.hexdigest(),bytes=target.stat().st_size)
    if observed_customers!=customer:raise ValueError('Projected customer entities do not cover all input sales lines.')
    name='BaselineActivity.jsonl';digest=hashlib.sha256()
    with (output/name).open('xb') as dst:
        for (day,product,event),(quantity,count) in sorted(activity.items()):
            record=dict(RunCode=run_doc['RunCode'],Date=day,ProductID=product,EventCode=event,Quantity=str(quantity),EventCount=count)
            line=(canonical(record)+'\n').encode('utf-8');dst.write(line);digest.update(line)
    tables[name]=dict(rows=len(activity),sha256=digest.hexdigest(),bytes=(output/name).stat().st_size)
    for name,entry in tables.items():
        if entry['bytes']>=1900*1024*1024:raise ValueError('A retained projection file exceeds safe SQL SINGLE_BLOB admission: '+name)
    estimated=sum(entry['rows']*AVERAGE_BYTES.get(Path(name).stem,0) for name,entry in tables.items())+8192
    projection=dict(schema='companyx.baseline.projection.v1',RunCode=run_doc['RunCode'],
        publication_mode='ANALYTICAL_PROJECTION_FULL_RAW_ARTIFACT',source_table_manifest_sha256=sha(folder/'table_manifest.json'),
        source_completion_sha256=sha(folder/'completion.json'),raw_tables=raw_tables,tables=tables,
        stochastic_audit=dict(status='PASSED',method='Exact per-stream PO-ID bitset uniqueness, row identity/value checks and complete original SHA256/row counts',counts=draw_counts),
        estimated_sql_bytes=estimated,projection_bytes=sum(e['bytes'] for e in tables.values()),
        retained_semantics='Full daily snapshots, order headers, customer-line entities and demand/shipment/loss events, retained-endpoint relations, policy/run summaries. Production/purchase/receipt activity aggregated exactly by date/product/event. Full original physical lineage and random draws remain in the verified raw artifacts/ZIP.',
        excluded_detail_storage='ORIGINAL_VERIFIED_ARTIFACT_PENDING_ZIP64_ARCHIVE')
    immutable_write(existing,json.dumps(projection,ensure_ascii=False,indent=2))
    return projection


def prepare_baseline(artifact_folder,*,project_root=None):
    project,folder=_folder(artifact_folder,project_root)
    demo,prepared,execution,run_doc,manifest=_header(folder,project)
    projection=_projection(folder,prepared,run_doc,manifest)
    sql=build_baseline(project)
    if Path(__file__).with_name('PublishBaseline.sql').read_text(encoding='utf-8')!=sql:raise ValueError('Baseline SQL differs from reviewed derivation.')
    hashes={}
    for name in ('input_source.json','input.json','execution_spec.json','execution_profile.json','run.json'):
        immutable_write(folder/(name+'.canonical'),canonical(read(folder/name)));hashes[name]=sha(folder/(name+'.canonical'))
    original=prepared['scope'];spec=prepared['spec']
    scope=dict(schema='companyx.baseline.publication_scope.v1',baseline_id=execution['baseline_id'],request_id=execution['baseline_id'],
        source_matrix_index=execution['source_matrix_index'],scenario_index=execution['scenario_index'],
        start=original['start'],end=original['end'],original_base_start=original['original_base_start'],
        initial_state_mode='NEW_EXPERIMENT',initial_state_rule=original['initial_state_rule'],product_scope_mode='WHOLE_ORDERS',
        evaluation_scope=original['evaluation_scope'],source_extract_hash=prepared['provenance']['source_extract_content_sha256'],
        source_scope_sha256=original['scope_sha256'],interpretation=original['parameter_interpretation'])
    immutable_write(folder/'baseline_publication_scope.json',json.dumps(scope,ensure_ascii=False,indent=2))
    selection=dict(policy='ROP',solver=spec['solver']['name'],timing=spec.get('production_lead_time_mode','LEGACY_REQUEST_DATE'),scenario=execution['source_matrix_index'],initial_state_rule='SAFETY_STOCK_LEVEL',source_sha256=sha(folder/'input_source.json'))
    export=dict(status='COMPLETE',schema='companyx.control.v1',selection=selection,core_sha256=run_doc['code_sha256'],
        completion_sha256=sha(folder/'completion.json'),canonical_files=hashes,scope_file_sha256=sha(folder/'baseline_publication_scope.json'),projection_sha256=sha(folder/'baseline_projection.json'))
    original_proof=read(demo/'KetQua/Demo_01/dw_source_proof.json')
    proof=dict(schema='companyx.baseline.source_proof.v1',database=DATABASE,source_database=SOURCE,etl_batch=original_proof['etl_batch'],
        source_extract_hash=prepared['provenance']['source_extract_content_sha256'],frozen_lead_input_hash=hashlib.sha256(canonical(read(demo/'KetQua/Demo_01/input_source.json')).encode('utf-8')).hexdigest())
    for name,value in [('simulation_selection.json',selection),('simulation_export.json',export),('dw_source_proof.json',proof)]:immutable_write(folder/name,json.dumps(value,ensure_ascii=False,indent=2))
    return project,demo,folder,sql,run_doc,projection


def publish_baseline(artifact_folder,*,project_root=None):
    import pyodbc
    project,demo,folder,sql,run_doc,projection=prepare_baseline(artifact_folder,project_root=project_root)
    # Admission includes analytical SQL plus tempdb/log allowance; actual raw is already on disk.
    reserve=max(4*2**30,int(projection['estimated_sql_bytes']*4))
    if shutil.disk_usage(project).free<reserve:raise RuntimeError('Insufficient free space for analytical publication/tempdb/log reserve.')
    from .operation_gate import publish_operation_gate
    with publish_operation_gate(),pyodbc.connect(CONNECTION,autocommit=True,timeout=15) as conn:
        conn.timeout=1800;cursor=conn.cursor();cursor.execute(sql,str(demo),str(folder),SOURCE);receipt=None
        while True:
            if cursor.description:
                names=[column[0] for column in cursor.description]
                for row in cursor.fetchall():
                    if 'PublicationReceipt' in names:receipt=json.loads(row[names.index('PublicationReceipt')])
            if not cursor.nextset():break
        if not receipt or receipt.get('status') not in ('LOADED','ALREADY_LOADED'):raise RuntimeError('No successful baseline publication receipt.')
    from .detail_publisher import publish_detail
    detail_receipt=publish_detail(folder,receipt['PlanningRunKey'],project_root=project)
    receipt.update(schema='companyx.baseline.publication.v1',RunCode=run_doc['RunCode'],verification_status='PASSED',detail_publication=detail_receipt,
        publication_mode='ANALYTICAL_PROJECTION_FULL_RAW_ARTIFACT',projection_sha256=sha(folder/'baseline_projection.json'),
        estimated_sql_bytes=projection['estimated_sql_bytes'],publisher_sql_sha256=hashlib.sha256(sql.encode('utf-8')).hexdigest(),published_at=datetime.now(timezone.utc).isoformat())
    output=folder/'baseline_publication_receipt.json'
    if output.exists():
        output=folder/'baseline_publication_attempts'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json');output.parent.mkdir(exist_ok=True)
    immutable_write(output,json.dumps(receipt,ensure_ascii=False,indent=2))
    return receipt


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('folder');parser.add_argument('--prepare-only',action='store_true');args=parser.parse_args()
    if args.prepare_only:
        *_,run_doc,projection=prepare_baseline(args.folder)
        print(json.dumps(dict(status='READY_FOR_SQL',RunCode=run_doc['RunCode'],estimated_sql_bytes=projection['estimated_sql_bytes'],projection_bytes=projection['projection_bytes'])))
    else:print(json.dumps(publish_baseline(args.folder),ensure_ascii=False))

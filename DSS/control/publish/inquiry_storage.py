"""Verified pre-publication storage for one completed V2 inquiry candidate.

SQL projections contain complete daily/customer/solve facts and exact activity
aggregates. Original raw tables remain authoritative in a verified ZIP64 archive.
No SQL is written, no solver is launched, and frozen simulation modules are not
modified. Storage status VERIFIED_UNPUBLISHED never implies SQL publication.
"""
from __future__ import annotations
from collections import Counter,defaultdict
from contextlib import contextmanager
from datetime import datetime,timezone
from decimal import Decimal
import hashlib,io,json,math,os,re,shutil,sys,zipfile
from pathlib import Path
sys.dont_write_bytecode=True
os.environ['PYTHONDONTWRITEBYTECODE']='1'

CUSTOMER_EVENTS={'CUSTOMER_ORDER_CREATED','CUSTOMER_DUE','SHIP_ON_TIME','SHIP_LATE','LOST_SALE'}
PUBLIC_ACTIVITY={'PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE','BUY_ORDER'}
FLOW_ACTIVITY=PUBLIC_ACTIVITY|{'BUY_RECEIVE_GOOD','BUY_REJECT'}
FULL_TABLES={'Fact_SimulationDaily','Fact_SimulationOrder','Fact_PolicySimulation','RunSummary','ProductScope','ValuationBasis','ExternalSupplyDraw','Fact_OptimizationSolve'}
RAW_EXTRA={'RunEntity','Fact_SimulationEvent','Bridge_RunEntityRelation','Fact_StochasticDraw'}
AVERAGE_BYTES={'Fact_SimulationDaily':285,'Fact_SimulationOrder':165,'Fact_PolicySimulation':274,'RunEntity':393,
 'Fact_SimulationEvent':275,'Bridge_RunEntityRelation':120,'Fact_OptimizationSolve':800,'InquiryActivity':100,'InquiryFlowAudit':100}
RESERVE_BYTES=12*2**30
CHUNK=4*1024*1024


def read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def canonical(value):return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),default=str,allow_nan=False)
def digest(value):return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()
def stamp():return datetime.now(timezone.utc).isoformat()
def sha(path):
    value=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda:stream.read(CHUNK),b''):value.update(block)
    return value.hexdigest()


def immutable_json(path,value):
    path=Path(path);raw=json.dumps(value,ensure_ascii=False,indent=2,allow_nan=False).encode('utf-8')
    if path.exists():
        if path.read_bytes()!=raw:raise ValueError('Refusing to overwrite existing storage evidence: '+str(path))
    else:
        path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('xb') as stream:stream.write(raw)


def _scope(folder,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[4]
    folder=Path(folder).resolve()
    if not folder.is_relative_to(project/'GPT') or folder==project/'GPT':raise ValueError('Inquiry storage requires a dedicated Project/GPT folder.')
    return project,folder


def _member(folder,relative):
    item=Path(relative)
    if item.is_absolute() or '..' in item.parts or ':' in str(item):raise ValueError('Unsafe storage member path.')
    path=(folder/item).resolve()
    if not path.is_relative_to(folder):raise ValueError('Storage member escapes its owned artifact folder.')
    return path


def _reserve(folder):
    if shutil.disk_usage(folder).free<RESERVE_BYTES:
        raise RuntimeError('Inquiry storage stopped before the 12 GiB free-space reserve. Existing raw artifacts are retained.')


def _progress(folder,stage,**values):
    path=folder/'inquiry_storage_progress.json';pending=path.with_suffix('.pending')
    pending.write_text(json.dumps(dict(stage=stage,updated_at=stamp(),**values),ensure_ascii=False,indent=2),encoding='utf-8')
    pending.replace(path)


def _project(folder,prepared,run_doc,manifest):
    target_manifest=folder/'inquiry_projection.json'
    if target_manifest.exists():
        projection=read(target_manifest)
        if projection['RunCode']!=run_doc['RunCode'] or projection['source_table_manifest_sha256']!=sha(folder/'table_manifest.json'):
            raise ValueError('Existing inquiry projection belongs to another source.')
        _verify_projection(folder,projection)
        return projection
    output=folder/'sql_projection/tables'
    if output.exists() and any(output.iterdir()):raise ValueError('Partial projection exists; retain it for inspection, do not overwrite.')
    output.mkdir(parents=True,exist_ok=True)
    customer={f"SO_LINE:{r['SalesOrderDetailID']}" for r in prepared['snapshot']['sales_order_lines']}
    found=set();flow=defaultdict(lambda:[Decimal(0),0]);tables={};raw_tables={}
    draw_seen={'lead':bytearray(),'quality':bytearray()};draw_counts=Counter()
    if not FULL_TABLES|RAW_EXTRA <= {Path(k).stem for k in manifest['tables']}:
        raise ValueError('Incomplete raw inquiry table contract.')
    for name,entry in manifest['tables'].items():
        if Path(name).name!=name or not name.endswith('.jsonl'):raise ValueError('Unsafe raw table name.')
        stem=Path(name).stem;source=folder/'tables'/name;target=output/name
        source_hash=hashlib.sha256();out_hash=hashlib.sha256();rows=0;kept=0;size=0;next_check=0
        with source.open('rb') as src,target.open('xb') as dst:
            for line in src:
                source_hash.update(line);size+=len(line)
                if not line.strip():continue
                row=json.loads(line);rows+=1
                if row.get('RunCode')!=run_doc['RunCode']:raise ValueError('Cross-run raw row: '+name)
                keep=stem in FULL_TABLES
                if stem=='RunEntity':
                    keep=row['EntityType']=='CUSTOMER_ORDER_LINE'
                    if keep:
                        if row['EntityCode'] not in customer or row['EntityCode'] in found:raise ValueError('Unexpected or duplicate customer entity.')
                        found.add(row['EntityCode'])
                elif stem=='Fact_SimulationEvent':
                    keep=row['EventCode'] in CUSTOMER_EVENTS and row['EntityCode'] in customer
                    if row['EventCode'] in CUSTOMER_EVENTS and row['EntityCode'] not in customer:raise ValueError('Customer event outside exact input cohort.')
                    if row['EventCode'] in FLOW_ACTIVITY:
                        quantity=Decimal(str(row['Quantity']))
                        if not quantity.is_finite() or quantity<=0:raise ValueError('Invalid physical activity quantity.')
                        day=row['EventAt'][:10]
                        if not prepared['snapshot']['start']<=day<=prepared['snapshot']['end']:raise ValueError('Activity outside the simulation interval.')
                        value=flow[(day,row['ProductID'],row['EventCode'])];value[0]+=quantity;value[1]+=1
                elif stem=='Bridge_RunEntityRelation':keep=row['ParentEntityCode'] in customer and row['ChildEntityCode'] in customer
                elif stem=='Fact_StochasticDraw':
                    keep=False;stream=row['StreamCode'];match=re.fullmatch(r'PO:([1-9][0-9]*)',row['DrawKey'])
                    if stream not in draw_seen or not match or row.get('EntityCode')!=row['DrawKey']:raise ValueError('Unsupported stochastic draw identity.')
                    identifier=int(match[1])
                    if identifier>entry['rows'] or not 0<float(row['UniformValue'])<1 or not math.isfinite(float(row['AppliedValue'])):raise ValueError('Invalid stochastic draw value/range.')
                    byte,bit=divmod(identifier,8);seen=draw_seen[stream]
                    if len(seen)<=byte:seen.extend(b'\0'*max(byte+1-len(seen),min(max(len(seen),1024),entry['rows']//8+2)))
                    if seen[byte]&(1<<bit):raise ValueError('Duplicate stochastic stream/PO identity.')
                    seen[byte]|=1<<bit;draw_counts[stream]+=1
                if keep:dst.write(line);out_hash.update(line);kept+=1
                if size>=next_check:_reserve(folder);next_check=size+128*1024*1024
        if source_hash.hexdigest()!=entry['sha256'] or rows!=entry['rows']:raise ValueError('Raw source hash/row count mismatch: '+name)
        raw_tables[name]=dict(rows=rows,sha256=entry['sha256'],bytes=size)
        tables[name]=dict(rows=kept,sha256=out_hash.hexdigest(),bytes=target.stat().st_size)
        _progress(folder,'projection',table=name,raw_rows=rows,retained_rows=kept)
    if found!=customer:raise ValueError('Projected customer entities do not cover every input line.')
    for name,is_public in [('InquiryFlowAudit.jsonl',False),('InquiryActivity.jsonl',True)]:
        value_hash=hashlib.sha256();count=0
        with (output/name).open('xb') as dst:
            for (day,product,event),(quantity,number) in sorted(flow.items()):
                if is_public and (event not in PUBLIC_ACTIVITY or not prepared['scope']['known_at']<=day<=prepared['scope']['analysis_end']):continue
                row=dict(RunCode=run_doc['RunCode'],Date=day,ProductID=product,EventCode=event,Quantity=str(quantity),EventCount=number)
                raw=(canonical(row)+'\n').encode('utf-8');dst.write(raw);value_hash.update(raw);count+=1
        tables[name]=dict(rows=count,sha256=value_hash.hexdigest(),bytes=(output/name).stat().st_size)
    for name,entry in tables.items():
        if entry['bytes']>=1900*1024*1024:raise ValueError('Retained SQL projection exceeds SINGLE_BLOB admission: '+name)
    projection=dict(schema='companyx.inquiry.projection.v1',RunCode=run_doc['RunCode'],
        publication_mode='ANALYTICAL_PROJECTION_FULL_RAW_ARCHIVE',source_table_manifest_sha256=sha(folder/'table_manifest.json'),
        source_completion_sha256=sha(folder/'completion.json'),source_scope_sha256=sha(folder/'scope.json'),
        known_at=prepared['scope']['known_at'],analysis_end=prepared['scope']['analysis_end'],
        raw_tables=raw_tables,tables=tables,projection_bytes=sum(e['bytes'] for e in tables.values()),
        estimated_sql_bytes=sum(e['rows']*AVERAGE_BYTES.get(Path(k).stem,0) for k,e in tables.items())+8192,
        stochastic_audit=dict(status='PASSED',method='Full raw hashes/row counts plus exact per-stream PO-ID bitset uniqueness and value/identity checks',counts=dict(draw_counts)),
        public_activity=dict(codes=sorted(PUBLIC_ACTIVITY),start=prepared['scope']['known_at'],end=prepared['scope']['analysis_end']),
        flow_audit=dict(codes=sorted(FLOW_ACTIVITY),start=prepared['snapshot']['start'],end=prepared['snapshot']['end'],purpose='Full-history SQL conservation validation, not an extra public activity measure group.'),
        retained_semantics='Full daily, order-header, customer-line and customer-event facts; full policy/run/optimization summaries. InquiryActivity contains five exact date/product/event aggregates from X. InquiryFlowAudit retains all seven exact physical-flow aggregates over the entire run.',
        omitted_detail_storage='Exact original JOB/EXEC/PO/receipt/BOM/random-draw rows remain in the verified raw ZIP; no synthetic physical events are fabricated for SQL.',
        metric_window_note='Original RunSummary and PolicySimulation cover the complete replay. Use dated facts/activity and inquiry summaries for the X..analysis_end comparison.')
    immutable_json(target_manifest,projection)
    return projection


def _verify_projection(folder,projection):
    for name,entry in projection['tables'].items():
        if Path(name).name!=name:raise ValueError('Unsafe projection filename.')
        path=folder/'sql_projection/tables'/name
        if sha(path)!=entry['sha256'] or path.stat().st_size!=entry['bytes']:raise ValueError('Projection identity changed: '+name)


def _archive(folder,manifest):
    evidence=folder/'inquiry_archive_manifest.json'
    if evidence.exists():return _verify_archive(folder)
    archive=folder/'inquiry_raw_artifacts.zip';pending=folder/'inquiry_raw_artifacts.pending.zip'
    if archive.exists() or pending.exists():raise ValueError('Unregistered inquiry archive exists; do not overwrite.')
    members={}
    for name,entry in manifest['tables'].items():
        if Path(name).name!=name:raise ValueError('Unsafe raw table filename.')
        path=_member(folder,'tables/'+name);stat=path.stat()
        members['tables/'+name]=dict(sha256=entry['sha256'],rows=entry['rows'],bytes=stat.st_size,mtime_ns=stat.st_mtime_ns)
    if (folder/'daily_totals.json').exists():
        path=folder/'daily_totals.json';stat=path.stat()
        members['daily_totals.json']=dict(sha256=sha(path),bytes=stat.st_size,mtime_ns=stat.st_mtime_ns)
    try:
        with zipfile.ZipFile(pending,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=1,allowZip64=True) as zipped:
            for relative,entry in members.items():
                value=hashlib.sha256();size=0;newlines=0;last=b''
                with _member(folder,relative).open('rb') as src,zipped.open(relative,'w',force_zip64=True) as dst:
                    for block in iter(lambda:src.read(CHUNK),b''):
                        _reserve(folder);dst.write(block);value.update(block);size+=len(block);newlines+=block.count(b'\n');last=block[-1:]
                count=newlines+int(bool(last) and last!=b'\n')
                if value.hexdigest()!=entry['sha256'] or size!=entry['bytes'] or ('rows'in entry and count!=entry['rows']):raise ValueError('Raw source changed while archiving: '+relative)
                _progress(folder,'compressing',member=relative,raw_bytes=size)
        # Read the compressed bytes back independently; reaching EOF verifies ZIP CRC.
        _verify_zip_members(pending,members,folder)
        pending.rename(archive)
    except BaseException:
        # Only the new, uncommitted temporary ZIP created by this call is removable.
        # Original raw artifacts have not yet been touched.
        if pending.exists():_member(folder,pending.name).unlink()
        raise
    record=dict(schema='companyx.inquiry.archive.v1',status='VERIFIED_RAW_ARCHIVE',RunCode=manifest['RunCode'],
        archive_file=archive.name,archive_sha256=sha(archive),archive_bytes=archive.stat().st_size,
        raw_bytes=sum(v['bytes'] for v in members.values()),members=members,table_manifest_sha256=sha(folder/'table_manifest.json'),
        verification_attestation_sha256=sha(folder/'inquiry_storage_verification.json'),
        projection_sha256=sha(folder/'inquiry_projection.json'),verified_at=stamp(),
        publication_status='UNPUBLISHED',verification_method='Source SHA/rows while writing ZIP64, independent decompression SHA/length/rows and ZIP CRC.')
    immutable_json(evidence,record)
    return record


def _verify_zip_members(archive,members,folder=None):
    with zipfile.ZipFile(archive,'r') as zipped:
        if len(zipped.namelist())!=len(members) or set(zipped.namelist())!=set(members):raise ValueError('Archive member set changed or contains duplicates.')
        for relative,entry in members.items():
            value=hashlib.sha256();size=0;newlines=0;last=b''
            with zipped.open(relative,'r') as src:
                for block in iter(lambda:src.read(CHUNK),b''):
                    value.update(block);size+=len(block);newlines+=block.count(b'\n');last=block[-1:]
            rows=newlines+int(bool(last) and last!=b'\n')
            if value.hexdigest()!=entry['sha256'] or size!=entry['bytes'] or ('rows'in entry and rows!=entry['rows']):raise ValueError('Archive stream identity mismatch: '+relative)
            if folder:_progress(folder,'archive_readback_verified',member=relative,raw_bytes=size)


def _verify_archive(folder,*,full=True):
    record=read(folder/'inquiry_archive_manifest.json')
    if record.get('schema')!='companyx.inquiry.archive.v1' or record.get('status')!='VERIFIED_RAW_ARCHIVE':raise ValueError('Unsupported inquiry archive evidence.')
    if record['RunCode']!=read(folder/'run.json')['RunCode'] or record['table_manifest_sha256']!=sha(folder/'table_manifest.json'):raise ValueError('Archive source identity differs.')
    path=_member(folder,record['archive_file'])
    if sha(path)!=record['archive_sha256'] or path.stat().st_size!=record['archive_bytes']:raise ValueError('Archive checksum/size changed.')
    if record['verification_attestation_sha256']!=sha(folder/'inquiry_storage_verification.json') or record['projection_sha256']!=sha(folder/'inquiry_projection.json'):raise ValueError('Archive verification/projection evidence changed.')
    raw=read(folder/'table_manifest.json')['tables']
    expected={'tables/'+name for name in raw}
    if not expected<=set(record['members']) or set(record['members'])-expected not in (set(),{'daily_totals.json'}):raise ValueError('Archive member contract differs.')
    for name,entry in raw.items():
        member=record['members']['tables/'+name]
        if member['sha256']!=entry['sha256'] or member['rows']!=entry['rows']:raise ValueError('Archived table differs from original manifest.')
    if full:_verify_zip_members(path,record['members'],folder)
    return record


@contextmanager
def open_inquiry_artifact_text(folder,relative):
    """Stream from already verified storage; never restore multi-gigabyte tables."""
    folder=Path(folder).resolve();path=_member(folder,relative)
    if path.exists():
        with path.open('r',encoding='utf-8-sig') as stream:yield stream
        return
    record=read(folder/'inquiry_archive_manifest.json');relative=str(Path(relative)).replace('\\','/')
    if relative not in record['members']:raise FileNotFoundError(relative)
    with zipfile.ZipFile(_member(folder,record['archive_file']),'r') as zipped:
        with zipped.open(relative,'r') as binary,io.TextIOWrapper(binary,encoding='utf-8-sig') as stream:yield stream


def _remove_verified_raw(folder,archive):
    for relative,entry in archive['members'].items():
        path=_member(folder,relative)
        if not path.exists():continue
        stat=path.stat()
        if stat.st_size!=entry['bytes'] or stat.st_mtime_ns!=entry['mtime_ns']:raise ValueError('Raw artifact changed after ZIP verification; retained: '+relative)
    for relative in archive['members']:
        path=_member(folder,relative)
        if path.exists():path.unlink()


def _static_files(folder):
    names=['request.json','scope.json','input.json','input_source.json','execution_spec.json','execution_profile.json','run.json',
        'completion.json','table_manifest.json','metrics.json','valuation_basis.json','control_execution_receipt.json','prefix_proof.json',
        'branch_state.json','inquiry_summary.json','inquiry_decision_plan.jsonl','inquiry_decision_plan_manifest.json','inquiry_projection.json',
        'storage_review/plan_at_X.jsonl','storage_review/plan_manifest.json']
    if (folder/'rolling_plan_manifest.json').exists():
        names.extend(['rolling_plan_versions.jsonl','rolling_plan_actions.jsonl','rolling_plan_manifest.json'])
    return {name:dict(sha256=sha(_member(folder,name)),bytes=_member(folder,name).stat().st_size) for name in names}


def prepare_candidate_storage(folder,project_root=None):
    project,folder=_scope(folder,project_root)
    sys.path.insert(0,str(project/'New Inventory Safety/DSS/control'))
    from simulation.inquiry_v2 import verify_inquiry_artifact
    if (folder/'inquiry_storage_receipt.json').exists():return verify_stored_inquiry(folder,project)['storage_receipt']
    if any((folder/p).exists() for p in ('RUNNING.lock','DW_PUBLISH.lock')):raise ValueError('Candidate execution/publication is still active.')
    if (folder/'inquiry_archive_manifest.json').exists():
        # Recovery after a fully verified archive but before all individual raw
        # files were removed. No simulation or compression is repeated.
        archive=_verify_archive(folder)
        _check_attestation(folder)
        _remove_verified_raw(folder,archive)
        attestation=read(folder/'inquiry_storage_verification.json');projection=read(folder/'inquiry_projection.json')
    else:
        _progress(folder,'verifying_raw_candidate')
        verification=verify_inquiry_artifact(folder,project)
        prepared=verification['prepared'];run_doc=read(folder/'run.json');manifest=read(folder/'table_manifest.json')
        from simulation.adapter import runtime
        _,_,_,inputs,_,_,valuation=runtime(project)
        from companyx_unified_v2.integration_contract import validate_profile
        validate_profile(read(folder/'execution_profile.json'),prepared['snapshot'],prepared['spec'],inputs.prepare(prepared['snapshot'],prepared['spec']))
        if valuation.validate(prepared['snapshot'])!=run_doc['valuation_sha256'] or read(folder/'valuation_basis.json')!=prepared['snapshot']['metadata']['valuation']:
            raise ValueError('Completed candidate valuation/profile identity mismatch.')
        projection=_project(folder,prepared,run_doc,manifest)
        from review_plan import export_review_plan
        review=export_review_plan(folder,folder/'storage_review')
        attestation=dict(schema='companyx.inquiry.storage_verification.v1',status='VERIFIED_RAW',RunCode=run_doc['RunCode'],
            scope_sha256=prepared['scope']['scope_sha256'],snapshot_sha256=prepared['snapshot_sha256'],
            execution_spec_sha256=prepared['execution_spec_sha256'],runtime_code_sha256=prepared['runtime_code_sha256'],
            adapter_sha256=prepared['adapter_sha256'],adapter_dependencies_sha256=prepared['adapter_dependencies_sha256'],
            common_state_sha256=verification['common_state_sha256'],storage_module_sha256=sha(__file__),
            static_files=_static_files(folder),verified_at=stamp(),typed_plan_sha256=review['sha256'],
            verification_method='Frozen V2 verifier on exact raw files, followed by full hash/row/identity checked analytical projection. Typed plan and summary remain unarchived.')
        immutable_json(folder/'inquiry_storage_verification.json',attestation)
        archive=_archive(folder,manifest)
        _remove_verified_raw(folder,archive)
    receipt=dict(schema='companyx.inquiry.storage.v1',status='VERIFIED_UNPUBLISHED',RunCode=attestation['RunCode'],
        artifact_folder=str(folder),archive_sha256=archive['archive_sha256'],archive_manifest_sha256=sha(folder/'inquiry_archive_manifest.json'),
        projection_sha256=sha(folder/'inquiry_projection.json'),verification_attestation_sha256=sha(folder/'inquiry_storage_verification.json'),
        raw_bytes=archive['raw_bytes'],archive_bytes=archive['archive_bytes'],projection_bytes=projection['projection_bytes'],
        estimated_sql_bytes=projection['estimated_sql_bytes'],common_state_sha256=attestation['common_state_sha256'],
        removed_raw_members=sorted(archive['members']),storage_module_sha256=sha(__file__),completed_at=stamp(),sql_written=False)
    immutable_json(folder/'inquiry_storage_receipt.json',receipt)
    _progress(folder,'VERIFIED_UNPUBLISHED',raw_bytes=archive['raw_bytes'],archive_bytes=archive['archive_bytes'])
    return receipt


def _check_attestation(folder):
    attestation=read(folder/'inquiry_storage_verification.json')
    if attestation.get('schema')!='companyx.inquiry.storage_verification.v1' or attestation.get('status')!='VERIFIED_RAW':raise ValueError('Invalid raw verification attestation.')
    if attestation['storage_module_sha256']!=sha(__file__):raise ValueError('Storage verifier module differs from its attested version.')
    for name,entry in attestation['static_files'].items():
        path=_member(folder,name)
        if sha(path)!=entry['sha256'] or path.stat().st_size!=entry['bytes']:raise ValueError('Attested business artifact changed: '+name)
    return attestation


def verify_stored_inquiry(folder,project_root=None):
    project,folder=_scope(folder,project_root)
    sys.path.insert(0,str(project/'New Inventory Safety/DSS/control'))
    from simulation import inquiry_v2 as v2
    _,_,_,inputs,legacy,run,valuation=v2.runtime(project)
    scope=read(folder/'scope.json');request=read(folder/'request.json')
    prepared=v2.build_request(request,scope['candidate_id'],project)
    attestation=_check_attestation(folder);storage=read(folder/'inquiry_storage_receipt.json')
    if storage.get('schema')!='companyx.inquiry.storage.v1' or storage.get('status')!='VERIFIED_UNPUBLISHED' or storage.get('sql_written') is not False:
        raise ValueError('A verified pre-publication inquiry storage receipt is required.')
    for name,expected in [('input',prepared['snapshot']),('input_source',prepared['snapshot']),('execution_spec',prepared['spec']),('scope',prepared['scope'])]:
        if read(folder/f'{name}.json')!=expected:raise ValueError('Stored inquiry does not reproduce: '+name)
    receipt=read(folder/'control_execution_receipt.json');completion=read(folder/'completion.json');run_doc=read(folder/'run.json');manifest=read(folder/'table_manifest.json')
    if (receipt.get('schema')!='companyx.inquiry.execution.v2' or receipt.get('status')!='COMPLETE' or completion.get('status')!='COMPLETE'
        or receipt.get('scope_sha256')!=prepared['scope']['scope_sha256'] or receipt.get('adapter_sha256')!=prepared['adapter_sha256']
        or receipt.get('adapter_dependencies_sha256')!=prepared['adapter_dependencies_sha256'] or receipt.get('core_sha256')!=run.code_hash()
        or receipt.get('run_code')!=run_doc['RunCode'] or completion.get('RunCode')!=run_doc['RunCode'] or manifest.get('RunCode')!=run_doc['RunCode']
        or run_doc['code_sha256']!=run.code_hash() or run_doc['input_sha256']!=prepared['snapshot_sha256']
        or run_doc['execution_spec_sha256']!=prepared['execution_spec_sha256'] or storage['RunCode']!=run_doc['RunCode']
        or attestation['RunCode']!=run_doc['RunCode'] or attestation['scope_sha256']!=scope['scope_sha256']
        or attestation['snapshot_sha256']!=prepared['snapshot_sha256'] or attestation['execution_spec_sha256']!=prepared['execution_spec_sha256']
        or attestation['adapter_sha256']!=prepared['adapter_sha256'] or attestation['runtime_code_sha256']!=run.code_hash()):
        raise ValueError('Stored inquiry execution identity mismatch.')
    if completion['table_manifest_sha256']!=sha(folder/'table_manifest.json') or completion['metrics_sha256']!=sha(folder/'metrics.json'):
        raise ValueError('Completion-bound artifacts changed.')
    from companyx_unified_v2.integration_contract import validate_profile
    validate_profile(read(folder/'execution_profile.json'),prepared['snapshot'],prepared['spec'],inputs.prepare(prepared['snapshot'],prepared['spec']))
    if valuation.validate(prepared['snapshot'])!=run_doc['valuation_sha256'] or read(folder/'valuation_basis.json')!=prepared['snapshot']['metadata']['valuation']:
        raise ValueError('Stored valuation/profile differs.')
    archive=_verify_archive(folder,full=True)
    if (storage['archive_sha256']!=archive['archive_sha256'] or storage['archive_manifest_sha256']!=sha(folder/'inquiry_archive_manifest.json')
        or storage['projection_sha256']!=sha(folder/'inquiry_projection.json') or storage['verification_attestation_sha256']!=sha(folder/'inquiry_storage_verification.json')
        or storage['storage_module_sha256']!=sha(__file__)):
        raise ValueError('Storage receipt archive/projection identity differs.')
    projection=read(folder/'inquiry_projection.json');_verify_projection(folder,projection)
    for name,entry in manifest['tables'].items():
        if projection['raw_tables'][name]['sha256']!=entry['sha256'] or projection['raw_tables'][name]['rows']!=entry['rows']:
            raise ValueError('Projection raw source differs from archived source.')
    proof=read(folder/'prefix_proof.json');state=read(folder/'branch_state.json')
    if (proof['status']!='PASSED' or state['common_state_sha256']!=legacy.digest(state['common_state'])
        or state.get('initialization_mode')!=scope['initialization_mode'] or state['prefix_proof_sha256']!=legacy.digest(proof)
        or attestation['common_state_sha256']!=state['common_state_sha256'] or storage['common_state_sha256']!=state['common_state_sha256']):
        raise ValueError('Stored common-state proof differs.')
    for name in ('prefix_proof','branch_state','inquiry_summary'):
        if sha(folder/f'{name}.json')!=receipt[name+'_sha256']:raise ValueError('Stored execution proof changed: '+name)
    checker=v2.PrefixVerifier(scope['base_run_folder'],scope['known_at'],legacy,project,scope['initialization_mode'])
    try:
        for table,field in checker.tables.items():
            with open_inquiry_artifact_text(folder,'tables/'+table+'.jsonl') as stream:
                for text in stream:
                    row=json.loads(text)
                    if row[field]>=scope['known_at']:break
                    checker.row(table,row)
        if checker.finish()!=proof:raise ValueError('Archived raw prefix differs from selected ROP baseline or fresh-state proof.')
    finally:checker.close()
    expected_lines={f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in scope['synthetic_orders'] for r in o['lines']}
    expected_orders={o['sales_order_id']:o['source_reference'] for o in scope['synthetic_orders']}
    for table,key,expected in [('RunEntity','EntityCode',expected_lines),('Fact_SimulationOrder','SourceSalesOrderID',expected_orders)]:
        found=set()
        with open_inquiry_artifact_text(folder,'tables/'+table+'.jsonl') as stream:
            for text in stream:
                row=json.loads(text)
                if row[key] in expected:
                    if row['SourceRecordReference']!=expected[row[key]]:raise ValueError('Archived synthetic source provenance changed.')
                    found.add(row[key])
        if found!=set(expected):raise ValueError('Archived synthetic entities are missing.')
    plan=receipt['decision_plan']
    if Path(plan['path']).name!=plan['path'] or sha(folder/plan['path'])!=plan['sha256']:raise ValueError('Original MILP plan identity differs.')
    if 'rolling_plan' in receipt:
        from simulation.rolling_plan import verify_rolling_plan
        verify_rolling_plan(folder,receipt['rolling_plan'],project)
    _progress(folder,'stored_candidate_verified',RunCode=run_doc['RunCode'])
    return dict(status='VERIFIED',prepared=prepared,receipt=receipt,storage_receipt=storage,projection=projection,
        archive=archive,common_state_sha256=state['common_state_sha256'])

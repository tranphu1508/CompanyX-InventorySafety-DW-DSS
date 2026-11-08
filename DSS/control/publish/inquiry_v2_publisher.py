"""Archive-aware V2 publication; frozen V1/V2 simulation adapters are read-only."""
from datetime import datetime,timezone
import hashlib,json,shutil,sys
from pathlib import Path
from .publisher import read,sha,canonical,immutable_write,CONNECTION,DATABASE,SOURCE
from .derive_inquiry_v2_semantic import build_inquiry_v2_semantic


def prepare_v2(artifact_folder,*,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    folder=Path(artifact_folder).resolve()
    if not folder.is_relative_to(project/'_local') or folder==project/'_local':raise ValueError('Dedicated GPT artifact folder required.')
    sys.path.insert(0,str(project/'DSS/control'))
    from .inquiry_storage import verify_stored_inquiry
    from simulation.adapter import runtime
    if (folder/'continuation_receipt.json').exists():
        from .continuation_storage import verify_stored_continuation
        verified=verify_stored_continuation(folder,project_root=project)
    else:
        if (folder.parents[2]/'cache_identity.json').exists():
            raise ValueError('A cache-enabled job requires independently verified continuation evidence.')
        verified=verify_stored_inquiry(folder,project_root=project)
    prepared=verified['prepared'];scope=prepared['scope'];spec=prepared['spec'];run_doc=read(folder/'run.json')
    if scope['schema']!='companyx.inquiry.scope.v2':raise ValueError('V2 scope required.')
    from .inquiry_purpose import build_publication_purpose
    purpose=build_publication_purpose(folder,project_root=project)
    immutable_write(folder/'publication_purpose.json',json.dumps(purpose,ensure_ascii=False,indent=2))
    _,demo,_,_,_,run,_=runtime(project)
    if run_doc['code_sha256']!=run.code_hash():raise ValueError('Immutable simulation core changed.')
    for relative,expected in read(demo/'SSIS/core_hashes.json').items():
        path=(demo/relative).resolve()
        if not path.is_relative_to(demo) or sha(path)!=expected:raise ValueError('Protected core changed: '+relative)
    sql=build_inquiry_v2_semantic(project)
    if Path(__file__).with_name('PublishInquiryV2Semantic.sql').read_text(encoding='utf-8')!=sql:raise ValueError('V2 semantic SQL differs from reviewed derivation.')
    hashes={}
    for name in ('input_source.json','input.json','execution_spec.json','execution_profile.json','run.json'):
        immutable_write(folder/(name+'.canonical'),canonical(read(folder/name)));hashes[name]=sha(folder/(name+'.canonical'))
    selection=dict(policy=spec['policy'],solver=spec['solver']['name'],timing=spec.get('production_lead_time_mode','LEGACY_REQUEST_DATE'),
        scenario=scope['source_matrix_index'],initial_state_rule=scope['initial_stock_rule'],source_sha256=sha(folder/'input_source.json'))
    export=dict(status='COMPLETE',schema='companyx.control.v1',selection=selection,core_sha256=run_doc['code_sha256'],
        completion_sha256=sha(folder/'completion.json'),canonical_files=hashes,scope_file_sha256=sha(folder/'scope.json'),
        prefix_proof_sha256=sha(folder/'prefix_proof.json'),branch_state_sha256=sha(folder/'branch_state.json'),
        projection_sha256=sha(folder/'inquiry_projection.json'),archive_manifest_sha256=sha(folder/'inquiry_archive_manifest.json'),
        publication_purpose_sha256=sha(folder/'publication_purpose.json'))
    if 'continuation' in verified:
        export.update(continuation_receipt_sha256=sha(folder/'continuation_receipt.json'),
            continuation_storage_receipt_sha256=sha(folder/'continuation_storage_receipt.json'),
            checkpoint_sha256=verified['continuation']['receipt']['checkpoint']['sha256'],
            effective_executor_hash=verified['continuation']['receipt']['effective_executor_hash'])
    proof=dict(schema='companyx.inquiry.source_proof.v2',database=DATABASE,source_database=SOURCE,
        etl_batch=read(demo/'KetQua/Demo_01/dw_source_proof.json')['etl_batch'],
        frozen_lead_input_hash=hashlib.sha256(canonical(read(demo/'KetQua/Demo_01/input_source.json')).encode('utf-8')).hexdigest(),
        base_snapshot_sha256=scope['base_snapshot_sha256'],reference_baseline_id=scope['reference_baseline_id'],
        bom_source_asof=scope['bom_source_asof'],storage_verification_sha256=sha(folder/'inquiry_storage_verification.json'))
    for name,value in [('simulation_selection.json',selection),('simulation_export.json',export),('dw_source_proof.json',proof)]:
        immutable_write(folder/name,json.dumps(value,ensure_ascii=False,indent=2))
    return project,demo,folder,sql,run_doc


def publish_v2(artifact_folder,*,project_root=None):
    import pyodbc
    project,demo,folder,sql,run_doc=prepare_v2(artifact_folder,project_root=project_root)
    projection=read(folder/'inquiry_projection.json')
    if shutil.disk_usage(project).free<max(4*2**30,4*projection['estimated_sql_bytes']):raise RuntimeError('Insufficient SQL/tempdb/log reserve.')
    from .operation_gate import publish_operation_gate
    with publish_operation_gate(),pyodbc.connect(CONNECTION,autocommit=True,timeout=15) as conn:
        conn.timeout=1800;cursor=conn.cursor();cursor.execute(sql,str(demo),str(folder),SOURCE);receipt=None
        while True:
            if cursor.description:
                columns=[column[0] for column in cursor.description]
                for row in cursor.fetchall():
                    if 'PublicationReceipt' in columns:receipt=json.loads(row[columns.index('PublicationReceipt')])
            if not cursor.nextset():break
        if not receipt or receipt.get('status') not in ('LOADED','ALREADY_LOADED'):raise RuntimeError('No successful V2 publication receipt.')
    from .detail_publisher import publish_detail
    detail_receipt=publish_detail(folder,receipt['PlanningRunKey'],project_root=project)
    scope=read(folder/'scope.json')
    receipt.update(RunCode=run_doc['RunCode'],scope_sha256=scope['scope_sha256'],detail_publication=detail_receipt,
        inquiry_purpose=read(folder/'publication_purpose.json')['purpose'],
        publication_purpose_sha256=sha(folder/'publication_purpose.json'),
        publication_mode='ANALYTICAL_PROJECTION_FULL_RAW_ARCHIVE',projection_sha256=sha(folder/'inquiry_projection.json'),
        archive_sha256=read(folder/'inquiry_archive_manifest.json')['archive_sha256'],
        publisher_sql_sha256=hashlib.sha256(sql.encode('utf-8')).hexdigest(),published_at=datetime.now(timezone.utc).isoformat())
    target=folder/'publication_receipt.json'
    if target.exists():
        target=folder/'publication_attempts'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json');target.parent.mkdir(exist_ok=True)
    immutable_write(target,json.dumps(receipt,ensure_ascii=False,indent=2))
    return receipt

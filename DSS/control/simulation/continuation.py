"""New immutable artifacts with explicit EOD checkpoints and tail-only execution.

The frozen V2 adapter remains responsible for preparation, initialization proof,
reporting, and the standard artifact contract. This additional execution layer is
always identified separately from the frozen runtime SHA.
"""
from __future__ import annotations
from contextlib import contextmanager
from copy import deepcopy
from datetime import date
from pathlib import Path
import hashlib,json,re,shutil,threading
from .adapter import runtime,project_path,RequestError,file_sha256
from . import inquiry_v2 as v2,checkpoint_codec as codec

_LOCK=threading.RLock()
PREFIX_TABLES=('RunEntity','Fact_SimulationDaily','Fact_SimulationEvent','Fact_OptimizationSolve',
               'Fact_StochasticDraw','Bridge_RunEntityRelation','ExternalSupplyDraw')
RECEIPT='continuation_receipt.json'
CHECKPOINT='des_checkpoint.json.gz'
PREFIX='continuation_prefix.json'

def effective_executor_hash(project_root=None):
    runtime(project_root)
    from . import resumable_engine,rolling_plan
    paths=[Path(__file__),Path(codec.__file__),Path(resumable_engine.__file__),Path(v2.__file__),Path(v2.v1.__file__),Path(v2.baseline_inputs.__file__),Path(rolling_plan.__file__)]
    from model_v3.release import release_identity
    return codec.digest({'execution_files':{p.name:file_sha256(p) for p in paths},
                         'optimizer_release':release_identity(project_root)})

def _owned(folder,project):
    folder=Path(folder).resolve();allowed=project/'GPT'
    if folder==allowed or not folder.is_relative_to(allowed):raise RequestError('CHECKPOINT_PATH_INVALID','Checkpoint artifacts must remain in Project/GPT.')
    return folder

def _read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def _reserve(project,additional_bytes=0):
    if shutil.disk_usage(project).free-additional_bytes<12*2**30:
        raise RuntimeError('Continuation needs to retain a 12 GiB disk reserve; new partial artifacts are retained.')

def validate_checkpoint_reference(artifact_folder,expected_family_hash,expected_end,expected_checkpoint_sha256,project_root=None):
    """Cache lookup eligibility only; full prefix/data validation precedes execution."""
    project=project_path(project_root);folder=_owned(artifact_folder,project)
    receipt=_read(folder/RECEIPT);manifest=_read(folder/'run.json');completion=_read(folder/'completion.json')
    if (receipt.get('schema')!='companyx.inquiry.continuation.v1' or receipt.get('status')!='COMPLETE'
        or receipt.get('family_hash')!=expected_family_hash or receipt.get('covered_end')!=expected_end
        or receipt.get('effective_executor_hash')!=effective_executor_hash(project)
        or receipt.get('artifact_run_code')!=manifest['RunCode'] or completion.get('RunCode')!=manifest['RunCode']
        or completion.get('status')!='COMPLETE' or manifest['end']!=expected_end):raise ValueError('Cache checkpoint reference identity differs')
    cp=receipt['checkpoint']
    if cp.get('file')!=CHECKPOINT or cp.get('sha256')!=expected_checkpoint_sha256:raise ValueError('Cache checkpoint identity differs')
    checkpoint=codec.load_checkpoint(folder/CHECKPOINT,expected_checkpoint_sha256)
    from . import resumable_engine
    if (checkpoint.get('schema')!=codec.SCHEMA or checkpoint['through']!=expected_end
        or checkpoint['executor_sha256']!=resumable_engine.executor_identity()
        or checkpoint['payload_sha256']!=codec.digest(checkpoint['payload'])):raise ValueError('Cache checkpoint contents differ')
    for name in ('run.json','completion.json','table_manifest.json','control_execution_receipt.json'):
        if file_sha256(folder/name)!=receipt['bound_files'][name]:raise ValueError('Cache artifact identity changed: '+name)
    return {'status':'VERIFIED_REFERENCE','receipt':receipt,'checkpoint_sha256':expected_checkpoint_sha256,
            'full_prefix_verified':False,'artifact_folder':str(folder),'covered_end':expected_end}

def _open_table(folder,table):
    from publish.inquiry_storage import open_inquiry_artifact_text
    return open_inquiry_artifact_text(folder,'tables/'+table+'.jsonl')

def _target_row(row,table,scope):
    row=dict(row);row.pop('RunCode',None)
    if table=='RunEntity':
        refs={f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in scope['synthetic_orders'] for r in o['lines']}
        if row['EntityCode'] in refs:row['SourceRecordReference']=refs[row['EntityCode']]
    return row

def _semantic_request(prepared):
    request=deepcopy(prepared['request'])
    for key in ('request_id','inquiry_id','analysis_end'):request.pop(key,None)
    # An artifact represents one offer; other offers' contents cannot alter it.
    request['candidates']=[c for c in request['candidates'] if c['candidate_id']==prepared['candidate_id']]
    return request

def _copy_support(parent,target,project):
    """Retain exact prior accepted solver evidence; never modify parent files."""
    copied={}
    for name in ('decisions','solve_audit','solves','daily_budgets'):
        source=parent/name
        if source.exists():
            for src in sorted(source.rglob('*')):
                if not src.is_file():continue
                relative=src.relative_to(parent);dest=target/relative
                _reserve(project,src.stat().st_size)
                dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
                copied[relative.as_posix()]=file_sha256(dest)
    events=parent/'purchase_events';index=events/'index.json'
    if index.is_file():
        (target/'purchase_events').mkdir(parents=True,exist_ok=True)
        shutil.copyfile(index,target/'purchase_events/index.json')
        names=[b['file'] for b in _read(index)['batches']]
        if (parent/'purchase_archive_manifest.json').exists():
            from publish.baseline_purchase_archive import purchase_archive_reader
            with purchase_archive_reader(parent,project_root=project) as zipped:
                for number,name in enumerate(names):
                    if number%1000==0:_reserve(project)
                    if Path(name).name!=name:raise ValueError('Unsafe purchase member name')
                    dest=target/'purchase_events'/name
                    raw=events/name
                    if raw.exists():shutil.copyfile(raw,dest)
                    else:
                        with zipped.open('purchase_events/'+name) as src,dest.open('wb') as out:shutil.copyfileobj(src,out)
        else:
            for number,name in enumerate(names):
                if number%1000==0:_reserve(project)
                if Path(name).name!=name:raise ValueError('Unsafe purchase member name')
                shutil.copyfile(events/name,target/'purchase_events'/name)
    return copied

def _emit_prefix(parent,sink,scope,project):
    proof={'schema':'companyx.continuation.prefix.v1','parent_table_manifest_sha256':file_sha256(parent/'table_manifest.json'),'tables':{}}
    for table in PREFIX_TABLES:
        count=0;h=hashlib.sha256()
        with _open_table(parent,table) as stream:
            for line in stream:
                if count%1000==0:_reserve(project)
                row=_target_row(json.loads(line),table,scope)
                h.update((codec.digest(codec.canonical(row))+'\n').encode())
                sink(table,row);count+=1
        proof['tables'][table]={'rows':count,'target_canonical_sha256':h.hexdigest()}
    return proof

def verify_continuation_artifact(folder,project_root=None,*,verify_core_artifact=True,verify_prefix=True):
    project=project_path(project_root);folder=_owned(folder,project)
    receipt=_read(folder/RECEIPT)
    if receipt.get('schema')!='companyx.inquiry.continuation.v1' or receipt.get('status')!='COMPLETE':raise ValueError('Unsupported/incomplete continuation receipt')
    if receipt['effective_executor_hash']!=effective_executor_hash(project):raise ValueError('Effective continuation executor changed')
    if not re.fullmatch('[0-9a-f]{64}',receipt.get('family_hash','')):raise ValueError('Invalid continuation family identity')
    scope=_read(folder/'scope.json');prepared=v2.build_request(_read(folder/'request.json'),scope['candidate_id'],project)
    manifest=_read(folder/'run.json');completion=_read(folder/'completion.json')
    if receipt['artifact_run_code']!=manifest['RunCode'] or completion['RunCode']!=manifest['RunCode'] or completion['status']!='COMPLETE':raise ValueError('Continuation run/completion identity mismatch')
    for name,expected in receipt['bound_files'].items():
        if Path(name).name!=name or file_sha256(folder/name)!=expected:raise ValueError('Continuation bound file changed: '+name)
    for name,expected in {**receipt.get('copied_solver_evidence',{}),**receipt.get('solver_evidence',{})}.items():
        member=(folder/name).resolve()
        if Path(name).is_absolute() or '..' in Path(name).parts or not member.is_relative_to(folder) or file_sha256(member)!=expected:
            raise ValueError('Copied solver evidence changed: '+name)
    if receipt['covered_end']!=prepared['snapshot']['end'] or receipt['engine_start']!=prepared['snapshot']['start']:raise ValueError('Continuation coverage differs')
    cp=receipt['checkpoint']
    if cp['file']!=CHECKPOINT:raise ValueError('Unexpected checkpoint filename')
    checkpoint=codec.load_checkpoint(folder/cp['file'],cp['sha256'])
    from . import resumable_engine
    _,_,_,inputs,_,run,_=runtime(project);data=inputs.prepare(prepared['snapshot'],prepared['spec'])
    if (checkpoint['schema']!=codec.SCHEMA or checkpoint['executor_sha256']!=resumable_engine.executor_identity()
        or checkpoint['payload_sha256']!=codec.digest(checkpoint['payload'])
        or checkpoint['physical_identity_sha256']!=codec.physical_identity(data,prepared['spec'])
        or checkpoint['known_orders_sha256']!=codec.known_orders_identity(data,data['end'])
        or checkpoint['through']!=str(data['end']) or checkpoint['start']!=str(data['start'])
        or checkpoint['next_day']!=(data['end']-data['start']).days+1
        or checkpoint['next_day']!=receipt['reused_days']+receipt['simulated_days']):
        raise ValueError('Continuation checkpoint coverage/content differs')
    if receipt['frozen_core_sha256']!=run.code_hash():raise ValueError('Frozen core changed')
    if verify_core_artifact:
        if (folder/'inquiry_storage_receipt.json').exists():
            from publish.inquiry_storage import verify_stored_inquiry
            verify_stored_inquiry(folder,project_root=project)
        else:v2.verify_inquiry_artifact(folder,project)
    if receipt['parent'] is not None:
        parent=_owned(receipt['parent']['artifact_folder'],project)
        parent_receipt=_read(parent/RECEIPT)
        if (file_sha256(parent/RECEIPT)!=receipt['parent']['continuation_receipt_sha256']
            or parent_receipt['family_hash']!=receipt['family_hash']
            or parent_receipt['checkpoint']['sha256']!=receipt['parent']['checkpoint_sha256']
            or parent_receipt['covered_end']!=receipt['parent']['covered_end']
            or file_sha256(parent/'table_manifest.json')!=receipt['parent']['table_manifest_sha256']
            or _read(parent/'run.json')['RunCode']!=receipt['parent']['run_code']):raise ValueError('Continuation parent identity differs')
        if verify_prefix:
            proof=_read(folder/PREFIX)
            if proof['parent_table_manifest_sha256']!=receipt['parent']['table_manifest_sha256']:raise ValueError('Prefix source manifest differs')
            for table,item in proof['tables'].items():
                h=hashlib.sha256();n=0
                with _open_table(parent,table) as old,_open_table(folder,table) as new:
                    for line in old:
                        expected=_target_row(json.loads(line),table,scope)
                        actual=json.loads(next(new,'{}'));actual.pop('RunCode',None)
                        if actual!=expected:raise ValueError('Continuation prefix differs: '+table)
                        h.update((codec.digest(codec.canonical(actual))+'\n').encode());n+=1
                if n!=item['rows'] or h.hexdigest()!=item['target_canonical_sha256']:raise ValueError('Continuation prefix proof mismatch')
    elif receipt['reused_days']!=0:raise ValueError('New continuation artifact has reused days')
    return {'status':'VERIFIED','prepared':prepared,'receipt':receipt,'checkpoint':checkpoint}

def execute_checkpointed(prepared,output_folder,parent_artifact=None,project_root=None,*,family_hash=None):
    project,_,_,inputs,legacy,run,_=runtime(project_root)
    from . import resumable_engine
    if not isinstance(family_hash,str) or not re.fullmatch('[0-9a-f]{64}',family_hash):raise ValueError('A SHA256 family_hash is required')
    folder=_owned(output_folder,project)
    if folder.exists() and any(folder.iterdir()):raise ValueError('Checkpoint execution requires an empty dedicated output folder')
    parent=None;cp=None;parent_receipt=None;previous=None
    if parent_artifact is not None:
        parent=_owned(parent_artifact,project)
        if parent==folder:raise ValueError('A completed parent is immutable')
        verified=verify_continuation_artifact(parent,project)
        previous=verified['prepared'];cp=verified['checkpoint'];parent_receipt=verified['receipt']
        if parent_receipt['family_hash']!=family_hash or _semantic_request(previous)!=_semantic_request(prepared):raise ValueError('Cache family/request differs')
        if prepared['snapshot']['end']<=previous['snapshot']['end']:raise ValueError('Continuation needs a later requested end')
        codec.validate(cp,inputs.prepare(prepared['snapshot'],prepared['spec']),prepared['spec'],resumable_engine.executor_identity())
    folder.mkdir(parents=True,exist_ok=True)
    executed=[];captured=[];prefix_proof=None;support={}
    def simulate(data,spec,controller=None,sink=None,progress=None,folder=None):
        nonlocal prefix_proof,support
        folder=Path(folder)
        if cp is not None:
            # Construct core before copying prior audit files (its normal constructor
            # intentionally rejects preexisting completed-run evidence).
            controller.core=controller.core_factory(data,spec,folder,False,controller.sink)
            state=codec.unpack(cp['payload'])
            for key,value in state['controller'].items():setattr(controller.core,key,value)
            controller.day=cp['next_day']
            prefix_proof=_emit_prefix(parent,sink,prepared['scope'],project)
            support=_copy_support(parent,folder,project)
            legacy.save(folder/'branch_state.json',_read(parent/'branch_state.json'))
            legacy.save(folder/PREFIX,prefix_proof)
        def tick(t,row):
            executed.append(t)
            if progress:progress(t,row)
            _reserve(project)
        def capture(value):captured.append(codec.save_checkpoint(folder/CHECKPOINT,value))
        return resumable_engine.simulate(data,spec,controller,sink,tick,folder,checkpoint=cp,checkpoint_sink=capture)
    with _LOCK,v2._PATCH_LOCK:
        original=run.simulate;run.simulate=simulate
        try:execution=v2.execute_prepared(prepared,folder,project)
        finally:run.simulate=original
    if len(captured)!=1:raise ValueError('Missing unique terminal checkpoint')
    expected_start=cp['next_day'] if cp else 0
    expected_days=(date.fromisoformat(prepared['snapshot']['end'])-date.fromisoformat(prepared['snapshot']['start'])).days+1
    if executed!=list(range(expected_start,expected_days)):raise ValueError('Execution did not cover exactly the new days')
    parent_doc=None
    if parent:
        parent_doc={'artifact_folder':str(parent),'run_code':_read(parent/'run.json')['RunCode'],'covered_end':previous['snapshot']['end'],
                    'continuation_receipt_sha256':file_sha256(parent/RECEIPT),'checkpoint_sha256':parent_receipt['checkpoint']['sha256'],
                    'table_manifest_sha256':file_sha256(parent/'table_manifest.json')}
    bound_names=['run.json','completion.json','table_manifest.json','control_execution_receipt.json','scope.json','input.json','execution_spec.json','branch_state.json','prefix_proof.json','optimizer_release.json']
    if parent:bound_names.append(PREFIX)
    checkpoint=codec.load_checkpoint(folder/CHECKPOINT,captured[0]['sha256'])
    receipt={'schema':'companyx.inquiry.continuation.v1','status':'COMPLETE','family_hash':family_hash,
        'artifact_run_code':execution['run_code'],'effective_executor_hash':effective_executor_hash(project),
        'frozen_core_sha256':prepared['runtime_code_sha256'],'frozen_v2_adapter_sha256':prepared['adapter_sha256'],
        'optimizer_release':prepared['scope']['optimizer_release'],
        'engine_start':prepared['snapshot']['start'],'known_at':prepared['request']['known_at'],'covered_end':prepared['snapshot']['end'],
        'mode':'EXTEND' if parent else 'NEW','reused_days':expected_start,'simulated_days':len(executed),
        'simulated_first_day_index':expected_start,'simulated_last_day_index':expected_days-1,'parent':parent_doc,
        'checkpoint':{'file':CHECKPOINT,'sha256':captured[0]['sha256'],'payload_sha256':checkpoint['payload_sha256'],
                      'through':checkpoint['through'],'next_day':checkpoint['next_day'],'executor_sha256':checkpoint['executor_sha256']},
        'prefix_proof_file':PREFIX if parent else None,'copied_solver_evidence':support,
        'solver_evidence':{p.relative_to(folder).as_posix():file_sha256(p) for name in ('decisions','solve_audit','solves','daily_budgets')
                           for p in sorted((folder/name).rglob('*')) if p.is_file()},
        'bound_files':{name:file_sha256(folder/name) for name in bound_names},
        'interpretation':'Prior accepted actions are frozen. Only new physical days execute; prior immutable raw rows are copied with source lineage. End date does not truncate the rolling optimization horizon.'}
    legacy.save(folder/RECEIPT,receipt)
    verify_continuation_artifact(folder,project)
    return {'execution_receipt':execution,'continuation_receipt':receipt}

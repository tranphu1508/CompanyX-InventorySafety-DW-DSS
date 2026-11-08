"""Selected MILP inquiries from published full-history ROP baselines or fresh stock.

V1 adapters and the original DSS are immutable. V2 preserves the selected physical
scenario and explicitly separates baseline-state replay from a new preset state.
"""
from __future__ import annotations
from collections import Counter
from contextlib import contextmanager,ExitStack
from copy import deepcopy
from datetime import date
import hashlib,json,os,sys,threading
from pathlib import Path
sys.dont_write_bytecode=True
os.environ['PYTHONDONTWRITEBYTECODE']='1'
if __package__:
    from .adapter import RequestError,runtime,project_path,file_sha256,_integer
    from . import inquiry as v1
    from . import baseline_inputs
else:
    sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
    from simulation.adapter import RequestError,runtime,project_path,file_sha256,_integer
    from simulation import inquiry as v1,baseline_inputs
from publish.baseline_archive import open_artifact_text
from model_v3 import release as model_release

SCHEMA='companyx.inquiry.request.v2'
MILP_FIRST='2013-07-01'
MODES={'BASELINE_AT_START','FIXED_PRESET'}
PRESETS={'ZERO','REORDER_POINT','SAFETY_STOCK_LEVEL','MIDPOINT_CEIL'}
_PATCH_LOCK=threading.RLock()


def _dependencies():
    from . import rolling_plan
    return {'inquiry.py':file_sha256(v1.__file__),'baseline_inputs.py':file_sha256(baseline_inputs.__file__),
            'rolling_plan.py':file_sha256(rolling_plan.__file__)}


def _select_entry(request,project_root=None):
    project=project_path(project_root)
    from common import demo_folder
    local = demo_folder(project)/'RuntimeData/reference'
    catalog_path=local/'catalog.json' if (local/'catalog.json').is_file() else project/'_local/output/companyx-split-20261107/baselines/catalog.json'
    if not catalog_path.is_file():raise RequestError('BASELINE_NOT_READY','No published baseline catalog is ready.')
    catalog=json.loads(catalog_path.read_text(encoding='utf-8-sig'))
    if catalog.get('schema')!='companyx.baseline.catalog.v1' or not isinstance(catalog.get('baselines'),list):
        raise RequestError('BASELINE_CATALOG_INVALID','Baseline catalog schema is invalid.')
    mode=request.get('initialization_mode')
    if mode not in MODES:raise RequestError('INVALID_INITIALIZATION_MODE','Choose BASELINE_AT_START or FIXED_PRESET.')
    scenario=_integer(request.get('scenario_index'),'scenario_index',1,8)
    run_key=_integer(request.get('base_run_key'),'base_run_key',1)
    available=[b for b in catalog['baselines'] if b.get('status')=='READY' and b.get('scenario_index')==scenario]
    if mode=='BASELINE_AT_START':
        v1._label(request.get('baseline_id'),'baseline_id')
        matches=[b for b in available if b.get('baseline_id')==request['baseline_id']]
        if request.get('initial_stock_rule')!='SAFETY_STOCK_LEVEL':
            raise RequestError('BASELINE_INITIAL_STOCK_LOCKED','Baseline replay retains its original SafetyStock initialization.')
    else:
        if request.get('baseline_id')!='':raise RequestError('FIXED_BASELINE_ID_NOT_EMPTY','FIXED_PRESET requires an empty baseline_id.')
        if request.get('initial_stock_rule') not in PRESETS:raise RequestError('INVALID_INITIAL_STOCK','Unsupported fixed stock preset.')
        matches=available
    if len(matches)!=1:raise RequestError('BASELINE_NOT_READY','Choose one READY baseline matching the selected physical scenario.')
    entry=dict(matches[0])
    if catalog_path.parent == local:
        entry['artifact_folder']=str(local/'runs'/Path(entry['artifact_folder'].replace('\\','/')).name)
    if (entry.get('PlanningRunKey')!=run_key or entry.get('source_matrix_index')!=scenario+16
        or entry.get('initial_stock_rule')!='SAFETY_STOCK_LEVEL'
        or entry.get('start')!=baseline_inputs.START or entry.get('end')!=baseline_inputs.END):
        raise RequestError('BASELINE_CATALOG_MISMATCH','Catalog run/scenario/date/stock identity does not match the request.')
    # Keep only immutable identity fields. Adding later catalog entries or changing
    # a display label must not invalidate a previously prepared branch.
    identity={k:entry[k] for k in ('baseline_id','scenario_index','source_matrix_index','PlanningRunKey','start','end','artifact_folder','initial_stock_rule')}
    return identity


def _load_reference(entry,project_root=None):
    project,_,_,_,legacy,run,valuation=runtime(project_root)
    folder=Path(entry['artifact_folder']).resolve()
    allowed=project/'_local/output/companyx-split-20261107/baselines/runs'
    from common import demo_folder
    local_allowed=(demo_folder(project)/'RuntimeData/reference/runs').resolve()
    if not ((folder.is_relative_to(allowed) and folder!=allowed) or (folder.is_relative_to(local_allowed) and folder!=local_allowed)):
        raise RequestError('BASELINE_PATH_INVALID','A baseline must be an owned run under Project/GPT baselines/runs.')
    snapshot=legacy.read(folder/'input.json');spec=legacy.read(folder/'execution_spec.json')
    manifest=legacy.read(folder/'run.json');completion=legacy.read(folder/'completion.json')
    provenance=legacy.read(folder/'input_provenance.json')
    prepared=legacy.read(folder/'prepared_baseline.json')
    publication=legacy.read(folder/'baseline_publication_receipt.json')
    execution=legacy.read(folder/'baseline_execution_receipt.json')
    if (spec.get('policy')!='ROP' or completion.get('status')!='COMPLETE'
        or completion.get('RunCode')!=manifest['RunCode']
        or publication.get('status') not in ('LOADED','ALREADY_LOADED')
        or publication.get('database')!='CompanyX_MOLAP_Source_20261105'
        or publication.get('RunStatus')!='SUCCEEDED' or publication.get('verification_status')!='PASSED'
        or publication.get('RunCode')!=manifest['RunCode'] or publication.get('PlanningRunKey')!=entry['PlanningRunKey']):
        raise RequestError('BASELINE_NOT_VERIFIED','Baseline execution/publication is not verified complete.')
    if (snapshot['start']!=entry['start'] or snapshot['end']!=entry['end']
        or provenance.get('scenario_index')!=entry['source_matrix_index']
        or legacy.digest(snapshot)!=manifest['input_sha256'] or legacy.digest(spec)!=manifest['execution_spec_sha256']
        or run.code_hash()!=manifest['code_sha256'] or execution.get('core_sha256')!=run.code_hash()
        or execution.get('RunCode')!=manifest['RunCode']
        or execution.get('source_matrix_index')!=entry['source_matrix_index']
        or prepared.get('snapshot')!=snapshot or prepared.get('spec')!=spec or prepared.get('provenance')!=provenance
        or legacy.digest(prepared.get('scope'))!=execution.get('scope_sha256')
        or provenance.get('execution_spec_sha256')!=legacy.digest(spec)
        or file_sha256(folder/'prepared_baseline.json')!=execution.get('prepared_file_sha256')
        or file_sha256(folder/'table_manifest.json')!=completion['table_manifest_sha256']
        or file_sha256(folder/'metrics.json')!=completion['metrics_sha256']):
        raise RequestError('BASELINE_IDENTITY_CHANGED','Published baseline files no longer match their execution identities.')
    baseline_inputs.verify_snapshot(snapshot,provenance,project)
    valuation.validate(snapshot)
    return dict(folder=folder,snapshot=snapshot,spec=spec,manifest=manifest,provenance=provenance,entry=entry)


def normalize_request(request,base):
    v2fields={'initialization_mode','baseline_id','initial_stock_rule','scenario_index'}
    allowed={'schema','request_id','inquiry_id','base_run_key','known_at','analysis_end','solver_name','solver_seconds','threads','penalties','candidates'}|v2fields
    if not isinstance(request,dict) or set(request)-allowed:raise RequestError('UNKNOWN_FIELDS','Invalid V2 inquiry fields.')
    if request.get('schema')!=SCHEMA:raise RequestError('INVALID_SCHEMA','Expected companyx.inquiry.request.v2.')
    if v1._day(request.get('known_at'),'known_at')<date.fromisoformat(MILP_FIRST):
        raise RequestError('FORECAST_CUTOFF_UNSAFE','MILP inquiries before 2013-07-01 are disabled; the frozen forecast is not cutoff-safe there.')
    # Reuse the frozen V1 validator for line quantities, equal candidate totals,
    # tranche dates and solver parameters, then restore V2 identity fields.
    common={k:deepcopy(v) for k,v in request.items() if k not in v2fields}
    common.update(schema=v1.SCHEMA,base_run_key=1)
    normalized=v1.normalize_manifest(common,base)
    normalized.update(schema=SCHEMA,base_run_key=request['base_run_key'],**{k:request[k] for k in v2fields})
    return normalized


def _stock_quantity(product,rule,finite):
    if not finite or rule=='ZERO':return 0
    if rule=='REORDER_POINT':return product['ReorderPointQty']
    if rule=='SAFETY_STOCK_LEVEL':return product['SafetyStockQty']
    if rule=='MIDPOINT_CEIL':return (product['ReorderPointQty']+product['SafetyStockQty']+1)//2
    raise RequestError('INVALID_INITIAL_STOCK','Unsupported fixed stock preset.')


def _prepare(request,candidate_id,reference,project_root=None):
    project,_,config,inputs,legacy,run,valuation=runtime(project_root)
    base=reference['snapshot'];base_spec=reference['spec'];entry=reference['entry'];folder=reference['folder']
    request=normalize_request(request,base)
    if candidate_id is None:
        if len(request['candidates'])!=1:raise RequestError('CANDIDATE_REQUIRED','Choose one candidate_id.')
        candidate_id=request['candidates'][0]['candidate_id']
    candidate=next((c for c in request['candidates'] if c['candidate_id']==candidate_id),None)
    if candidate is None:raise RequestError('CANDIDATE_UNKNOWN','Candidate does not exist in the inquiry request.')
    mode=request['initialization_mode'];snapshot=deepcopy(base)
    snapshot['start']=base['start'] if mode=='BASELINE_AT_START' else request['known_at']
    snapshot['end']=request['analysis_end']
    snapshot['sales_order_lines']=[r for r in snapshot['sales_order_lines'] if snapshot['start']<=r['OrderDate']<=snapshot['end']]
    if mode=='FIXED_PRESET':
        for p in snapshot['products']:
            p['InitialQty']=_stock_quantity(p,request['initial_stock_rule'],p['IsManufactured'] or base_spec['supply']['mode']!='INSTANT_UNLIMITED')
            if p['IsManufactured']:p['ManufacturingParameters']['initial']=p['InitialQty']
    synthetic=[];order_id=max(2000000000,max(r['SalesOrderID'] for r in base['sales_order_lines'])+1)
    line_id=max(2000000000,max(r['SalesOrderDetailID'] for r in base['sales_order_lines'])+1)
    for number,tranche in enumerate(candidate['tranches'],1):
        lines=[]
        for line in tranche['lines']:
            row=dict(SalesOrderID=order_id,SalesOrderDetailID=line_id,ProductID=line['product_id'],OrderQty=line['quantity'],OrderDate=request['known_at'],DueDate=tranche['due_date'])
            snapshot['sales_order_lines'].append(row);lines.append(deepcopy(row));line_id+=1
        synthetic.append(dict(inquiry_id=request['inquiry_id'],candidate_id=candidate_id,tranche_number=number,sales_order_id=order_id,
            known_at=request['known_at'],due_date=tranche['due_date'],lines=lines,
            source_reference=f"Inquiry:{request['inquiry_id']}/candidate:{candidate_id}/tranche:{number}"))
        order_id+=1
    if line_id>2147483647 or order_id>2147483647:raise RequestError('SYNTHETIC_ID_EXHAUSTED','Synthetic IDs exceed SQL INT range.')
    spec=deepcopy(base_spec);spec.update(policy='QUETSCHLICH_ADAPT',**request['penalties'])
    spec['solver'].update(name=request['solver_name'],time_limit_seconds=request['solver_seconds'],threads=request['threads'])
    spec=config.resolve(spec)
    snapshot,optimizer_release,resale_forecast=model_release.prepare_snapshot(snapshot,request['known_at'],project)
    original_scope=base['metadata']['baseline_scope']
    scope=dict(schema='companyx.inquiry.scope.v2',request_id=request['request_id'],request=request,
        inquiry_id=request['inquiry_id'],candidate_id=candidate_id,candidate_kind=candidate['kind'],
        initialization_mode=mode,initial_stock_rule=request['initial_stock_rule'],initial_state_mode=mode,
        baseline_id=request['baseline_id'],reference_baseline_id=entry['baseline_id'],scenario_index=request['scenario_index'],
        source_matrix_index=entry['source_matrix_index'],base_run_key=entry['PlanningRunKey'],
        baseline_catalog_identity=entry,baseline_catalog_identity_sha256=legacy.digest(entry),
        base_run_folder=str(folder),base_run_code=reference['manifest']['RunCode'],
        base_snapshot_sha256=file_sha256(folder/'input.json'),base_snapshot_content_sha256=legacy.digest(base),
        base_execution_spec_sha256=legacy.digest(base_spec),base_input_provenance_sha256=file_sha256(folder/'input_provenance.json'),
        base_baseline_scope_sha256=legacy.digest(original_scope),base_valuation_sha256=valuation.validate(base),
        scoped_valuation_sha256=valuation.validate(snapshot),original_base_start=base['start'],original_base_end=base['end'],
        bom_source_asof=original_scope['original_base_start'],source_scope_id=original_scope['source_scope_id'],
        start=snapshot['start'],end=snapshot['end'],known_at=request['known_at'],analysis_end=request['analysis_end'],
        policy_mode='HYBRID_ROP_THEN_MILP' if mode=='BASELINE_AT_START' else 'MILP_FROM_FRESH_PRESET',
        warmup_policy='ROP' if mode=='BASELINE_AT_START' else None,inquiry_policy='QUETSCHLICH_ADAPT',
        control_comparison='BASELINE candidate is a no-inquiry MILP control from the same selected initialization; it is not the historical ROP policy.',
        product_scope_mode='FULL_ORIGINAL_NETWORK',evaluation_scope='HYPOTHETICAL_INQUIRY_BRANCH',
        requested_product_ids=sorted({r['ProductID'] for o in synthetic for r in o['lines']}),
        effective_product_ids=sorted(p['ProductID'] for p in snapshot['products']),
        selected_sales_order_line_ids=sorted(r['SalesOrderDetailID'] for r in snapshot['sales_order_lines']),
        selected_sales_order_ids=sorted({r['SalesOrderID'] for r in snapshot['sales_order_lines']}),
        observed_sales_order_line_ids=sorted(r['SalesOrderDetailID'] for r in snapshot['sales_order_lines'] if r['SalesOrderDetailID']<2000000000),
        synthetic_sales_order_ids=[o['sales_order_id'] for o in synthetic],
        synthetic_sales_order_line_ids=[r['SalesOrderDetailID'] for o in synthetic for r in o['lines']],synthetic_orders=synthetic,
        original_order_coverage_complete=True,excluded_pre_start_order_lines=sum(r['OrderDate']<snapshot['start'] for r in base['sales_order_lines']),
        adapter_sha256=file_sha256(__file__),adapter_dependencies_sha256=_dependencies(),
        optimizer_release=optimizer_release,resale_forecast=resale_forecast,
        state_interpretation=('Exact deterministic ROP replay from the published full-history SafetyStock baseline to X, retaining inventory, WIP, jobs, purchases and existing order commitments.' if mode=='BASELINE_AT_START' else
            'A new experiment starts at X with the selected fixed on-hand rule and zero opening WIP, jobs, purchases and customer backlog. Only orders created on or after X are admitted.'),
        parameter_interpretation=original_scope['parameter_interpretation'],
        contract_interpretation='Each tranche is a distinct all-or-nothing child order known at X; staged offers change the customer contract, not the core shipment mechanism.',
        attribution_interpretation='JOB/EXEC production and BOM usage are auditable; no exclusive customer-order pegging exists.',
        forecast_interpretation='Manufactured direct_mu is preserved. Direct resale forecast is bound to the versioned pre-2013-07-01 calibration artifact; known_at must not precede its cutoff. Lost-sales forecast expires per day in corrected MILP v3.')
    scope['scope_sha256']=legacy.digest(scope)
    snapshot['metadata']['inquiry_scope']=scope
    data=inputs.prepare(snapshot,spec)
    from companyx_unified_v2.orders import OrderBook
    OrderBook(data['lines'],data['P'],data['external_ids'],data['start'],data['end'],'7B' if spec['allow_backorders'] else '7C',data['raw'])
    return dict(prepared_schema='companyx.inquiry.prepared.v2',request=request,candidate_id=candidate_id,snapshot=snapshot,spec=spec,scope=scope,
        snapshot_sha256=legacy.digest(snapshot),execution_spec_sha256=legacy.digest(spec),runtime_code_sha256=run.code_hash(),
        adapter_sha256=file_sha256(__file__),adapter_dependencies_sha256=_dependencies())


def build_request(request,candidate_id=None,project_root=None):
    if not isinstance(request,dict):raise RequestError('INVALID_REQUEST','Inquiry request must be an object.')
    entry=_select_entry(request,project_root)
    return _prepare(request,candidate_id,_load_reference(entry,project_root),project_root)


build_inquiry_candidate=build_request


class PrefixVerifier:
    tables=v1.PrefixVerifier.tables
    def __init__(self,folder,known_at,legacy,project,mode):
        self.folder,self.known_at,self.legacy,self.mode=Path(folder),known_at,legacy,mode
        self.stack=ExitStack();self.counts=Counter();self.hashes={k:hashlib.sha256() for k in self.tables};self.finished=False
        try:
            self.streams={k:self.stack.enter_context(open_artifact_text(folder,'tables/'+k+'.jsonl',project_root=project)) for k in self.tables} if mode=='BASELINE_AT_START' else {}
        except BaseException:self.stack.close();raise
    def row(self,table,row):
        if table not in self.tables or row[self.tables[table]]>=self.known_at:return
        if self.mode!='BASELINE_AT_START':raise RequestError('FIXED_PRESET_WARMUP_LEAK','Fresh preset output unexpectedly contains pre-X rows.')
        expected=json.loads(next(self.streams[table],'{}'));expected.pop('RunCode',None)
        actual=dict(row);actual.pop('RunCode',None)
        if actual!=expected:raise RequestError('SAVED_PREFIX_MISMATCH',f'Warmup {table} differs from the selected published baseline.',{'row_index':self.counts[table],'actual':actual,'expected':expected})
        self.counts[table]+=1;self.hashes[table].update((self.legacy.canonical(actual)+'\n').encode('utf-8'))
    def finish(self):
        if not self.finished:
            for table,stream in self.streams.items():
                row=json.loads(next(stream,'{}'))
                if row and row[self.tables[table]]<self.known_at:raise RequestError('SAVED_PREFIX_INCOMPLETE',f'Missing baseline {table} prefix rows.')
            self.finished=True
        return dict(status='PASSED',initialization_mode=self.mode,cutoff_exclusive=self.known_at,
            rule='EXACT_SAVED_ROP_PREFIX' if self.mode=='BASELINE_AT_START' else 'FRESH_PRESET_NO_WARMUP_REQUIRED',
            baseline_prefix_compared=self.mode=='BASELINE_AT_START',tables={k:dict(rows=self.counts[k],canonical_sha256=h.hexdigest()) for k,h in self.hashes.items()},excluded_fields=['RunCode'])
    def close(self):self.stack.close()


@contextmanager
def hybrid_runtime(run,prepared,folder,legacy,project):
    with _PATCH_LOCK:
        original_controller,original_simulate=run.Controller,run.simulate
        if prepared['scope'].get('optimizer_release')!=model_release.release_identity(project):
            raise RequestError('OPTIMIZER_RELEASE_CHANGED','Prepared corrected optimizer release is no longer current.')
        corrected_controller=model_release.controller_factory()
        scope=prepared['scope'];prefix=PrefixVerifier(scope['base_run_folder'],scope['known_at'],legacy,project,scope['initialization_mode'])
        switch_day=(date.fromisoformat(scope['known_at'])-date.fromisoformat(scope['start'])).days
        try:
            def factory(data,spec,folder,resume=False,sink=None):
                return v1.GatedController(data,spec,folder,resume,sink,switch_day=switch_day,core_factory=corrected_controller,scope=scope,prefix=prefix,legacy=legacy)
            def simulate(data,spec,controller=None,sink=None,progress=None,folder=None):
                lines={f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in scope['synthetic_orders'] for r in o['lines']}
                orders={o['sales_order_id']:o['source_reference'] for o in scope['synthetic_orders']}
                def emit(table,row):
                    prefix.row(table,row)
                    if table=='RunEntity' and row['EntityCode'] in lines:row=dict(row,SourceRecordReference=lines[row['EntityCode']])
                    elif table=='Fact_SimulationOrder' and row['SourceSalesOrderID'] in orders:row=dict(row,SourceRecordReference=orders[row['SourceSalesOrderID']])
                    sink(table,row)
                controller.sink=emit
                def tick(day,row):
                    if progress:progress(day,row)
                    controller.day=day+1
                result=original_simulate(data,spec,controller,emit,tick,folder)
                legacy.save(Path(folder)/'prefix_proof.json',prefix.finish())
                state=legacy.read(Path(folder)/'branch_state.json')
                state.update(schema='companyx.inquiry.branch_state.v2',initialization_mode=scope['initialization_mode'],
                    initial_stock_rule=scope['initial_stock_rule'],reference_baseline_id=scope['reference_baseline_id'],
                    exact_saved_state_method=scope['state_interpretation'])
                legacy.save(Path(folder)/'branch_state.json',state)
                return result
            run.Controller,run.simulate=factory,simulate
            yield
            if prepared['scope']['optimizer_release']!=model_release.release_identity(project):
                raise RequestError('OPTIMIZER_RELEASE_CHANGED','Corrected optimizer release changed during execution.')
        finally:
            run.Controller,run.simulate=original_controller,original_simulate
            prefix.close()


def execute_prepared(prepared,output_folder,project_root=None):
    project,demo,_,_,legacy,run,_=runtime(project_root)
    if prepared.get('prepared_schema')!='companyx.inquiry.prepared.v2':raise RequestError('INVALID_PREPARED_SCHEMA','Unsupported V2 prepared schema.')
    if prepared!=build_request(prepared['request'],prepared['candidate_id'],project):raise RequestError('PREPARED_IDENTITY_CHANGED','Prepared V2 inquiry identity changed.')
    folder=Path(output_folder).resolve()
    if not folder.is_relative_to(project/'_local') or folder==project/'_local':raise RequestError('OUTPUT_OUTSIDE_GPT','Inquiry output must be in a dedicated Project/GPT folder.')
    if (folder/'run.json').exists() or (folder/'completion.json').exists():raise RequestError('RUN_ALREADY_EXISTS','Existing runs are immutable; choose a fresh output folder.')
    folder.mkdir(parents=True,exist_ok=True)
    for name,obj in [('request',prepared['request']),('scope',prepared['scope']),('input_source',prepared['snapshot'])]:legacy.save(folder/f'{name}.json',obj)
    legacy.save(folder/'optimizer_release.json',prepared['scope']['optimizer_release'])
    legacy.verify_release()
    from native_path_worker import gurobi_native_paths
    old_env={k:os.environ.get(k) for k in ('PYTHONPATH','TMP','TEMP','GRB_LICENSE_FILE')}
    temp=folder/'tmp';temp.mkdir(exist_ok=True)
    os.environ['TMP']=os.environ['TEMP']=str(temp)
    os.environ['PYTHONPATH']=str(demo/'DSS/runtime/src')+(os.pathsep+old_env['PYTHONPATH'] if old_env['PYTHONPATH'] else '')
    if not os.environ.get('GRB_LICENSE_FILE') and Path(r'E:\Gurobi\gurobi.lic').is_file():os.environ['GRB_LICENSE_FILE']=r'E:\Gurobi\gurobi.lic'
    try:
        enabled=prepared['spec']['solver']['name']=='GUROBI' and os.name=='nt' and not str(folder).isascii()
        with hybrid_runtime(run,prepared,folder,legacy,project),gurobi_native_paths(folder,enabled=enabled):
            metrics=run.execute(prepared['snapshot'],prepared['spec'],folder,name=f"INQUIRY V2 {prepared['request']['inquiry_id']} / {prepared['candidate_id']} / {prepared['scope']['policy_mode']}")
        if run.code_hash()!=prepared['runtime_code_sha256']:raise RequestError('FROZEN_RUNTIME_CHANGED','Frozen runtime changed during execution.')
        plan=v1.export_decision_plan(folder,prepared,project)
        from .rolling_plan import export_rolling_plan
        rolling_plan=export_rolling_plan(folder,prepared,project)
        summary=v1.summarize_candidate(folder,prepared)
        summary.update(schema='companyx.inquiry.summary.v2',initialization_mode=prepared['scope']['initialization_mode'],
            initial_stock_rule=prepared['scope']['initial_stock_rule'],control_comparison=prepared['scope']['control_comparison'])
        legacy.save(folder/'inquiry_summary.json',summary)
        receipt=dict(schema='companyx.inquiry.execution.v2',status='COMPLETE',output_folder=str(folder),request_id=prepared['request']['request_id'],
            run_code=legacy.read(folder/'run.json')['RunCode'],scope_sha256=prepared['scope']['scope_sha256'],adapter_sha256=prepared['adapter_sha256'],
            adapter_dependencies_sha256=prepared['adapter_dependencies_sha256'],core_sha256=prepared['runtime_code_sha256'],policy_mode=prepared['scope']['policy_mode'],
            optimizer_release=prepared['scope']['optimizer_release'],
            initialization_mode=prepared['scope']['initialization_mode'],prefix_proof_sha256=file_sha256(folder/'prefix_proof.json'),
            branch_state_sha256=file_sha256(folder/'branch_state.json'),inquiry_summary_sha256=file_sha256(folder/'inquiry_summary.json'),decision_plan=plan,rolling_plan=rolling_plan,metrics=metrics)
        legacy.save(folder/'control_execution_receipt.json',receipt)
        return receipt
    finally:
        for key,value in old_env.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value


def verify_inquiry_artifact(folder,project_root=None):
    project,_,_,_,legacy,_,_=runtime(project_root);folder=Path(folder).resolve()
    if not folder.is_relative_to(project/'_local'):raise RequestError('OUTPUT_OUTSIDE_GPT','Inquiry artifacts must be under Project/GPT.')
    scope=legacy.read(folder/'scope.json')
    if 'optimizer_release' not in scope:
        from . import inquiry_v2_legacy_20261105 as historical
        return historical.verify_inquiry_artifact(folder,project)
    prepared=build_request(legacy.read(folder/'request.json'),scope['candidate_id'],project)
    for name,expected in [('input',prepared['snapshot']),('input_source',prepared['snapshot']),('execution_spec',prepared['spec']),('scope',prepared['scope'])]:
        if legacy.read(folder/f'{name}.json')!=expected:raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'{name}.json differs from canonical V2 preparation.')
    receipt=legacy.read(folder/'control_execution_receipt.json');completion=legacy.read(folder/'completion.json');manifest=legacy.read(folder/'run.json')
    if (receipt.get('schema')!='companyx.inquiry.execution.v2' or receipt.get('status')!='COMPLETE' or completion.get('status')!='COMPLETE'
        or receipt.get('scope_sha256')!=scope['scope_sha256'] or receipt.get('adapter_sha256')!=prepared['adapter_sha256']
        or receipt.get('adapter_dependencies_sha256')!=prepared['adapter_dependencies_sha256'] or receipt.get('core_sha256')!=prepared['runtime_code_sha256']
        or receipt.get('run_code')!=manifest['RunCode'] or completion.get('RunCode')!=manifest['RunCode']
        or manifest['input_sha256']!=prepared['snapshot_sha256'] or manifest['execution_spec_sha256']!=prepared['execution_spec_sha256']
        or receipt.get('optimizer_release')!=scope['optimizer_release']
        or legacy.read(folder/'optimizer_release.json')!=scope['optimizer_release']):
        raise RequestError('INQUIRY_ARTIFACT_CHANGED','V2 run identity mismatch.')
    if file_sha256(folder/'table_manifest.json')!=completion['table_manifest_sha256'] or file_sha256(folder/'metrics.json')!=completion['metrics_sha256']:
        raise RequestError('INQUIRY_ARTIFACT_CHANGED','Completion artifact hashes differ.')
    tables=legacy.read(folder/'table_manifest.json')
    for filename,item in tables['tables'].items():
        if Path(filename).name!=filename or file_sha256(folder/'tables'/filename)!=item['sha256']:raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'Table identity changed: {filename}')
    for name in ('prefix_proof','branch_state','inquiry_summary'):
        if file_sha256(folder/f'{name}.json')!=receipt[name+'_sha256']:raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'{name} identity changed.')
    proof=legacy.read(folder/'prefix_proof.json');state=legacy.read(folder/'branch_state.json')
    if (proof['status']!='PASSED' or state['common_state_sha256']!=legacy.digest(state['common_state'])
        or state.get('initialization_mode')!=scope['initialization_mode'] or state['prefix_proof_sha256']!=legacy.digest(proof)):
        raise RequestError('INQUIRY_STATE_INVALID','V2 initialization/state proof is invalid.')
    plan=receipt['decision_plan']
    if Path(plan['path']).name!=plan['path'] or file_sha256(folder/plan['path'])!=plan['sha256']:raise RequestError('INQUIRY_ARTIFACT_CHANGED','Decision plan changed.')
    from .rolling_plan import verify_rolling_plan
    if 'rolling_plan' not in receipt:raise RequestError('ROLLING_PLAN_MISSING','New inquiry requires accepted plans for every decision day.')
    verify_rolling_plan(folder,receipt['rolling_plan'],project)
    checker=PrefixVerifier(scope['base_run_folder'],scope['known_at'],legacy,project,scope['initialization_mode'])
    try:
        for table,field in checker.tables.items():
            with (folder/'tables'/f'{table}.jsonl').open(encoding='utf-8-sig') as stream:
                for text in stream:
                    row=json.loads(text)
                    if row[field]>=scope['known_at']:break
                    checker.row(table,row)
        if checker.finish()!=proof:raise RequestError('INQUIRY_PREFIX_INVALID','V2 prefix proof differs from actual output.')
    finally:checker.close()
    lines={f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in scope['synthetic_orders'] for r in o['lines']}
    orders={o['sales_order_id']:o['source_reference'] for o in scope['synthetic_orders']}
    for table,key,expected in [('RunEntity','EntityCode',lines),('Fact_SimulationOrder','SourceSalesOrderID',orders)]:
        found=set()
        with (folder/'tables'/f'{table}.jsonl').open(encoding='utf-8-sig') as stream:
            for text in stream:
                row=json.loads(text)
                if row[key] in expected:
                    if row['SourceRecordReference']!=expected[row[key]]:raise RequestError('SYNTHETIC_PROVENANCE_INVALID','Hypothetical source reference changed.')
                    found.add(row[key])
        if found!=set(expected):raise RequestError('SYNTHETIC_PROVENANCE_INVALID','Hypothetical entities missing.')
    return dict(status='VERIFIED',prepared=prepared,receipt=receipt,common_state_sha256=state['common_state_sha256'])

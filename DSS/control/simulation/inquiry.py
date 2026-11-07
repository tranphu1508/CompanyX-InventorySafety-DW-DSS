"""Prospective inquiries, replaying an immutable ROP run to its decision date.

The process-local gate reuses the original physical executor. Original source,
snapshots, results, and libraries are never written. The gate's SHA is an explicit
part of every branch identity; these runs are labelled HYBRID_ROP_THEN_MILP.
"""
from __future__ import annotations

from collections import Counter
from contextlib import contextmanager
from copy import deepcopy
from datetime import date, timedelta
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import threading

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
from .adapter import RequestError, runtime, project_path, file_sha256, _positive, _integer, PENALTIES

SCHEMA = 'companyx.inquiry.request.v1'
_PATCH_LOCK = threading.RLock()


def _day(value, name):
    try:
        result = date.fromisoformat(value)
        if str(result) != value:
            raise ValueError()
        return result
    except (ValueError, TypeError):
        raise RequestError('INVALID_DATES', f'{name} must use YYYY-MM-DD.') from None


def _label(value, name):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', value):
        raise RequestError('INVALID_ID', f'{name} must contain 1-80 letters, digits, underscores or hyphens.')
    return value


def _base(project_root=None):
    project, demo, config, inputs, legacy, run, valuation = runtime(project_root)
    folder = demo / 'KetQua/Demo_01'
    snapshot = legacy.read(folder / 'input.json')
    spec = legacy.read(folder / 'execution_spec.json')
    manifest = legacy.read(folder / 'run.json')
    if spec['policy'] != 'ROP' or not (folder / 'completion.json').is_file():
        raise RequestError('BASE_RUN_UNSUPPORTED', 'The inquiry prototype requires the completed Demo_01 ROP run.')
    if legacy.digest(snapshot) != manifest['input_sha256'] or legacy.digest(spec) != manifest['execution_spec_sha256']:
        raise RequestError('BASE_IDENTITY_CHANGED', 'The saved run input or specification no longer matches its manifest.')
    if run.code_hash() != manifest['code_sha256']:
        raise RequestError('BASE_CODE_CHANGED', 'Current immutable runtime differs from the saved baseline runtime.')
    valuation.validate(snapshot)
    return project, folder, snapshot, spec, manifest


def normalize_request(request, base):
    allowed = {'schema','request_id','inquiry_id','known_at','analysis_end','solver_name','solver_seconds',
               'threads','penalties','candidate_id','candidate_kind','tranches'}
    if not isinstance(request, dict) or set(request) - allowed:
        raise RequestError('UNKNOWN_FIELDS', 'Invalid inquiry request fields.',
                           {'fields': sorted(set(request) - allowed) if isinstance(request, dict) else []})
    if request.get('schema', SCHEMA) != SCHEMA:
        raise RequestError('INVALID_SCHEMA', 'Unsupported inquiry request schema.')
    result = deepcopy(request)
    result['schema'] = SCHEMA
    for key in ('request_id','inquiry_id','candidate_id'):
        result[key] = _label(request.get(key), key)
    start = _day(request.get('known_at'), 'known_at')
    end = _day(request.get('analysis_end'), 'analysis_end')
    if not _day(base['start'], 'base.start') <= start <= end <= _day(base['end'], 'base.end'):
        raise RequestError('DATE_RANGE_OUTSIDE_SOURCE', 'Inquiry dates must lie inside the saved run window.')
    kind = request.get('candidate_kind')
    if kind not in ('BASELINE','FULL','STAGED'):
        raise RequestError('INVALID_CANDIDATE', 'candidate_kind must be BASELINE, FULL or STAGED.')
    tranches = request.get('tranches', [])
    if not isinstance(tranches, list) or (kind == 'BASELINE' and tranches) or (kind == 'FULL' and len(tranches) != 1) or (kind == 'STAGED' and len(tranches) < 2):
        raise RequestError('INVALID_TRANCHES', 'BASELINE has zero tranches, FULL has one, STAGED has at least two.')
    if len(tranches) > 100:
        raise RequestError('INVALID_TRANCHES', 'At most 100 tranches are supported.')
    products = {p['ProductID']: p for p in base['products']}
    normalized = []
    for n, tranche in enumerate(tranches, 1):
        if not isinstance(tranche, dict) or set(tranche) != {'due_date','lines'}:
            raise RequestError('INVALID_TRANCHES', 'Each tranche requires exactly due_date and lines.')
        due = _day(tranche['due_date'], 'due_date')
        if not start <= due <= end:
            raise RequestError('INVALID_TRANCHES', 'Every tranche due date must be inside the inquiry analysis interval.')
        if not isinstance(tranche['lines'], list) or not tranche['lines']:
            raise RequestError('INVALID_LINES', 'Each delivery tranche requires at least one product line.')
        lines = []
        seen = set()
        for line in tranche['lines']:
            if not isinstance(line, dict) or set(line) != {'product_id','quantity'}:
                raise RequestError('INVALID_LINES', 'Each inquiry line requires exactly product_id and quantity.')
            pid = _integer(line['product_id'], 'product_id', 1)
            quantity = _integer(line['quantity'], 'quantity', 1, 1000000)
            if pid not in products or pid in seen:
                raise RequestError('INVALID_PRODUCTS', 'Inquiry ProductIDs must exist and be unique within each tranche.')
            # Existing atomic optimization links sales only for independent roots.
            if not products[pid]['IsManufactured'] or not products[pid]['ManufacturingParameters']['root']:
                raise RequestError('UNSUPPORTED_INQUIRY_PRODUCT', 'This prototype accepts manufactured independent-sales products only.', {'product_id':pid})
            seen.add(pid)
            lines.append(dict(product_id=pid, quantity=quantity))
        normalized.append(dict(due_date=str(due), lines=sorted(lines, key=lambda x:x['product_id'])))
    if [t['due_date'] for t in normalized] != sorted(t['due_date'] for t in normalized):
        raise RequestError('INVALID_TRANCHES', 'Tranches must be ordered by delivery date.')
    result['tranches'] = normalized
    result['solver_name'] = request.get('solver_name', 'GUROBI')
    if result['solver_name'] not in ('GUROBI','CPLEX'):
        raise RequestError('INVALID_SOLVER', 'Choose GUROBI or CPLEX.')
    result['solver_seconds'] = _positive(request.get('solver_seconds', 120), 'solver_seconds', 86400)
    result['threads'] = _integer(request.get('threads', min(2, os.cpu_count() or 1)), 'threads', 1, os.cpu_count() or 1)
    penalties = request.get('penalties', {})
    if not isinstance(penalties, dict) or set(penalties) - set(PENALTIES):
        raise RequestError('INVALID_PENALTIES', 'Unsupported penalty keys.')
    result['penalties'] = {k:_positive(v,k) for k,v in penalties.items()}
    return result


def normalize_manifest(request, base):
    allowed = {'schema','request_id','inquiry_id','base_run_key','known_at','analysis_end','solver_name',
               'solver_seconds','threads','penalties','candidates'}
    if not isinstance(request, dict) or set(request)-allowed:
        raise RequestError('UNKNOWN_FIELDS','Invalid inquiry manifest fields.')
    if type(request.get('base_run_key')) is not int or request['base_run_key'] != 1:
        raise RequestError('BASE_RUN_UNSUPPORTED','This prototype branches from saved ROP RunKey 1 only.')
    candidates=request.get('candidates')
    if not isinstance(candidates,list) or not candidates or len(candidates)>20:
        raise RequestError('INVALID_CANDIDATES','Provide 1-20 candidate deals, including the no-inquiry BASELINE.')
    normalized=[]
    ids=set()
    total=None
    normalized_common=None
    for candidate in candidates:
        if not isinstance(candidate,dict) or set(candidate)!={'candidate_id','kind','tranches'}:
            raise RequestError('INVALID_CANDIDATES','Each candidate requires candidate_id, kind, and tranches.')
        leaf={k:v for k,v in request.items() if k not in ('base_run_key','candidates')}
        leaf.update(candidate_id=candidate['candidate_id'],candidate_kind=candidate['kind'],tranches=candidate['tranches'])
        leaf=normalize_request(leaf,base)
        cid=leaf['candidate_id']
        if cid in ids:
            raise RequestError('INVALID_CANDIDATES','Candidate identifiers must be unique.')
        ids.add(cid)
        normalized.append(dict(candidate_id=cid,kind=leaf['candidate_kind'],tranches=leaf['tranches']))
        normalized_common={k:v for k,v in leaf.items() if k not in ('candidate_id','candidate_kind','tranches')}
        if leaf['candidate_kind']!='BASELINE':
            quantities=Counter()
            for tranche in leaf['tranches']:
                for line in tranche['lines']:quantities[line['product_id']]+=line['quantity']
            if total is not None and total!=quantities:
                raise RequestError('CANDIDATE_QUANTITIES_DIFFER','Every deal must cover exactly the same inquiry product quantities.')
            total=quantities
    if sum(c['kind']=='BASELINE' for c in normalized)!=1:
        raise RequestError('BASELINE_REQUIRED','Exactly one BASELINE without an inquiry is required.')
    return dict(normalized_common,base_run_key=1,candidates=normalized)


def build_inquiry_candidate(request, candidate_id=None, project_root=None):
    project, folder, original, base_spec, manifest = _base(project_root)
    _, _, config, inputs, legacy, run, valuation = runtime(project)
    manifest_request=normalize_manifest(request,original)
    if candidate_id is None:
        if len(manifest_request['candidates'])!=1:
            raise RequestError('CANDIDATE_REQUIRED','Choose one candidate_id from the inquiry manifest.')
        candidate_id=manifest_request['candidates'][0]['candidate_id']
    candidate=next((c for c in manifest_request['candidates'] if c['candidate_id']==candidate_id),None)
    if candidate is None:
        raise RequestError('CANDIDATE_UNKNOWN','Candidate does not exist in the inquiry manifest.')
    request={k:v for k,v in manifest_request.items() if k not in ('base_run_key','candidates')}
    request.update(candidate_id=candidate_id,candidate_kind=candidate['kind'],tranches=candidate['tranches'])
    snapshot = deepcopy(original)
    snapshot['end'] = request['analysis_end']
    snapshot['sales_order_lines'] = [r for r in snapshot['sales_order_lines'] if r['OrderDate'] <= snapshot['end']]
    synthetic = []
    max_order = max(r['SalesOrderID'] for r in original['sales_order_lines'])
    max_line = max(r['SalesOrderDetailID'] for r in original['sales_order_lines'])
    order_id = max(2000000000, max_order + 1)
    line_id = max(2000000000, max_line + 1)
    for number, tranche in enumerate(request['tranches'], 1):
        lines = []
        for line in tranche['lines']:
            row = dict(SalesOrderID=order_id, SalesOrderDetailID=line_id, ProductID=line['product_id'],
                       OrderQty=line['quantity'], OrderDate=request['known_at'], DueDate=tranche['due_date'])
            snapshot['sales_order_lines'].append(row)
            lines.append(deepcopy(row))
            line_id += 1
        synthetic.append(dict(inquiry_id=request['inquiry_id'], candidate_id=request['candidate_id'],
                              tranche_number=number, sales_order_id=order_id, known_at=request['known_at'],
                              due_date=tranche['due_date'], lines=lines,
                              source_reference=f"Inquiry:{request['inquiry_id']}/candidate:{request['candidate_id']}/tranche:{number}"))
        order_id += 1
    if line_id > 2147483647 or order_id > 2147483647:
        raise RequestError('SYNTHETIC_ID_EXHAUSTED', 'Synthetic identifiers exceed SQL INT range.')
    spec = deepcopy(base_spec)
    spec.update(policy='QUETSCHLICH_ADAPT', **request['penalties'])
    spec['solver'].update(name=request['solver_name'], time_limit_seconds=request['solver_seconds'], threads=request['threads'])
    spec = config.resolve(spec)
    scope = dict(schema='companyx.inquiry.scope.v1', request_id=request['request_id'], request=manifest_request,
        inquiry_id=request['inquiry_id'], candidate_id=request['candidate_id'], candidate_kind=request['candidate_kind'],
        known_at=request['known_at'], analysis_end=request['analysis_end'], start=snapshot['start'], end=snapshot['end'],
        original_base_start=original['start'], original_base_end=original['end'], base_run_code=manifest['RunCode'],
        base_run_folder=str(folder), base_snapshot_sha256=file_sha256(folder/'input.json'),
        base_snapshot_content_sha256=legacy.digest(original), base_execution_spec_sha256=legacy.digest(base_spec),
        base_valuation_sha256=original['metadata']['valuation']['sha256'],
        scoped_valuation_sha256=original['metadata']['valuation']['sha256'],
        initial_state_mode='REPLAY_SAVED_RUN_TO_X', policy_mode='HYBRID_ROP_THEN_MILP',
        warmup_policy='ROP', inquiry_policy='QUETSCHLICH_ADAPT',
        product_scope_mode='FULL_ORIGINAL_NETWORK', evaluation_scope='HYPOTHETICAL_INQUIRY_BRANCH',
        requested_product_ids=sorted({l['ProductID'] for o in synthetic for l in o['lines']}),
        effective_product_ids=sorted(p['ProductID'] for p in snapshot['products']),
        selected_sales_order_line_ids=sorted(r['SalesOrderDetailID'] for r in snapshot['sales_order_lines']),
        selected_sales_order_ids=sorted({r['SalesOrderID'] for r in snapshot['sales_order_lines']}),
        observed_sales_order_line_ids=sorted(r['SalesOrderDetailID'] for r in snapshot['sales_order_lines'] if r['SalesOrderDetailID']<2000000000),
        synthetic_sales_order_ids=[o['sales_order_id'] for o in synthetic],
        synthetic_sales_order_line_ids=[l['SalesOrderDetailID'] for o in synthetic for l in o['lines']],
        synthetic_orders=synthetic, original_order_coverage_complete=True,
        adapter_sha256=file_sha256(__file__),
        state_interpretation='Exact deterministic replay of the saved ROP history to the beginning of X after receipts and new order revelation; no opening balances are fabricated.',
        contract_interpretation='Every tranche is a distinct all-or-nothing child order known at X. STAGED changes the customer delivery contract; it is not native partial dispatch of one SalesOrder.',
        attribution_interpretation='Production and BOM events identify jobs and executions. No stock-lot to customer-order pegging exists; incremental differences are counterfactual comparisons, not exclusive allocations.',
        forecast_interpretation='All frozen direct_mu values are preserved; hypothetical inquiry demand is explicit additional known demand from X.')
    scope['scope_sha256'] = legacy.digest(scope)
    snapshot['metadata']['inquiry_scope'] = scope
    valuation.validate(snapshot)
    data = inputs.prepare(snapshot, spec)
    from companyx_unified_v2.orders import OrderBook
    OrderBook(data['lines'],data['P'],data['external_ids'],data['start'],data['end'],
              '7B' if spec['allow_backorders'] else '7C',data['raw'])
    return dict(prepared_schema='companyx.inquiry.prepared.v1', request=manifest_request, candidate_id=candidate_id,
                snapshot=snapshot, spec=spec, scope=scope,
                snapshot_sha256=legacy.digest(snapshot), execution_spec_sha256=legacy.digest(spec),
                runtime_code_sha256=run.code_hash(), adapter_sha256=file_sha256(__file__))


build_request = build_inquiry_candidate


class PrefixVerifier:
    """Compare every emitted physical daily/event row with immutable saved output."""
    tables = {'Fact_SimulationDaily':'Date', 'Fact_SimulationEvent':'EventAt'}

    def __init__(self, base_folder, known_at, legacy):
        self.known_at, self.legacy = known_at, legacy
        self.streams = {k:open(Path(base_folder)/'tables'/f'{k}.jsonl',encoding='utf-8-sig') for k in self.tables}
        self.counts = Counter()
        self.hashes = {k:hashlib.sha256() for k in self.tables}
        self.finished = False

    def row(self, table, row):
        if table not in self.tables or row[self.tables[table]] >= self.known_at:
            return
        expected = json.loads(next(self.streams[table], '{}'))
        expected.pop('RunCode', None)
        actual = dict(row)
        actual.pop('RunCode', None)
        if actual != expected:
            raise RequestError('SAVED_PREFIX_MISMATCH', f'Warmup {table} differs from saved run.',
                               {'row_index':self.counts[table], 'actual':actual, 'expected':expected})
        self.counts[table] += 1
        self.hashes[table].update((self.legacy.canonical(actual)+'\n').encode('utf-8'))

    def finish(self):
        if not self.finished:
            for table, stream in self.streams.items():
                next_row = json.loads(next(stream, '{}'))
                if next_row and next_row[self.tables[table]] < self.known_at:
                    raise RequestError('SAVED_PREFIX_INCOMPLETE', f'Warmup is missing saved {table} rows.')
            self.finished = True
        return dict(status='PASSED', cutoff_exclusive=self.known_at,
                    tables={k:dict(rows=self.counts[k],canonical_sha256=h.hexdigest()) for k,h in self.hashes.items()},
                    excluded_fields=['RunCode'])

    def close(self):
        for stream in self.streams.values():
            stream.close()


def _state_value(value):
    """Canonical JSON-safe lossless state representation, including tuple keys/arrays."""
    if isinstance(value, dict):
        return [[_state_value(k),_state_value(v)] for k,v in sorted(value.items(),key=lambda x:repr(x[0]))]
    if isinstance(value, (list,tuple)):
        return [_state_value(x) for x in value]
    if isinstance(value, (set,frozenset)):
        return sorted((_state_value(x) for x in value),key=repr)
    if isinstance(value, date):
        return str(value)
    if hasattr(value,'tolist'):
        return _state_value(value.tolist())
    return value


class GatedController:
    def __init__(self, data, spec, folder, resume, sink, *, switch_day, core_factory, scope, prefix, legacy):
        if resume:
            raise RequestError('INQUIRY_RESUME_UNSUPPORTED', 'Create a fresh branch; hybrid replay resume is not supported.')
        self.data,self.spec,self.folder,self.sink = data,spec,Path(folder),sink
        self.day,self.switch_day = 0,switch_day
        self.core_factory,self.scope,self.prefix,self.legacy = core_factory,scope,prefix,legacy
        self.core = None

    def __bool__(self):
        return self.day >= self.switch_day

    @property
    def current_solve_sequence(self):
        return getattr(self.core,'current_solve_sequence',None) if self.core else None

    @property
    def logs(self):
        return self.core.logs if self.core else []

    @property
    def audit(self):
        return self.core.audit if self.core else []

    def decide(self, day, inv, pipe, book, queue, orders, supply):
        if day != self.day or day < self.switch_day:
            raise AssertionError('Hybrid gate day differs from physical executor day.')
        if self.core is None:
            proof = self.prefix.finish()
            self.legacy.save(self.folder/'prefix_proof.json', proof)
            synthetic = set(self.scope['synthetic_sales_order_ids'])
            existing_orders = [o for o in orders if o['SalesOrderID'] not in synthetic]
            # Manufactured book is derived from original active order objects, not
            # by subtracting aggregate demand (which would lose order identities).
            state = dict(day=day, inventory=inv,pipeline=pipe,queue=queue,orders=existing_orders,
                         supply={k:getattr(supply,k) for k in ('schedule','counts','ordered','arrived','good','reject','pipeline','public',
                                 'num_orders','num_receipts','replacement_lots','replacement_units','delay_counts','batch_number','receipt_number')})
            common = _state_value(state)
            self.legacy.save(self.folder/'branch_state.json', dict(schema='companyx.inquiry.branch_state.v1',
                known_at=self.scope['known_at'], stage='AFTER_RECEIPTS_AND_REVEAL_BEFORE_DECISION',
                common_state=common, common_state_sha256=self.legacy.digest(common),
                synthetic_orders=[o for o in orders if o['SalesOrderID'] in synthetic],
                prefix_proof_sha256=self.legacy.digest(proof),
                exact_saved_state_method='Reconstruct from identical full physical-event and end-of-day ledgers before X, with identical saved inputs and seeds.'))
            self.core = self.core_factory(self.data,self.spec,self.folder,False,self.sink)
        action = self.core.decide(day,inv,pipe,book,queue,orders,supply)
        return action


@contextmanager
def hybrid_runtime(run, prepared, folder, legacy):
    """Patch only this Python process, under a lock; always restore module references."""
    with _PATCH_LOCK:
        original_controller,original_simulate = run.Controller,run.simulate
        scope = prepared['scope']
        prefix = PrefixVerifier(scope['base_run_folder'],scope['known_at'],legacy)
        switch_day = (date.fromisoformat(scope['known_at'])-date.fromisoformat(scope['start'])).days
        try:
            def factory(data,spec,folder,resume=False,sink=None):
                return GatedController(data,spec,folder,resume,sink,switch_day=switch_day,
                    core_factory=original_controller,scope=scope,prefix=prefix,legacy=legacy)
            def simulate(data,spec,controller=None,sink=None,progress=None,folder=None):
                synthetic_lines = {f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in scope['synthetic_orders'] for r in o['lines']}
                synthetic_orders = {o['sales_order_id']:o['source_reference'] for o in scope['synthetic_orders']}
                def emit(table,row):
                    prefix.row(table,row)
                    if table == 'RunEntity' and row['EntityCode'] in synthetic_lines:
                        row=dict(row,SourceRecordReference=synthetic_lines[row['EntityCode']])
                    elif table == 'Fact_SimulationOrder' and row['SourceSalesOrderID'] in synthetic_orders:
                        row=dict(row,SourceRecordReference=synthetic_orders[row['SourceSalesOrderID']])
                    sink(table,row)
                controller.sink = emit
                def tick(day,row):
                    if progress:
                        progress(day,row)
                    controller.day = day+1
                result = original_simulate(data,spec,controller,emit,tick,folder)
                legacy.save(Path(folder)/'prefix_proof.json', prefix.finish())
                return result
            run.Controller,run.simulate = factory,simulate
            yield
        finally:
            run.Controller,run.simulate = original_controller,original_simulate
            prefix.close()


def execute_prepared(prepared, output_folder, project_root=None):
    project,demo,config,inputs,legacy,run,valuation = runtime(project_root)
    if prepared.get('prepared_schema') != 'companyx.inquiry.prepared.v1':
        raise RequestError('INVALID_PREPARED_SCHEMA', 'Unsupported inquiry prepared schema.')
    if prepared != build_inquiry_candidate(prepared['request'],prepared['candidate_id'],project):
        raise RequestError('PREPARED_IDENTITY_CHANGED', 'Prepared inquiry identity changed; regenerate explicitly.')
    folder = Path(output_folder).resolve()
    if not folder.is_relative_to(project/'GPT') or folder == project/'GPT':
        raise RequestError('OUTPUT_OUTSIDE_GPT', 'Inquiry artifacts must be under Project/GPT.')
    if (folder/'run.json').exists() or (folder/'completion.json').exists():
        raise RequestError('RUN_ALREADY_EXISTS', 'Existing runs are immutable; choose a fresh output directory.')
    folder.mkdir(parents=True,exist_ok=True)
    for name,obj in [('request',prepared['request']),('scope',prepared['scope']),('input_source',prepared['snapshot'])]:
        legacy.save(folder/f'{name}.json',obj)
    legacy.verify_release()
    from native_path_worker import gurobi_native_paths
    old_env={k:os.environ.get(k) for k in ('PYTHONPATH','TMP','TEMP','GRB_LICENSE_FILE')}
    temp=folder/'tmp'
    temp.mkdir(exist_ok=True)
    os.environ['TMP']=os.environ['TEMP']=str(temp)
    os.environ['PYTHONPATH']=str(demo/'DSS/runtime/src')+(os.pathsep+old_env['PYTHONPATH'] if old_env['PYTHONPATH'] else '')
    if not os.environ.get('GRB_LICENSE_FILE') and Path(r'E:\Gurobi\gurobi.lic').is_file():
        os.environ['GRB_LICENSE_FILE']=r'E:\Gurobi\gurobi.lic'
    try:
        enabled=prepared['spec']['solver']['name']=='GUROBI' and os.name=='nt' and not str(folder).isascii()
        with hybrid_runtime(run,prepared,folder,legacy), gurobi_native_paths(folder,enabled=enabled):
            metrics=run.execute(prepared['snapshot'],prepared['spec'],folder,
                name=f"INQUIRY {prepared['scope']['inquiry_id']} / {prepared['scope']['candidate_id']} / HYBRID_ROP_THEN_MILP")
        if run.code_hash()!=prepared['runtime_code_sha256']:
            raise RequestError('FROZEN_RUNTIME_CHANGED','Frozen runtime changed during execution.')
        plan_receipt=export_decision_plan(folder,prepared,project)
        from .rolling_plan import export_rolling_plan
        rolling_plan=export_rolling_plan(folder,prepared,project,allow_legacy_model=True)
        summary=summarize_candidate(folder,prepared)
        legacy.save(folder/'inquiry_summary.json',summary)
        receipt=dict(schema='companyx.inquiry.execution.v1',status='COMPLETE',output_folder=str(folder),
                     request_id=prepared['request']['request_id'],run_code=legacy.read(folder/'run.json')['RunCode'],
                     scope_sha256=prepared['scope']['scope_sha256'],adapter_sha256=prepared['adapter_sha256'],
                     core_sha256=prepared['runtime_code_sha256'],policy_mode='HYBRID_ROP_THEN_MILP',
                     prefix_proof_sha256=file_sha256(folder/'prefix_proof.json'),
                     branch_state_sha256=file_sha256(folder/'branch_state.json'),
                     inquiry_summary_sha256=file_sha256(folder/'inquiry_summary.json'),
                     decision_plan=plan_receipt,rolling_plan=rolling_plan,metrics=metrics)
        legacy.save(folder/'control_execution_receipt.json',receipt)
        return receipt
    finally:
        for key,value in old_env.items():
            if value is None:os.environ.pop(key,None)
            else:os.environ[key]=value


def export_decision_plan(folder,prepared,project_root=None):
    """Export the accepted solution at X, including tentative future decisions.

    request.pkl.gz is the model written by this runtime in this newly created
    job, never a user-supplied pickle. The prepared artifact and solution identity
    are checked before decoding. Later periods are plans, not realized events.
    """
    import pickle
    import numpy as np
    _,_,_,inputs,legacy,_,_=runtime(project_root)
    folder=Path(folder)
    day=(date.fromisoformat(prepared['scope']['known_at'])-date.fromisoformat(prepared['snapshot']['start'])).days
    decision=legacy.read(folder/'decisions'/f'{day:04d}.json')
    solution=(folder/decision['solution_reference']).resolve()
    if not solution.is_relative_to(folder.resolve()) or file_sha256(solution)!=decision['solution_sha256']:
        raise RequestError('PLAN_SOLUTION_CHANGED','The accepted planning solution identity changed.')
    model_file=solution.parent/'request.pkl.gz'
    with gzip.open(model_file,'rb') as stream:model=pickle.load(stream)['model']
    values=np.load(solution,allow_pickle=False)
    if len(values)!=len(model['keys']):raise RequestError('PLAN_SOLUTION_CHANGED','Planning variable count differs.')
    data=inputs.prepare(prepared['snapshot'],prepared['spec'])
    known=date.fromisoformat(prepared['scope']['known_at'])
    names={'q':'PRODUCTION_REQUEST','a':'PRODUCTION_START','buy':'PURCHASE_ORDER',
           'order_ship':'WHOLE_ORDER_SHIPMENT','order_loss':'WHOLE_ORDER_LOSS','order_unserved':'WHOLE_ORDER_UNSERVED',
           'I':'PROJECTED_ON_HAND','raw_I':'PROJECTED_ON_HAND','Ba':'PROJECTED_ACTUAL_BACKLOG'}
    output=folder/'inquiry_decision_plan.jsonl'
    count=0
    with output.open('w',encoding='utf-8',newline='\n') as stream:
        def emit(row):
            nonlocal count
            stream.write(legacy.canonical(row)+'\n');count+=1
        for key,value in zip(model['keys'],values):
            kind=key[0]
            if kind not in names or abs(float(value))<1e-9:continue
            _,identifier,period,*rest=key
            row=dict(DecisionAt=str(known),PlanAt=str(known+timedelta(days=period)),PeriodOffset=period,
                     ActionCode=names[kind],Quantity=float(value),IsImplementedFirstPeriod=period==0,
                     IsTentativeFuture=period>0,ProductID=identifier if not kind.startswith('order_') else None,
                     SalesOrderID=identifier if kind.startswith('order_') else None,
                     QueueAge=rest[0] if kind=='a' else None,
                     SolveSequence=decision['solver']['SolveSequence'])
            emit(row)
            if kind=='a':
                for child,amount,unit in data['bom'].children[identifier]:
                    emit(dict(row,ActionCode='PLANNED_BOM_ISSUE',ParentProductID=identifier,ProductID=child,
                              Quantity=float(value)*amount,StockUnit=unit))
    receipt=dict(path=output.name,sha256=file_sha256(output),rows=count,decision_at=str(known),
                 model_sha256=file_sha256(model_file),solution_sha256=decision['solution_sha256'],
                 interpretation='Accepted MILP plan at inquiry date. Only period 0 is executed; later days are tentative and reoptimized daily. BOM requirements are linked to production products, not customer-order pegging.')
    legacy.save(folder/'inquiry_decision_plan_manifest.json',receipt)
    return receipt


def summarize_candidate(folder,prepared):
    folder=Path(folder)
    scope=prepared['scope']
    synthetic={r['SalesOrderDetailID']:(o,r) for o in scope['synthetic_orders'] for r in o['lines']}
    delivered=Counter();on_time=Counter();late=Counter();lost=Counter();late_unit_days=Counter()
    deliveries=[]
    with (folder/'tables/Fact_SimulationEvent.jsonl').open(encoding='utf-8-sig') as stream:
        for text in stream:
            row=json.loads(text)
            code=row['EventCode']
            if code not in ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE') or not row['EntityCode'].startswith('SO_LINE:'):continue
            identifier=int(row['EntityCode'].split(':',1)[1])
            if identifier not in synthetic:continue
            order,line=synthetic[identifier];qty=row['Quantity']
            if code=='LOST_SALE':lost[identifier]+=qty
            else:
                delivered[identifier]+=qty
                (on_time if code=='SHIP_ON_TIME' else late)[identifier]+=qty
                late_unit_days[identifier]+=qty*max(0,(date.fromisoformat(row['EventAt'])-date.fromisoformat(line['DueDate'])).days)
                deliveries.append(dict(tranche_number=order['tranche_number'],product_id=line['ProductID'],quantity=qty,
                                       delivered_at=row['EventAt'],due_at=line['DueDate'],event_code=code))
    lines=[]
    for identifier,(order,line) in synthetic.items():
        remaining=line['OrderQty']-delivered[identifier]-lost[identifier]
        late_unit_days[identifier]+=remaining*max(0,(date.fromisoformat(scope['end'])-date.fromisoformat(line['DueDate'])).days+1)
        lines.append(dict(tranche_number=order['tranche_number'],sales_order_id=order['sales_order_id'],sales_order_line_id=identifier,
            product_id=line['ProductID'],quantity=line['OrderQty'],due_at=line['DueDate'],delivered_qty=delivered[identifier],
            on_time_qty=on_time[identifier],late_qty=late[identifier],lost_qty=lost[identifier],remaining_qty=remaining,
            late_unit_days=late_unit_days[identifier]))
    end=scope['analysis_end'];known=scope['known_at']
    existing={}
    with (folder/'tables/Fact_SimulationOrder.jsonl').open(encoding='utf-8-sig') as stream:
        for text in stream:
            row=json.loads(text)
            if row['SourceSalesOrderID'] in scope['synthetic_sales_order_ids']:continue
            # Keep all original order outcomes for exact baseline/candidate comparison,
            # including old commitments which were already overdue at X.
            existing[str(row['SourceSalesOrderID'])]={k:row.get(k) for k in ('OrderStatus','KnownAt','DueAt','CompletedAt','CancelledAt')}
    return dict(schema='companyx.inquiry.summary.v1',inquiry_id=scope['inquiry_id'],candidate_id=scope['candidate_id'],
                candidate_kind=scope['candidate_kind'],known_at=known,analysis_end=end,lines=lines,deliveries=deliveries,
                total_inquiry_qty=sum(x['quantity'] for x in lines),on_time_qty=sum(on_time.values()),
                delivered_qty=sum(delivered.values()),lost_qty=sum(lost.values()),
                remaining_qty=sum(x['remaining_qty'] for x in lines),late_unit_days=sum(late_unit_days.values()),
                all_tranches_delivered_on_time=all(x['on_time_qty']==x['quantity'] for x in lines) if lines else None,
                existing_order_outcomes=existing,
                production_attribution='See Fact_SimulationEvent for realized JOB/EXEC/BOM usage, and inquiry_decision_plan.jsonl for the plan at X. No customer-order pegging is claimed.')


def verify_inquiry_artifact(folder, project_root=None):
    """Read-only verification for the publication stage; no SQL writes."""
    project,_,_,_,legacy,run,_=runtime(project_root)
    folder=Path(folder).resolve()
    if not folder.is_relative_to(project/'GPT'):
        raise RequestError('OUTPUT_OUTSIDE_GPT','Inquiry artifacts must be under Project/GPT.')
    scope=legacy.read(folder/'scope.json')
    prepared=build_inquiry_candidate(legacy.read(folder/'request.json'),scope['candidate_id'],project)
    for name,expected in [('input',prepared['snapshot']),('input_source',prepared['snapshot']),('execution_spec',prepared['spec']),('scope',prepared['scope'])]:
        if legacy.read(folder/f'{name}.json')!=expected:
            raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'{name}.json differs from its approved preparation.')
    receipt=legacy.read(folder/'control_execution_receipt.json')
    completion=legacy.read(folder/'completion.json')
    run_manifest=legacy.read(folder/'run.json')
    if (receipt.get('scope_sha256')!=prepared['scope']['scope_sha256'] or receipt.get('adapter_sha256')!=prepared['adapter_sha256']
        or receipt.get('core_sha256')!=prepared['runtime_code_sha256'] or receipt.get('run_code')!=run_manifest['RunCode']
        or completion.get('RunCode')!=run_manifest['RunCode'] or run_manifest['input_sha256']!=prepared['snapshot_sha256']
        or run_manifest['execution_spec_sha256']!=prepared['execution_spec_sha256']):
        raise RequestError('INQUIRY_ARTIFACT_CHANGED','Inquiry run identity does not match prepared artifacts.')
    if receipt['status']!='COMPLETE' or completion['status']!='COMPLETE':
        raise RequestError('INQUIRY_NOT_COMPLETE','Incomplete inquiry cannot be published.')
    if file_sha256(folder/'table_manifest.json')!=completion['table_manifest_sha256'] or file_sha256(folder/'metrics.json')!=completion['metrics_sha256']:
        raise RequestError('INQUIRY_ARTIFACT_CHANGED','Completion artifact hashes do not match.')
    manifest=legacy.read(folder/'table_manifest.json')
    for filename,item in manifest['tables'].items():
        if Path(filename).name!=filename or file_sha256(folder/'tables'/filename)!=item['sha256']:
            raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'Table identity changed: {filename}')
    for name in ('prefix_proof','branch_state','inquiry_summary'):
        if file_sha256(folder/f'{name}.json')!=receipt[name+'_sha256']:
            raise RequestError('INQUIRY_ARTIFACT_CHANGED',f'{name} identity changed.')
    proof=legacy.read(folder/'prefix_proof.json')
    state=legacy.read(folder/'branch_state.json')
    if proof['status']!='PASSED' or state['common_state_sha256']!=legacy.digest(state['common_state']):
        raise RequestError('INQUIRY_STATE_INVALID','State continuation proof is invalid.')
    plan=receipt['decision_plan']
    if Path(plan['path']).name!=plan['path'] or file_sha256(folder/plan['path'])!=plan['sha256']:
        raise RequestError('INQUIRY_ARTIFACT_CHANGED','Decision plan identity changed.')
    if 'rolling_plan' in receipt:
        from .rolling_plan import verify_rolling_plan
        verify_rolling_plan(folder,receipt['rolling_plan'],project,allow_legacy_model=True)
    synthetic_lines={f"SO_LINE:{r['SalesOrderDetailID']}":o['source_reference'] for o in prepared['scope']['synthetic_orders'] for r in o['lines']}
    synthetic_orders={o['sales_order_id']:o['source_reference'] for o in prepared['scope']['synthetic_orders']}
    for table,key,expected in [('RunEntity','EntityCode',synthetic_lines),('Fact_SimulationOrder','SourceSalesOrderID',synthetic_orders)]:
        found=set()
        with (folder/'tables'/f'{table}.jsonl').open(encoding='utf-8-sig') as stream:
            for line in stream:
                row=json.loads(line)
                if row[key] in expected:
                    if row['SourceRecordReference']!=expected[row[key]]:
                        raise RequestError('SYNTHETIC_PROVENANCE_INVALID','Hypothetical source reference was replaced.')
                    found.add(row[key])
        if found!=set(expected):raise RequestError('SYNTHETIC_PROVENANCE_INVALID','Hypothetical entities are missing.')
    # Independently recheck the prefix tables, not only their proof labels.
    checker=PrefixVerifier(prepared['scope']['base_run_folder'],prepared['scope']['known_at'],legacy)
    try:
        for table,field in checker.tables.items():
            with (folder/'tables'/f'{table}.jsonl').open(encoding='utf-8-sig') as stream:
                for line in stream:
                    row=json.loads(line)
                    if row[field]>=prepared['scope']['known_at']:break
                    checker.row(table,row)
        if checker.finish()!=proof:
            raise RequestError('INQUIRY_PREFIX_INVALID','Saved prefix proof does not match replayed output.')
    finally:checker.close()
    return dict(status='VERIFIED',prepared=prepared,receipt=receipt,common_state_sha256=state['common_state_sha256'])

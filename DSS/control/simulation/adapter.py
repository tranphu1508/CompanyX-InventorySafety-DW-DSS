"""Scoped experiment inputs for the immutable CompanyX MILP/DES runtime.

No SQL writes. No edits, cache files or outputs in the frozen demo. Input dates
describe a new experiment, not reconstruction of historical operational state.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from copy import deepcopy
from datetime import date
import hashlib
import json
import math
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
SCHEMA = 'companyx.control.request.v1'
PRODUCT_MODES = {'SELECTED_LINES', 'WHOLE_ORDERS'}
PENALTIES = ('lost_unit_penalty', 'late_unit_day_penalty', 'terminal_unserved_unit_penalty')


class RequestError(ValueError):
    def __init__(self, code: str, message: str, details=None):
        super().__init__(message)
        self.code, self.details = code, details or {}

    def as_dict(self):
        return {'code': self.code, 'message': str(self), 'details': self.details}


def project_path(project_root=None):
    from common import demo_folder
    if project_root is not None:
        result = Path(project_root).resolve()
    else:
        result = Path(__file__).resolve().parents[3]
    if not demo_folder(result).is_dir():
        raise RequestError('PROJECT_NOT_FOUND', 'The frozen CompanyX demo was not found.')
    return result


def runtime(project_root=None):
    from common import demo_folder
    project = project_path(project_root)
    demo = demo_folder(project)
    library = demo / 'DSS/runtime/src'
    for path in (library, demo / 'DSS'):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))
    from companyx_unified_v2 import config, inputs, legacy, run, valuation
    for module in (config, inputs, legacy, run, valuation):
        if not Path(module.__file__).resolve().is_relative_to(library):
            raise RequestError('RUNTIME_COLLISION', 'A different CompanyX runtime is already imported.')
    return project, demo, config, inputs, legacy, run, valuation


def file_sha256(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def _integer(value, name, low=0, high=2147483647):
    if type(value) is not int or not low <= value <= high:
        raise RequestError('INVALID_PARAMETER', f'{name} must be an integer from {low} to {high}.')
    return value


def _positive(value, name, maximum=None):
    if type(value) not in (int, float) or not math.isfinite(value) or value <= 0 or (maximum is not None and value > maximum):
        raise RequestError('INVALID_PARAMETER', f'{name} must be finite and positive' + (f', at most {maximum}.' if maximum else '.'))
    return value


def normalize_request(request, base, matrix):
    if not isinstance(request, dict):
        raise RequestError('INVALID_REQUEST', 'Request must be a JSON object.')
    allowed = {'schema', 'request_id', 'start_date', 'end_date', 'product_ids', 'scenario_index',
               'policy', 'solver_name', 'product_scope', 'initialization', 'penalties',
               'solver_seconds', 'threads', 'replication', 'production_lead_time_mode'}
    if set(request) - allowed:
        raise RequestError('UNKNOWN_FIELDS', 'Unrecognized request fields.', {'fields': sorted(set(request) - allowed)})
    if request.get('schema', SCHEMA) != SCHEMA:
        raise RequestError('INVALID_SCHEMA', 'Unsupported request schema.')
    try:
        start, end = (date.fromisoformat(request[k]) for k in ('start_date', 'end_date'))
    except (ValueError, KeyError, TypeError):
        raise RequestError('INVALID_DATES', 'start_date and end_date must use YYYY-MM-DD.') from None
    if start > end or start < date.fromisoformat(base['start']) or end > date.fromisoformat(base['end']):
        raise RequestError('DATE_RANGE_OUTSIDE_SOURCE', 'Choose an interval inside the available source window.',
                           {'available_start': base['start'], 'available_end': base['end']})
    ids = request.get('product_ids')
    if not isinstance(ids, list) or not ids or any(type(p) is not int or p <= 0 for p in ids):
        raise RequestError('INVALID_PRODUCTS', 'product_ids must be a nonempty list of positive ProductID integers.')
    ids = sorted(set(ids))
    known = {p['ProductID'] for p in base['products']}
    if set(ids) - known:
        raise RequestError('UNKNOWN_PRODUCTS', 'Some products are outside the frozen simulation source.', {'product_ids': sorted(set(ids) - known)})
    scope = request.get('product_scope')
    if scope not in PRODUCT_MODES:
        raise RequestError('PRODUCT_SCOPE_REQUIRED', 'Select SELECTED_LINES or WHOLE_ORDERS explicitly.')
    initialization = request.get('initialization')
    if initialization != 'NEW_EXPERIMENT':
        raise RequestError('INITIAL_STATE_REQUIRED', 'Only explicit NEW_EXPERIMENT is implemented: scenario stock, zero opening WIP/PO/customer obligations.')
    scenario_index = _integer(request.get('scenario_index'), 'scenario_index', 1, len(matrix['scenarios']))
    policy = request.get('policy', 'ROP')
    solver = request.get('solver_name', 'GUROBI')
    if policy not in ('ROP', 'QUETSCHLICH_ADAPT') or solver not in ('GUROBI', 'CPLEX'):
        raise RequestError('INVALID_POLICY_SOLVER', 'Choose ROP or QUETSCHLICH_ADAPT, and GUROBI or CPLEX.')
    penalties = request.get('penalties', {})
    if not isinstance(penalties, dict) or set(penalties) - set(PENALTIES):
        raise RequestError('INVALID_PENALTIES', 'Only the three supported MILP penalty coefficients can be changed.')
    penalties = {name: _positive(value, name) for name, value in penalties.items()}
    normalized = dict(schema=SCHEMA, start_date=start.isoformat(), end_date=end.isoformat(),
                      product_ids=ids, scenario_index=scenario_index, policy=policy,
                      solver_name=solver, product_scope=scope, initialization=initialization,
                      penalties=penalties, replication=_integer(request.get('replication', 0), 'replication'))
    if 'solver_seconds' in request:
        normalized['solver_seconds'] = _positive(request['solver_seconds'], 'solver_seconds', 86400)
    if 'threads' in request:
        normalized['threads'] = _integer(request['threads'], 'threads', 1, os.cpu_count() or 1)
    timing = request.get('production_lead_time_mode', 'LEGACY_REQUEST_DATE')
    if timing not in ('LEGACY_REQUEST_DATE', 'ACTUAL_START_DATE'):
        raise RequestError('INVALID_TIMING', 'Unsupported production lead-time mode.')
    normalized['production_lead_time_mode'] = timing
    if 'request_id' in request:
        rid = request['request_id']
        if not isinstance(rid, str) or not rid or len(rid) > 100:
            raise RequestError('INVALID_REQUEST_ID', 'request_id must be a nonempty string at most 100 characters.')
        normalized['request_id'] = rid
    return normalized


def build_request(request: dict, project_root=None):
    """Validate and construct a reproducible scoped snapshot/spec; no execution."""
    project, demo, config, inputs, legacy, run, valuation = runtime(project_root)
    source_path = demo / 'KetQua/Demo_01/input_source.json'
    matrix_path = demo / 'DSS/all_four_matrix.json'
    base, matrix = legacy.read(source_path), legacy.read(matrix_path)
    valuation.validate(base)
    normalized = normalize_request(request, base, matrix)
    selected = set(normalized['product_ids'])
    start, end = normalized['start_date'], normalized['end_date']
    source_lines = base['sales_order_lines']
    eligible = [line for line in source_lines if start <= line['OrderDate'][:10] <= end]
    order_ids = {line['SalesOrderID'] for line in eligible if line['ProductID'] in selected}
    lines = [deepcopy(line) for line in eligible if (line['ProductID'] in selected if normalized['product_scope'] == 'SELECTED_LINES' else line['SalesOrderID'] in order_ids)]
    products = {p['ProductID']: p for p in base['products']}
    independent = selected | {line['ProductID'] for line in lines}
    children = defaultdict(list)
    for edge in base['bom']:
        children[edge['ProductAssemblyID']].append(edge['ComponentID'])
    effective = set(independent)
    pending = list(effective)
    while pending:
        parent = pending.pop()
        if parent not in products:
            raise RequestError('BOM_PRODUCT_MISSING', 'The selected BOM requires a product missing from the frozen snapshot.', {'ProductID': parent})
        for child in children[parent]:
            if child not in effective:
                effective.add(child)
                pending.append(child)
    manufactured = {p for p in effective if products[p]['IsManufactured']}
    if not manufactured:
        raise RequestError('PURCHASED_ONLY_NOT_SUPPORTED', 'The preserved runtime requires manufactured products; choose a manufactured ProductID or WHOLE_ORDERS with a manufactured sibling.')
    if not (manufactured & independent):
        raise RequestError('NO_MANUFACTURED_DEMAND_ROOT', 'At least one selected demand product must be manufactured.')
    grouped = defaultdict(list)
    for line in lines:
        grouped[line['SalesOrderID']].append(line)
    incompatible = [oid for oid, group in grouped.items() if not any(line['ProductID'] in manufactured for line in group)]
    if incompatible:
        raise RequestError('PURCHASED_ONLY_ORDER_NOT_SUPPORTED', 'The preserved full-order runtime requires a manufactured line in each modeled order; choose WHOLE_ORDERS or only manufactured demand products.',
                           {'order_count': len(incompatible), 'example_sales_order_ids': sorted(incompatible)[:10]})
    s = deepcopy(base)
    s.update(start=start, end=end, products=[deepcopy(p) for p in base['products'] if p['ProductID'] in effective],
             sales_order_lines=lines, bom=[deepcopy(e) for e in base['bom'] if e['ProductAssemblyID'] in manufactured],
             topological_order=[p for p in base['topological_order'] if p in manufactured],
             supply_options=[deepcopy(v) for v in base['supply_options'] if v['ProductID'] in effective])
    # Valuation is subsetted, not recomputed from today's master or future data.
    value = deepcopy(base['metadata']['valuation'])
    value['rows'] = [row for row in value['rows'] if row['ProductID'] in effective]
    value['fallback_product_ids'] = [p for p in value['fallback_product_ids'] if p in effective]
    value['sha256'] = legacy.digest({k: v for k, v in value.items() if k != 'sha256'})
    s['metadata']['valuation'] = value
    forecast_disabled = []
    for p in s['products']:
        if p['IsManufactured']:
            params = p['ManufacturingParameters']
            if p['ProductID'] not in independent:
                params['root'] = False
                params['direct_mu'] = 0.0
                forecast_disabled.append(p['ProductID'])
            else:
                # Explicitly selected components can be independent-demand roots.
                params['root'] = True
    scenario = deepcopy(matrix['scenarios'][normalized['scenario_index'] - 1])
    scenario_name = scenario.pop('name')
    initial_rule = scenario.pop('initial_state_rule', 'APPROVED_ON_HAND_ZERO_OTHER')
    scenario.update(policy=normalized['policy'], replication=normalized['replication'],
                    production_lead_time_mode=normalized['production_lead_time_mode'], **normalized['penalties'])
    scenario['solver']['name'] = normalized['solver_name']
    for request_key, spec_key in (('solver_seconds', 'time_limit_seconds'), ('threads', 'threads')):
        if request_key in normalized:
            scenario['solver'][spec_key] = normalized[request_key]
    spec = config.resolve(scenario)
    prepared = inputs.prepare(s, spec)
    owned = set(prepared['P']) | set(prepared['raw'])
    for p in s['products']:
        if p['ProductID'] not in owned or initial_rule == 'ZERO':
            qty = 0
        elif initial_rule == 'REORDER_POINT':
            qty = p['ReorderPointQty']
        elif initial_rule == 'SAFETY_STOCK_LEVEL':
            qty = p['SafetyStockQty']
        elif initial_rule == 'MIDPOINT_CEIL':
            qty = (p['ReorderPointQty'] + p['SafetyStockQty'] + 1) // 2
        elif initial_rule == 'APPROVED_ON_HAND_ZERO_OTHER':
            qty = p['InitialQty']
        else:
            raise RequestError('INVALID_INITIAL_RULE', 'Unsupported initial stock rule in scenario.')
        p['InitialQty'] = qty
        if p['IsManufactured']:
            p['ManufacturingParameters']['initial'] = qty
    original_order_line_ids = defaultdict(list)
    for line in eligible:
        if line['SalesOrderID'] in order_ids:
            original_order_line_ids[line['SalesOrderID']].append(line['SalesOrderDetailID'])
    selected_line_ids = {line['SalesOrderDetailID'] for line in lines}
    partial_orders = [oid for oid, ids in original_order_line_ids.items() if set(ids) - selected_line_ids]
    scope = dict(schema='companyx.control.scope.v1', request=normalized, request_id=normalized.get('request_id'),
        base_snapshot_sha256=file_sha256(source_path), base_snapshot_content_sha256=legacy.digest(base),
        source_snapshot_reference=str(source_path), original_base_start=base['start'], original_base_end=base['end'],
        start=start, end=end, requested_product_ids=sorted(selected), effective_product_ids=sorted(effective),
        demand_product_ids=sorted(independent), bom_dependency_product_ids=sorted(effective - independent),
        manufactured_product_ids=sorted(manufactured), forecast_disabled_bom_only_product_ids=sorted(forecast_disabled),
        selected_sales_order_line_ids=sorted(selected_line_ids), selected_sales_order_ids=sorted(grouped),
        product_scope_mode=normalized['product_scope'], initial_state_mode=normalized['initialization'],
        initial_stock_rule=initial_rule, scenario_index=normalized['scenario_index'], scenario_name=scenario_name,
        partial_original_order_ids=sorted(partial_orders), full_original_order_count=len(grouped)-len(partial_orders),
        selected_order_line_count=len(lines), selected_order_count=len(grouped), simulation_days=(date.fromisoformat(end)-date.fromisoformat(start)).days+1,
        evaluation_scope=('SELECTED_PRODUCT_ORDER_PROJECTION' if normalized['product_scope']=='SELECTED_LINES' else 'WHOLE_ORIGINAL_ORDERS_MATCHING_SELECTED_PRODUCTS'),
        original_order_identity_preserved=True, original_order_coverage_complete=not partial_orders,
        base_valuation_sha256=base['metadata']['valuation']['sha256'], scoped_valuation_sha256=value['sha256'],
        planning_forecast='Frozen pre-base-start direct_mu retained for included independent-demand products; BOM-only independent demand set to zero; no evaluation-period fitting.',
        opening_state='Scenario initial stock; zero opening WIP, open purchases and customer obligations. Orders created before requested start are excluded explicitly.',
        temporal_basis='Fixed historical what-if source: BOM, prices, vendor and lead assumptions remain the approved base snapshot; not reconstructed as-of selected start.',
        due_after_end_lines=sum(line['DueDate'][:10] > end for line in lines),
        prestart_selected_lines_excluded=sum(line['ProductID'] in selected and line['OrderDate'][:10] < start for line in source_lines))
    scope['scope_sha256'] = legacy.digest(scope)
    s['metadata']['control_scope'] = deepcopy(scope)
    s['metadata']['cohort'] = scope['evaluation_scope']
    s['metadata']['initial_stock'] = initial_rule + '; NEW_EXPERIMENT at requested start, not historical stock reconstruction'
    valuation.validate(s)
    data = inputs.prepare(s, spec)
    from companyx_unified_v2.orders import OrderBook
    OrderBook(data['lines'], data['P'], data['external_ids'], data['start'], data['end'],
              '7B' if spec['allow_backorders'] else '7C', data['raw'])
    return dict(prepared_schema='companyx.control.prepared.v1', request=normalized,
                snapshot=s, spec=spec, scope=scope, snapshot_sha256=legacy.digest(s),
                execution_spec_sha256=legacy.digest(spec), runtime_code_sha256=run.code_hash())


def execute_request(request: dict, output_folder, project_root=None):
    """Execute one validated request, writing only to a fresh GPT run folder."""
    return execute_prepared(build_request(request, project_root), output_folder, project_root)


def execute_prepared(prepared: dict, output_folder, project_root=None):
    """Execute the exact hash-pinned prepared input across the SSIS boundary."""
    built = deepcopy(prepared)
    project, demo, config, inputs, legacy, run, valuation = runtime(project_root)
    if built.get('prepared_schema') != 'companyx.control.prepared.v1':
        raise RequestError('INVALID_PREPARED_SCHEMA', 'Unsupported prepared input artifact.')
    if (legacy.digest(built['snapshot']) != built.get('snapshot_sha256')
            or legacy.digest(built['spec']) != built.get('execution_spec_sha256')
            or run.code_hash() != built.get('runtime_code_sha256')):
        raise RequestError('PREPARED_IDENTITY_CHANGED', 'Prepared input/spec or frozen runtime changed after preparation.')
    if (legacy.digest({k: v for k, v in built['scope'].items() if k != 'scope_sha256'}) != built['scope'].get('scope_sha256')
            or built['snapshot']['metadata']['control_scope'] != built['scope']
            or built['scope']['request'] != built['request']):
        raise RequestError('PREPARED_SCOPE_CHANGED', 'Prepared scope provenance changed.')
    valuation.validate(built['snapshot'])
    inputs.prepare(built['snapshot'], built['spec'])
    if config.resolve(built['spec']) != built['spec']:
        raise RequestError('PREPARED_SPEC_CHANGED', 'Prepared execution spec no longer resolves identically.')
    folder = Path(output_folder).resolve()
    if not folder.is_relative_to(project / '_local') or folder == project / '_local':
        raise RequestError('OUTPUT_OUTSIDE_GPT', 'Simulation output must be in a dedicated folder under Project/GPT.')
    if (folder / 'run.json').exists() or (folder / 'completion.json').exists():
        raise RequestError('RUN_ALREADY_EXISTS', 'Existing runs are immutable; use a new request/run folder.')
    folder.mkdir(parents=True, exist_ok=True)
    legacy.save(folder / 'request.json', built['request'])
    legacy.save(folder / 'scope.json', built['scope'])
    legacy.save(folder / 'input_source.json', built['snapshot'])
    legacy.verify_release()
    before = run.code_hash()
    from native_path_worker import gurobi_native_paths
    use_native = built['spec']['policy'] == 'QUETSCHLICH_ADAPT' and built['spec']['solver']['name'] == 'GUROBI' and os.name == 'nt' and not str(folder).isascii()
    old_environment = {key: os.environ.get(key) for key in ('PYTHONPATH', 'TMP', 'TEMP', 'GRB_LICENSE_FILE')}
    temp = folder / 'tmp'
    temp.mkdir(exist_ok=True)
    os.environ['TMP'] = os.environ['TEMP'] = str(temp)
    library = str(demo / 'DSS/runtime/src')
    os.environ['PYTHONPATH'] = library + (os.pathsep + old_environment['PYTHONPATH'] if old_environment['PYTHONPATH'] else '')
    if not os.environ.get('GRB_LICENSE_FILE') and Path(r'E:\Gurobi\gurobi.lic').is_file():
        os.environ['GRB_LICENSE_FILE'] = r'E:\Gurobi\gurobi.lic'
    try:
        name = f"CONTROL {built['scope']['product_scope_mode']} / {built['scope']['scenario_name']} / {built['request']['policy']}"
        with gurobi_native_paths(folder, enabled=use_native):
            metrics = run.execute(built['snapshot'], built['spec'], folder, name=name)
        if run.code_hash() != before:
            raise RuntimeError('Frozen runtime code changed during execution.')
        receipt = dict(schema='companyx.control.execution.v1', status='COMPLETE',
            output_folder=str(folder), request_id=built['request'].get('request_id'),
            scope_sha256=built['scope']['scope_sha256'], core_sha256=before,
            run_code=legacy.read(folder / 'run.json')['RunCode'], metrics=metrics)
        legacy.save(folder / 'control_execution_receipt.json', receipt)
        return receipt
    finally:
        for key, value in old_environment.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('preview', 'run'))
    parser.add_argument('--request', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--project-root')
    args = parser.parse_args()
    request = json.loads(Path(args.request).read_text(encoding='utf-8-sig'))
    if args.action == 'run':
        result = execute_request(request, args.output, args.project_root)
    else:
        result = build_request(request, args.project_root)
        output = Path(args.output).resolve()
        project = project_path(args.project_root)
        if not output.is_relative_to(project / '_local'):
            raise RequestError('OUTPUT_OUTSIDE_GPT', 'Preview output must be under Project/GPT.')
        if output.exists():
            raise RequestError('PREVIEW_EXISTS', 'Preview output already exists; choose a new filename.')
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
        result = result['scope']
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

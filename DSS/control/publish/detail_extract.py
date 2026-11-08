"""Read-only DSS detail projection, with explicit non-reserving plan attribution.

No optimizer, dispatcher, stock balance or customer priority is changed here.
Observed component issues are tied only to the JOB/EXEC present in the event.
Plan FIFO is an explanatory decomposition of an accepted plan, not a MILP
reservation or an observed physical lot genealogy.
"""
from __future__ import annotations

from collections import Counter, defaultdict, deque
from contextlib import contextmanager
from datetime import date, timedelta
from decimal import Decimal
from itertools import groupby
from pathlib import Path
import gzip
import hashlib
import json
import shutil
import zipfile

SCHEMA = 'companyx.execution-detail.v1'
METHOD = 'EXPLANATORY_PLAN_FIFO_NO_RESERVATION'
TOL = Decimal('0.00001')
TABLES = ('OrderLineDay', 'OrderDay', 'ProductionJobDay', 'ProductionExecution',
          'MaterialTrace', 'AdvisoryAllocation', 'PlanSupplyBalance', 'PlanOrderMaterial')


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'),
                      allow_nan=False, default=str)


def quantity(value):
    value = Decimal(str(value))
    if not value.is_finite():
        raise ValueError('Non-finite quantity in detail source')
    return value


def numeric(value):
    value = quantity(value)
    return int(value) if value == value.to_integral_value() else float(value)


def member(folder, relative):
    relative = Path(str(relative).replace('\\', '/'))
    result = (folder / relative).resolve()
    if relative.is_absolute() or '..' in relative.parts or not result.is_relative_to(folder):
        raise ValueError('Detail reference leaves the owned artifact folder')
    return result


@contextmanager
def open_raw(folder, name):
    """Plain, gzip, inquiry ZIP and baseline ZIP. Hash the logical stream later."""
    if Path(name).name != name or not name.endswith('.jsonl'):
        raise ValueError('Invalid detail source table name')
    plain = folder / 'tables' / name
    if plain.exists():
        with plain.open('rb') as stream:
            yield stream
        return
    if (folder / 'stream_storage_manifest.json').exists():
        binding = read(folder / 'stream_storage_manifest.json')['tables'][name]
        compressed = member(folder, binding['gzip_file'])
        if compressed.exists():
            if sha(compressed) != binding['gzip_sha256']:
                raise ValueError('Compressed detail source changed')
            with gzip.open(compressed, 'rb') as stream:
                yield stream
            return
    for manifest_name in ('inquiry_archive_manifest.json', 'archive_manifest.json'):
        if not (folder / manifest_name).exists():
            continue
        archive = read(folder / manifest_name)
        relative = 'tables/' + name
        if relative not in archive['members']:
            continue
        with zipfile.ZipFile(member(folder, archive['archive_file']), 'r') as zipped:
            if zipped.namelist().count(relative) != 1:
                raise ValueError('Ambiguous source archive member')
            with zipped.open(relative, 'r') as stream:
                yield stream
            return
    raise FileNotFoundError('No full raw source for ' + name)


def verified_rows(folder, stem, manifest, run_code):
    name = stem + '.jsonl'
    expected = manifest['tables'][name]
    digest = hashlib.sha256()
    count = 0
    with open_raw(folder, name) as stream:
        for raw in stream:
            digest.update(raw)
            if not raw.strip():
                continue
            row = json.loads(raw)
            if row.get('RunCode') != run_code:
                raise ValueError('Cross-run detail source row: ' + name)
            count += 1
            yield row
    if digest.hexdigest() != expected['sha256'] or count != expected['rows']:
        raise ValueError('Detail source SHA/row count differs: ' + name)


def _physical_details(snapshot, headers, events, emit):
    """Consume date-ordered events once. Memory follows open jobs/orders only."""
    start = date.fromisoformat(snapshot['start'])
    end = date.fromisoformat(snapshot['end'])
    lines = {}
    reveal = defaultdict(list)
    for source in snapshot['sales_order_lines']:
        lid = int(source['SalesOrderDetailID'])
        oid = int(source['SalesOrderID'])
        header = headers[oid]
        if lid in lines:
            raise ValueError('Duplicate SalesOrderDetailID')
        known = header['KnownAt'][:10]
        due = header['DueAt'][:10]
        if known != source['OrderDate'][:10] or due != source['DueDate'][:10]:
            raise ValueError('Order dates differ between source header and input')
        lines[lid] = dict(oid=oid, p=int(source['ProductID']), q=quantity(source['OrderQty']),
                          known=known, due=due, shipped=Decimal(0), lost=Decimal(0))
        reveal[known].append(lid)
    active = set()
    jobs = {}
    executions = {}
    last_sequence = -1
    last_event_day = ''
    grouped = iter(groupby(events, key=lambda r: r['EventAt'][:10]))
    current = next(grouped, None)
    for offset in range((end - start).days + 1):
        day = str(start + timedelta(days=offset))
        active.update(reveal.get(day, ()))
        closing_lines = set()
        closing_jobs = set()
        if current is not None and current[0] < day:
            raise ValueError('Events before simulation start or out of order')
        rows = list(current[1]) if current is not None and current[0] == day else []
        # BOM is emitted before PRODUCTION_START by the executor. Register starts
        # first for identity lookup, then apply changes in original event order.
        for row in rows:
            if row['EventCode'] == 'PRODUCTION_START':
                ex = row.get('ProductionExecutionCode')
                if not ex or ex in executions:
                    raise ValueError('Missing/duplicate production execution identity')
                executions[ex] = dict(ExecutionCode=ex, JobCode=row['EntityCode'],
                                      ProductID=int(row['ProductID']), StartAt=day,
                                      CompletedAt=None, StartedQty=quantity(row['Quantity']),
                                      GoodQty=Decimal(0), SolveSequence=row.get('DecisionSolveSequence'))
        for row in rows:
            seq = int(row['EventSequence'])
            if seq <= last_sequence or day < last_event_day:
                raise ValueError('Event sequence/date not strictly ordered')
            last_sequence, last_event_day = seq, day
            code = row['EventCode']
            q = quantity(row['Quantity'])
            if q < 0:
                raise ValueError('Negative physical flow')
            if code in ('SHIP_ON_TIME', 'SHIP_LATE', 'LOST_SALE'):
                lid = int(row['EntityCode'].removeprefix('SO_LINE:'))
                line = lines[lid]
                if lid not in active or int(row['ProductID']) != line['p']:
                    raise ValueError('Unrevealed or mismatched customer line event')
                line['lost' if code == 'LOST_SALE' else 'shipped'] += q
                remaining = line['q'] - line['shipped'] - line['lost']
                if remaining < -TOL:
                    raise ValueError('Customer quantity over-consumed')
                if abs(remaining) <= TOL:
                    closing_lines.add(lid)
            elif code == 'PRODUCTION_REQUEST':
                job = row['EntityCode']
                if job in jobs:
                    raise ValueError('Repeated production job request identity')
                jobs[job] = dict(ProductID=int(row['ProductID']), CreatedAt=day,
                                 RequestedQty=q, StartedToDateQty=Decimal(0), GoodToDateQty=Decimal(0))
            elif code in ('PRODUCTION_START', 'PRODUCTION_GOOD'):
                job = row['EntityCode']
                item = jobs[job]
                ex = row.get('ProductionExecutionCode')
                execution = executions[ex]
                if execution['JobCode'] != job or execution['ProductID'] != int(row['ProductID']):
                    raise ValueError('Production execution mismatch')
                if code == 'PRODUCTION_START':
                    item['StartedToDateQty'] += q
                else:
                    item['GoodToDateQty'] += q
                    execution['GoodQty'] += q
                    if execution['GoodQty'] > execution['StartedQty'] + TOL:
                        raise ValueError('Production receipt exceeds start')
                    if abs(execution['GoodQty'] - execution['StartedQty']) <= TOL:
                        execution['CompletedAt'] = day
                        emit('ProductionExecution', {k: numeric(v) if isinstance(v, Decimal) else v
                                                     for k, v in execution.items()})
                        del executions[ex]
                if item['StartedToDateQty'] > item['RequestedQty'] + TOL:
                    raise ValueError('Production starts exceed request')
                if abs(item['GoodToDateQty'] - item['RequestedQty']) <= TOL:
                    closing_jobs.add(job)
            elif code == 'BOM_ISSUE':
                ex = row.get('ProductionExecutionCode')
                execution = executions[ex]
                if execution['JobCode'] != row['EntityCode']:
                    raise ValueError('BOM issue points to another job')
                emit('MaterialTrace', dict(EventSequence=seq, EventAt=day, JobCode=row['EntityCode'],
                     ExecutionCode=ex, ParentProductID=execution['ProductID'],
                     ComponentProductID=int(row['ProductID']), Quantity=numeric(q),
                     SolveSequence=row.get('DecisionSolveSequence'), TraceMethod='OBSERVED_JOB_EXECUTION'))
        active_orders = {}
        for lid in sorted(active):
            line = lines[lid]
            remaining = max(Decimal(0), line['q'] - line['shipped'] - line['lost'])
            status = 'OPEN' if remaining > TOL else ('LOST' if line['lost'] > TOL else 'FULFILLED')
            emit('OrderLineDay', dict(Date=day, SalesOrderID=line['oid'], SalesOrderDetailID=lid,
                 ProductID=line['p'], KnownAt=line['known'], DueAt=line['due'], OriginalQty=numeric(line['q']),
                 ShippedToDateQty=numeric(line['shipped']), LostToDateQty=numeric(line['lost']),
                 RemainingQty=numeric(remaining), OpenLineFlag=int(remaining > TOL),
                 DueOpenFlag=int(remaining > TOL and line['due'] <= day),
                 ClosedTodayFlag=int(lid in closing_lines), OrderStatus=status))
            aggregate = active_orders.setdefault(line['oid'], dict(open=False, lost=False, closed=True))
            aggregate['open'] |= remaining > TOL
            aggregate['lost'] |= line['lost'] > TOL
            aggregate['closed'] &= lid in closing_lines
        for oid, result in sorted(active_orders.items()):
            h = headers[oid]
            status = 'OPEN' if result['open'] else ('LOST' if result['lost'] else 'FULFILLED')
            emit('OrderDay', dict(Date=day, SalesOrderID=oid, KnownAt=h['KnownAt'][:10], DueAt=h['DueAt'][:10],
                 OpenOrderFlag=int(result['open']), DueOpenOrderFlag=int(result['open'] and h['DueAt'][:10] <= day),
                 CompletedTodayFlag=int(not result['open'] and not result['lost']),
                 LostTodayFlag=int(not result['open'] and result['lost']), OrderStatus=status))
        for job, item in sorted(jobs.items()):
            queued = item['RequestedQty'] - item['StartedToDateQty']
            wip = item['StartedToDateQty'] - item['GoodToDateQty']
            if queued < -TOL or wip < -TOL:
                raise ValueError('Negative job state')
            emit('ProductionJobDay', dict(Date=day, JobCode=job,
                 **{k: numeric(v) if isinstance(v, Decimal) else v for k, v in item.items()},
                 QueuedQty=numeric(max(Decimal(0), queued)), WIPQty=numeric(max(Decimal(0), wip)),
                 OpenJobFlag=int(queued + wip > TOL), ClosedTodayFlag=int(job in closing_jobs)))
        for job in closing_jobs:
            del jobs[job]
        active.difference_update(closing_lines)
        if rows:
            current = next(grouped, None)
    if current is not None:
        raise ValueError('Events extend beyond simulation end')
    for execution in executions.values():
        emit('ProductionExecution', {k: numeric(v) if isinstance(v, Decimal) else v for k, v in execution.items()})
    # Validate terminal source facts independently of reconstructed daily rows.
    by_order = defaultdict(list)
    for line in lines.values():
        by_order[line['oid']].append(line)
    for oid, values in by_order.items():
        remaining = sum(v['q'] - v['shipped'] - v['lost'] for v in values)
        status = 'OPEN' if remaining > TOL else ('LOST' if any(v['lost'] > TOL for v in values) else 'FULFILLED')
        if headers[oid]['OrderStatus'] != status:
            raise ValueError('Reconstructed terminal order state differs')


def allocate_plan(version, actions, state, snapshot, emit):
    """FIFO explanatory flow decomposition; independent for every plan version."""
    vid, decision = version['DecisionVersionID'], version['DecisionAt']
    horizon = version['HorizonEndAt']
    start = date.fromisoformat(snapshot['start'])
    supplies = []
    supply_codes = set()
    finite = {int(p) for p, q in state['inventory']}
    finite.update(int(p['ProductID']) for p in snapshot['products'] if p['IsManufactured'])
    def add(code, kind, p, available, q, action=None):
        q = quantity(q)
        if q < -TOL:
            raise ValueError('Negative proposed supply')
        if q <= TOL or available > horizon:
            return
        if code in supply_codes:
            raise ValueError('Duplicate plan supply identity')
        supply_codes.add(code)
        supplies.append(dict(SupplyCode=code, SupplyKind=kind, AvailableAt=available,
                             ProductID=int(p), SupplyActionRowNumber=action,
                             SupplyQty=q, AllocatedQty=Decimal(0), ResidualQty=q))
    for p, q in state['inventory']:
        add('STOCK:' + str(p), 'OPENING_STOCK', p, decision, q)
    for index, (day, receipts) in enumerate(state['pipeline']):
        available = str(start + timedelta(days=int(day)))
        if available <= decision:
            raise ValueError('Pre-dispatch state retained already-received WIP')
        for n, (p, q) in enumerate(receipts):
            add(f'WIP:{index}:{n}', 'OPENING_WIP', p, available, q)
    accept = 1 - quantity(state['spec']['supply']['reject_probability'])
    for i, purchase in enumerate(state.get('public_purchases', [])):
        available = str(start + timedelta(days=int(purchase['expected_day'])))
        if available > decision:
            add(f'PO:{i}', 'OPENING_PURCHASE', purchase['p'], available, quantity(purchase['q']) * accept)
    for row in actions:
        if row['ActionCode'] in ('PLANNED_PRODUCTION_RECEIPT', 'PLANNED_PURCHASE_RECEIPT'):
            kind = 'PLANNED_PRODUCTION' if row['ActionCode'] == 'PLANNED_PRODUCTION_RECEIPT' else 'PLANNED_PURCHASE'
            add('ACTION:' + str(row['RowNumber']), kind, row['ProductID'], row['PlanAt'], row['Quantity'], row.get('ParentActionRowNumber'))
    by_product = defaultdict(list)
    for s in sorted(supplies, key=lambda s: (s['AvailableAt'], s['SupplyCode'])):
        by_product[s['ProductID']].append(s)
    demand_codes = {'ORDER_LINE_SHIPMENT': ('SALES_ORDER_LINE', 0), 'PLANNED_BOM_ISSUE': ('PLANNED_BOM', 1), 'FORECAST_SHIPMENT': ('FORECAST', 2)}
    demands = sorted((r for r in actions if r['ActionCode'] in demand_codes and quantity(r.get('Quantity') or 0) > TOL),
                     key=lambda r: (r['PlanAt'], demand_codes[r['ActionCode']][1], r.get('SalesOrderID') or 0, r['RowNumber']))
    allocation_no = 0
    known_orders = {int(o['SalesOrderID']) for o in state['orders']}
    allocations = []
    for row in demands:
        p, day, remaining = int(row['ProductID']), row['PlanAt'], quantity(row['Quantity'])
        if row['ActionCode'] == 'ORDER_LINE_SHIPMENT':
            if int(row['SalesOrderID']) not in known_orders:
                raise ValueError('Plan allocation uses an unrevealed order')
        if p not in finite:
            add('EXTERNAL:' + str(row['RowNumber']), 'UNLIMITED_EXTERNAL', p, day, remaining)
            by_product[p].append(supplies[-1])
        for supply in by_product[p]:
            if supply['AvailableAt'] > day or supply['ResidualQty'] <= TOL:
                continue
            allocated = min(remaining, supply['ResidualQty'])
            if allocated <= TOL:
                break
            supply['AllocatedQty'] += allocated
            supply['ResidualQty'] -= allocated
            remaining -= allocated
            allocation_no += 1
            allocation = dict(DecisionVersionID=vid, AllocationNo=allocation_no,
                 DecisionAt=decision, PlanAt=day, ProductID=p, ParentProductID=row.get('ParentProductID'),
                 SalesOrderID=row.get('SalesOrderID'), SalesOrderDetailID=row.get('SalesOrderDetailID'),
                 ConsumerType=demand_codes[row['ActionCode']][0], ConsumerActionRowNumber=row['RowNumber'],
                 SupplyCode=supply['SupplyCode'], SupplyKind=supply['SupplyKind'],
                 SupplyAvailableAt=supply['AvailableAt'], SupplyActionRowNumber=supply['SupplyActionRowNumber'],
                 AllocatedQty=numeric(allocated), IsAdvisory=True, Method=METHOD)
            emit('AdvisoryAllocation', allocation)
            allocations.append(allocation)
            if remaining <= TOL:
                break
        if remaining > TOL:
            raise ValueError(f'Accepted-plan supply reconstruction shortfall: {vid} {day} Product {p}: {remaining}')
    for supply in supplies:
        if abs(supply['SupplyQty'] - supply['AllocatedQty'] - supply['ResidualQty']) > TOL:
            raise ValueError('Advisory supply conservation failed')
        emit('PlanSupplyBalance', dict(DecisionVersionID=vid, DecisionAt=decision, HorizonEndAt=horizon,
             **{k: numeric(v) if isinstance(v, Decimal) else v for k, v in supply.items()}, IsAdvisory=True, Method=METHOD))
    _order_material_lineage(version, actions, supplies, allocations, snapshot, emit)


def _order_material_lineage(version, actions, supplies, allocations, snapshot, emit):
    """Proportional BOM attribution over advisory edges, never physical genealogy."""
    supply_map = {s['SupplyCode']: s for s in supplies}
    bom_actions = defaultdict(list)
    for row in actions:
        if row['ActionCode'] == 'PLANNED_BOM_ISSUE':
            bom_actions[row['ParentActionRowNumber']].append(row)
    consumption = defaultdict(list)
    for edge in allocations:
        consumption[edge['ConsumerActionRowNumber']].append(edge)
    output_qty = Counter()
    for supply in supplies:
        if supply['SupplyKind'] == 'PLANNED_PRODUCTION':
            output_qty[supply['SupplyActionRowNumber']] += supply['SupplyQty']
    assembly_ids = {int(edge['ProductAssemblyID']) for edge in snapshot.get('bom', [])}
    attributed = defaultdict(Decimal)
    row_number = 0

    def walk(supply, allocated_output, order_edge, depth, path):
        nonlocal row_number
        if supply['SupplyKind'] != 'PLANNED_PRODUCTION':
            return
        start_action = supply['SupplyActionRowNumber']
        if start_action in path or depth > 64:
            raise ValueError('Cycle or unsupported depth in advisory material lineage')
        total_output = output_qty[start_action]
        if total_output <= 0:
            raise ValueError('Planned production supply has no output')
        share = quantity(allocated_output) / total_output
        if share > 1 + TOL:
            raise ValueError('Order attribution exceeds planned production supply')
        for bom in bom_actions[start_action]:
            for edge in consumption[bom['RowNumber']]:
                component_supply = supply_map[edge['SupplyCode']]
                q = share * quantity(edge['AllocatedQty'])
                if q <= 0:
                    continue
                key = edge['AllocationNo']
                attributed[key] += q
                if attributed[key] > quantity(edge['AllocatedQty']) + TOL:
                    raise ValueError('Component edge attributed to orders more than once')
                row_number += 1
                continuing = component_supply['SupplyKind'] == 'PLANNED_PRODUCTION'
                emit('PlanOrderMaterial', dict(DecisionVersionID=version['DecisionVersionID'],
                     MaterialRowNo=row_number, DecisionAt=version['DecisionAt'], PlanAt=bom['PlanAt'],
                     SalesOrderID=order_edge['SalesOrderID'], SalesOrderDetailID=order_edge['SalesOrderDetailID'],
                     RootProductID=order_edge['ProductID'], ParentProductID=bom['ParentProductID'],
                     ComponentProductID=bom['ProductID'], AttributedQty=numeric(q),
                     MaterialDepth=depth, IsLeafComponent=int(bom['ProductID']) not in assembly_ids,
                     ProductionActionRowNumber=start_action, ComponentConsumerActionRowNumber=bom['RowNumber'],
                     ComponentSupplyCode=component_supply['SupplyCode'], ComponentSupplyKind=component_supply['SupplyKind'],
                     ComponentSupplyActionRowNumber=component_supply['SupplyActionRowNumber'],
                     RootSupplyCode=order_edge['SupplyCode'],
                     LineageBoundary='CONTINUES_PLANNED_PRODUCTION' if continuing else 'STOPS_AT_' + component_supply['SupplyKind'],
                     Method='EXPLANATORY_PLAN_PROPORTIONAL_LINEAGE_NO_RESERVATION', IsAdvisory=True))
                if continuing:
                    walk(component_supply, q, order_edge, depth + 1, path | {start_action})

    for order_edge in allocations:
        if order_edge['ConsumerType'] == 'SALES_ORDER_LINE':
            walk(supply_map[order_edge['SupplyCode']], quantity(order_edge['AllocatedQty']), order_edge, 1, set())


def export_detail(folder, prepared=None, project_root=None, *, destination=None):
    """Return verified detail manifest. No SQL/cube writes and no source edits."""
    folder = Path(folder).resolve()
    project = Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    if not folder.is_relative_to(project / '_local') or folder == project / '_local':
        raise ValueError('Detail source must be a dedicated Project/GPT artifact folder')
    source_hash = sha(folder / 'table_manifest.json')
    input_hash = sha(folder / 'input.json')
    spec_hash = sha(folder / 'execution_spec.json')
    contract_hash = sha(Path(__file__).with_name('detail_contract.json'))
    plan_hash = sha(folder / 'rolling_plan_manifest.json') if (folder / 'rolling_plan_manifest.json').exists() else None
    identity = hashlib.sha256((source_hash + input_hash + spec_hash + str(plan_hash) + sha(__file__) + contract_hash).encode('ascii')).hexdigest()
    target = Path(destination).resolve() if destination else folder / 'execution_detail_v1' / identity[:24]
    if not target.is_relative_to(project / '_local') or target == project / '_local':
        raise ValueError('Detail output must stay in Project/GPT')
    manifest_path = target / 'detail_manifest.json'
    source_manifest = read(folder / 'table_manifest.json')
    run_code = read(folder / 'run.json')['RunCode']
    if manifest_path.exists():
        record = read(manifest_path)
        if (record['schema'] != SCHEMA or record['source_table_manifest_sha256'] != source_hash
                or record['RunCode'] != run_code or record.get('source_identity') != identity
                or record.get('input_sha256') != input_hash
                or record.get('rolling_plan_manifest_sha256') != plan_hash):
            raise ValueError('Existing detail export belongs to different input')
        for name, entry in record['tables'].items():
            if sha(target / name) != entry['sha256']:
                raise ValueError('Existing detail table changed')
        return record
    if target.exists() and any(target.iterdir()):
        raise ValueError('Incomplete detail output exists; retain for inspection')
    target.mkdir(parents=True, exist_ok=True)
    snapshot = prepared['snapshot'] if prepared else read(folder / 'input.json')
    spec = prepared['spec'] if prepared else read(folder / 'execution_spec.json')
    streams = {name: (target / (name + '.jsonl')).open('xb') for name in TABLES}
    counts = Counter()
    digests = {name: hashlib.sha256() for name in TABLES}
    written_bytes = 0
    next_space_check = 0
    def emit(name, row):
        nonlocal written_bytes, next_space_check
        raw = (canonical(dict(RunCode=run_code, **row)) + '\n').encode('utf-8')
        if written_bytes >= next_space_check:
            if shutil.disk_usage(target).free < 20 * 1024**3:
                raise RuntimeError('Detail export stopped before crossing 20GiB free-space reserve')
            next_space_check = written_bytes + 64 * 1024**2
        streams[name].write(raw)
        written_bytes += len(raw)
        counts[name] += 1
        digests[name].update(raw)
    try:
        headers = {}
        for row in verified_rows(folder, 'Fact_SimulationOrder', source_manifest, run_code):
            oid = int(row['SourceSalesOrderID'])
            if oid in headers:
                raise ValueError('Duplicate customer order header')
            headers[oid] = row
        _physical_details(snapshot, headers, verified_rows(folder, 'Fact_SimulationEvent', source_manifest, run_code), emit)
        plan_versions = 0
        if spec['policy'] == 'QUETSCHLICH_ADAPT':
            from simulation.rolling_plan import verify_rolling_plan
            rolling = verify_rolling_plan(folder, read(folder / 'rolling_plan_manifest.json'), project)
            versions = {v['DecisionVersionID']: v for v in (json.loads(line) for line in (folder / 'rolling_plan_versions.jsonl').read_text(encoding='utf-8').splitlines())}
            with (folder / 'rolling_plan_actions.jsonl').open(encoding='utf-8') as action_file:
                for vid, rows in groupby((json.loads(line) for line in action_file), key=lambda r: r['DecisionVersionID']):
                    version = versions.pop(vid)
                    state_path = member(folder, version['StateReference'].split('#sha256=')[0])
                    state = read(state_path)
                    if hashlib.sha256(canonical(state).encode('utf-8')).hexdigest() != version['StateSHA256']:
                        raise ValueError('Accepted plan state bytes changed')
                    allocate_plan(version, list(rows), state, snapshot, emit)
                    plan_versions += 1
            if versions:
                raise ValueError('Rolling plan version has no action rows')
        else:
            rolling = None
        for stream in streams.values():
            stream.close()
        record = dict(schema=SCHEMA, RunCode=run_code, status='VERIFIED_DETAIL_EXPORT',
                      artifact_folder=str(folder), detail_folder=str(target),
                      source_table_manifest_sha256=source_hash,
                      exporter_sha256=sha(__file__), source_identity=identity,
                      input_sha256=input_hash, execution_spec_sha256=spec_hash, contract_sha256=contract_hash,
                      source_tables={k: source_manifest['tables'][k] for k in ('Fact_SimulationOrder.jsonl', 'Fact_SimulationEvent.jsonl')},
                      rolling_plan_manifest_sha256=plan_hash,
                      plan_version_count=plan_versions,
                      allocation_method=METHOD, changes_dispatch_or_reservations=False,
                      tables={name + '.jsonl': dict(rows=counts[name], sha256=digests[name].hexdigest(), bytes=(target / (name + '.jsonl')).stat().st_size) for name in TABLES})
        manifest_path.write_text(json.dumps(record, ensure_ascii=False, indent=2), encoding='utf-8')
        return record
    except BaseException as error:
        for stream in streams.values():
            stream.close()
        (target / 'FAILED.json').write_text(json.dumps(dict(error=str(error), source_unchanged=True), indent=2), encoding='utf-8')
        raise


export_execution_detail = export_detail

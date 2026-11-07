"""Typed snapshots of every *accepted* rolling MILP decision.

This is an observational export. It neither reserves stock nor changes a solver
action. A future plan is never labelled as a DES execution. Model pickles are
only opened beneath the owned run directory after accepted-decision provenance
has been checked; these are solver requests created by the local runtime.
"""
from __future__ import annotations

from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path
import gzip
import json
import math
import pickle

from .adapter import RequestError, file_sha256, runtime

SCHEMA = 'companyx.rolling-plan.v1'
VERSIONS = 'rolling_plan_versions.jsonl'
ACTIONS = 'rolling_plan_actions.jsonl'
MANIFEST = 'rolling_plan_manifest.json'


def _member(folder, reference):
    relative = Path(reference.replace('\\', '/'))
    result = (folder / relative).resolve()
    if relative.is_absolute() or '..' in relative.parts or not result.is_relative_to(folder):
        raise RequestError('ROLLING_PLAN_PATH_INVALID', 'Accepted-plan reference leaves the owned artifact.')
    if not result.is_file():
        raise RequestError('ROLLING_PLAN_EVIDENCE_MISSING', 'Missing accepted-plan evidence: ' + str(relative))
    return result


def _reference(folder, text):
    name, separator, expected = text.partition('#sha256=')
    if not separator or len(expected) != 64:
        raise RequestError('ROLLING_PLAN_REFERENCE_INVALID', 'Expected a content-bound reference.')
    return _member(folder, name), expected


def _receipt_locations(model):
    """Get receipt timing and yield from the actual accepted model balances."""
    targets = defaultdict(list)
    for label, coefficients in zip(model['labels'], model['rows']):
        if label not in ('inventory', 'raw_inventory'):
            continue
        inventory = [(j, model['keys'][j]) for j, c in coefficients.items()
                     if c == 1 and model['keys'][j][0] in ('I', 'raw_I')]
        if len(inventory) != 1:
            raise RequestError('ROLLING_PLAN_MODEL_UNSUPPORTED', 'Inventory row does not have one ending-state variable.')
        _, key = inventory[0]
        for j, coefficient in coefficients.items():
            if coefficient < 0 and model['keys'][j][0] in ('a', 'buy'):
                targets[j].append((int(key[2]), float(-coefficient)))
    return targets


def iter_accepted_plans(folder, prepared, project_root=None, *, allow_legacy_model=False):
    """Yield (version, typed actions, verified pre-decision state).

    Only decisions/ references are followed. Failed attempts and unaccepted
    feasible solutions cannot enter the stream. Legacy model requests that were
    not hash-bound by the decision require an explicit historical-read opt-in.
    """
    import numpy as np
    project, _, _, inputs, legacy, _, _ = runtime(project_root)
    folder = Path(folder).resolve()
    if folder == project/'GPT' or not folder.is_relative_to(project/'GPT'):
        raise RequestError('OUTPUT_OUTSIDE_GPT', 'Rolling-plan artifacts must be under Project/GPT.')
    data = inputs.prepare(prepared['snapshot'], prepared['spec'])
    start = date.fromisoformat(prepared['snapshot']['start'])
    known = date.fromisoformat(prepared.get('scope', {}).get('known_at', prepared['snapshot']['start']))
    end = date.fromisoformat(prepared['snapshot']['end'])
    names = {
        'q': 'PRODUCTION_REQUEST', 'a': 'PRODUCTION_START', 'buy': 'PURCHASE_ORDER',
        'order_ship': 'WHOLE_ORDER_SHIPMENT', 'order_loss': 'WHOLE_ORDER_LOSS',
        'order_unserved': 'WHOLE_ORDER_UNSERVED', 'I': 'PROJECTED_ON_HAND',
        'raw_I': 'PROJECTED_ON_HAND', 'Ba': 'PROJECTED_ACTUAL_BACKLOG',
        'yf': 'FORECAST_SHIPMENT', 'raw_yf': 'FORECAST_SHIPMENT',
        'Bf': 'PROJECTED_FORECAST_SHORTAGE', 'raw_Bf': 'PROJECTED_FORECAST_SHORTAGE',
    }
    seen_days = set()
    seen_solves = set()
    for decision_file in sorted((folder/'decisions').glob('*.json')):
        decision = legacy.read(decision_file)
        day = int(decision['day'])
        today = start + timedelta(days=day)
        if today < known or today > end:
            continue
        if day in seen_days or decision_file.name != f'{day:04d}.json':
            raise RequestError('ROLLING_PLAN_DUPLICATE_DECISION', 'Expected exactly one accepted decision per day.')
        seen_days.add(day)
        sequence = int(decision['solver']['SolveSequence'])
        if sequence in seen_solves:
            raise RequestError('ROLLING_PLAN_DUPLICATE_SOLVE', 'An accepted solve cannot represent two decision dates.')
        seen_solves.add(sequence)
        audit_record = legacy.read(_member(folder, f'solve_audit/{sequence:07d}.json'))
        audit = audit_record['row']
        if legacy.digest(audit) != audit_record['sha256']:
            raise RequestError('ROLLING_PLAN_AUDIT_CHANGED', 'Solve audit content hash differs.')
        actual_decision_file, decision_hash = _reference(folder, audit['DecisionOutputReference'])
        if (actual_decision_file != decision_file.resolve() or legacy.digest(decision) != decision_hash
                or audit['SolveSequence'] != sequence or audit['DecisionAt'] != str(today)
                or not audit['HasFeasibleSolution'] or audit['ActionSource'] != 'SOLVER_INCUMBENT'):
            raise RequestError('ROLLING_PLAN_NOT_ACCEPTED', 'Decision is not the accepted, audited feasible action.')
        state_file, state_hash = _reference(folder, audit['StateInputReference'])
        state = legacy.read(state_file)
        if (legacy.digest(state) != state_hash or state_hash != decision['state_hash']
                or int(state['day']) != day):
            raise RequestError('ROLLING_PLAN_STATE_CHANGED', 'Accepted-decision state identity differs.')
        solution_file = _member(folder, decision['solution_reference'])
        if file_sha256(solution_file) != decision['solution_sha256']:
            raise RequestError('ROLLING_PLAN_SOLUTION_CHANGED', 'Accepted solution bytes differ.')
        model_file = _member(folder, (solution_file.parent/'request.pkl.gz').relative_to(folder).as_posix())
        model_hash = file_sha256(model_file)
        model_bound = decision.get('model_sha256') is not None
        if model_bound and model_hash != decision['model_sha256']:
            raise RequestError('ROLLING_PLAN_MODEL_CHANGED', 'Accepted model request bytes differ.')
        if not model_bound and not allow_legacy_model:
            raise RequestError('ROLLING_PLAN_MODEL_UNBOUND', 'This historical decision did not bind its model hash. Archive it or use explicit legacy-read mode.')
        with gzip.open(model_file, 'rb') as stream:
            model = pickle.load(stream)['model']
        values = np.load(solution_file, allow_pickle=False)
        if len(values) != len(model['keys']) or not np.isfinite(values).all():
            raise RequestError('ROLLING_PLAN_SOLUTION_INVALID', 'Accepted variable values are invalid.')
        orders = {int(o['SalesOrderID']): o for o in state['orders']}
        if any(date.fromisoformat(str(o['order'])[:10]) > today for o in orders.values()):
            raise RequestError('ROLLING_PLAN_FUTURE_ORDER', 'Future customer order in the accepted information set.')
        horizon = int(decision['solver']['horizon'])
        version = dict(SchemaVersion=SCHEMA, DecisionVersionID=decision_hash,
            DecisionAt=str(today), DayIndex=day, SolveSequence=sequence,
            HorizonEndAt=str(today+timedelta(days=horizon)),
            DecisionReference=decision_file.relative_to(folder).as_posix(), DecisionSHA256=decision_hash,
            StateReference=state_file.relative_to(folder).as_posix(), StateSHA256=state_hash,
            ModelReference=model_file.relative_to(folder).as_posix(), ModelSHA256=model_hash,
            SolutionReference=solution_file.relative_to(folder).as_posix(), SolutionSHA256=decision['solution_sha256'],
            ModelBoundAtDecision=model_bound, StateAt='PRE_DISPATCH_AFTER_RECEIPTS')
        if audit['HorizonEndAt'] != version['HorizonEndAt']:
            raise RequestError('ROLLING_PLAN_HORIZON_CHANGED', 'Accepted horizon differs from the solve audit.')
        receipt_locations = _receipt_locations(model)
        rows = []

        def emit(row):
            row = dict(row, RowNumber=len(rows)+1)
            rows.append(row)
            return row

        for variable_index, (key, raw_value) in enumerate(zip(model['keys'], values)):
            kind = key[0]
            if kind not in names:
                continue
            value = float(raw_value)
            projected = kind in ('I', 'raw_I', 'Ba', 'Bf', 'raw_Bf')
            binary = kind.startswith('order_')
            if abs(value) < 1e-9:
                value = 0.0
                if not projected and not binary:
                    continue
            _, identifier, period, *rest = key
            period = int(period)
            if period < 0 or period > horizon:
                raise RequestError('ROLLING_PLAN_PERIOD_INVALID', 'Variable period is outside accepted horizon.')
            if binary:
                if abs(value-round(value)) > 1e-5 or round(value) not in (0, 1):
                    raise RequestError('ROLLING_PLAN_BINARY_INVALID', 'Whole-order decision is not binary.')
                value = int(round(value))
            product = None if binary else int(identifier)
            locations = receipt_locations.get(variable_index, [])
            completion = str(today+timedelta(days=locations[0][0])) if len(locations) == 1 else None
            row = emit(dict(DecisionVersionID=decision_hash, DecisionAt=str(today),
                PlanAt=str(today+timedelta(days=period)), PeriodOffset=period, SolveSequence=sequence,
                ActionCode=names[kind], ValueKind='WHOLE_ORDER_BINARY_DECISION' if binary else 'PROJECTED_STATE' if projected else 'PLANNED_MATERIAL_QUANTITY',
                ProductID=product, ParentProductID=None, SalesOrderID=int(identifier) if binary else None,
                SalesOrderDetailID=None, Quantity=None if binary else value, OrderDecisionFlag=value if binary else None,
                QueueAge=int(rest[0]) if kind == 'a' else None,
                StockUnit=data['products'][product].get('StockUnit') if product is not None else 'order',
                IsFirstPeriod=period == 0, IsTentativeFuture=period > 0, IsObservedExecution=False,
                PlannedCompletionAt=completion, ModelVariableIndex=variable_index, ParentActionRowNumber=None))
            if binary:
                order = orders.get(int(identifier))
                if order is None:
                    raise RequestError('ROLLING_PLAN_ORDER_MISSING', 'Accepted whole-order variable has no revealed order.')
                for line in order['lines']:
                    emit(dict(row, ActionCode='ORDER_LINE_'+names[kind].removeprefix('WHOLE_ORDER_'),
                        ValueKind='PLANNED_ORDER_LINE_QUANTITY', ProductID=int(line['p']),
                        SalesOrderDetailID=int(line['id']), Quantity=float(line['remaining'])*value,
                        OrderDecisionFlag=None, StockUnit=data['products'][int(line['p'])].get('StockUnit'),
                        ParentActionRowNumber=row['RowNumber']))
            if kind == 'a':
                for child, amount, unit in data['bom'].children[int(identifier)]:
                    emit(dict(row, ActionCode='PLANNED_BOM_ISSUE', ParentProductID=int(identifier),
                        ProductID=int(child), Quantity=value*amount, StockUnit=unit,
                        ParentActionRowNumber=row['RowNumber'], PlannedCompletionAt=None))
            for arrival_period, coefficient in locations:
                emit(dict(row, ActionCode='PLANNED_PRODUCTION_RECEIPT' if kind == 'a' else 'PLANNED_PURCHASE_RECEIPT',
                    PlanAt=str(today+timedelta(days=arrival_period)), PeriodOffset=arrival_period,
                    Quantity=value*coefficient, IsFirstPeriod=arrival_period == 0,
                    IsTentativeFuture=arrival_period > 0, ParentActionRowNumber=row['RowNumber'],
                    PlannedCompletionAt=None))
        yield version, rows, state


def export_rolling_plan(folder, prepared, project_root=None, *, allow_legacy_model=False):
    project, _, _, _, legacy, _, _ = runtime(project_root)
    folder = Path(folder).resolve()
    if folder == project/'GPT' or not folder.is_relative_to(project/'GPT'):
        raise RequestError('OUTPUT_OUTSIDE_GPT', 'Rolling-plan outputs must remain under Project/GPT.')
    start = date.fromisoformat(prepared['snapshot']['start'])
    known = date.fromisoformat(prepared.get('scope', {}).get('known_at', prepared['snapshot']['start']))
    end = date.fromisoformat(prepared['snapshot']['end'])
    applicable = prepared['spec']['policy'] == 'QUETSCHLICH_ADAPT'
    expected = list(range((known-start).days, (end-start).days+1)) if applicable else []
    versions, rows, observed, model_bound = 0, 0, [], True
    with (folder/VERSIONS).open('w', encoding='utf-8', newline='\n') as vout, (folder/ACTIONS).open('w', encoding='utf-8', newline='\n') as aout:
        if applicable:
            for version, actions, _ in iter_accepted_plans(folder, prepared, project, allow_legacy_model=allow_legacy_model):
                vout.write(legacy.canonical(version)+'\n')
                for action in actions:
                    aout.write(legacy.canonical(action)+'\n')
                versions += 1
                rows += len(actions)
                observed.append(version['DayIndex'])
                model_bound = model_bound and version['ModelBoundAtDecision']
    missing = sorted(set(expected)-set(observed))
    extra = sorted(set(observed)-set(expected))
    status = 'NOT_APPLICABLE' if not applicable else 'COMPLETE' if not missing and not extra else 'INCOMPLETE'
    receipt = dict(schema=SCHEMA, status=status, applicable=applicable,
        decision_start=str(known) if applicable else None, decision_end=str(end) if applicable else None,
        expected_decisions=len(expected), accepted_decisions=versions, action_rows=rows,
        missing_day_indices=missing, unexpected_day_indices=extra, all_models_bound_at_decision=model_bound,
        exporter_sha256=file_sha256(__file__),
        versions=dict(path=VERSIONS, rows=versions, sha256=file_sha256(folder/VERSIONS)),
        actions=dict(path=ACTIONS, rows=rows, sha256=file_sha256(folder/ACTIONS)),
        interpretation='One accepted plan version per decision day. Future rows are tentative; binary order decisions and line quantities are separate. No reservation or physical execution is implied.')
    legacy.save(folder/MANIFEST, receipt)
    if status == 'INCOMPLETE':
        raise RequestError('ROLLING_PLAN_COVERAGE_INCOMPLETE', 'Accepted plans do not cover every MILP decision day.', receipt)
    return receipt


def verify_rolling_plan(folder, receipt, project_root=None, *, allow_legacy_model=False):
    """Verify publication inputs without decoding trusted runtime pickles again."""
    project, _, _, _, legacy, _, _ = runtime(project_root)
    folder = Path(folder).resolve()
    if folder == project/'GPT' or not folder.is_relative_to(project/'GPT'):
        raise RequestError('OUTPUT_OUTSIDE_GPT', 'Rolling-plan artifacts must remain under Project/GPT.')
    if receipt.get('schema') != SCHEMA or receipt.get('status') not in ('COMPLETE','NOT_APPLICABLE'):
        raise RequestError('ROLLING_PLAN_INCOMPLETE', 'A complete rolling-plan export is required.')
    if receipt.get('applicable') and (receipt['status'] != 'COMPLETE'
            or receipt.get('missing_day_indices') or receipt.get('unexpected_day_indices')
            or receipt.get('expected_decisions') != receipt.get('accepted_decisions')):
        raise RequestError('ROLLING_PLAN_INCOMPLETE', 'Every applicable decision day must have an accepted version.')
    if receipt.get('applicable') and not receipt.get('all_models_bound_at_decision') and not allow_legacy_model:
        raise RequestError('ROLLING_PLAN_MODEL_UNBOUND', 'Historical unbound model plans are not eligible for the new publication contract.')
    if legacy.read(folder/MANIFEST) != receipt:
        raise RequestError('ROLLING_PLAN_CHANGED', 'Rolling-plan manifest differs from execution receipt.')
    for name, expected_path in (('versions', VERSIONS), ('actions', ACTIONS)):
        item = receipt[name]
        if item['path'] != expected_path or file_sha256(folder/expected_path) != item['sha256']:
            raise RequestError('ROLLING_PLAN_CHANGED', 'Rolling-plan data bytes differ: '+name)
        with (folder/expected_path).open(encoding='utf-8') as stream:
            if sum(1 for _ in stream) != item['rows']:
                raise RequestError('ROLLING_PLAN_CHANGED', 'Rolling-plan row count differs: '+name)
    return dict(status='VERIFIED', schema=SCHEMA, accepted_decisions=receipt['accepted_decisions'])

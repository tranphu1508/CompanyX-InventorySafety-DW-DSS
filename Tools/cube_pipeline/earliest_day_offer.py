"""Find the first deadline that ships the full inquiry while preserving all known old deadlines.

The new order is not forced in the final objective solve; old due dates are protected. Every candidate is
solved independently from the same verified, frozen ROP decision state.
A1/A2/C and the sequential B search run in parallel and are saved in one SIM offer group.
No preliminary original-deadline optimization is needed.
"""
from __future__ import annotations

import argparse
from copy import deepcopy
from datetime import date, timedelta
from pathlib import Path
import json
import os
import sys
import traceback

from settings import DEMO, GPT, OUTPUT, read, save, sql
from dss_bridge import validate_input


def progress(folder: Path, **fields):
    save(folder / 'progress.json', fields)
    detail = fields.get('message') or fields.get('state', '')
    print(detail, flush=True)


def request_for_day(original: dict, product: int, qty: int, due: date, slot: str) -> dict:
    request = deepcopy(original)
    baselines = [c for c in request['candidates'] if c['kind'] == 'BASELINE']
    if len(baselines) != 1:
        raise ValueError('Expected exactly one reference BASELINE candidate.')
    label = 'AUTO_' + slot
    if baselines[0]['candidate_id'] == label:
        label += '_2'
    request['candidates'] = [baselines[0], {
        'candidate_id': label,
        'kind': 'FULL',
        'tranches': [{'due_date': due.isoformat(),
                      'lines': [{'product_id': product, 'quantity': qty}]}],
    }]
    return request


def offer_group(priority: dict, qty: int, known: str, due: str, binding: dict) -> dict:
    """Storage envelope for verified variants; not an extra simulated A plan."""
    variants = priority.get('variants', [])
    if len(variants) != 3 or {v.get('variant') for v in variants} != {'A1', 'A2', 'C'}:
        raise ValueError('Expected exactly A1, A2 and C before publication.')
    state_hash = priority.get('sourceStateHash')
    if (not state_hash or priority.get('sourceSnapshotId') != binding['snapshot_id']
            or priority.get('knownAt') != known or priority.get('newOrderDue') != due):
        raise ValueError('Offer bundle does not match the requested state, snapshot or dates.')
    for variant in variants:
        mode, status = variant['variant'], variant.get('status')
        if variant.get('baseStateHash') != state_hash or variant.get('due') != due:
            raise ValueError('Offer variants do not share the requested state and deadline.')
        if status == 'INFEASIBLE' and mode != 'C':
            continue
        if status != 'OPTIMAL':
            raise ValueError('All variants require an optimum or an infeasibility certificate.')
        expected = (0, qty) if mode == 'C' else (qty, 0)
        if (variant.get('plannedShip'), variant.get('plannedLoss')) != expected:
            raise ValueError('Invalid whole-order settlement in offer variant.')
    return dict(schema='companyx.day-offer-group.v2', slot='A', due=due,
                baseStateHash=state_hash, snapshotId=binding['snapshot_id'], priority=priority)


def publish(run: int, product: int, qty: int, known: str,
            original_due: str, results: list[dict], attempts: list[dict],
            source: Path, folder: Path, status: str) -> None:
    """Atomically replace only this one A/B offer group; back up prior rows to JSON."""
    if not results or results[0]['slot'] != 'A':
        raise ValueError('The A1/A2/C storage group is required before publication.')
    if len(results) > 2 or (len(results) == 2 and results[1]['slot'] != 'B'):
        raise ValueError('Only A and the first chosen B may be published.')
    if len({r['baseStateHash'] for r in results}) != 1:
        raise ValueError('Candidate plans do not share the exact same opening state.')

    details = {
        'schema': 'companyx.earliest-day-search.v1',
        'policy': 'PRESERVE_ALL_OLD_DUE_DATES_FIRST_FULL_DELIVERY',
        'status': status,
        'openingSource': str(source),
        'openingStateHash': results[0]['baseStateHash'],
        'attempts': attempts,
        'selectedDue': results[1]['due'] if len(results) == 2 else (
            original_due if status == 'ORIGINAL_DUE_ACCEPTED_WITH_OLD_COMMITMENTS' else None),
        'note': 'Searches the first date MILP voluntarily ships the full new order while every known old order is constrained on time.',
    }
    rows = [dict(result, search=details) for result in results]
    where = '''BaseRunKey=? AND ProductID=? AND Quantity=? AND KnownAt=? AND OriginalDue=?'''
    key = (run, product, qty, known, original_due)
    with sql('SIM', autocommit=False) as cn:
        # Freeze only the targeted offer group while it is replaced.
        prior = cn.execute(
            f'SELECT DueAt,Slot,PlanJSON FROM cxdetail.DayOfferPlan WITH(UPDLOCK,HOLDLOCK) '
            f'WHERE {where}', *key
        ).fetchall()
        save(folder / 'previous_day_offers.json', [
            {'due': str(row[0]), 'slot': str(row[1]).strip(),
             'plan': json.loads(row[2])} for row in prior
        ])
        cn.execute(f'DELETE FROM cxdetail.DayOfferPlan WHERE {where}', *key)
        for result in rows:
            cn.execute('''INSERT INTO cxdetail.DayOfferPlan
                (BaseRunKey,ProductID,Quantity,KnownAt,OriginalDue,DueAt,Slot,PlanJSON)
                VALUES (?,?,?,?,?,?,?,?)''',
                run, product, qty, known, original_due, result['due'], result['slot'],
                json.dumps(result, ensure_ascii=False, separators=(',', ':'), allow_nan=False))
        cn.commit()
    save(folder / 'selected_result.json', {'status': status, 'offers': rows})


def run_search(run: int, product: int, qty: int, known: str,
               due: str, max_days: int, folder: Path, source_override: Path | None) -> None:
    known_date = date.fromisoformat(known)
    original_due = date.fromisoformat(due)
    if qty <= 0 or run <= 0 or product <= 0 or max_days < 0 or max_days > 90:
        raise ValueError('run/product/qty must be positive and max-days must be 0..90.')
    if original_due < known_date:
        raise ValueError('Due date must not precede the date the order was known.')
    binding = validate_input()
    from rop_checkpoints import lookup, request_base
    source = Path(source_override or lookup(run,known,binding)).resolve()
    if source.is_file():
        original, baseline_end = request_base(source,run,known,binding)
    else:
        if not source.is_relative_to(OUTPUT / 'runs') or not source.is_dir():
            raise ValueError('Opening candidate must be an existing run under GPT/output/.../runs.')
        scope = read(source / 'scope.json')
        if (scope.get('known_at') != known or int(scope.get('base_run_key', -1)) != run
                or scope.get('candidate_kind') != 'BASELINE'
                or scope.get('synthetic_orders')
                or read(source / 'prefix_proof.json').get('status') != 'PASSED'
                or read(source.parents[2] / 'input_binding.json') != binding):
            raise ValueError('Opening BASELINE does not match run, known date or current ACT snapshot.')
        original = read(source.parents[2] / 'request.json')
        if (original['known_at'] != known or original['base_run_key'] != run
                or original.get('initialization_mode') != 'BASELINE_AT_START'):
            raise ValueError('Opening request is incompatible with this search.')
        # Extend the inquiry analysis window, if needed, only up to the VERIFIED
        # full-history ROP baseline end. All dates share this one fixed end date.
        baseline_end = date.fromisoformat(scope['original_base_end'])
    last_day = min(baseline_end, original_due + timedelta(days=max_days))
    if last_day < original_due:
        raise ValueError('Original deadline is beyond the verified ROP baseline end.')
    original['analysis_end'] = max(
        date.fromisoformat(original['analysis_end']), last_day
    ).isoformat()

    # A1/A2 and B share the verified opening state; B protects all old deadlines.
    from parallel_offers import run as parallel_run
    request = request_for_day(original, product, qty, original_due, 'A')
    progress(folder, state='running', tested=0, currentDue=due,
             message='Dang toi uu A1/A2/C va tim B giu dung han toan bo don cu.')
    priority, b = parallel_run(source, request, folder/'parallel',
                               max_days=(last_day-original_due).days)
    results = [offer_group(priority, qty, known, due, binding)]
    attempts = b['search']['attempts']
    if b['status'] != 'NO_B':
        if (b['status'] != 'OPTIMAL' or b.get('snapshotId') != binding['snapshot_id']
                or b.get('baseStateHash') != results[0]['baseStateHash']
                or (b.get('plannedShip'), b.get('plannedLoss')) != (qty, 0)):
            raise ValueError('Invalid verified B settlement or source identity.')
        selected_due = b['due']
        if selected_due != due:
            b['slot'] = 'B'
            results.append(b)
        status = 'FIRST_FULL_DELIVERY_WITH_OLD_COMMITMENTS' if selected_due != due else 'ORIGINAL_DUE_ACCEPTED_WITH_OLD_COMMITMENTS'
    else:
        selected_due = None
        status = 'NO_B_WITH_OLD_COMMITMENTS_WITHIN_WINDOW'
    publish(run, product, qty, known, due, results, attempts, source, folder, status)
    progress(folder, state='done', tested=len(attempts), totalDays=len(attempts),
             currentDue=selected_due or str(last_day), foundDue=selected_due,
             message='Da luu A1/A2/C; B chi duoc nhan khi giu dung han toan bo don cu.')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=int, required=True)
    parser.add_argument('--product', type=int, required=True)
    parser.add_argument('--qty', type=int, required=True)
    parser.add_argument('--known', required=True)
    parser.add_argument('--due', required=True)
    parser.add_argument('--max-days', type=int, default=45)
    parser.add_argument('--folder', type=Path, required=True)
    parser.add_argument('--prepare-opening', action='store_true', help='Ensure a verified daily ROP checkpoint family exists; never republish historical facts')
    parser.add_argument('--source', type=Path, help='Optional verified no-inquiry BASELINE artifact folder')
    args = parser.parse_args()
    folder = args.folder.resolve()
    if not (folder.is_relative_to(GPT) and folder != GPT):
        parser.error('--folder must be under GPT')
    folder.mkdir(parents=True, exist_ok=True)
    os.environ['PYTHONPATH'] = str(Path(__file__).resolve().parents[2] / 'DSS/runtime/src')
    license_file = Path(r'E:\Gurobi\gurobi.lic')
    if license_file.exists():
        os.environ.setdefault('GRB_LICENSE_FILE', str(license_file))
    try:
        if args.prepare_opening and args.source is None:
            from rop_checkpoints import lookup
            progress(folder,state='running',message='Dang nap checkpoint ROP da xac minh tu SIM.')
            args.source = lookup(args.run,args.known,validate_input(),prepare=True)
        run_search(args.run, args.product, args.qty, args.known, args.due,
                   args.max_days, folder, args.source)
        return 0
    except BaseException as exc:
        save(folder / 'progress.json', {'state': 'failed', 'message': str(exc)})
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

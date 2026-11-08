"""Find the first deadline on which the unchanged MILP chooses to ship the FULL inquiry order.

No forcing of order_ship or change to the optimizer objective. Every candidate is
solved independently from the same verified, frozen ROP decision state.
A1/A2/C priority plans are prepared after the deadline search and saved in the same SIM offer group.
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
from day_offer_plan import solve, validate_input


def progress(folder: Path, **fields):
    save(folder / 'progress.json', fields)
    detail = fields.get('message') or fields.get('state', '')
    print(detail, flush=True)


def find_opening_source(run: int, known: str, binding: dict) -> Path:
    """Find an existing, verified, no-inquiry decision at KnownAt for this ROP run."""
    root = OUTPUT / 'runs'
    matches = []
    for file in sorted(root.glob('*/candidates/*/artifacts/scope.json')):
        try:
            scope = read(file)
            source = file.parent
            if not (scope.get('candidate_kind') == 'BASELINE'
                    and scope.get('initialization_mode') == 'BASELINE_AT_START'
                    and scope.get('known_at') == known
                    and int(scope.get('base_run_key', -1)) == run
                    and not scope.get('synthetic_orders')):
                continue
            if read(source / 'prefix_proof.json').get('status') != 'PASSED':
                continue
            if read(source.parents[2] / 'input_binding.json') != binding:
                continue
            matches.append(source)
        except (OSError, ValueError, KeyError, TypeError):
            continue
    if not matches:
        raise ValueError(
            'Chua co nhanh BASELINE khong don moi da duoc xac minh tai ngay biet don '
            f'{known} cho RunKey={run}, hoac snapshot ACT da thay doi. '
            'Can chay inquiry BASELINE truoc, theo pipeline hien co.'
        )
    return matches[-1]


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


def one_day(source: Path, original: dict, binding: dict, folder: Path,
            product: int, qty: int, due: date, slot: str, decision_day: int) -> dict:
    request = request_for_day(original, product, qty, due, slot)
    results = solve(source, request, folder, binding)
    if len(results) != 1:
        raise ValueError('The per-day solve must produce exactly one FULL candidate.')
    result = results[0]
    decision_file = folder / request['candidates'][1]['candidate_id'] / 'decisions' / f'{decision_day:04d}.json'
    decision = read(decision_file)
    if decision['solver']['status'] != 'OPTIMAL':
        raise RuntimeError(f"Day {due}: solver status {decision['solver']['status']} is not OPTIMAL; "
                           'cannot assert earliest under this objective.')
    if result['plannedShip'] + result['plannedLoss'] != qty:
        raise ValueError('Invalid complete settlement returned by the MILP.')
    result['slot'] = slot  # The SIM table has a CHAR(1) Slot ('A' or 'B').
    return result


def prepare_priority(source, original, product, qty, due, folder):
    from priority_offer_plan import run as run_priority
    request = request_for_day(original, product, qty, date.fromisoformat(due), 'A')
    run_priority(source, request, folder / 'priority')


def publish(run: int, product: int, qty: int, known: str,
            original_due: str, results: list[dict], attempts: list[dict],
            source: Path, folder: Path, status: str) -> None:
    """Atomically replace only this one A/B offer group; back up prior rows to JSON."""
    if not results or results[0]['slot'] != 'A':
        raise ValueError('A must be evaluated before publication.')
    if len(results) > 2 or (len(results) == 2 and results[1]['slot'] != 'B'):
        raise ValueError('Only A and the first chosen B may be published.')
    if len({r['baseStateHash'] for r in results}) != 1:
        raise ValueError('Candidate plans do not share the exact same opening state.')

    details = {
        'schema': 'companyx.earliest-day-search.v1',
        'policy': 'UNMODIFIED_MILP_FIRST_FULL_DELIVERY',
        'status': status,
        'openingSource': str(source),
        'openingStateHash': results[0]['baseStateHash'],
        'attempts': attempts,
        'selectedDue': results[1]['due'] if len(results) == 2 else (
            original_due if results[0]['plannedShip'] == qty else None),
        'note': 'Searches the first date the unchanged optimal MILP voluntarily ships the full order.',
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
    source = source_override or find_opening_source(run, known, binding)
    source = source.resolve()
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

    # Same day index, source and binding for every candidate (no chaining).
    day_index = (known_date - date.fromisoformat(scope['start'])).days
    attempts: list[dict] = []
    results: list[dict] = []
    progress(folder, state='running', totalDays=(last_day-original_due).days + 1,
             tested=0, currentDue=due, message='Da khoa mot trang thai ROP chung. Bat dau thu han goc.')

    for n in range((last_day - original_due).days + 1):
        candidate_due = original_due + timedelta(days=n)
        slot = 'A' if n == 0 else 'B'
        test_dir = folder / 'trials' / candidate_due.isoformat()
        progress(folder, state='testing', tested=n, currentDue=str(candidate_due),
                 totalDays=(last_day-original_due).days+1,
                 message=f'Dang toi uu han {candidate_due.isoformat()} ({n+1} ngay da xet).')
        result = one_day(source, original, binding, test_dir,
                         product, qty, candidate_due, slot, day_index)
        entry = {'due': str(candidate_due), 'solverStatus': 'OPTIMAL',
                 'plannedShip': result['plannedShip'], 'plannedLoss': result['plannedLoss'],
                 'baseStateHash': result['baseStateHash']}
        if attempts and attempts[0]['baseStateHash'] != entry['baseStateHash']:
            raise ValueError('The state changed between deadline attempts.')
        attempts.append(entry)
        if n == 0:
            results.append(result)
        if result['plannedShip'] == qty and result['plannedLoss'] == 0:
            if n > 0:
                results.append(result)
            status = 'ORIGINAL_DUE_ACCEPTED' if n == 0 else 'FIRST_FULL_DELIVERY_FOUND'
            publish(run, product, qty, known, due, results, attempts, source, folder, status)
            prepare_priority(source, original, product, qty, due, folder)
            progress(folder, state='done', tested=len(attempts), totalDays=len(attempts),
                     currentDue=str(candidate_due), foundDue=str(candidate_due),
                     message=f'MILP tu chon giao du lan dau vao {candidate_due.isoformat()}.')
            return
    publish(run, product, qty, known, due, results, attempts, source, folder, 'NOT_FOUND_WITHIN_WINDOW')
    prepare_priority(source, original, product, qty, due, folder)
    progress(folder, state='done', tested=len(attempts), totalDays=len(attempts),
             currentDue=str(last_day), foundDue=None,
             message=f'Chua tim duoc ngay MILP tu giao du trong khoang den {last_day}.')


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--run', type=int, required=True)
    parser.add_argument('--product', type=int, required=True)
    parser.add_argument('--qty', type=int, required=True)
    parser.add_argument('--known', required=True)
    parser.add_argument('--due', required=True)
    parser.add_argument('--max-days', type=int, default=45)
    parser.add_argument('--folder', type=Path, required=True)
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
        run_search(args.run, args.product, args.qty, args.known, args.due,
                   args.max_days, folder, args.source)
        return 0
    except BaseException as exc:
        save(folder / 'progress.json', {'state': 'failed', 'message': str(exc)})
        traceback.print_exc()
        return 1


if __name__ == '__main__':
    raise SystemExit(main())

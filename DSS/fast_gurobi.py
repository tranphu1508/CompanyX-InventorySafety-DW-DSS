"""Gurobi child for the SSIS simulation and MOLAP inquiry, using the original solve files."""
import gzip
import hashlib
import math
import os
from pathlib import Path
import pickle
import shutil
import sys
import time
import traceback
from types import SimpleNamespace

import gurobipy as gp
import numpy as np

from fast_formulation import strengthen
from native_path_worker import acceleration_identity

sys.path.insert(0, str(Path(__file__).resolve().parent / 'runtime/src'))
from companyx_unified_v2.cplex_solver import validate
from companyx_unified_v2.gurobi_solver import accepted_status, build_native, finite
from companyx_unified_v2.legacy import read, save

OPERATING = {'q', 'a', 'buy', 'lot_count'}


def shifted_hints(source, folder):
    day_folder = folder.parent if folder.name.startswith('attempt_') else folder
    if day_folder.parent.name != 'solves' or not day_folder.name.isdigit():
        return {}, None
    run = day_folder.parent.parent
    day = int(day_folder.name) - 1
    decision = run / 'decisions' / f'{day:04d}.json'
    if day < 0 or not decision.is_file():
        return {}, None
    last = read(decision)
    path = (run / last['solution_reference']).resolve()
    if (last['day'] != day or not path.is_relative_to(run / 'solves')
            or hashlib.sha256(path.read_bytes()).hexdigest() != last['solution_sha256']):
        raise ValueError('Previous accepted decision/solution identity mismatch')
    values = np.load(path, allow_pickle=False)
    with gzip.open(path.parent / 'request.pkl.gz', 'rb') as stream:
        keys = pickle.load(stream)['model']['keys']
    if len(keys) != len(values):
        raise ValueError('Previous request and solution have different columns')
    # All MOLAP operating keys put the relative day at position 2, including buy and lot_count.
    hints = {}
    for key, value in zip(keys, values):
        if key[0] in OPERATING and key[2] > 0:
            key = (*key[:2], key[2] - 1, *key[3:])
            j = source.index.get(key)
            if j is not None and source.lb[j] <= value <= source.ub[j]:
                hints[j] = float(value)
    return hints, last['solution_sha256']


def balance_start(source):
    """Try no new activity and settle each balance, using the supplied model's own recurrences."""
    z = np.zeros(len(source.keys))
    for j, key in enumerate(source.keys):
        if key[0] == 'order_loss':
            z[j] = 1
    targets = {'inventory': 'I', 'raw_inventory': 'raw_I', 'Ba': 'Ba', 'Bf': 'Bf',
               'raw_forecast': 'raw_Bf'}
    for label, row, rhs in zip(source.labels, source.rows, source.lo):
        kind = targets.get(label)
        if kind:
            j = next((j for j, a in row.items() if a == 1 and source.keys[j][0] == kind), None)
            if j is None:
                return None
            z[j] = rhs - sum(a * z[i] for i, a in row.items() if i != j)
    for j, key in enumerate(source.keys):
        if key[0] == 'material_short':
            _, child, amount, k = key
            stock = source.index.get(('I', child, k), source.index.get(('raw_I', child, k)))
            z[j] = float(z[stock] < amount)
    try:
        return validate(source, z)[0]
    except ValueError:
        return None  # Open production/commitments may need a repaired start.


class NativeRun:
    def __init__(self, folder):
        self.folder = folder
        self.seconds = 0.0
        self.stop_reason = None
        self.skipped_samples = 0

    def guard(self):
        if (self.folder / 'STOP').exists():
            self.stop_reason = 'STOP_REQUESTED'
        elif shutil.disk_usage(self.folder).free < 10 * 2**30:
            self.stop_reason = 'LOW_DISK'
        return self.stop_reason

    def optimize(self, model, stage):
        if self.guard():
            raise InterruptedError(self.stop_reason)
        start = time.perf_counter()
        last_tick = -math.inf
        obj = bound = None
        def callback(m, where):
            nonlocal last_tick, obj, bound
            now = time.perf_counter()
            if where == gp.GRB.Callback.MIP:
                obj = finite(m.cbGet(gp.GRB.Callback.MIP_OBJBST))
                bound = finite(m.cbGet(gp.GRB.Callback.MIP_OBJBND))
            if now - last_tick < 3:
                return
            last_tick = now
            try:
                if self.guard():
                    m.terminate()
                gap = None if obj is None or bound is None else abs(obj-bound) / max(abs(obj), 1e-10)
                save(self.folder/'native_progress.json', dict(pid=os.getpid(), stage=stage,
                     updated_epoch=time.time(), solver_seconds=self.seconds+now-start,
                     objective=obj, best_bound=bound, relative_gap=gap, stop_reason=self.stop_reason))
            except PermissionError as error:
                if getattr(error, 'winerror', None) in (5, 32) and self.stop_reason is None:
                    self.skipped_samples += 1
                else:
                    self.stop_reason = str(error)
                    m.terminate()
            except Exception as error:
                self.stop_reason = str(error)
                m.terminate()
        try:
            model.optimize(callback)
        finally:
            self.seconds += time.perf_counter() - start
        if self.stop_reason:
            raise InterruptedError(self.stop_reason)


def prepare_start(native, source, hints, timer, budget):
    best = balance_start(source)
    best_obj = float(np.dot(source.cost, best)) if best is not None else math.inf
    origin = 'BALANCE' if best is not None else 'NONE'
    attempts = []
    cap = min(30.0, 0.2 * budget)
    if hints:
        for release_starts in (False, True):
            allowance = min(cap-timer.seconds, cap if release_starts else cap / 2)
            if allowance < .05:
                break
            fixed = {j: v for j, v in hints.items() if not release_starts or source.keys[j][0] != 'a'}
            if not fixed:
                break
            with native.copy() as sub:
                sub.Params.LogFile = 'repair_%d.log' % (len(attempts) + 1)
                sub.Params.TimeLimit = allowance
                sub.Params.MIPFocus = 1
                sub.Params.SolutionLimit = 1
                variables = sub.getVars()
                selected = [variables[j] for j in fixed]
                sub.setAttr('LB', selected, list(fixed.values()))
                sub.setAttr('UB', selected, list(fixed.values()))
                timer.optimize(sub, 'START_REPAIR')
                attempts.append(dict(fixed=len(fixed), status=sub.Status, solutions=sub.SolCount))
                if sub.SolCount:
                    try:
                        z, checks = validate(source, sub.getAttr('X'))
                    except ValueError:
                        continue
                    if checks['objective'] <= best_obj:
                        best, best_obj, origin = z, checks['objective'], 'REPAIRED_PREVIOUS_DAY'
                    break
    return best, dict(source=origin, hints=len(hints), attempts=attempts, solver_seconds=timer.seconds,
                      objective=best_obj if best is not None else None, full_start_validated=best is not None)


def solve(original, settings, folder, timer):
    if settings['name'] != 'GUROBI':
        raise ValueError('Expected a Gurobi execution spec')
    start = time.perf_counter()
    source, report = strengthen(original)
    hints, previous = shifted_hints(source, folder)
    report['strengthen_and_hint_seconds'] = time.perf_counter() - start
    budget = settings['time_limit_seconds']
    with gp.Env(empty=True) as env:
        env.setParam('OutputFlag', 0)
        env.start()
        native, x, matrix, groups = build_native(source, env)
        del matrix, groups
        with native:
            p = native.Params
            p.LogToConsole = 0
            p.LogFile = 'native.log'
            p.OutputFlag = 1
            p.Threads, p.Seed = settings['threads'], settings['seed']
            p.MIPGap, p.MIPGapAbs = settings['relative_gap'], settings['absolute_gap']
            p.IntFeasTol, p.FeasibilityTol = 1e-6, 1e-7
            (folder/'nodes').mkdir(exist_ok=True)
            p.NodefileStart, p.NodefileDir = 2.0, 'nodes'
            spec_hash = acceleration_identity()
            save(folder/'phase.json', dict(status='START_REPAIR', pid=os.getpid(), solver='GUROBI',
                 started_epoch=time.time(), settings=settings))
            seed, repair = prepare_start(native, source, hints, timer, budget)
            repair['previous_solution_sha256'] = previous
            if seed is not None:
                x.Start = seed
            elif hints:
                # Gurobi may complete this partial start within the main solve's native budget.
                partial = np.full(len(source.keys), gp.GRB.UNDEFINED)
                for j, value in hints.items():
                    partial[j] = value
                x.Start = partial
                repair['source'] = 'PARTIAL_PREVIOUS_DAY'
            p.TimeLimit = max(0.0, budget-timer.seconds)
            p.MIPFocus = 3
            params = dict(Threads=p.Threads, TimeLimit=p.TimeLimit, MIPGap=p.MIPGap, MIPGapAbs=p.MIPGapAbs,
                          Seed=p.Seed, ConcurrentMIP=p.ConcurrentMIP, MIPFocus=p.MIPFocus, Method=p.Method,
                          NodefileStart=p.NodefileStart, warm_start_count=int(seed is not None or bool(hints)),
                          repair120=False, daily_native_budget=budget, repair_native_seconds=timer.seconds)
            save(folder/'structure.json', dict(columns=native.NumVars, rows=native.NumConstrs,
                 integers=native.NumIntVars, original_rows=len(original.rows),
                 original_columns=len(original.keys), full_model=True))
            save(folder/'phase.json', dict(status='SOLVING', pid=os.getpid(), solver='GUROBI',
                 version=list(gp.gurobi.version()), started_epoch=time.time(), settings=settings, native_settings=params))
            load_seconds = time.perf_counter()-start-timer.seconds
            timer.optimize(native, 'SOLVING')
            status, accepted = accepted_status(native.Status, native.SolCount)
            try:
                bound = finite(native.ObjBound)
            except (AttributeError, gp.GurobiError):
                bound = None
            result = dict(solver='GUROBI', version=list(gp.gurobi.version()), native_status_code=native.Status,
                          status=status, accepted=accepted, has_feasible_solution=bool(native.SolCount),
                          solver_seconds=timer.seconds, main_solver_seconds=timer.seconds-repair['solver_seconds'],
                          load_seconds=load_seconds, settings=settings, native_settings=params, stop_reason=None,
                          objective=None, best_bound=bound, relative_gap=None, action_source='NONE',
                          node_count=native.NodeCount, acceleration=report, acceleration_identity=spec_hash,
                          mip_start=repair, skipped_progress_samples=timer.skipped_samples)
            z = None
            if native.SolCount:
                z, _ = validate(source, x.X)
                z, checks = validate(original, z)
                if abs(checks['objective']-native.ObjVal) > 1e-6 * max(1, abs(native.ObjVal)):
                    raise ValueError('Transferred objective mismatch')
                result.update(checks, relative_gap=finite(native.MIPGap), original_model_checked=True)
            if accepted:
                result['action_source'] = 'SOLVER_INCUMBENT'
            save(folder/'solver.json', result)
            if not accepted:
                raise RuntimeError('Gurobi solution not accepted: '+status)
            return z, result


def main():
    folder = Path(sys.argv[1]).resolve()
    os.chdir(folder)  # Gurobi native log/spill paths must be relative on localized Windows.
    timer = NativeRun(folder)
    try:
        with gzip.open(folder/'request.pkl.gz', 'rb') as stream:
            request = pickle.load(stream)
        z, result = solve(SimpleNamespace(**request['model']), request['settings'], folder, timer)
        np.save(folder/'solution.npy', z, allow_pickle=False)
        save(folder/'done.json', result)
    except BaseException as error:
        if not (folder/'solver.json').exists():
            save(folder/'solver.json', dict(solver='GUROBI', status='INTERRUPTED' if timer.stop_reason else 'ERROR',
                 accepted=False, has_feasible_solution=False, action_source='NONE', error=str(error),
                 stop_reason=timer.stop_reason, solver_seconds=timer.seconds))
        save(folder/'error.json', dict(error=str(error), traceback=traceback.format_exc()))
        raise


if __name__ == '__main__':
    main()

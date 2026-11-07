"""Simulation entry point for SSIS. No SQL connection, ETL or DW publication."""
import argparse, copy, hashlib, json, sys, os, shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'DSS'))
from input_validation import validate_before_simulation
from native_path_worker import acceleration_identity, gurobi_native_paths, validate_native_path_support
RUNTIME_SRC = str(ROOT / 'DSS/runtime/src')
sys.path.insert(0, RUNTIME_SRC)
# Solver workers use `python -m`; sys.path edits do not reach child processes.
os.environ['PYTHONPATH'] = os.pathsep.join(
    [RUNTIME_SRC] + ([os.environ['PYTHONPATH']] if os.environ.get('PYTHONPATH') else [])
)
os.environ['PYTHONUTF8'] = '1'
from companyx_unified_v2.legacy import read, save, verify_release, canonical, digest
from companyx_unified_v2.config import resolve
from companyx_unified_v2.run import execute, code_hash, sha
from companyx_unified_v2.inputs import prepare

def main():
    p = argparse.ArgumentParser()
    p.add_argument('--folder', required=True)
    p.add_argument('--policy', choices=['ROP', 'QUETSCHLICH_ADAPT'], required=True)
    p.add_argument('--solver', choices=['CPLEX', 'GUROBI'], required=True)
    p.add_argument('--timing', choices=['LEGACY_REQUEST_DATE', 'ACTUAL_START_DATE'], required=True)
    p.add_argument('--scenario', type=int, default=1)
    p.add_argument('--gurobi-license', default='')
    a = p.parse_args()
    if a.policy == 'QUETSCHLICH_ADAPT' and a.solver == 'GUROBI' and a.gurobi_license:
        if not Path(a.gurobi_license).is_file(): raise ValueError('Gurobi license path does not exist')
        os.environ['GRB_LICENSE_FILE'] = a.gurobi_license
    folder = Path(a.folder).resolve()
    native_paths = (a.policy == 'QUETSCHLICH_ADAPT' and a.solver == 'GUROBI'
                    and os.name == 'nt' and not str(folder).isascii())
    if a.policy == 'QUETSCHLICH_ADAPT' and a.solver == 'GUROBI':
        if native_paths:
            validate_native_path_support()
        if shutil.disk_usage(folder).free < 10 * 2**30:
            raise ValueError('Gurobi requires at least 10 GiB free on the output drive; the unchanged core also enforces this limit.')
    verify_release()
    validate_before_simulation(folder, ROOT)
    proof = read(folder / 'dw_source_proof.json')
    if proof['status'] != 'VERIFIED' or sha(folder/'input_source.json') != proof['snapshot_file_sha256']:
        raise ValueError('SSIS input proof missing or changed')
    matrix = read(ROOT/'DSS/all_four_matrix.json')
    if not 1 <= a.scenario <= len(matrix['scenarios']):
        raise ValueError('Scenario index outside supplied matrix')
    scenario = copy.deepcopy(matrix['scenarios'][a.scenario-1])
    name = scenario.pop('name')
    initial_rule = scenario.pop('initial_state_rule', 'APPROVED_ON_HAND_ZERO_OTHER')
    scenario.update(policy=a.policy, replication=0, production_lead_time_mode=a.timing)
    scenario['solver']['name'] = a.solver
    spec = resolve(scenario)
    snapshot = read(folder/'input_source.json')
    data = prepare(snapshot, spec)
    owned = set(data['P']) | set(data['raw'])
    for product in snapshot['products']:
        pid = product['ProductID']
        if pid not in owned or initial_rule == 'ZERO': qty = 0
        elif initial_rule == 'REORDER_POINT': qty = product['ReorderPointQty']
        elif initial_rule == 'SAFETY_STOCK_LEVEL': qty = product['SafetyStockQty']
        elif initial_rule == 'MIDPOINT_CEIL': qty = (product['ReorderPointQty'] + product['SafetyStockQty'] + 1)//2
        elif initial_rule == 'APPROVED_ON_HAND_ZERO_OTHER': qty = product['InitialQty']
        else: raise ValueError('Unsupported initial state')
        if int(qty) != qty or qty < 0: raise ValueError('Invalid initial quantity')
        product['InitialQty'] = int(qty)
        if product['IsManufactured']: product['ManufacturingParameters']['initial'] = int(qty)
    selection = dict(policy=a.policy, solver=a.solver, timing=a.timing, scenario=a.scenario,
                     initial_state_rule=initial_rule, source_sha256=proof['snapshot_file_sha256'])
    accelerated = a.policy == 'QUETSCHLICH_ADAPT' and a.solver == 'GUROBI'
    if accelerated:
        selection['gurobi_acceleration'] = acceleration_identity()
    if (folder/'completion.json').exists():
        if read(folder/'simulation_selection.json') != selection: raise ValueError('Completed run belongs to different parameters')
        run = read(folder/'run.json')
        if run['input_sha256'] != digest(snapshot) or run['execution_spec_sha256'] != digest(spec) or run['code_sha256'] != code_hash():
            raise ValueError('Completed run identity changed')
        print('ALREADY_COMPLETE; simulation not rerun')
        return
    if (folder/'run.json').exists(): raise ValueError('Incomplete run retained. No automatic restart or replay.')
    save(folder/'simulation_selection.json', selection)
    with gurobi_native_paths(folder, enabled=native_paths, accelerate=accelerated):
        execute(snapshot, spec, folder, name=name + ' / ' + a.policy)
    # Canonical exports are model provenance, not database operations.
    for filename in ('input_source.json', 'input.json', 'execution_spec.json', 'execution_profile.json', 'run.json'):
        (folder/(filename+'.canonical')).write_text(canonical(read(folder/filename)), encoding='utf-8')
    save(folder/'simulation_export.json', dict(status='COMPLETE', schema='companyx.ssis.native.v1',
         selection=selection, core_sha256=code_hash(), completion_sha256=sha(folder/'completion.json'),
         canonical_files={f: sha(folder/(f+'.canonical')) for f in ('input_source.json','input.json','execution_spec.json','execution_profile.json','run.json')}))
    print('SIMULATION_COMPLETE; SSIS may validate and publish results')

if __name__ == '__main__': main()

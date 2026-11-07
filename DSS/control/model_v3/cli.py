"""Corrected standalone MILP entrypoint, including future finite procurement.

Usage: python -B -m model_v3.cli --input snapshot.json --spec spec.json
       --output <Project/GPT/dedicated-run> [--validate-only]
No finite scenarios are added to the active Power BI demo by this entrypoint.
"""
import argparse
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True)
    parser.add_argument('--spec', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--project-root')
    parser.add_argument('--name')
    parser.add_argument('--validate-only', action='store_true')
    args = parser.parse_args(argv)
    from simulation.adapter import runtime
    from .release import prepare_snapshot, activate
    from .forecast import get_resale_forecast
    project, demo, config, inputs, legacy, run, _ = runtime(args.project_root)
    folder = Path(args.output).resolve()
    if folder == project / 'GPT' or not folder.is_relative_to(project / 'GPT'):
        raise ValueError('Corrected execution output must be a dedicated Project/GPT directory')
    snapshot = legacy.read(args.input)
    spec = config.resolve(legacy.read(args.spec))
    if spec['policy'] != 'QUETSCHLICH_ADAPT':
        raise ValueError('This entrypoint is for corrected MILP; preserve existing ROP baseline entrypoints')
    snapshot, identity, forecast = prepare_snapshot(snapshot, snapshot['start'], project)
    data = inputs.prepare(snapshot, spec)
    forecast_rates = get_resale_forecast(data, required=bool(data['raw']), as_of=data['start'])
    validation = {'status': 'VALID', 'optimizer_release': identity,
        'manufactured_products': len(data['P']), 'finite_purchased_products': len(data['raw']),
        'resale_forecast_products': len(forecast_rates), 'forecast_provenance': forecast,
        'frozen_physical_core_sha256': run.code_hash(), 'native_solver_called': False}
    if args.validate_only:
        print(json.dumps(validation, ensure_ascii=False))
        return validation
    if folder.exists() and any(folder.iterdir()):
        raise ValueError('Use an empty dedicated run folder; historical runs/checkpoints are immutable')
    folder.mkdir(parents=True, exist_ok=True)
    legacy.save(folder / 'corrected_preflight.json', validation)
    legacy.save(folder / 'optimizer_release.json', identity)
    legacy.save(folder / 'input_source.json', snapshot)
    temp = folder / 'tmp'
    temp.mkdir()
    old_env = {k: os.environ.get(k) for k in ('PYTHONPATH', 'TMP', 'TEMP', 'GRB_LICENSE_FILE')}
    os.environ['TMP'] = os.environ['TEMP'] = str(temp)
    paths = [str(Path(__file__).resolve().parents[1]), str(demo / 'DSS/runtime/src')]
    if old_env['PYTHONPATH']:
        paths.append(old_env['PYTHONPATH'])
    os.environ['PYTHONPATH'] = os.pathsep.join(paths)
    if not os.environ.get('GRB_LICENSE_FILE') and Path(r'E:\Gurobi\gurobi.lic').is_file():
        os.environ['GRB_LICENSE_FILE'] = r'E:\Gurobi\gurobi.lic'
    from native_path_worker import gurobi_native_paths
    try:
        legacy.verify_release()
        enabled = spec['solver']['name'] == 'GUROBI' and os.name == 'nt' and not str(folder).isascii()
        with activate(run, identity, project), gurobi_native_paths(folder, enabled=enabled):
            metrics = run.execute(snapshot, spec, folder, name=args.name or 'CompanyX corrected MILP v3')
        receipt = {'schema': 'companyx.corrected.execution.v1', 'status': 'COMPLETE',
            'optimizer_release': identity, 'frozen_physical_core_sha256': run.code_hash(),
            'RunCode': legacy.read(folder / 'run.json')['RunCode'], 'metrics': metrics,
            'historical_results_modified': False}
        legacy.save(folder / 'corrected_execution_receipt.json', receipt)
        print(json.dumps(receipt, ensure_ascii=False))
        return receipt
    finally:
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value


if __name__ == '__main__':
    main()

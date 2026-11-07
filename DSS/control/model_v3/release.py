"""Explicit corrected optimizer release over the preserved physical DSS runtime.

The original runtime remains the provenance authority for historical ROP runs.
New MILP execution selects this release explicitly and binds every source file
and the frozen resale forecast artifact into its separate model identity.
"""
from contextlib import contextmanager
from copy import deepcopy
from pathlib import Path
import hashlib
import json
import threading
from . import MODEL_VERSION

VERSION = MODEL_VERSION
_LOCK = threading.RLock()


def _digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
        separators=(',', ':'), allow_nan=False).encode('utf-8')).hexdigest()


def release_identity(project_root=None):
    from .forecast import artifact_identity
    from common import PROJECT, demo_folder
    folder = Path(__file__).resolve().parent
    required = {'__init__.py', 'optimizer.py', 'atomic_model.py', 'supply_model.py',
                'forecast.py', 'release.py', 'cli.py'}
    paths = sorted(folder.glob('*.py'))
    if required - {p.name for p in paths}:
        raise ValueError('Corrected optimizer release is incomplete')
    files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    solver_dir = demo_folder(project_root or PROJECT) / 'DSS'
    for name in ('native_path_worker.py', 'fast_formulation.py', 'fast_gurobi.py'):
        files['DSS/' + name] = hashlib.sha256((solver_dir / name).read_bytes()).hexdigest()
    forecast = artifact_identity(project_root)
    body = {'version': VERSION, 'files': files,
            'resale_forecast': {k: forecast[k] for k in ('schema', 'sha256', 'cutoff')}}
    return {**body, 'sha256': _digest(body),
            'historical_physical_runtime': 'companyx_unified_v2',
            'forecast_artifact_path': forecast['path']}


def prepare_snapshot(snapshot, known_at, project_root=None):
    from .forecast import prepare_snapshot as attach_forecast
    enriched, forecast = attach_forecast(snapshot, known_at, project_root)
    identity = release_identity(project_root)
    enriched = deepcopy(enriched)
    enriched.setdefault('metadata', {})['optimizer_release'] = identity
    return enriched, identity, forecast


def controller_factory():
    from .optimizer import Controller
    import inspect
    if not Path(inspect.getfile(Controller)).resolve().is_relative_to(Path(__file__).resolve().parent):
        raise ValueError('Corrected optimizer Controller import collision')
    return Controller


@contextmanager
def activate(run, expected_identity=None, project_root=None):
    """Select corrected MILP only in this process; restore references on exit."""
    with _LOCK:
        identity = release_identity(project_root)
        if expected_identity is not None and identity != expected_identity:
            raise ValueError('Corrected optimizer release changed since preparation')
        original = run.Controller
        run.Controller = controller_factory()
        try:
            yield identity
            if release_identity(project_root) != identity:
                raise ValueError('Corrected optimizer release changed during execution')
        finally:
            run.Controller = original

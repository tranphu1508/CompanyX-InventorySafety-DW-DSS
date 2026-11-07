"""Windows Unicode path adapter for the unchanged Gurobi solver worker.

Only native LogFile/NodefileDir strings are made relative to the worker's own
physical solve folder. Model construction, numerical parameters, callbacks,
solution validation and artifacts remain the responsibility of the core.
The parent adapter replaces optimizer.subprocess only, never subprocess itself.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
from importlib.metadata import version
import json
import os
from pathlib import Path
import sys

GUROBI_MODULE = 'companyx_unified_v2.gurobi_solver'
VERIFIED_GUROBI_VERSION = '13.0.3'


def acceleration_identity():
    folder = Path(__file__).resolve().parent
    names = ('native_path_worker.py', 'fast_formulation.py', 'fast_gurobi.py')
    files = {name: hashlib.sha256((folder / name).read_bytes()).hexdigest() for name in names}
    signature = hashlib.sha256(json.dumps(files, sort_keys=True).encode('utf-8')).hexdigest()
    return dict(version='companyx.molap.gurobi.fast.v1', sha256=signature, files=files)


def accelerated_command(folder):
    worker = Path(__file__).resolve().with_name('fast_gurobi.py')
    return [sys.executable, '-B', '-X', 'utf8', str(worker), str(Path(folder).resolve())]


def validate_native_path_support():
    """Fail before a run starts if the tested adapter/runtime is unavailable."""
    if os.name != 'nt':
        raise ValueError('The Gurobi native path adapter is for Windows only.')
    if version('gurobipy') != VERIFIED_GUROBI_VERSION:
        raise ValueError('Unicode Gurobi output paths require the verified gurobipy '
                         + VERIFIED_GUROBI_VERSION + ' runtime.')


class _WorkerSubprocess:
    """Delegate every operation except the exact existing Gurobi worker call."""
    def __init__(self, original, run_folder, accelerate=False):
        self._original = original
        self._run_folder = Path(run_folder).resolve()
        self._accelerate = accelerate

    def __getattr__(self, name):
        return getattr(self._original, name)

    def Popen(self, args, *positional, **keywords):
        if isinstance(args, (list, tuple)) and GUROBI_MODULE in args:
            if (len(args) != 4 or list(args[1:3]) != ['-m', GUROBI_MODULE]
                    or Path(args[0]).resolve() != Path(sys.executable).resolve()):
                raise ValueError('Unexpected Gurobi worker command; refusing an unverified launch.')
            folder = Path(args[3]).resolve()
            if not folder.is_relative_to(self._run_folder / 'solves'):
                raise ValueError('Gurobi solve folder is outside this simulation run.')
            if self._accelerate:
                args = accelerated_command(folder)
            else:
                args = [args[0], '-B', '-X', 'utf8', str(Path(__file__).resolve()),
                        '--folder', str(folder)]
        return self._original.Popen(args, *positional, **keywords)


@contextmanager
def gurobi_native_paths(run_folder, enabled=False, *, accelerate=False):
    """Route only Gurobi children in this run; other processes use their original command."""
    if not enabled and not accelerate:
        yield
        return
    if enabled:
        validate_native_path_support()
    from companyx_unified_v2 import optimizer
    original = optimizer.subprocess
    if isinstance(original, _WorkerSubprocess):
        raise ValueError('The Gurobi native path adapter is already active.')
    optimizer.subprocess = _WorkerSubprocess(original, run_folder, accelerate)
    try:
        yield
    finally:
        optimizer.subprocess = original


class _PathParameters:
    def __init__(self, original, folder):
        object.__setattr__(self, '_original', original)
        object.__setattr__(self, '_folder', folder)

    def __getattr__(self, name):
        return getattr(self._original, name)

    def __setattr__(self, name, value):
        if name in ('LogFile', 'NodefileDir'):
            target = Path(value).resolve()
            relative = 'native.log' if name == 'LogFile' else 'nodes'
            if target != self._folder / relative or Path.cwd().resolve() != self._folder:
                raise ValueError('Unexpected Gurobi native output path or working directory.')
            value = relative
        setattr(self._original, name, value)


def _gurobi_facade(gp, folder):
    # A public Model subclass preserves all native methods and objects. Only
    # its Params accessor adds the two filesystem translations above.
    class PathModel(gp.Model):
        def __getattribute__(self, name):
            value = super().__getattribute__(name)
            return _PathParameters(value, folder) if name == 'Params' else value

    class GurobiFacade:
        Model = PathModel

        def __getattr__(self, name):
            return getattr(gp, name)

    return GurobiFacade()


def run_worker(folder):
    validate_native_path_support()
    folder = Path(folder).resolve()
    if not (folder / 'request.pkl.gz').is_file():
        raise ValueError('The solver request is missing from the solve folder.')
    runtime = Path(__file__).resolve().parent / 'runtime/src'
    sys.path.insert(0, str(runtime))
    from companyx_unified_v2 import gurobi_solver as worker
    original_gp, original_cwd, original_argv = worker.gp, Path.cwd(), sys.argv
    try:
        worker.gp = _gurobi_facade(original_gp, folder)
        os.chdir(folder)
        sys.argv = [GUROBI_MODULE, str(folder)]
        worker.main()
    finally:
        worker.gp = original_gp
        os.chdir(original_cwd)
        sys.argv = original_argv


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--folder', required=True, type=Path)
    args = parser.parse_args()
    run_worker(args.folder)


if __name__ == '__main__':
    main()

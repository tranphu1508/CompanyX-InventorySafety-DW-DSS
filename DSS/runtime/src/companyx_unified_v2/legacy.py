"""Load the immutable release without importing its monkey-patching CLI.

Only read-only functions/classes are reused. No legacy function, weight, input,
module attribute, source file or result is replaced by this extension.
"""
from pathlib import Path
from datetime import date
import hashlib
import importlib
import json
import sys

GPT = Path(__file__).resolve().parents[2]
RELEASE = Path(__file__).resolve().parent / 'legacy_core'
ORIGINAL = GPT.parent / 'DSS/Output/CompanyX Inventory Optimization V1'
sys.dont_write_bytecode = True

def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))

def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, default=str,
                      separators=(',', ':'), allow_nan=False)

def digest(value):
    return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()

def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2,
                                    default=str, allow_nan=False), encoding='utf-8')
    temporary.replace(path)

def verify_release(root=RELEASE):
    manifest = read(root / 'manifest.json')
    for relative, expected in manifest['sha256'].items():
        actual = hashlib.sha256((root / relative).read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f'Immutable release changed: {root / relative}')
    return {'root': str(root), 'files_verified': len(manifest['sha256']),
            'manifest_sha256': hashlib.sha256((root/'manifest.json').read_bytes()).hexdigest()}

def module(name):
    allowed = {'companyx_nonopt_mid2013', 'companyx_bom_graph',
               'companyx_workorder_median', 'companyx_active_days'}
    if name not in allowed:
        raise ValueError(name)
    old_path = list(sys.path)
    try:
        sys.path.insert(0, str(RELEASE / 'code'))
        mod = importlib.import_module(name)
        for item in allowed & set(sys.modules):
            if Path(sys.modules[item].__file__).resolve() != (RELEASE/'code'/f'{item}.py').resolve():
                raise RuntimeError(f'Legacy namespace collision: {item}; use an isolated process')
        return mod
    finally:
        sys.path[:] = old_path

def inputs(group='nonopt'):
    raise ValueError('Portable runtime requires an explicit approved input snapshot or DW artifact; rebuilding from historical source is disabled')
    folder = RELEASE / 'data' / group
    protocol = read(folder/'protocol.json')
    params = {int(k): v for k, v in read(folder/'parameters.json').items()}
    orders = read(folder/'orders.json')
    for line in orders:
        for field in ('order', 'due', 'ship'):
            line[field] = date.fromisoformat(line[field][:10])
    return protocol, params, orders, read(folder/'active_edges.json'), read(folder/'topological_order.json')

def release_quantity(policy, ip, params, day):
    if policy == 'rp_safety':
        return params['ss'] - ip if ip < params['rp'] else 0
    return module('companyx_workorder_median').release_qty(policy, ip, params, day)

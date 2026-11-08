"""Operational demo scope; does not change simulation physics or cache identity."""
from pathlib import Path
from common import PROJECT,read

def read_active_scope(project_root=None):
    project=Path(project_root).resolve() if project_root else PROJECT
    policy=read(project/'RuntimeData/active-scope.json')
    for field in ('active_scenario_indices','active_baseline_matrix_indices'):
        values=policy.get(field)
        if type(values) is not list or any(type(value) is not int for value in values):
            raise ValueError('Active scope indices must be JSON integer arrays, excluding booleans')
    if (policy.get('schema')!='companyx.active-simulation-scope.v1'
        or policy.get('active_scenario_indices')!=[1,2]
        or policy.get('active_baseline_matrix_indices')!=[17,18]
        or policy.get('required_supply_mode')!='INSTANT_UNLIMITED'
        or policy.get('production_duration_policy')!='PRESERVE_EXISTING'):
        raise ValueError('Active scope must preserve production duration and allow only instantaneous procurement scenarios 1 and 2')
    return policy

def assert_active_scenario(value,project_root=None):
    policy=read_active_scope(project_root)
    if type(value) is not int or value not in policy['active_scenario_indices']:
        raise ValueError('Kịch bản có lead time mua linh kiện đã bỏ khỏi phạm vi nhóm. Chỉ nhận kịch bản 1 và 2; thời gian sản xuất giữ nguyên.')
    return policy

def assert_instant_supply(prepared,project_root=None):
    policy=read_active_scope(project_root)
    if prepared['spec']['supply']['mode']!=policy['required_supply_mode']:
        raise ValueError('Prepared simulation is outside the active instantaneous-procurement scope')

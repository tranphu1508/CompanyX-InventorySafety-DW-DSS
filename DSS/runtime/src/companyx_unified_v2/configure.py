"""Create a new immutable spec/matrix with explicit resource and penalty settings."""
import argparse
from pathlib import Path
from copy import deepcopy
from .config import resolve,expand
from .legacy import read,save

def with_parameters(source,**changes):
    # Apply overrides first: a config from a larger machine may contain a thread
    # count that is invalid here, and must still be editable down to this host.
    c=deepcopy(source);c.setdefault('solver',{})
    mapping={'solver_name':'name','daily_solver_seconds':'time_limit_seconds','cpu_threads':'threads','max_ram_gib':'max_ram_gib'}
    allowed=set(mapping)|{'production_lead_time_mode','lost_unit_penalty','late_unit_day_penalty','terminal_unserved_unit_penalty'}
    if changes.keys()-allowed:raise ValueError('Unknown configurable parameter')
    for key,value in changes.items():
        if key in mapping:c['solver'][mapping[key]]=value
        else:c[key]=value
    return resolve(c)

def configure_matrix(matrix,**changes):
    result=deepcopy(matrix)
    for scenario in result['scenarios']:
        c=with_parameters({k:v for k,v in scenario.items() if k!='name'},**changes)
        for key in ('solver','lost_unit_penalty','late_unit_day_penalty','terminal_unserved_unit_penalty'):scenario[key]=c[key]
        if 'production_lead_time_mode' in c:scenario['production_lead_time_mode']=c['production_lead_time_mode']
    expand(result);return result

def main():
    p=argparse.ArgumentParser(description=__doc__)
    group=p.add_mutually_exclusive_group(required=True);group.add_argument('--spec');group.add_argument('--matrix')
    p.add_argument('--output',required=True)
    for name in ('daily-solver-seconds','max-ram-gib','lost-unit-penalty','late-unit-day-penalty','terminal-unserved-unit-penalty'):p.add_argument('--'+name,type=float)
    p.add_argument('--solver-name',choices=['GUROBI','CPLEX'])
    p.add_argument('--production-lead-time-mode',choices=['LEGACY_REQUEST_DATE','ACTUAL_START_DATE'])
    p.add_argument('--cpu-threads',type=int);p.add_argument('--unlimited-ram',action='store_true')
    a=p.parse_args()
    if a.max_ram_gib is not None and a.unlimited_ram:p.error('Choose a RAM cap or --unlimited-ram')
    target=Path(a.output)
    if target.exists():raise ValueError('Use a new config filename; published configuration is immutable')
    changes={k:v for k,v in vars(a).items() if k not in ('spec','matrix','output','unlimited_ram') and v is not None}
    if a.unlimited_ram:changes['max_ram_gib']=None
    value=(configure_matrix if a.matrix else with_parameters)(read(a.matrix or a.spec),**changes)
    save(target,value);print(str(target.resolve()))

if __name__=='__main__':main()

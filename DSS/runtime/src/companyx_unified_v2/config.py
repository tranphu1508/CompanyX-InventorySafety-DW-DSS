"""One immutable execution spec per case × policy × replication."""
from copy import deepcopy
from itertools import product
import math,os

PROFILES={'LT1':[1,0,0,0,0],'LT2':[.60,.25,.10,.05,0],
          'LT3':[.45,.25,.15,.10,.05],'LT4':[.30,.25,.20,.15,.10],'LT5':[.2]*5}
DEFAULT=dict(schema='companyx.unified.spec.v2',policy='ROP',allow_backorders=True,
    supply=dict(mode='INSTANT_UNLIMITED',finite_scope='BOM',delay_probabilities=PROFILES['LT1'],
                reject_probability=0.,lead_time_multiplier=1.,daily_limit_mode='UNLIMITED',
                lifecycle='ORDER_TO_RECEIPT_NO_DISPATCH'),
    solver=dict(name='GUROBI',time_limit_seconds=900.,threads=8,relative_gap=0.,
                absolute_gap=0.,seed=0,workmem_mb=None,max_ram_gib=None),replication=0,lost_unit_penalty=3000.,late_unit_day_penalty=1000.,terminal_unserved_unit_penalty=3000.,
    holding_cost_rate_per_year=0.,holding_cost_rate_note='Group approved temporary 0 percent/year; 2026-10-27; ACT/365 on end-of-day on-hand plus WIP value.')

def resolve(source):
    if set(source)-set(DEFAULT)-{'production_lead_time_mode'}:raise ValueError('Unknown execution-spec fields: '+str(set(source)-set(DEFAULT)))
    c=deepcopy(DEFAULT)
    for key,value in source.items():
        if key in ('supply','solver'):
            if not isinstance(value,dict) or set(value)-set(c[key]):raise ValueError('Unknown '+key+' options')
            c[key].update(value)
        else:c[key]=value
    if c['schema']=='companyx.unified.spec.v1':c['schema']=DEFAULT['schema']
    if c['schema']!=DEFAULT['schema'] or c['policy'] not in ('ROP','QUETSCHLICH_ADAPT'):
        raise ValueError('Supported policies: ROP, QUETSCHLICH_ADAPT')
    if type(c['allow_backorders']) is not bool:raise ValueError('allow_backorders must be boolean')
    if type(c['replication']) is not int or c['replication']<0:raise ValueError('Invalid replication')
    from .production_timing import mode
    mode(c)  # validate an explicit choice; omitted remains byte-compatible legacy spec
    s=c['supply'];v=c['solver'];probs=s['delay_probabilities']
    s['mode']={'UNLIMITED':'INSTANT_UNLIMITED','FINITE':'PURCHASE_WITH_LEADTIME'}.get(s['mode'],s['mode'])
    if s['mode'] not in ('INSTANT_UNLIMITED','PURCHASE_WITH_LEADTIME') or s['finite_scope'] not in ('BOM','ALL_PURCHASED'):
        raise ValueError('Invalid supply mode/scope')
    if s['daily_limit_mode']!='UNLIMITED' or s['lifecycle']!='ORDER_TO_RECEIPT_NO_DISPATCH':
        raise ValueError('Unsupported capability: dispatch/calendar limits require a separate implemented lifecycle')
    if len(probs)!=5 or any(not math.isfinite(x) or x<0 for x in probs) or abs(sum(probs)-1)>1e-10:
        raise ValueError('Five probabilities for additive delays 0..4 days must sum to one')
    if not 0<=s['reject_probability']<1 or not 0<s['lead_time_multiplier']<float('inf'):
        raise ValueError('Invalid supply factor')
    # Unlimited is a what-if switch: configured lead/quality factors remain in
    # the immutable spec, but have no physical effect until supply is finite.
    if v['name'] not in ('GUROBI','CPLEX') or type(v['time_limit_seconds']) not in (int,float) or not math.isfinite(v['time_limit_seconds']) or v['time_limit_seconds']<=0 or type(v['threads']) is not int or not 1<=v['threads']<=min(1024,os.cpu_count() or 1):
        raise ValueError('Gurobi or CPLEX required; finite positive daily solver budget; integer threads within this machine logical CPU count (maximum 1024)')
    for key in ('relative_gap','absolute_gap'):
        if not math.isfinite(v[key]) or v[key]<0:raise ValueError('Invalid gap')
    if type(v['seed']) is not int or not 0<=v['seed']<=2147483647 or (v['workmem_mb'] is not None and (not math.isfinite(v['workmem_mb']) or v['workmem_mb']<=0)):
        raise ValueError('Invalid CPLEX seed or working memory')
    for key in ('lost_unit_penalty','late_unit_day_penalty','terminal_unserved_unit_penalty'):
        if type(c[key]) not in (int,float) or not math.isfinite(c[key]) or c[key]<=0:raise ValueError('Penalty must be finite and positive: '+key)
    if v['max_ram_gib'] is not None and (type(v['max_ram_gib']) not in (int,float) or not math.isfinite(v['max_ram_gib']) or v['max_ram_gib']<=0):raise ValueError('max_ram_gib must be positive or null')
    rate=c['holding_cost_rate_per_year']
    if type(rate) not in (int,float) or not math.isfinite(rate) or rate<0:raise ValueError('Invalid annual holding cost rate')
    if not isinstance(c['holding_cost_rate_note'],str) or not c['holding_cost_rate_note'].strip():raise ValueError('Holding rate provenance required')
    if rate!=0 and c['holding_cost_rate_note']==DEFAULT['holding_cost_rate_note']:
        c['holding_cost_rate_note']=f'Caller-specified annual rate {rate}; ACT/365 on end-of-day on-hand plus WIP value.'
    return c

def with_holding_rate_percent(source,percent):
    """Public API: 20 means 20%/year, not 20 times inventory value."""
    if type(percent) not in (int,float) or not math.isfinite(percent) or percent<0:raise ValueError('Holding percent must be finite and nonnegative')
    c=resolve(source);c['holding_cost_rate_per_year']=percent/100
    c['holding_cost_rate_note']=f'Caller-specified {percent}%/year; ACT/365; on-hand plus WIP, transit excluded.'
    return resolve(c)

def expand(matrix):
    """Scenario objects already contain simultaneous factors; cross with policies."""
    if set(matrix)!={'scenarios','policies','replications'}:raise ValueError('Invalid matrix fields')
    if any(not isinstance(matrix[k],list) or not matrix[k] for k in matrix):raise ValueError('Matrix axes must be nonempty lists')
    if len(set(matrix['policies']))!=len(matrix['policies']) or len(set(matrix['replications']))!=len(matrix['replications']):
        raise ValueError('Duplicate policy/replication; use distinct Replication numbers')
    out=[]
    for scenario,policy,rep in product(matrix['scenarios'],matrix['policies'],matrix['replications']):
        if set(scenario)-{'production_lead_time_mode','name','allow_backorders','supply','solver','lost_unit_penalty','late_unit_day_penalty','terminal_unserved_unit_penalty','holding_cost_rate_per_year','holding_cost_rate_note'}:raise ValueError('Invalid scenario')
        if not isinstance(scenario.get('name'),str) or not scenario['name'].strip():raise ValueError('Scenario requires a full name')
        spec=resolve({k:v for k,v in scenario.items() if k!='name'}|dict(policy=policy,replication=rep))
        out.append(dict(name=scenario['name'],spec=spec))
    return out

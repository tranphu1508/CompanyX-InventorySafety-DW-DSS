"""Explicit, non-executable JSON checkpoint format for the external DES executor.

No pickle, frozen module edits, frame inspection, or opaque solver state is used.
The solver is cold-built each new day as in the original controller.
"""
from __future__ import annotations
from collections import Counter,defaultdict
from datetime import date,timedelta
from copy import deepcopy
import gzip,hashlib,json,os,tempfile
from pathlib import Path
import numpy as np

SCHEMA='companyx.des.checkpoint.v1'
STATE_KEYS=('inv','initial','wip','received','used','sold','requested','started','pipe','receipt_jobs','queue',
            'jobid','execution','sequence','product_sums','unvalued','daily','ledger','logs')
SUPPLY_KEYS=('schedule','counts','ordered','arrived','good','reject','pipeline','public','num_orders',
             'num_receipts','replacement_lots','replacement_units','delay_counts','batch_number','receipt_number','index')

def pack(value):
    if isinstance(value,np.generic):return pack(value.item())
    if isinstance(value,np.ndarray):return {'$':'ndarray','dtype':value.dtype.str,'shape':list(value.shape),'items':value.tolist()}
    if isinstance(value,date):return {'$':'date','value':value.isoformat()}
    if isinstance(value,dict):
        tag='counter' if isinstance(value,Counter) else 'defaultdict' if isinstance(value,defaultdict) else 'dict'
        result={'$':tag,'items':[[pack(k),pack(v)] for k,v in value.items()]}
        if tag=='defaultdict':
            factories={list:'list',Counter:'counter',int:'int',dict:'dict'}
            if value.default_factory not in factories:raise ValueError('Unsupported defaultdict factory')
            result['factory']=factories[value.default_factory]
        return result
    if isinstance(value,(list,tuple,set,frozenset)):
        tag='list' if isinstance(value,list) else 'tuple' if isinstance(value,tuple) else 'set'
        items=sorted(value,key=repr) if tag=='set' else value
        return {'$':tag,'items':[pack(x) for x in items]}
    if value is None or isinstance(value,(str,bool,int,float)):return value
    raise TypeError('Unsupported checkpoint value: '+type(value).__name__)

def unpack(value):
    if not isinstance(value,dict):return value
    tag=value.get('$')
    if tag=='date':return date.fromisoformat(value['value'])
    if tag=='ndarray':
        dtype=np.dtype(value['dtype'])
        if dtype.kind not in 'biuf':raise ValueError('Unsafe/unsupported array dtype')
        result=np.asarray(value['items'],dtype=dtype)
        if list(result.shape)!=value['shape']:raise ValueError('Checkpoint array shape mismatch')
        return result
    if tag in ('list','tuple','set'):
        rows=[unpack(x) for x in value['items']]
        return rows if tag=='list' else tuple(rows) if tag=='tuple' else set(rows)
    if tag in ('dict','counter','defaultdict'):
        rows=[(unpack(k),unpack(v)) for k,v in value['items']]
        if tag=='counter':return Counter(dict(rows))
        if tag=='defaultdict':return defaultdict({'list':list,'counter':Counter,'int':int,'dict':dict}[value['factory']],rows)
        return dict(rows)
    raise ValueError('Unknown checkpoint value type')

def digest(value):
    return hashlib.sha256(json.dumps(value,ensure_ascii=False,allow_nan=False,sort_keys=True,separators=(',',':')).encode()).hexdigest()

def canonical(value):
    """Order-insensitive semantic hash representation, separate from state order."""
    value=pack(value)
    def visit(v):
        if isinstance(v,dict):
            out={k:visit(x) for k,x in v.items()}
            if v.get('$') in ('dict','counter','defaultdict'):
                out['items'].sort(key=lambda item:json.dumps(item[0],sort_keys=True,separators=(',',':')))
            return out
        if isinstance(v,list):return [visit(x) for x in v]
        return v
    return visit(value)

def physical_identity(data,spec):
    keys=('P','edges','topo','start','raw','rawparams','external_ids','vendors','products','costs','valuation_sha256')
    return digest(canonical({'data':{k:data[k] for k in keys if k in data},'spec':spec}))

def known_orders_identity(data,cutoff):
    rows=[x for x in data['lines'] if (date.fromisoformat(x['order'][:10]) if isinstance(x['order'],str) else x['order'])<=cutoff]
    return digest(canonical(sorted(rows,key=lambda x:x['id'])))

def capture(data,spec,local_state,ob,supply,controller,executor_sha256):
    t=local_state['t'];cutoff=data['start']+timedelta(days=t)
    core=getattr(controller,'core',controller) if controller is not None else None
    control={k:deepcopy(getattr(core,k)) for k in ('logs','audit','current_solve_sequence') if core is not None and hasattr(core,k)}
    orders=[deepcopy(o) for o in ob.orders.values() if o['order']<=cutoff]
    payload={'engine':{k:local_state[k] for k in STATE_KEYS},
             'orders':orders,'order_history':{k:getattr(ob,k) for k in ('audit','delivery','external_draws')},
             'supply':{k:getattr(supply,k) for k in SUPPLY_KEYS},'controller':control}
    encoded=pack(payload)
    return {'schema':SCHEMA,'boundary':'END_OF_DAY_AFTER_CHECKS_BEFORE_FINAL_REPORTS','start':str(data['start']),
            'through':str(cutoff),'next_day':t+1,'physical_identity_sha256':physical_identity(data,spec),
            'known_orders_sha256':known_orders_identity(data,cutoff),'executor_sha256':executor_sha256,
            'payload_sha256':digest(encoded),'payload':encoded}

def validate(checkpoint,data,spec,executor_sha256):
    if checkpoint.get('schema')!=SCHEMA:raise ValueError('Unsupported checkpoint schema')
    if checkpoint.get('executor_sha256')!=executor_sha256:raise ValueError('Checkpoint executor identity changed')
    if checkpoint.get('payload_sha256')!=digest(checkpoint.get('payload')):raise ValueError('Checkpoint payload changed')
    if checkpoint.get('physical_identity_sha256')!=physical_identity(data,spec):raise ValueError('Checkpoint physical/spec identity differs')
    cutoff=date.fromisoformat(checkpoint['through'])
    if checkpoint['start']!=str(data['start']) or checkpoint['next_day']!=(cutoff-data['start']).days+1:
        raise ValueError('Checkpoint day/start identity differs')
    if not data['start']<=cutoff<data['end']:raise ValueError('Extension must execute at least one new day')
    if checkpoint['known_orders_sha256']!=known_orders_identity(data,cutoff):raise ValueError('Known order prefix changed')
    return unpack(checkpoint['payload'])

def restore_orders(ob,payload):
    for saved in payload['orders']:
        target=ob.orders[saved['SalesOrderID']];lines={x['id']:x for x in target['lines']}
        for row in saved['lines']:
            lines[row['id']].clear();lines[row['id']].update(deepcopy(row))
        target.update({k:deepcopy(v) for k,v in saved.items() if k!='lines'})
    ob.active={oid:o for oid,o in ob.orders.items() if o['status']=='OPEN'}
    for k,v in payload['order_history'].items():setattr(ob,k,deepcopy(v))
    ob.check()

def save_checkpoint(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=path.name+'.',suffix='.tmp',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as raw:
            with gzip.GzipFile(fileobj=raw,mode='wb',mtime=0) as compressed:
                compressed.write(json.dumps(value,ensure_ascii=False,allow_nan=False,separators=(',',':')).encode('utf-8'))
            raw.flush();os.fsync(raw.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)
    return {'path':str(path),'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'through':value['through'],'next_day':value['next_day']}

def load_checkpoint(path,expected_sha256):
    path=Path(path)
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected_sha256:raise ValueError('Checkpoint file identity changed')
    with gzip.open(path,'rt',encoding='utf-8') as f:return json.load(f)

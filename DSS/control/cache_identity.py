"""End-independent inquiry identity. Dates alone never authorize reuse."""
from __future__ import annotations
import hashlib,json,sys
from importlib import metadata
from copy import deepcopy
from pathlib import Path
from common import CODE,PROJECT,OUTPUT,demo_folder,read

def canonical(value):
    return json.dumps(value,ensure_ascii=False,sort_keys=True,separators=(',',':'),allow_nan=False)

def digest(value):return hashlib.sha256(canonical(value).encode('utf-8')).hexdigest()

def file_sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda:f.read(1024*1024),b''):h.update(block)
    return h.hexdigest()

def build_identity(manifest,purpose,*,project_root=None,executor_hash=None):
    project=Path(project_root).resolve() if project_root else PROJECT
    if purpose not in ('ORDER_INQUIRY','PIPELINE_SMOKE'):raise ValueError('Unsupported cache purpose')
    catalog=read(project/'RuntimeData/reference/catalog.json')
    matches=[b for b in catalog['baselines'] if b.get('status')=='READY' and b['PlanningRunKey']==manifest['base_run_key']]
    if len(matches)!=1:raise ValueError('Cache requires exactly one verified READY baseline reference')
    b=matches[0];folder=(project/'RuntimeData/reference/runs'/Path(b['artifact_folder'].replace('\\','/')).name).resolve()
    if not folder.is_relative_to(project/'RuntimeData/reference/runs'):raise ValueError('Baseline reference outside GPT')
    execution=read(folder/'baseline_execution_receipt.json');run=read(folder/'run.json')
    if executor_hash is None:
        from simulation.continuation import effective_executor_hash
        executor_hash=effective_executor_hash(project_root=project)
    if len(executor_hash)!=64 or any(c not in '0123456789abcdef' for c in executor_hash):raise ValueError('Invalid executor hash')
    intent=deepcopy(manifest)
    for k in ('request_id','inquiry_id','analysis_end'):intent.pop(k,None)
    packages={}
    from model_v3.release import release_identity
    for name in ('numpy','scipy','gurobipy','cplex'):
        try:packages[name]=metadata.version(name)
        except metadata.PackageNotFoundError:packages[name]='NOT_INSTALLED'
    contract={
        'schema':'companyx.cache.family.v1','purpose':purpose,'intent':intent,
        'source':{'baseline_id':b['baseline_id'],'PlanningRunKey':b['PlanningRunKey'],
                  'RunCode':run['RunCode'],'scope_sha256':execution['scope_sha256'],
                  'prepared_file_sha256':execution['prepared_file_sha256'],
                  'full_snapshot_sha256':file_sha(folder/'input_source.json'),
                  'full_provenance_sha256':file_sha(folder/'input_provenance.json'),
                  'baseline_spec_sha256':file_sha(folder/'execution_spec.json')},
        'implementation':{'core_sha256':run['code_sha256'],
                          'optimizer_release':release_identity(project),
                          'inquiry_adapter_sha256':file_sha(project/'DSS/control/simulation/inquiry_v2.py'),
                          'effective_executor_sha256':executor_hash},
        'environment':{'python':sys.version,'packages':packages,
                       'native_path_worker_sha256':file_sha(demo_folder(project)/'DSS/native_path_worker.py')},
        'continuation_contract':'EOD checkpoint; unchanged start and causal policy; analysis_end is an observation stop, not the MILP horizon.'}
    return {'schema':'companyx.cache.identity.v1','family_hash':digest(contract),'family_contract':contract}

def verify_identity(identity):
    if identity.get('schema')!='companyx.cache.identity.v1' or digest(identity.get('family_contract'))!=identity.get('family_hash'):
        raise ValueError('Invalid cache family identity')
    return identity

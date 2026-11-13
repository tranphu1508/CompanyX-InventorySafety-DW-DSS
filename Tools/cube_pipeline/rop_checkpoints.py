"""Daily decision checkpoints linked to existing ROP runs, with no history publication."""
from pathlib import Path
from datetime import date, timedelta, datetime, timezone
from contextlib import contextmanager
import argparse, gzip, hashlib, json, os, sys, uuid

from settings import DEMO, PROJECT, GPT, read, save, sql, lease, sha
from dss_bridge import validate_input, inquiry_v2
inquiry_v2.runtime(PROJECT)

SCHEMA = 'companyx.rop.decision-checkpoint.v1'
BOUNDARY = 'AFTER_RECEIPTS_AND_REVEAL_BEFORE_DECISION'
FIELDS = ('day','inventory','pipeline','book','queue','orders','public_purchases')
ROOT = GPT/'rop-checkpoints'


def template(run, known):
    catalog=read(DEMO/'RuntimeData/reference/catalog.json')
    entry=next(b for b in catalog['baselines'] if b['PlanningRunKey']==run and b['status']=='READY')
    request=dict(schema='companyx.inquiry.request.v2',request_id='checkpoint-offer',inquiry_id='checkpoint-offer',
                 base_run_key=run,known_at=known,analysis_end=known,solver_name='GUROBI',solver_seconds=900,
                 threads=12,penalties={},scenario_index=entry['scenario_index'],baseline_id=entry['baseline_id'],
                 initialization_mode='BASELINE_AT_START',initial_stock_rule=entry['initial_stock_rule'],
                 candidates=[dict(candidate_id='BASELINE',kind='BASELINE',tranches=[])])
    return request,inquiry_v2._select_entry(request,PROJECT)


def identity(run, binding):
    from simulation.resumable_engine import executor_identity
    _,entry=template(run,'2013-07-01')
    folder=Path(entry['artifact_folder'])
    baseline=read(folder/'run.json')
    spec=read(folder/'execution_spec.json')
    _,_,_,_,legacy,_,_=inquiry_v2.runtime(PROJECT)
    document=dict(schema=SCHEMA,boundary=BOUNDARY,baseRunKey=run,baseRunCode=baseline['RunCode'],
                  inputBinding=binding,baselineInputSHA256=sha(folder/'input.json'),
                  baselineSpecSHA256=legacy.digest(spec),baselineCoreSHA256=baseline['code_sha256'],
                  executorSHA256=executor_identity(),checkpointCodeSHA256=sha(Path(__file__)),
                  start=entry['start'],end=entry['end'])
    return legacy.digest(document),document,entry


def install():
    with sql('SIM') as cn:
        cursor=cn.execute((DEMO/'Database/Setup/ROPDecisionCheckpoint.sql').read_text(encoding='utf-8'))
        while cursor.nextset():pass


def physical_state(value):
    return {key:value[key] for key in FIELDS}


def build(run, binding=None):
    """One verified full ROP replay to capture all dates; no simulator publisher is called."""
    from simulation import resumable_engine
    binding=binding or validate_input()
    family,document,entry=identity(run,binding)
    install()
    with sql('SIM') as lock,lease(lock,'CompanyX.ROPCheckpoint.'+str(run)):
        expected=(date.fromisoformat(entry['end'])-date.fromisoformat(entry['start'])).days+1
        existing=lock.execute('SELECT COUNT(*) FROM cxsim.ROPDecisionCheckpoint WHERE BaseRunKey=? AND InputIdentity=?',run,family).fetchval()
        if existing==expected:
            print('Reusing complete checkpoint family',run,family,flush=True)
            return family
        reference=inquiry_v2._load_reference(entry,PROJECT)
        with sql('SIM') as cn:
            row=cn.execute('SELECT RunCode,RunStatus FROM dss.Dim_PlanningRun WHERE PlanningRunKey=?',run).fetchone()
            if not row or str(row[0]).lower()!=document['baseRunCode'].lower() or row[1]!='SUCCEEDED':
                raise ValueError('Checkpoint must reference an existing successful ROP run')
        _,_,_,inputs,legacy,_,_=inquiry_v2.runtime(PROJECT)
        spec=reference['spec']
        if spec['policy']!='ROP':raise ValueError('Expected ROP baseline')
        data=inputs.prepare(reference['snapshot'],spec)
        if data['raw'] or spec['supply']['mode']!='INSTANT_UNLIMITED':
            raise ValueError('Decision checkpoint currently covers the two instant-unlimited ROP scenarios only')
        folder=ROOT/family/uuid.uuid4().hex
        folder.mkdir(parents=True,exist_ok=False)
        save(folder/'build-status.json',dict(status='RUNNING',baseRunKey=run))
        records=[]
        proof=inquiry_v2.PrefixVerifier(reference['folder'],str(data['end']+timedelta(days=1)),legacy,PROJECT,'BASELINE_AT_START')
        def capture(day,inv,pipe,book,queue,orders,supply):
            known=str(data['start']+timedelta(days=day))
            state=dict(day=day,inventory=sorted(inv.items()),pipeline=sorted(pipe.items()),book=sorted(book.items()),
                       queue=queue,orders=orders,public_purchases=supply.public_pipeline(day))
            state=json.loads(legacy.canonical(state))
            if state['public_purchases']:raise ValueError('Unexpected finite purchases in checkpoint')
            payload=dict(schema=SCHEMA,boundary=BOUNDARY,inputIdentity=family,baseRunKey=run,knownAt=known,
                         state=state,stateSHA256=legacy.digest(state))
            path=folder/(known+'.json.gz')
            with path.open('wb') as raw:
                with gzip.GzipFile(fileobj=raw,mode='wb',mtime=0) as stream:
                    stream.write(json.dumps(payload,ensure_ascii=False,allow_nan=False,separators=(',',':')).encode('utf-8'))
            records.append((run,known,family,str(path.relative_to(DEMO)),sha(path)))
            if day%100==0:print('ROP checkpoint',run,known,day+1,'/',expected,flush=True)
        try:
            result=resumable_engine.simulate(data,spec,sink=proof.row,decision_sink=capture)
            comparison=proof.finish()
            if len(records)!=expected:raise ValueError('Incomplete daily checkpoint coverage')
            if validate_input()!=binding:raise ValueError('ACT binding changed while building checkpoints')
            manifest=dict(schema=SCHEMA,status='VERIFIED',identity=document,inputIdentity=family,
                          checkpointCount=len(records),baselineComparison=comparison,
                          metrics=result['metrics'],createdAt=datetime.now(timezone.utc).isoformat(),
                          checkpoints=[dict(date=r[1],file=Path(r[3]).name,sha256=r[4]) for r in records],
                          publication='REGISTRY_ONLY_NO_ROP_FACTS_OR_RUNS_INSERTED')
            save(folder/'manifest.json',manifest)
            manifest_hash=sha(folder/'manifest.json')
            # A complete, verified family becomes visible atomically.
            with sql('SIM',autocommit=False) as cn:
                cn.execute('DELETE FROM cxsim.ROPDecisionCheckpoint WHERE BaseRunKey=? AND InputIdentity=?',run,family)
                cn.cursor().executemany('INSERT cxsim.ROPDecisionCheckpoint VALUES (?,?,?,?,?,?)',
                                       [r+(manifest_hash,) for r in records])
                cn.commit()
            save(folder/'build-status.json',dict(status='VERIFIED',checkpointCount=len(records)))
            print('Verified and registered',run,len(records),'daily checkpoints',flush=True)
            return family
        except BaseException as exc:
            save(folder/'build-status.json',dict(status='FAILED',error=str(exc)))
            raise
        finally:proof.close()


def lookup(run,known,binding,*,prepare=False):
    family,document,entry=identity(run,binding)
    if not entry['start']<=known<=entry['end']:raise ValueError('Date outside ROP checkpoint coverage')
    with sql('SIM') as cn:
        installed=cn.execute("SELECT OBJECT_ID('cxsim.ROPDecisionCheckpoint','U')").fetchval()
        row=cn.execute('SELECT CheckpointPath FROM cxsim.ROPDecisionCheckpoint WHERE BaseRunKey=? AND DecisionDate=? AND InputIdentity=?',run,known,family).fetchone() if installed else None
    if row is None and prepare:
        build(run,binding)
        return lookup(run,known,binding)
    if row is None:raise ValueError('Missing verified ROP checkpoints; run rop_checkpoints.py build first')
    path=(DEMO/row[0]).resolve()
    load(path,run,known,binding)
    return path


def load(path,run,known,binding):
    """Reject stale, corrupt or unregistered state. Never fall back to history publication."""
    path=Path(path).resolve()
    if not path.is_relative_to(ROOT.resolve()):raise ValueError('Checkpoint path outside owned local storage')
    family,document,entry=identity(run,binding)
    with sql('SIM') as cn:
        row=cn.execute('SELECT CheckpointPath,FileSHA256,ManifestSHA256 FROM cxsim.ROPDecisionCheckpoint WHERE BaseRunKey=? AND DecisionDate=? AND InputIdentity=?',run,known,family).fetchone()
    if not row or (DEMO/row[0]).resolve()!=path or sha(path)!=row[1]:raise ValueError('Checkpoint registration/file identity mismatch')
    manifest_path=path.parent/'manifest.json'
    if sha(manifest_path)!=row[2]:raise ValueError('Checkpoint verification manifest changed')
    manifest=read(manifest_path)
    if manifest['status']!='VERIFIED' or manifest['identity']!=document or manifest['baselineComparison']['status']!='PASSED':
        raise ValueError('Unverified checkpoint family')
    with gzip.open(path,'rt',encoding='utf-8') as f:payload=json.load(f)
    _,_,_,_,legacy,_,_=inquiry_v2.runtime(PROJECT)
    if (payload['schema']!=SCHEMA or payload['boundary']!=BOUNDARY or payload['inputIdentity']!=family
            or payload['baseRunKey']!=run or payload['knownAt']!=known
            or payload['state']['day']!=(date.fromisoformat(known)-date.fromisoformat(entry['start'])).days
            or legacy.digest(payload['state'])!=payload['stateSHA256']):
        raise ValueError('Invalid decision boundary or checkpoint contents')
    return payload,entry


def request_base(path,run,known,binding):
    _,entry=load(path,run,known,binding)
    request,_=template(run,known)
    return request,date.fromisoformat(entry['end'])


if __name__=='__main__':
    p=argparse.ArgumentParser()
    p.add_argument('action',choices=['build'])
    p.add_argument('--run',type=int,action='append')
    args=p.parse_args()
    for run in args.run or [8,9]:build(run)

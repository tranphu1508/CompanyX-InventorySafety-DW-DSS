"""Run-local artifacts, immutable inputs/spec, deterministic replay, no SQL writes."""
from pathlib import Path
from datetime import datetime,timezone,timedelta
import argparse,gzip,hashlib,json,os,time,traceback,uuid
from .legacy import save,read,digest,verify_release
from .config import resolve,with_holding_rate_percent
from .inputs import frozen_snapshot,prepare
from .engine import simulate
from .optimizer import Controller
from .integration_contract import profile

def stamp():return datetime.now(timezone.utc).isoformat()
def sha(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
    return h.hexdigest()
def code_hash():return digest({p.relative_to(Path(__file__).parent).as_posix():sha(p) for p in sorted(Path(__file__).parent.rglob('*')) if p.is_file() and p.suffix in ('.py','.json')})

class Sink:
    def __init__(self,folder,run_code):
        self.folder=folder;folder.mkdir(parents=True,exist_ok=True);self.run_code=run_code;self.files={};self.counts={}
        # A zero-event day/run still has a complete, versioned table contract.
        # Replays truncate every known table, so no stale optional table survives.
        for table in ('RunEntity','Fact_SimulationDaily','Fact_SimulationEvent','Fact_SimulationOrder',
                      'Fact_OptimizationSolve','Fact_StochasticDraw','RunSummary','ProductScope','ValuationBasis',
                      'Fact_PolicySimulation','Bridge_RunEntityRelation','ExternalSupplyDraw'):
            self.files[table]=(folder/f'{table}.jsonl').open('w',encoding='utf-8');self.counts[table]=0
    def __call__(self,table,row):
        if table not in self.files:self.files[table]=(self.folder/f'{table}.jsonl').open('w',encoding='utf-8');self.counts[table]=0
        self.counts[table]+=1
        self.files[table].write(json.dumps(dict(RunCode=self.run_code,**row),ensure_ascii=False,default=str,allow_nan=False,separators=(',',':'))+'\n')
        if table=='Fact_OptimizationSolve':self.files[table].flush()
    def close(self):
        for f in self.files.values():f.close()

def execute(snapshot,spec,folder,resume=False,name=None):
    folder=Path(folder).resolve();spec=resolve(spec)
    # Reject before touching status/limits/locks: timing changes require a fresh run.
    if (folder/'completion.json').exists():
        raise ValueError('Completed runs are immutable; create a new run to repeat')
    if (folder/'run.json').exists():
        if not resume:raise ValueError('Existing run directory; use a fresh path or explicit resume')
        old=read(folder/'run.json')
        identity=dict(input_sha256=digest(snapshot),execution_spec_sha256=digest(spec),code_sha256=code_hash())
        if any(old.get(k)!=v for k,v in identity.items()):raise ValueError('Resume input/spec/code identity mismatch')
    folder.mkdir(parents=True,exist_ok=True)
    lock=folder/'RUNNING.lock'
    fd=os.open(str(lock),os.O_CREAT|os.O_EXCL|os.O_WRONLY);os.write(fd,str(os.getpid()).encode());os.close(fd)
    try:
        from .resources import memory_limit
        spec=resolve(spec)
        with memory_limit(spec['solver']['max_ram_gib'],folder):
            return _execute(snapshot,spec,folder,resume,name)
    except BaseException as exc:
        current=read(folder/'status.json') if (folder/'status.json').exists() else {}
        if current.get('status') not in ('FAILED','INTERRUPTED'):
            save(folder/'status.json',dict(status='FAILED',error=str(exc),completed_days=current.get('completed_days',0),updated_at=stamp()))
        raise
    finally:lock.unlink(missing_ok=True)

def _execute(snapshot,spec,folder,resume=False,name=None):
    spec=resolve(spec);data=prepare(snapshot,spec)
    identity=dict(input_sha256=digest(snapshot),execution_spec_sha256=digest(spec),code_sha256=code_hash())
    manifestpath=folder/'run.json';completion=folder/'completion.json'
    if manifestpath.exists():
        if not resume:raise ValueError('Existing run directory; use a fresh path or explicit resume')
        manifest=read(manifestpath)
        if any(manifest[k]!=v for k,v in identity.items()):raise ValueError('Resume input/spec/code identity mismatch')
        if completion.exists():raise ValueError('Completed runs are immutable; create a new run to repeat')
    else:
        case_name=('Giao nguyên SalesOrder và cho phép giao bù' if spec['allow_backorders'] else 'Giao nguyên SalesOrder, không cho phép giao bù')
        case_name+='; '+('cung vô hạn tức thời' if spec['supply']['mode']=='INSTANT_UNLIMITED' else 'mua theo leadtime, các yếu tố cung theo execution_spec')
        manifest=dict(schema='companyx.unified.run.v2',RunCode=str(uuid.uuid4()),CaseName=name or case_name,
            PolicyName='ROP' if spec['policy']=='ROP' else 'Quetschlich Adapt',
            policy=spec['policy'],created_at=stamp(),start=snapshot['start'],end=snapshot['end'],replication=spec['replication'],
            **identity,valuation_sha256=data.get('valuation_sha256'),simulation_only_2014_authorization=True,ml_holdout_unchanged=True)
        save(manifestpath,manifest);save(folder/'input.json',snapshot);save(folder/'execution_spec.json',spec)
        save(folder/'execution_profile.json',profile(snapshot,spec,data))
        if data.get('valuation_sha256'):save(folder/'valuation_basis.json',snapshot['metadata']['valuation'])
    sink=Sink(folder/'tables',manifest['RunCode']);began=time.perf_counter()
    try:
        save(folder/'status.json',dict(status='RUNNING',pid=os.getpid(),started_at=stamp(),completed_days=0))
        controller=Controller(data,spec,folder,resume,sink) if spec['policy']=='QUETSCHLICH_ADAPT' else None
        def progress(t,row):
            save(folder/'status.json',dict(status='RUNNING',pid=os.getpid(),completed_days=t+1,last_completed_date=row['Date'],updated_at=stamp()))
            if (folder/'STOP').exists():raise InterruptedError('Stop requested after current day')
        result=simulate(data,spec,controller,sink,progress,folder)
        logs=controller.logs if controller else []
        metrics=result['metrics'];metrics.update(policy=spec['policy'],full_order=True,allow_backorders=spec['allow_backorders'],
            solve_count=len(logs),feasible_time_limit_count=sum(x['status']=='FEASIBLE_TIME_LIMIT' for x in logs),
            feasible_time_limit_rate=sum(x['status']=='FEASIBLE_TIME_LIMIT' for x in logs)/len(logs) if logs else None,
            wall_seconds=time.perf_counter()-began,valuation_sha256=data.get('valuation_sha256'),
            holding_cost_rate_per_year=spec['holding_cost_rate_per_year'],
            solve_attempt_count=len(controller.audit) if controller else 0)
        sink('RunSummary',metrics)
        for row in snapshot.get('metadata',{}).get('valuation',{}).get('rows',[]):
            sink('ValuationBasis',dict(**row,ValuationHash=data['valuation_sha256']))
        for row in snapshot['products']:sink('ProductScope',dict(ProductID=row['ProductID'],IsManufactured=row['IsManufactured'],IsResale=row['IsResale'],StockUnit=row['StockUnit']))
        save(folder/'metrics.json',metrics);save(folder/'daily_totals.json',result['daily'])
        sink.close()
        manifest_tables={p.name:dict(rows=sink.counts[p.stem],sha256=sha(p)) for p in sorted((folder/'tables').glob('*.jsonl'))}
        save(folder/'table_manifest.json',dict(schema='companyx.unified.tables.v2',RunCode=manifest['RunCode'],tables=manifest_tables))
        done=dict(status='COMPLETE',completed_days=metrics['calendar_days'],finished_at=stamp(),RunCode=manifest['RunCode'],
                  table_manifest_sha256=sha(folder/'table_manifest.json'),metrics_sha256=sha(folder/'metrics.json'))
        save(completion,done);save(folder/'status.json',done)
        return metrics
    except BaseException as exc:
        previous=read(folder/'status.json') if (folder/'status.json').exists() else {}
        save(folder/'status.json',dict(status='INTERRUPTED' if isinstance(exc,(InterruptedError,KeyboardInterrupt)) else 'FAILED',
            error=str(exc),traceback=traceback.format_exc(),completed_days=previous.get('completed_days',0),updated_at=stamp()))
        sink.files['Fact_OptimizationSolve'].flush()
        save(folder/'failure_audit_manifest.json',dict(RunCode=manifest['RunCode'],input_sha256=identity['input_sha256'],
            execution_spec_sha256=identity['execution_spec_sha256'],status=read(folder/'status.json')['status'],
            solve_table_sha256=sha(folder/'tables/Fact_OptimizationSolve.jsonl'),solve_rows=sink.counts['Fact_OptimizationSolve'],
            result_publication_allowed=False))
        raise
    finally:
        sink.close()

def main():
    p=argparse.ArgumentParser();p.add_argument('--input');p.add_argument('--spec',required=True);p.add_argument('--output',required=True)
    p.add_argument('--name');p.add_argument('--resume',action='store_true');p.add_argument('--validate-only',action='store_true')
    p.add_argument('--holding-rate-percent',type=float)
    p.add_argument('--solver-name',choices=['GUROBI','CPLEX'])
    p.add_argument('--production-lead-time-mode',choices=['LEGACY_REQUEST_DATE','ACTUAL_START_DATE'])
    args=p.parse_args()
    snapshot=read(args.input) if args.input else frozen_snapshot();spec=resolve(read(args.spec))
    if args.solver_name is not None:spec=resolve(dict(spec,solver=dict(spec['solver'],name=args.solver_name)))
    if args.production_lead_time_mode is not None:spec=resolve(dict(spec,production_lead_time_mode=args.production_lead_time_mode))
    if args.holding_rate_percent is not None:spec=with_holding_rate_percent(spec,args.holding_rate_percent)
    data=prepare(snapshot,spec)
    if args.validate_only:
        print(json.dumps(dict(status='VALID',manufactured=len(data['P']),finite_purchased=len(data['raw']),
            sales_lines=len(data['lines']),spec=spec),ensure_ascii=False));return
    verify_release()
    metrics=execute(snapshot,spec,args.output,args.resume,args.name)
    print(json.dumps(metrics,ensure_ascii=False))

if __name__=='__main__':main()

from collections import defaultdict
from functools import lru_cache
from pathlib import Path
import gzip,json,math,os,pickle,subprocess,sys,time
from datetime import timedelta
import numpy as np
from .legacy import module,digest,save,read
from .atomic_model import build_model,action_from_plan
from .supply_model import extend
from .cplex_solver import validate
from .production_timing import adapt_model
from .immediate_start import validate_plan

def build(data,spec,inv,pipe,book,queue,orders,supply,day,horizon=None):
    d=module('companyx_active_days').dataset(data['P'],data['edges'],data['start'])
    if data['raw']:
        @lru_cache(None)
        def effective(p):
            if p in data['raw']:return math.ceil(supply.vendor(p)['base_lead_days']+supply.expected_delay)
            if p not in data['P']:return 0
            return max(data['P'][p]['lead_days'],1+max([effective(c) for c,a,u in data['bom'].children[p]]+[0]))
        # Direct resale purchases also need an actionable horizon, even when
        # they are not children of any manufactured root.
        d['effective_lead']=max([effective(p) for p in d['roots']]+[effective(p) for p in data['raw']])
    model,meta=build_model(d,inv,pipe,book,queue,orders,day,'7B' if spec['allow_backorders'] else '7C',
                          spec['lost_unit_penalty'],horizon=horizon)
    if data['raw']:model,meta=extend(model,meta,d,data,supply.config,inv,queue,supply,day,orders)
    # Per-model objective coefficients only; never mutate legacy module WEIGHTS.
    for j,key in enumerate(model.keys):
        if key[0] in ('Ba','Bf'):
            model.cost[j]=spec['late_unit_day_penalty']+(spec['terminal_unserved_unit_penalty'] if key[2]==meta['H'] else 0)
    return adapt_model(model,meta,data,spec)

class Controller:
    def __init__(self,data,spec,folder,resume=False,sink=None):
        self.data,self.spec,self.folder=data,spec,Path(folder).resolve();self.logs=[]
        self.folder.mkdir(parents=True,exist_ok=True);self.replay={};self.sink=sink;self.audit=[]
        for p in sorted((self.folder/'solve_audit').glob('*.json')):
            if not resume:raise ValueError('Existing solve audit requires resume')
            record=read(p)
            if digest(record['row'])!=record['sha256']:raise ValueError('Solve audit changed')
            if record['row']['SolveSequence']!=len(self.audit)+1:raise ValueError('Non-contiguous solve audit')
            self.audit.append(record['row'])
            if sink:sink('Fact_OptimizationSolve',record['row'])
        for p in sorted((self.folder/'decisions').glob('*.json')):
            if not resume:raise ValueError('Existing decisions require resume')
            x=read(p)
            if x['day']!=len(self.replay):raise ValueError('Non-contiguous checkpoint')
            self.replay[x['day']]=x
    def _audit(self,day,attempt,sequence,log,horizon,state_reference,output_reference=None):
        today=self.data['start']+timedelta(days=day)
        row=dict(SolveSequence=sequence,DecisionAt=str(today),AttemptNo=attempt,ObjectiveStage='WEIGHTED_SUM',
            InformationCutoffAt=str(today),HorizonEndAt=str(today+timedelta(days=horizon)),PlanningForecastRunKey=None,
            ForecastInputReference='input.json#sha256='+self.data['snapshot_sha256']+';products/ManufacturingParameters/direct_mu',
            StateInputReference=state_reference,DecisionOutputReference=output_reference,
            SolverStatus=log['status'],HasFeasibleSolution=bool(log.get('has_feasible_solution',False)),
            ActionSource='SOLVER_INCUMBENT' if output_reference else 'NONE',
            ObjectiveValue=log.get('objective'),BestBound=log.get('best_bound'),RelativeGap=log.get('relative_gap'),
            SolverSeconds=log.get('solver_seconds',0))
        save(self.folder/'solve_audit'/f'{sequence:07d}.json',dict(row=row,sha256=digest(row),native=log))
        self.audit.append(row)
        if self.sink:self.sink('Fact_OptimizationSolve',row)
    def decide(self,day,inv,pipe,book,queue,orders,supply):
        # Only revealed orders and publicly expected purchases enter state/model hashes.
        state=dict(day=day,inventory=sorted(inv.items()),pipeline=sorted(pipe.items()),book=sorted(book.items()),
                   queue=queue,orders=orders,public_purchases=supply.public_pipeline(day),input_hash=self.data['snapshot_sha256'],spec=self.spec)
        state_hash=digest(state)
        if day in self.replay:
            x=self.replay[day]
            if x['state_hash']!=state_hash:raise ValueError('Replay state/input/spec mismatch')
            path=self.folder/x['solution_reference']
            import hashlib
            if hashlib.sha256(path.read_bytes()).hexdigest()!=x['solution_sha256']:raise ValueError('Checkpoint solution changed')
            self.current_solve_sequence=x['solver']['SolveSequence']
            audit=next((r for r in self.audit if r['SolveSequence']==self.current_solve_sequence),None)
            if not audit or audit['DecisionOutputReference']!=f'decisions/{day:04d}.json#sha256='+digest(x):
                raise ValueError('Decision missing or inconsistent solve audit')
            self.logs.append(x['solver']);return x['action']
        sequence=len(self.audit)+1;today=str(self.data['start']+timedelta(days=day))
        attempt=1+max([r['AttemptNo'] for r in self.audit if r['DecisionAt']==today]+[0])
        self.current_solve_sequence=sequence
        solvefolder=self.folder/'solves'/f'{day:04d}'
        if attempt>1:solvefolder=solvefolder/f'attempt_{attempt:03d}'
        solvefolder.mkdir(parents=True,exist_ok=True)
        save(solvefolder/'state.json',state)
        state_reference=str((solvefolder/'state.json').relative_to(self.folder))+'#sha256='+state_hash
        meta={'H':0};began=time.perf_counter()
        try:
            m,meta=build(self.data,self.spec,inv,pipe,book,queue,orders,supply,day)
            build_seconds=time.perf_counter()-began
            return self._solve(day,m,meta,solvefolder,state_hash,state_reference,build_seconds,attempt,sequence)
        except BaseException as exc:
            if any(r['SolveSequence']==sequence for r in self.audit):raise
            log=read(solvefolder/'solver.json') if (solvefolder/'solver.json').exists() else dict(status='ERROR',has_feasible_solution=False)
            # Native evidence remains untouched; an invalid/non-executed result has no action.
            if log.get('status') in ('OPTIMAL','NEAR_OPTIMAL','FEASIBLE_TIME_LIMIT'):log.update(status='ERROR',has_feasible_solution=False)
            log.update(error=str(exc),horizon_available=bool(meta['H']),state_reference=state_reference)
            self._audit(day,attempt,sequence,log,meta['H'],state_reference)
            raise
    def _solve(self,day,m,meta,solvefolder,state_hash,state_reference,build_seconds,attempt,sequence):
        from .resources import DailyBudget
        budget=DailyBudget(self.folder/'daily_budgets'/f'{day:04d}.json',self.spec['solver']['time_limit_seconds'])
        settings=dict(self.spec['solver'],time_limit_seconds=budget.reserve())
        with gzip.open(solvefolder/'request.pkl.gz','wb',compresslevel=1) as f:pickle.dump(dict(model=m.__dict__,settings=settings),f,protocol=5)
        env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env['OMP_NUM_THREADS']='1'
        for key in ('OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):env[key]='1'
        flags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0
        with (solvefolder/'worker.log').open('w',encoding='utf-8') as log:
            child=subprocess.Popen([sys.executable,'-m','companyx_unified_v2.gurobi_solver' if settings['name']=='GUROBI' else 'companyx_unified_v2.cplex_solver',str(solvefolder)],env=env,stdout=log,stderr=subprocess.STDOUT,creationflags=flags)
            save(self.folder/'worker.json',dict(pid=child.pid,day=day,solver_folder=str(solvefolder)))
            try:
                while child.poll() is None:
                    if (self.folder/'STOP').exists():(solvefolder/'STOP').touch()
                    time.sleep(.2)
            finally:
                if child.poll() is None:child.terminate();child.wait()
        budget.settle(read(solvefolder/'solver.json').get('solver_seconds') if (solvefolder/'solver.json').exists() else None)
        if (self.folder/'STOP').exists():raise InterruptedError('Stop requested during solve; see '+str(solvefolder))
        if child.returncode or not (solvefolder/'done.json').exists():raise RuntimeError(settings['name']+' child failed: '+str(solvefolder/'error.json'))
        log=read(solvefolder/'done.json');z=np.load(solvefolder/'solution.npy',allow_pickle=False);z,checks=validate(m,z)
        validate_plan(m,meta,z,self.data)
        action=action_from_plan(m,meta,z,day)
        action['purchases']={p:int(z[j]) for (p,k),j in meta.get('buys',{}).items() if k==0 and z[j]}
        action['projected_inventory'].update({p:float(z[j]) for (p,k),j in meta.get('raw_stocks',{}).items() if k==0})
        log.update(day=day,horizon=meta['H'],build_seconds=build_seconds,state_hash=state_hash,SolveSequence=sequence,AttemptNo=attempt,
                   state_reference=state_reference,
                   output_reference=f'decisions/{day:04d}.json')
        import hashlib
        item=dict(day=day,state_hash=state_hash,solver=log,action=action,
                  solution_reference=str((solvefolder/'solution.npy').relative_to(self.folder)),
                  solution_sha256=hashlib.sha256((solvefolder/'solution.npy').read_bytes()).hexdigest())
        save(self.folder/'decisions'/f'{day:04d}.json',item);self.logs.append(log)
        self._audit(day,attempt,sequence,log,meta['H'],state_reference,log['output_reference']+'#sha256='+digest(item))
        return action

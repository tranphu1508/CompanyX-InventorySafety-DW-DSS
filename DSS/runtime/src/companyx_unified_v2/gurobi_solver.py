"""Gurobi on the corrected original daily model: no pilot/Repair120 alterations."""
from pathlib import Path
from types import SimpleNamespace
import gzip,json,math,os,pickle,shutil,sys,time,traceback
import numpy as np
import scipy.sparse as sp
import gurobipy as gp
from .legacy import save,read
from .cplex_solver import validate

def build_native(source,env):
    m=gp.Model(env=env);m.ModelSense=gp.GRB.MINIMIZE
    x=m.addMVar(len(source.keys),lb=np.asarray(source.lb),ub=np.asarray(source.ub),obj=np.asarray(source.cost),
               vtype=np.asarray(['I' if flag else 'C' for flag in source.integer]),name='x')
    lengths=np.asarray([len(r) for r in source.rows],dtype=np.int64)
    ptr=np.r_[0,np.cumsum(lengths)];nnz=int(ptr[-1])
    matrix=sp.csr_matrix((np.fromiter((v for r in source.rows for v in r.values()),float,count=nnz),
        np.fromiter((j for r in source.rows for j in r),np.int32,count=nnz),ptr),shape=(len(source.rows),len(source.keys)))
    matrix.sort_indices();lo=np.asarray(source.lo);hi=np.asarray(source.hi);equal=np.isfinite(lo)&(lo==hi)
    groups=[(np.flatnonzero(equal),'=',hi),(np.flatnonzero(np.isfinite(lo)&~equal),'>',lo),
            (np.flatnonzero(np.isfinite(hi)&~equal),'<',hi)]
    for ids,sense,rhs in groups:
        if len(ids):m.addMConstr(matrix[ids],x,sense,rhs[ids])
    m.update()
    return m,x,matrix,groups

def accepted_status(status,solutions):
    if status==gp.GRB.OPTIMAL and solutions:return 'OPTIMAL',True
    if status==gp.GRB.TIME_LIMIT and solutions:return 'FEASIBLE_TIME_LIMIT',True
    if status==gp.GRB.INFEASIBLE:return 'INFEASIBLE',False
    if not solutions:return 'NO_INCUMBENT',False
    return 'INTERRUPTED',False

def finite(value):return float(value) if math.isfinite(value) and abs(value)<1e70 else None

def solve(source,settings,folder):
    if settings['name']!='GUROBI':raise ValueError('Gurobi requires explicit GUROBI execution spec')
    folder=Path(folder).resolve();folder.mkdir(parents=True,exist_ok=True)
    result=None;started=None;began=time.perf_counter();stop_reason=None;last_tick=0
    try:
        with gp.Env(empty=True) as env:
            env.setParam('OutputFlag',0);env.start()
            m,x,matrix,groups=build_native(source,env)
            del matrix,groups
            with m:
                m.Params.OutputFlag=1;m.Params.LogToConsole=0;m.Params.LogFile=str(folder/'native.log')
                m.Params.Threads=settings['threads'];m.Params.TimeLimit=settings['time_limit_seconds']
                m.Params.MIPGap=settings['relative_gap'];m.Params.MIPGapAbs=settings['absolute_gap']
                m.Params.Seed=settings['seed'];m.Params.IntFeasTol=1e-6;m.Params.FeasibilityTol=1e-7
                # Private node spill is IO configuration, not a per-process RAM cap.
                nodes=folder/'nodes';nodes.mkdir(exist_ok=True)
                m.Params.NodefileStart=2.0;m.Params.NodefileDir=str(nodes)
                native=dict(Threads=m.Params.Threads,TimeLimit=m.Params.TimeLimit,MIPGap=m.Params.MIPGap,
                    MIPGapAbs=m.Params.MIPGapAbs,Seed=m.Params.Seed,ConcurrentMIP=m.Params.ConcurrentMIP,
                    MIPFocus=m.Params.MIPFocus,Method=m.Params.Method,NodefileStart=m.Params.NodefileStart,
                    warm_start_count=0,repair120=False)
                save(folder/'structure.json',dict(columns=m.NumVars,rows=m.NumConstrs,integers=m.NumIntVars,
                    original_rows=len(source.rows),original_columns=len(source.keys),full_model=True))
                started=time.perf_counter()
                save(folder/'phase.json',dict(status='SOLVING',pid=os.getpid(),started_epoch=time.time(),solver='GUROBI',
                    version=list(gp.gurobi.version()),settings=settings,native_settings=native))
                def callback(model,where):
                    nonlocal last_tick,stop_reason
                    now=time.perf_counter()
                    if now-last_tick<3:return
                    last_tick=now
                    try:
                        if (folder/'STOP').exists():stop_reason='STOP_REQUESTED';model.terminate()
                        if shutil.disk_usage(folder).free<10*2**30:stop_reason='LOW_DISK';model.terminate()
                        obj=bound=None
                        if where==gp.GRB.Callback.MIP:
                            obj=finite(model.cbGet(gp.GRB.Callback.MIP_OBJBST));bound=finite(model.cbGet(gp.GRB.Callback.MIP_OBJBND))
                        save(folder/'native_progress.json',dict(pid=os.getpid(),updated_epoch=time.time(),solver_seconds=now-started,
                            objective=obj,best_bound=bound,relative_gap=None if obj is None or bound is None else abs(obj-bound)/max(abs(obj),1e-10),stop_reason=stop_reason))
                    except Exception as exc:
                        stop_reason='MONITOR_CALLBACK_ERROR: '+str(exc);model.terminate()
                m.optimize(callback)
                seconds=time.perf_counter()-started;status,accepted=accepted_status(m.Status,m.SolCount)
                if stop_reason:status='INTERRUPTED';accepted=False
                try:bound=finite(m.ObjBound)
                except (AttributeError,gp.GurobiError):bound=None
                result=dict(solver='GUROBI',version=list(gp.gurobi.version()),native_status_code=m.Status,
                    status=status,accepted=accepted,has_feasible_solution=bool(m.SolCount),solver_seconds=seconds,
                    load_seconds=started-began,settings=settings,native_settings=native,stop_reason=stop_reason,
                    objective=None,best_bound=bound,relative_gap=None,action_source='NONE')
                z=None
                if m.SolCount:
                    z,checks=validate(source,np.asarray(x.X));result.update(checks)
                    if abs(checks['objective']-m.ObjVal)>1e-6*max(1,abs(m.ObjVal)):raise ValueError('Transferred objective mismatch')
                    result['relative_gap']=finite(m.MIPGap)
                result['action_source']='SOLVER_INCUMBENT' if accepted else 'NONE'
                save(folder/'solver.json',result)
                if not accepted:raise RuntimeError('Gurobi solution not accepted: '+str(stop_reason or status))
                return z,result
    except BaseException as exc:
        if not (folder/'solver.json').exists():
            save(folder/'solver.json',dict(result or {},solver='GUROBI',status='ERROR',accepted=False,
                has_feasible_solution=False,action_source='NONE',error=str(exc),
                solver_seconds=time.perf_counter()-started if started else 0))
        raise

def main():
    folder=Path(sys.argv[1]).resolve()
    try:
        with gzip.open(folder/'request.pkl.gz','rb') as f:r=pickle.load(f)
        z,log=solve(SimpleNamespace(**r['model']),r['settings'],folder)
        np.save(folder/'solution.npy',z,allow_pickle=False);save(folder/'done.json',log)
    except BaseException as exc:
        save(folder/'error.json',dict(error=str(exc),traceback=traceback.format_exc()));raise

if __name__=='__main__':main()

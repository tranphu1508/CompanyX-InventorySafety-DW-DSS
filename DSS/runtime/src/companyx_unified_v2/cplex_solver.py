"""Native CPLEX in an isolated child, with independent primal validation."""
from pathlib import Path
from types import SimpleNamespace
import gzip,json,math,os,pickle,sys,time,traceback
import numpy as np
from .legacy import save

def validate(m,z):
    z=np.asarray(z,dtype=float)
    if len(z)!=len(m.keys) or not np.all(np.isfinite(z)):raise ValueError('Invalid primal vector')
    integer=np.asarray(m.integer,dtype=bool)
    # Manufacturing states are integer-implied, while expected raw inventories may be fractional.
    implied=np.array([k[0]!='raw_I' for k in m.keys])
    mask=integer|implied
    error=float(np.max(np.abs(z[mask]-np.rint(z[mask])),initial=0))
    if error>1e-5:raise ValueError('Nonintegral physical state')
    z[mask]=np.rint(z[mask])
    activity=np.fromiter((sum(z[j]*a for j,a in row.items()) for row in m.rows),dtype=float,count=len(m.rows))
    violation=max(float(np.max(np.maximum(np.array(m.lo)-activity,0),initial=0)),
                  float(np.max(np.maximum(activity-np.array(m.hi),0),initial=0)),
                  float(np.max(np.maximum(np.array(m.lb)-z,0),initial=0)),
                  float(np.max(np.maximum(z-np.array(m.ub),0),initial=0)))
    if violation>1e-5:raise ValueError(f'Original-model constraint violation: {violation}')
    return z,dict(max_constraint_violation=violation,max_integer_error=error,objective=float(np.array(m.cost)@z))

def solve(m,settings,folder):
    import cplex
    from cplex.callbacks import MIPInfoCallback
    folder=Path(folder).resolve();folder.mkdir(parents=True,exist_ok=True)
    c=cplex.Cplex();stream=(folder/'native.log').open('w',encoding='utf-8')
    began=time.perf_counter();oldcwd=Path.cwd();started=None;result=None;seconds=None
    try:
        for setter in (c.set_log_stream,c.set_results_stream,c.set_warning_stream,c.set_error_stream):setter(stream)
        c.objective.set_sense(c.objective.sense.minimize)
        types=''.join('B' if flag and lo==0 and hi==1 else 'I' if flag else 'C' for flag,lo,hi in zip(m.integer,m.lb,m.ub))
        c.variables.add(obj=m.cost,lb=m.lb,ub=m.ub,types=types)
        for base in range(0,len(m.rows),2000):
            expr=[];senses=[];rhs=[];ranges=[]
            for row,lo,hi in zip(m.rows[base:base+2000],m.lo[base:base+2000],m.hi[base:base+2000]):
                expr.append(cplex.SparsePair(ind=list(row),val=list(row.values())))
                if lo==hi:senses.append('E');rhs.append(lo);ranges.append(0.)
                elif math.isfinite(lo) and math.isfinite(hi):senses.append('R');rhs.append(lo);ranges.append(hi-lo)
                elif math.isfinite(lo):senses.append('G');rhs.append(lo);ranges.append(0.)
                elif math.isfinite(hi):senses.append('L');rhs.append(hi);ranges.append(0.)
                else:raise ValueError('Free row unsupported')
            c.linear_constraints.add(lin_expr=expr,senses=''.join(senses),rhs=rhs,range_values=ranges)
        c.parameters.threads.set(settings['threads']);c.parameters.parallel.set(1);c.parameters.randomseed.set(settings['seed'])
        c.parameters.timelimit.set(settings['time_limit_seconds']);c.parameters.clocktype.set(2)
        c.parameters.mip.tolerances.mipgap.set(settings['relative_gap']);c.parameters.mip.tolerances.absmipgap.set(settings['absolute_gap'])
        c.parameters.mip.tolerances.integrality.set(1e-6);c.parameters.simplex.tolerances.feasibility.set(1e-7)
        # Only this child changes CWD. Relative native paths avoid CPLEX Unicode error 1422.
        nodes=folder/'nodes';nodes.mkdir(exist_ok=True);os.chdir(nodes)
        c.parameters.workdir.set('.')
        if settings['workmem_mb'] is None:
            # User removed RAM limits. Keep nodes in compressed memory; no
            # app-imposed working-memory threshold, disk spill, or process cap.
            c.parameters.mip.strategy.file.set(1)
        else:
            c.parameters.workmem.set(settings['workmem_mb']);c.parameters.mip.strategy.file.set(3)
        class Stop(MIPInfoCallback):
            def __call__(self):
                if (folder/'STOP').exists():self.abort()
        c.register_callback(Stop)
        started=time.perf_counter()
        save(folder/'phase.json',dict(status='SOLVING',pid=os.getpid(),settings=settings,started_epoch=time.time(),
                                     variables=len(m.keys),constraints=len(m.rows),version=c.get_version(),
                                     memory_limit_bytes=int(settings['max_ram_gib']*2**30) if settings.get('max_ram_gib') is not None else None,native_threads=c.parameters.threads.get(),
                                     native_node_file_strategy=c.parameters.mip.strategy.file.get()))
        c.solve();seconds=time.perf_counter()-started
        native=c.solution.get_status_string();status_code=c.solution.get_status();feasible=c.solution.is_primal_feasible()
        result=dict(solver='CPLEX',version=c.get_version(),native_status=native,native_status_code=status_code,
            solver_seconds=seconds,load_seconds=started-began,settings=settings,has_feasible_solution=bool(feasible),
            objective=None,best_bound=None,relative_gap=None,action_source='NONE')
        def finite(x):return float(x) if math.isfinite(x) and abs(x)<1e70 else None
        try:result['best_bound']=finite(c.solution.MIP.get_best_objective())
        except cplex.exceptions.CplexError:pass
        z=None
        if feasible:
            z,checks=validate(m,c.solution.get_values());result.update(checks)
            result['relative_gap']=finite(c.solution.MIP.get_mip_relative_gap())
            native_obj=c.solution.get_objective_value()
            if abs(checks['objective']-native_obj)>1e-6*max(1,abs(native_obj)):raise ValueError('Objective mismatch')
        # A stopped/memory-aborted incumbent is not silently called a time-limit result.
        optimal=status_code==c.solution.status.MIP_optimal
        near=status_code==c.solution.status.optimal_tolerance
        timed=status_code==c.solution.status.MIP_time_limit_feasible
        infeasible=status_code==c.solution.status.MIP_infeasible
        result['status']='OPTIMAL' if optimal else 'NEAR_OPTIMAL' if near else 'FEASIBLE_TIME_LIMIT' if timed and feasible else 'INFEASIBLE' if infeasible else 'NO_INCUMBENT' if not feasible else 'INTERRUPTED'
        result['accepted']=bool(feasible and (optimal or near or timed))
        result['action_source']='SOLVER_INCUMBENT' if result['accepted'] else 'NONE'
        save(folder/'solver.json',result)
        if not result['accepted']:raise RuntimeError(f'CPLEX decision not accepted: {native}')
        return z,result
    except BaseException as exc:
        # Preserve native solve duration even when extraction/primal validation fails.
        # An unvalidated primal must never count as HasFeasibleSolution in V6.
        if not (folder/'solver.json').exists():
            failed=dict(result or {},solver='CPLEX',status='ERROR',accepted=False,
                has_feasible_solution=False,action_source='NONE',error=str(exc),
                solver_seconds=seconds if seconds is not None else time.perf_counter()-started if started is not None else 0.,
                timing_basis='native solve wall clock; zero only if solve was not entered')
            save(folder/'solver.json',failed)
        raise
    finally:
        c.end();stream.close();os.chdir(oldcwd)

def main():
    folder=Path(sys.argv[1]).resolve()
    try:
        with gzip.open(folder/'request.pkl.gz','rb') as f:request=pickle.load(f)
        z,log=solve(SimpleNamespace(**request['model']),request['settings'],folder)
        np.save(folder/'solution.npy',z,allow_pickle=False)
        save(folder/'done.json',log)
    except BaseException as exc:
        save(folder/'error.json',dict(error=str(exc),traceback=traceback.format_exc()))
        raise

if __name__=='__main__':main()

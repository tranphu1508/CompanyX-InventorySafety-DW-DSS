"""Bounded parallel workers; no shared process state, no global solver threads."""
from pathlib import Path
import argparse,json,os,subprocess,sys,time
from .config import expand
from .legacy import save,read,digest

def free_memory_gib():
    if os.name=='nt':
        import ctypes
        class Memory(ctypes.Structure):
            _fields_=[('length',ctypes.c_ulong),('load',ctypes.c_ulong)]+[(x,ctypes.c_ulonglong) for x in ('total_phys','avail_phys','total_page','avail_page','total_virtual','avail_virtual','extended')]
        m=Memory();m.length=ctypes.sizeof(m)
        if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)):raise OSError('Memory query failed')
        return min(m.avail_phys,m.avail_page)/2**30
    return os.sysconf('SC_AVPHYS_PAGES')*os.sysconf('SC_PAGE_SIZE')/2**30

def run_batch(matrix,input_path,output,max_workers=2,cpu_budget=16,reserve_memory_gib=0,worker_memory_gib=0):
    if max_workers<1 or cpu_budget<1 or reserve_memory_gib<0 or worker_memory_gib<0:raise ValueError('Invalid scheduler budget')
    cases=expand(matrix);output=Path(output).resolve()
    if output.exists() and any(output.iterdir()):raise ValueError('Batch output must be new/empty')
    output.mkdir(parents=True,exist_ok=True);pending=[];active={};finished=[];overlap=0
    input_path=Path(input_path).resolve()
    for i,case in enumerate(cases):
        threads=case['spec']['solver']['threads'] if case['spec']['policy']=='QUETSCHLICH_ADAPT' else 1
        if threads>cpu_budget:raise ValueError('A run exceeds CPU budget; set explicit per-run solver threads')
        folder=output/f"run_{i+1:03d}_{case['spec']['policy'].lower()}_{digest(case)[:10]}"
        specfile=output/f'spec_{i+1:03d}.json';save(specfile,case['spec'])
        pending.append(dict(index=i,name=case['name'],folder=str(folder),spec=str(specfile),threads=threads))
    save(output/'batch.json',dict(matrix=matrix,input=str(input_path),max_workers=max_workers,cpu_budget=cpu_budget,
        reserve_memory_gib=reserve_memory_gib,worker_memory_gib=worker_memory_gib,cases=pending))
    flags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0
    try:
        while pending or active:
            stopping=(output/'STOP').exists()
            for i,(child,job,stream) in list(active.items()):
                if stopping:
                    folder=Path(job['folder']);folder.mkdir(parents=True,exist_ok=True);(folder/'STOP').touch()
                if child.poll() is not None:
                    stream.close();statuspath=Path(job['folder'])/'status.json'
                    status=read(statuspath) if statuspath.exists() else dict(status='FAILED',error='Worker exited without status')
                    if child.returncode!=0 and status.get('status')=='COMPLETE':
                        status=dict(status='FAILED',error='Worker exited nonzero despite completion status',returncode=child.returncode)
                    elif status.get('status') not in ('COMPLETE','FAILED','INTERRUPTED'):
                        status=dict(status='FAILED',error='Worker exited without terminal status',last_status=status,returncode=child.returncode)
                    elif status.get('status')=='COMPLETE' and not (Path(job['folder'])/'completion.json').exists():
                        status=dict(status='FAILED',error='Worker exited without completion.json')
                    finished.append(dict(**job,returncode=child.returncode,status=status));del active[i]
            if stopping and not active:break
            used=sum(j['threads'] for _,j,_ in active.values())
            for job in list(pending):
                if stopping or len(active)>=max_workers:break
                if used+job['threads']>cpu_budget:continue
                if reserve_memory_gib+worker_memory_gib>0 and free_memory_gib()<reserve_memory_gib+worker_memory_gib:break
                stream=(output/f"worker_{job['index']:03d}.log").open('w',encoding='utf-8')
                env=os.environ.copy()
                for key in ('OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):env[key]='1'
                child=subprocess.Popen([sys.executable,'-m','companyx_unified_v2.run','--input',str(input_path),'--spec',job['spec'],'--output',job['folder'],'--name',job['name']],
                    env=env,stdout=stream,stderr=subprocess.STDOUT,creationflags=flags)
                active[job['index']]=(child,job,stream);pending.remove(job);used+=job['threads'];overlap=max(overlap,len(active))
            save(output/'status.json',dict(status='STOPPING' if stopping else 'RUNNING',
                running=[dict(**j,pid=c.pid) for c,j,_ in active.values()],pending=pending,finished=finished,
                max_observed_concurrency=overlap,free_memory_gib=free_memory_gib()))
            if pending or active:time.sleep(1)
    finally:
        # Stop only owned runs. Their controllers signal and clean up owned CPLEX children.
        for child,job,stream in active.values():
            folder=Path(job['folder']);folder.mkdir(parents=True,exist_ok=True);(folder/'STOP').touch()
        for child,job,stream in active.values():child.wait();stream.close()
    result=dict(status='INTERRUPTED' if pending else 'COMPLETE' if all(x['status']['status']=='COMPLETE' for x in finished) else 'FAILED',
                finished=finished,pending=pending,max_observed_concurrency=overlap)
    save(output/'status.json',result);return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--matrix',required=True);p.add_argument('--input',required=True);p.add_argument('--output',required=True)
    p.add_argument('--max-workers',type=int,default=2);p.add_argument('--cpu-budget',type=int,default=16)
    p.add_argument('--reserve-memory-gib',type=float,default=0);p.add_argument('--worker-memory-gib',type=float,default=0)
    a=p.parse_args();r=run_batch(read(a.matrix),a.input,a.output,a.max_workers,a.cpu_budget,a.reserve_memory_gib,a.worker_memory_gib)
    if r['status']!='COMPLETE':sys.exit(1)

if __name__=='__main__':main()

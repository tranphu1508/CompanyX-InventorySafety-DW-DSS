"""Four isolated offer workers; only the parent publishes after horizon reconciliation."""
from concurrent.futures import ProcessPoolExecutor
from datetime import date
import multiprocessing
import os
from pathlib import Path
import time

from settings import read, save
from priority_offer_plan import context, model_for, solve_variant, bundle_results, impact
from protected_old_offer import run as protected_run, NoProtectedOffer


def worker(mode, source, request, folder, horizon, threads, max_days):
    folder=Path(folder)
    started=time.time()
    save(folder/'worker.json',dict(mode=mode,pid=os.getpid(),threads=threads,started=started,state='RUNNING'))
    try:
        if mode=='B':
            try:
                result=protected_run(source,request,None,folder,max_days=max_days,
                                     base_horizon=horizon,solver_threads=threads)
            except NoProtectedOffer:
                result=dict(status='NO_B',search=read(folder/'progress.json'))
        else:
            ctx=context(source,request)
            ctx['solver_threads']=threads
            result=solve_variant(ctx,folder,mode,horizon)
        save(folder/'worker.json',dict(mode=mode,pid=os.getpid(),threads=threads,started=started,
                                      finished=time.time(),state='DONE'))
        return result
    except BaseException:
        save(folder/'worker.json',dict(mode=mode,pid=os.getpid(),threads=threads,started=started,
                                      finished=time.time(),state='FAILED'))
        raise


def run(source, request, folder, max_days=45):
    folder=Path(folder)
    ctx=context(source,request)
    _,meta,_=model_for(ctx,'A1')
    initial_horizon=meta['H']
    threads=min(ctx['spec']['solver']['threads'],max(1,(os.cpu_count() or 1)//4))
    save(folder/'execution.json',dict(workers=4,threadsPerWorker=threads,
                                    initialHorizon=initial_horizon,policy='A1_A2_C_B_PARALLEL_B_DATES_SEQUENTIAL'))
    with ProcessPoolExecutor(max_workers=4,mp_context=multiprocessing.get_context('spawn')) as pool:
        jobs={mode:pool.submit(worker,mode,source,request,folder/mode,initial_horizon,threads,max_days)
              for mode in ('A1','A2','C','B')}
        # A2 determines the final common horizon. Results on a shorter horizon are speculative.
        a2=jobs['A2'].result()
        horizon=(date.fromisoformat(a2['evaluationEnd'])-ctx['known']).days if a2['status']=='OPTIMAL' else initial_horizon
        results={mode:job.result() for mode,job in jobs.items()}
        b_folder=folder/'B'
        if horizon!=initial_horizon:
            modes=['C','B']+(['A1'] if results['A1']['status']=='OPTIMAL' else [])
            again={mode:pool.submit(worker,mode,source,request,folder/'common'/mode,horizon,threads,max_days)
                   for mode in modes}
            results.update({mode:job.result() for mode,job in again.items()})
            b_folder=folder/'common'/'B'
        b=results.pop('B')
        if b['status']!='NO_B':
            control=results['C']
            b_horizon=(date.fromisoformat(b['evaluationEnd'])-ctx['known']).days
            if b_horizon!=horizon:
                control=pool.submit(worker,'C',source,request,b_folder/'control-common',b_horizon,threads,max_days).result()
            b['impact']=impact(b,control,ctx)
            assert b['impact']['additionalLostOrders']==0 and b['impact']['delayedOrders']==0
            save(b_folder/'B.json',b)
    # No worker writes warehouse rows. All variants must be verified before publication.
    bundle=bundle_results(ctx,request,results,folder)
    save(folder/'execution.json',dict(workers=4,threadsPerWorker=threads,initialHorizon=initial_horizon,
                                    finalHorizon=horizon,reconciled=horizon!=initial_horizon,state='VERIFIED'))
    return bundle,b

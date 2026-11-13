"""B: earliest deadline that serves the new order and preserves every known old due date.
Uses the same verified one-day state and optimizer; no DES execution or core edits.
"""
from datetime import date,timedelta
from pathlib import Path
from copy import deepcopy
from priority_offer_plan import context,model_for,solve,summarize,impact
from settings import read,save

class NoProtectedOffer(RuntimeError):
    pass

def run(source,request,control,folder,max_days=45,*,base_horizon=None,solver_threads=None):
    folder=Path(folder);folder.mkdir(parents=True,exist_ok=True)
    known=date.fromisoformat(request['known_at'])
    full=next(c for c in request['candidates'] if c['kind']=='FULL')
    original=date.fromisoformat(full['tranches'][0]['due_date'])
    control=deepcopy(control)
    if control is not None:
        control['settlements']={int(k):v for k,v in control['settlements'].items()}
        base_h=(date.fromisoformat(control['evaluationEnd'])-known).days
    elif base_horizon is not None:
        base_h=base_horizon
    else:
        raise ValueError('B requires a control or an explicit evaluation horizon')
    attempts=[]
    for delta in range(max_days+1):
        due=original+timedelta(days=delta)
        req=deepcopy(request)
        next(c for c in req['candidates'] if c['kind']=='FULL')['tranches'][0]['due_date']=due.isoformat()
        req['analysis_end']=max(req['analysis_end'],due.isoformat())
        ctx=context(Path(source),req)
        if solver_threads is not None:ctx['solver_threads']=solver_threads
        horizon=max(base_h,(due-known).days)
        model,meta,orders=model_for(ctx,'A1',horizon)
        old_ids={o['SalesOrderID'] for o in ctx['old']}
        for order in ctx['old']:
            t=(order['due']-known).days
            index=model.index.get(('order_ship',order['SalesOrderID'],t))
            if index is None:raise ValueError('Old commitment has no on-time decision variable')
            model.lb[index]=1
        for j,key in enumerate(model.keys):
            if key[0] in ('order_unserved','order_loss') and key[1] in old_ids:model.ub[j]=0
        check,values=solve(model,meta,ctx,folder/f'feasibility-{delta:03d}','B',feasibility=True)
        attempts.append({'due':due.isoformat(),'feasible':check['hasSolution'],'infeasible_proven':check['infeasible']})
        save(folder/'progress.json',{'attempts':attempts,'currentDue':due.isoformat()})
        print('B_ATTEMPT',due,check['status'],flush=True)
        if check['infeasible']:continue
        if not check['hasSolution']:raise RuntimeError('Feasibility unresolved; cannot claim earliest deadline')
        # Restore the unchanged objective's choice for the new order. Old orders remain hard commitments.
        index=model.index[('order_ship',ctx['oid'],(due-known).days)]
        model.lb[index]=0
        answer,values=solve(model,meta,ctx,folder/f'optimal-{delta:03d}','B')
        if not answer['optimal']:raise RuntimeError('B optimality unresolved')
        summary=summarize(model,meta,values,ctx,orders,horizon)
        shipment=summary['settlements'][ctx['oid']]
        if shipment['status']!='order_ship':continue
        if control is not None and horizon!=base_h:
            cm,cmeta,co=model_for(ctx,'C',horizon)
            ca,cv=solve(cm,cmeta,ctx,folder/'control-common','C')
            if not ca['optimal']:raise RuntimeError('Common control not optimal')
            control=summarize(cm,cmeta,cv,ctx,co,horizon)
        qty=ctx['new'][0]['lines'][0]['remaining']
        summary.update(variant='B',status='OPTIMAL',due=due.isoformat(),plannedShip=qty,plannedLoss=0,
                       baseStateHash=ctx['stateHash'],snapshotId=ctx['binding']['snapshot_id'],
                       orderChanges=list(summary['settlements'].values()),policy='PRESERVE_ALL_OLD_DUE_DATES',
                       daysAfterOriginalDue=delta,search={'status':'FIRST_FULL_DELIVERY_WITH_OLD_COMMITMENTS','attempts':attempts})
        if control is not None:
            summary['impact']=impact(summary,control,ctx)
            assert summary['impact']['additionalLostOrders']==0 and summary['impact']['delayedOrders']==0
        save(folder/'B.json',summary)
        return summary
    raise NoProtectedOffer('No eligible B within the searched window')

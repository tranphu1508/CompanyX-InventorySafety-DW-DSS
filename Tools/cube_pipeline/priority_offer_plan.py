"""Single-date priority offers, with immutable opening state and explicit plan outcomes."""
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import date, timedelta
from pathlib import Path
from types import SimpleNamespace
import argparse, gzip, json, os, pickle, sys, time

from settings import DEMO, PROJECT, GPT, read, save, sql
sys.path[:0] = [str(DEMO/'DSS/control'), str(DEMO/'DSS'), str(DEMO/'DSS/runtime/src')]
from dss_bridge import validate_input, inquiry_v2
from day_offer_plan import dates
from model_v3.optimizer import build, forecast_objective
from companyx_unified_v2.orders import OrderBook
from companyx_unified_v2.supply import Supply
from companyx_unified_v2.gurobi_solver import build_native
from companyx_unified_v2.cplex_solver import validate
from companyx_unified_v2.immediate_start import validate_plan
from simulation.rolling_plan import _receipt_locations
import gurobipy as gp
import numpy as np

def context(source, request):
    binding = validate_input()
    scope = read(source/'scope.json')
    state = read(source/'solves'/f"{(date.fromisoformat(request['known_at'])-date.fromisoformat(scope['start'])).days:04d}"/'state.json')
    day = state['day']
    accepted = read(source/'decisions'/f'{day:04d}.json')
    _, _, _, inputs, legacy, _, _ = inquiry_v2.runtime(PROJECT)
    if (scope['known_at'] != request['known_at'] or scope['base_run_key'] != request['base_run_key']
        or scope['synthetic_orders'] or read(source/'prefix_proof.json')['status'] != 'PASSED'
        or legacy.digest(state) != accepted['state_hash']
        or read(source.parents[2]/'input_binding.json') != binding or state['public_purchases']):
        raise ValueError('Opening state/input identity mismatch')
    candidate = next(c for c in request['candidates'] if c['kind']=='FULL')
    prepared = inquiry_v2.build_request(request, candidate['candidate_id'], PROJECT)
    if prepared['spec'] != state['spec'] or prepared['scope']['base_run_code'] != scope['base_run_code']:
        raise ValueError('Source state configuration changed')
    data = inputs.prepare(prepared['snapshot'], prepared['spec'])
    oid = prepared['scope']['synthetic_sales_order_ids'][0]
    book = OrderBook([l for l in data['lines'] if l['SalesOrderID']==oid], data['P'], data['external_ids'],
                     data['start'], data['end'], '7C')
    book.reveal(day)
    old = dates(state['orders'])
    new = book.snapshot()
    demand = defaultdict(list, dict(dates(state['book'])))
    for pid, lines in book.manufactured_book().items():
        demand[pid].extend(lines)
    spec = prepared['spec']
    if data['raw'] or spec['supply']['mode'] != 'INSTANT_UNLIMITED':
        raise ValueError('Priority negotiation currently supports the instant-unlimited procurement scenario')
    supply = Supply(data,dict(rep=spec['replication'],probs=spec['supply']['delay_probabilities'],
                             p=spec['supply']['reject_probability']))
    return dict(data=data,spec=spec,inv=Counter(dict(state['inventory'])),pipe=dict(state['pipeline']),
                queue=state['queue'],old=old,new=new,book=demand,oldbook=defaultdict(list,dict(dates(state['book']))),
                supply=supply,day=day,known=date.fromisoformat(request['known_at']),oid=oid,
                stateHash=accepted['state_hash'],binding=binding)

def model_for(ctx, mode, horizon=None, delay=None):
    negotiation = mode=='A2'
    spec = deepcopy(ctx['spec'])
    if negotiation:
        spec['allow_backorders'] = True
    orders = ctx['old'] if mode=='C' else sorted(ctx['old']+ctx['new'],key=OrderBook.priority)
    book = ctx['oldbook'] if mode=='C' else ctx['book']
    model, meta = build(ctx['data'],spec,ctx['inv'],ctx['pipe'],book,ctx['queue'],orders,ctx['supply'],ctx['day'],horizon=horizon)
    if negotiation:
        forecast_objective(model,meta,ctx['spec'])
    if mode!='C':
        due = (ctx['new'][0]['due']-ctx['known']).days
        forced = model.index.get(('order_ship',ctx['oid'],due))
        if forced is None:
            raise ValueError('New deadline outside optimization horizon')
        model.lb[forced] = 1
        if negotiation:
            for j,key in enumerate(model.keys):
                if key[0]=='order_unserved':
                    model.ub[j]=0
                elif key[0]=='order_ship':
                    order = next(o for o in orders if o['SalesOrderID']==key[1])
                    deadline = max(0,(order['due']-ctx['known']).days)
                    if (key[1]==ctx['oid'] and key[2]!=due) or (key[1]!=ctx['oid'] and key[2]>deadline+delay):
                        model.ub[j]=0
    return model,meta,orders

def solve(model, meta, ctx, folder, mode, feasibility=False):
    folder.mkdir(parents=True,exist_ok=True)
    request_hash = __import__('hashlib').sha256(pickle.dumps(model.__dict__,protocol=5)).hexdigest()
    saved = folder/'result.json'
    if saved.exists():
        result=read(saved)
        if result['modelHash']!=request_hash:
            raise ValueError('Diagnostic/resume model changed')
        values=np.load(folder/'solution.npy',allow_pickle=False) if result['hasSolution'] else None
        return result,values
    with gzip.open(folder/'model.pkl.gz','wb') as stream:
        pickle.dump(model.__dict__,stream,protocol=5)
    with gp.Env(empty=True) as env:
        env.setParam('OutputFlag',0)
        env.start()
        native,x,_,_=build_native(model,env)
        with native:
            settings=ctx['spec']['solver']
            native.Params.Threads=settings['threads']
            native.Params.TimeLimit=settings['time_limit_seconds']
            native.Params.MIPGap=0
            native.Params.MIPGapAbs=0
            native.Params.FeasibilityTol=1e-7
            native.Params.IntFeasTol=1e-6
            native.Params.Seed=settings['seed']
            native.Params.LogFile=str(folder/'solver.log')
            if feasibility:
                native.setObjective(0)
                native.Params.SolutionLimit=1
            elif mode=='A2':
                # All orders are hard constraints. First reduce order-days, then holding value-days.
                orders={o['SalesOrderID']:o for o in ctx['old']}
                late=np.zeros(len(model.keys))
                holding=np.zeros(len(model.keys))
                for j,key in enumerate(model.keys):
                    if key[0]=='order_ship' and key[1] in orders:
                        late[j]=max(0,key[2]-(orders[key[1]]['due']-ctx['known']).days)
                    if key[0] in ('I','raw_I'):
                        cost=ctx['data']['products'][key[1]]['UnitCost']
                        if cost is None: raise ValueError('Missing inventory valuation')
                        holding[j]=cost
                native.setObjectiveN(late@x,0,priority=2,abstol=0,reltol=0,name='old_order_days_late')
                native.setObjectiveN(holding@x,1,priority=1,abstol=0,reltol=0,name='inventory_value_days')
            native.optimize()
            result=dict(modelHash=request_hash,status=int(native.Status),hasSolution=bool(native.SolCount),
                        optimal=native.Status==gp.GRB.OPTIMAL,infeasible=native.Status==gp.GRB.INFEASIBLE,
                        seconds=native.Runtime)
            values=None
            if native.SolCount:
                values=np.asarray(x.X)
                validate(model,values)
                validate_plan(model,meta,values,ctx['data'])
                np.save(folder/'solution.npy',values,allow_pickle=False)
            save(saved,result)
    return result,values

def summarize(model,meta,values,ctx,orders,horizon):
    locations=_receipt_locations(model.__dict__)
    changes={}
    actions=[]
    inventory=0
    for j,key in enumerate(model.keys):
        value=float(values[j])
        if key[0] in ('I','raw_I'):
            cost=ctx['data']['products'][key[1]]['UnitCost']
            if cost is None:raise ValueError('Missing inventory valuation')
            inventory+=value*cost
        if abs(value)<1e-7:continue
        if key[0] in ('order_ship','order_loss','order_unserved'):
            changes[key[1]]=dict(orderId=key[1],status=key[0],date=str(ctx['known']+timedelta(days=key[2])))
        if key[0]=='a':
            receipts=locations.get(j,[])
            if len(receipts)!=1:raise ValueError('Ambiguous production completion')
            actions.append(dict(ProductID=key[1],ActionCode='PRODUCTION_START',
                PlanAt=str(ctx['known']+timedelta(days=key[2])),
                PlannedCompletionAt=str(ctx['known']+timedelta(days=receipts[0][0])),Quantity=value))
    late=[]
    for order in orders:
        item=changes.get(order['SalesOrderID'])
        if item is None:raise ValueError('Missing settlement')
        if item['status']=='order_ship':
            delay=max(0,(date.fromisoformat(item['date'])-order['due']).days)
            item['lateDays']=delay
            if delay and order['SalesOrderID']!=ctx['oid']:late.append(delay)
        item.update(units=sum(l['remaining'] for l in order['lines']),originalDue=str(order['due']))
    return dict(actions=actions,settlements=changes,inventoryMean=inventory/(horizon+1),
                delayedOrders=len(late),totalLateDays=sum(late),meanLateDays=sum(late)/len(late) if late else 0,
                maxLateDays=max(late,default=0),evaluationStart=str(ctx['known']),
                evaluationEnd=str(ctx['known']+timedelta(days=horizon)))

def impact(result,control,ctx):
    extra=[]
    for order in ctx['old']:
        oid=order['SalesOrderID']
        before=control['settlements'][oid]
        after=result['settlements'][oid]
        if before['status']=='order_ship' and after['status']!='order_ship':extra.append(after)
    return dict(additionalLostOrders=len(extra),additionalLostUnits=sum(o['units'] for o in extra),
                additionalLostOrderIds=[o['orderId'] for o in extra],
                delayedOrders=result['delayedOrders'],totalLateDays=result['totalLateDays'],
                meanLateDays=result['meanLateDays'],maxLateDays=result['maxLateDays'],
                inventoryMean=result['inventoryMean'],controlInventoryMean=control['inventoryMean'],
                inventoryDelta=result['inventoryMean']-control['inventoryMean'],
                evaluationStart=result['evaluationStart'],evaluationEnd=result['evaluationEnd'])

def run(source,request,folder,publish=True):
    folder.mkdir(parents=True,exist_ok=True)
    ctx=context(source,request)
    a1,meta,orders=model_for(ctx,'A1')
    horizon=meta['H']
    root=ctx['new'][0]['lines'][0]
    product=root['p']
    due=(ctx['new'][0]['due']-ctx['known']).days
    # A finite upper bound on arrivals before the new deadline proves some cases impossible,
    # even after every old customer order is removed.
    capacity=ctx['inv'][product]+sum(q for t,items in ctx['pipe'].items() if ctx['day']<=t<=ctx['day']+due for p,q in items if p==product)
    for label,row in zip(a1.labels,a1.rows):
        if label!='inventory':continue
        own=next((a1.keys[j] for j,c in row.items() if c==1 and a1.keys[j][0]=='I'),None)
        if own and own[1]==product and own[2]<=due:
            capacity+=sum(-c*a1.ub[j] for j,c in row.items() if c<0 and a1.keys[j][0]=='a')
    results={}
    if capacity+1e-6<root['remaining']:
        certificate=dict(reason='NEW_ORDER_PHYSICAL_DEADLINE',productId=product,quantity=root['remaining'],
                         maximumAvailableUpperBound=capacity,due=str(ctx['new'][0]['due']))
        save(folder/'physical_certificate.json',certificate)
        for mode in ('A1','A2'):
            results[mode]=dict(variant=mode,status='INFEASIBLE',reason=certificate['reason'],
                explanation='Tồn kho và khả năng hoàn thành trước hạn không đủ, kể cả khi nhường nguồn hàng của đơn cũ.',
                actions=[],impact=None,orderChanges=[],certificate=certificate)
    else:
        answer,values=solve(a1,meta,ctx,folder/'A1','A1')
        if not answer['optimal'] and not answer['infeasible']:
            raise RuntimeError('A1 has not reached an optimal solution or infeasibility certificate')
        if answer['optimal']:
            results['A1']=summarize(a1,meta,values,ctx,orders,horizon)
            results['A1'].update(variant='A1',status='OPTIMAL')
        else:
            results['A1']=dict(variant='A1',status='INFEASIBLE',actions=[],impact=None,orderChanges=[])
        # Feasibility is monotone in the allowed delay. Bracket, then locate the
        # smallest maximum delay before optimizing total order-days and holding.
        def check_delay(delay):
            h=max(horizon,max((o['due']-ctx['known']).days+delay for o in ctx['old']) if ctx['old'] else horizon)
            candidate,cm,co=model_for(ctx,'A2',h,delay)
            check,z=solve(candidate,cm,ctx,folder/f'A2-search-{delay:04d}','A2',feasibility=True)
            save(folder/'progress.json',dict(stage='A2_SEARCH',delay=delay,status=check))
            if not check['hasSolution'] and not check['infeasible']:
                raise RuntimeError('A2 feasibility unresolved by solver')
            return check['hasSolution'],candidate,cm,co,h

        feasible,candidate,cm,co,h=check_delay(0)
        lower,upper=0,0
        if not feasible:
            # Test whether postponing old orders can help the new hard deadline at all.
            relaxed=dict(ctx,old=[],oldbook=defaultdict(list),book=defaultdict(list))
            for line in ctx['new'][0]['lines']:
                if line['manufactured']:relaxed['book'][line['p']].append(line)
            rm,rmeta,_=model_for(relaxed,'A1',horizon)
            proof,_=solve(rm,rmeta,relaxed,folder/'new-order-alone','A1',feasibility=True)
            if proof['infeasible']:
                results['A2']=dict(variant='A2',status='INFEASIBLE',reason='NEW_ORDER_ALONE_INFEASIBLE',
                    explanation='Đơn mới vẫn bất khả thi khi bỏ nghĩa vụ giao của tất cả đơn cũ.',
                    actions=[],impact=None,orderChanges=[])
            elif not proof['hasSolution']:
                raise RuntimeError('New-order physical feasibility unresolved')
            else:
                upper=1
                while not check_delay(upper)[0]:
                    lower,upper=upper,upper*2
                while upper-lower>1:
                    middle=(lower+upper)//2
                    if check_delay(middle)[0]:upper=middle
                    else:lower=middle
                feasible,candidate,cm,co,h=check_delay(upper)
        if feasible or 'A2' not in results:
            answer,z=solve(candidate,cm,ctx,folder/'A2','A2')
            if not answer['optimal']:raise RuntimeError('A2 optimality pending; completed results are not published')
            results['A2']=summarize(candidate,cm,z,ctx,co,h)
            results['A2'].update(variant='A2',status='OPTIMAL',minimumMaxDelayDays=upper)
            horizon=h
    # Recompute the control and A1 on one common horizon for comparable inventory means.
    control,cm,co=model_for(ctx,'C',horizon)
    answer,z=solve(control,cm,ctx,folder/'C','C')
    if not answer['optimal']:raise RuntimeError('Control optimality pending')
    results['C']=summarize(control,cm,z,ctx,co,horizon)
    results['C'].update(variant='C',status='OPTIMAL')
    if results['A1']['status']=='OPTIMAL' and results['A1']['evaluationEnd']!=results['C']['evaluationEnd']:
        m,mm,oo=model_for(ctx,'A1',horizon)
        answer,z=solve(m,mm,ctx,folder/'A1-common','A1')
        if not answer['optimal']:raise RuntimeError('Common-horizon A1 optimality pending')
        results['A1']=summarize(m,mm,z,ctx,oo,horizon)
        results['A1'].update(variant='A1',status='OPTIMAL')
    for mode,result in results.items():
        result['due']=str(ctx['new'][0]['due'])
        result['baseStateHash']=ctx['stateHash']
        if result['status']=='OPTIMAL':
            result['impact']=impact(result,results['C'],ctx)
            result['orderChanges']=list(result['settlements'].values())
            result['plannedShip']=root['remaining'] if mode!='C' else 0
            result['plannedLoss']=0 if mode!='C' else root['remaining']
    bundle=dict(schema='companyx.priority-offer.v1',knownAt=request['known_at'],
                newOrderDue=str(ctx['new'][0]['due']),sourceStateHash=ctx['stateHash'],
                sourceSnapshotId=ctx['binding']['snapshot_id'],variants=list(results.values()),
                interpretation='Single-date plans. A2 minimizes maximum delay, then total old-order days late, then inventory value-days.')
    save(folder/'priority.json',bundle)
    if not publish:
        print('Verified without SQL publication', {m:r['status'] for m,r in results.items()},flush=True)
        return bundle
    key=(request['base_run_key'],product,root['remaining'],request['known_at'],str(ctx['new'][0]['due']))
    with sql('SIM',autocommit=False) as cn:
        row=cn.execute("SELECT PlanJSON FROM cxdetail.DayOfferPlan WITH(UPDLOCK,HOLDLOCK) WHERE BaseRunKey=? AND ProductID=? AND Quantity=? AND KnownAt=? AND OriginalDue=? AND Slot='A'",*key).fetchone()
        if not row:raise ValueError('Original A plan is missing')
        document=json.loads(row[0])
        document['priority']=bundle
        cn.execute("UPDATE cxdetail.DayOfferPlan SET PlanJSON=? WHERE BaseRunKey=? AND ProductID=? AND Quantity=? AND KnownAt=? AND OriginalDue=? AND Slot='A'",json.dumps(document,separators=(',',':')),*key)
        cn.commit()
    save(folder/'publication.json',dict(status='PUBLISHED',key=key,variants={m:r['status'] for m,r in results.items()}))
    print('Published priority variants', {m:r['status'] for m,r in results.items()},flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for name in ('request','source','folder'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--no-publish',action='store_true')
    args=parser.parse_args()
    if any(GPT not in p.resolve().parents for p in (args.request,args.source,args.folder)):raise ValueError('Artifacts must stay under GPT')
    os.environ.setdefault('GRB_LICENSE_FILE',r'E:\Gurobi\gurobi.lic')
    run(args.source,read(args.request),args.folder,publish=not args.no_publish)

"""Versioned external checkpoint executor; frozen physical loop preserved.
Frozen engine source SHA256: 2b02a69e7f2d5222007cc10f2aaa48b49e3f993920e3c8558428626140e0efd2
Only initialization/restore, loop start and EOD checkpoint hooks differ.
"""
from collections import Counter,defaultdict
from copy import deepcopy
from datetime import timedelta
import math
from companyx_unified_v2.production_timing import finish_day
from companyx_unified_v2.immediate_start import startable_quantity, assert_immediate_starts
from companyx_unified_v2.orders import OrderBook
from companyx_unified_v2.supply import Supply,uniforms

from . import checkpoint_codec as checkpoint_io
from pathlib import Path
import hashlib

def executor_identity():
    from model_v3.release import release_identity
    return checkpoint_io.digest({'execution_files':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (Path(__file__),Path(checkpoint_io.__file__))},'optimizer_release':release_identity()})

def simulate(data,spec,controller=None,sink=None,progress=None,folder=None,*,checkpoint=None,checkpoint_sink=None):
    P=data['P'];raw=data['raw'];stock=set(P)|raw;bom=data['bom'];start=data['start'];end=data['end']
    if (spec['policy']=='QUETSCHLICH_ADAPT')!=(controller is not None):raise ValueError('Policy/controller mismatch')
    case='7B' if spec['allow_backorders'] else '7C'
    ob=OrderBook(data['lines'],P,data['external_ids'],start,end,case,raw)
    inv=Counter({p:x['initial'] for p,x in P.items()});inv.update({p:x['initial'] for p,x in data['rawparams'].items()})
    initial=inv.copy();wip=Counter();received=Counter();used=Counter();sold=Counter();requested=Counter();started=Counter()
    pipe=defaultdict(list);receipt_jobs=defaultdict(list);queue=[];jobid=0;execution=0
    config=dict(rep=spec['replication'],probs=spec['supply']['delay_probabilities'],p=spec['supply']['reject_probability'])
    supply=Supply(data,config,folder);logs=defaultdict(list);daily=[];ledger=[];sequence=0;t=0
    product_sums=defaultdict(Counter);unvalued=set()
    def emit(table,row):
        if sink:sink(table,row)
        else:logs[table].append(row)
    def event(code,p,q,entity,**kw):
        nonlocal sequence
        sequence+=1
        emit('Fact_SimulationEvent',dict(EventSequence=sequence,EventAt=str(start+timedelta(days=t)),
            EventCode=code,ProductID=p,Quantity=q,EntityCode=entity,KnownAt=str(start+timedelta(days=t)),**kw))
    def entity(code,kind,p,q,created,due=None,**kw):
        emit('RunEntity',dict(EntityCode=code,EntityType=kind,ProductID=p,OriginalQty=q,OpeningRemainingQty=0,
            CreatedAt=str(start+timedelta(days=created)),DueAt=str(start+timedelta(days=due)) if due is not None else None,
            IsOpeningEntity=False,**kw))
    def relation(parent,child,code,p,q):
        emit('Bridge_RunEntityRelation',dict(ParentEntityCode=parent,ChildEntityCode=child,RelationCode=code,
            AllocatedProductID=p,AllocatedQty=q))
    def solve_sequence():return getattr(controller,'current_solve_sequence',t+1) if controller else None
    def external_draw(p,q,entity_code,**values):
        # A virtual provision is not a purchase or receipt in the V6 event catalog.
        emit('ExternalSupplyDraw',dict(Date=str(start+timedelta(days=t)),ProductID=p,Quantity=q,EntityCode=entity_code,**values))
    def observe(kind,m,a,b,c):
        if kind=='order':
            import numpy as np
            ordinals=np.arange(m['ordinal0'],m['ordinal0']+len(a))
            us=uniforms(config['rep'],'lead',m['p'],m['vendor'],m['created'],m['purpose'],ordinals)
            for i,q in enumerate(a):
                code=f"PO:{m['id0']+i}";parent=f'PO:{int(c[i])}' if c is not None and len(c) else None
                entity(code,'PURCHASE_ORDER_LINE',m['p'],int(q),t,math.ceil(m['expected_due']),
                    SourceRecordReference=None,PromisedAvailableAt=str(start+timedelta(days=math.ceil(m['expected_due']))))
                event('BUY_ORDER',m['p'],int(q),code,VendorID=m['vendor'],RelatedEntityCode=parent,
                    DecisionSolveSequence=solve_sequence() if m['purpose']=='regular' else None,ReasonCode=m['purpose'])
                emit('Fact_StochasticDraw',dict(StreamCode='lead',DrawKey=code,UniformValue=float(us[i]),
                    AppliedValue=int(b[i]),ProductID=m['p'],EntityCode=code,DecisionAt=str(start+timedelta(days=t+m['base_lead']+int(b[i]))),TrialQty=int(q),
                    RandomKey=[20261026,config['rep'],'lead',[m['p'],m['vendor'],t,m['purpose'],int(ordinals[i])]]))
        else:
            for oid,q,bad in zip(a,b,c):
                code=f'PO:{int(oid)}';receipt=f'RECEIPT:{int(oid)}'
                entity(receipt,'RECEIPT_LOT',m['p'],int(q),t)
                relation(code,receipt,'HAS_RECEIPT',m['p'],int(q))
                if q>bad:event('BUY_RECEIVE_GOOD',m['p'],int(q-bad),receipt,RelatedEntityCode=code,VendorID=m['vendor'])
                if bad:event('BUY_REJECT',m['p'],int(bad),receipt,RelatedEntityCode=code,VendorID=m['vendor'])
    supply.observer=observe
    # Quality draw parameters and uniforms are added by the Supply observer below.
    supply.draw_observer=lambda row:emit('Fact_StochasticDraw',row)
    next_day=0
    if checkpoint is not None:
        restored=checkpoint_io.validate(checkpoint,data,spec,executor_identity())
        checkpoint_io.restore_orders(ob,restored)
        for key,value in restored['supply'].items():setattr(supply,key,value)
        saved=restored['engine']
        inv=saved['inv']
        initial=saved['initial']
        wip=saved['wip']
        received=saved['received']
        used=saved['used']
        sold=saved['sold']
        requested=saved['requested']
        started=saved['started']
        pipe=saved['pipe']
        receipt_jobs=saved['receipt_jobs']
        queue=saved['queue']
        jobid=saved['jobid']
        execution=saved['execution']
        sequence=saved['sequence']
        product_sums=saved['product_sums']
        unvalued=saved['unvalued']
        daily=saved['daily']
        ledger=saved['ledger']
        logs=saved['logs']
        next_day=checkpoint['next_day']
    for t in range(next_day,(end-start).days+1):
        today=start+timedelta(days=t);arrive=Counter();consume=Counter();sales=Counter();on_time=Counter();late=Counter();loss=Counter()
        pg=supply.good.copy();pr=supply.reject.copy()
        for p,q in pipe.pop(t,[]):inv[p]+=q;wip[p]-=q;received[p]+=q;arrive[p]+=q
        for job,p,q,ex in receipt_jobs.pop(t,[]):event('PRODUCTION_GOOD',p,q,f'JOB:{job}',ProductionExecutionCode=ex)
        supply.receive(t,inv)
        ob.reveal(t)
        for o in ob.events.get(t,[]):
            for x in o['lines']:
                entity(f"SO_LINE:{x['id']}",'CUSTOMER_ORDER_LINE',x['p'],x['q'],t,(x['due']-start).days,
                    CustomerOrderCode=f"SO:{o['SalesOrderID']}",SourceRecordReference=f"SalesOrderDetail:{x['id']}")
        due=Counter()
        for o in ob.active.values():
            if o['due']==today:
                for x in o['lines']:due[x['p']]+=x['remaining']
        offset=len(ob.delivery);action=None
        if controller:
            action=controller.decide(t,inv.copy(),deepcopy(dict(pipe)),ob.manufactured_book(),deepcopy(queue),ob.snapshot(),supply)
            if action['day']!=t:raise ValueError('Decision day mismatch')
        ob.dispatch_atomic(inv,today,t,None if action is None else action['order_shipments'])
        for x in ob.delivery[offset:]:
            p=x['ProductID'];q=x['quantity'];sales[p]+=q
            if p in stock:sold[p]+=q
            order=ob.orders[x['SalesOrderID']]
            (on_time if today<=order['due'] else late)[p]+=q
            if p not in stock:external_draw(p,q,f"SO_LINE:{x['id']}",ReasonCode='UNLIMITED_RESALE')
            event('SHIP_ON_TIME' if today<=order['due'] else 'SHIP_LATE',p,q,f"SO_LINE:{x['id']}",
                OrderActionCode=f"SO:{x['SalesOrderID']}:SHIP",DecisionSolveSequence=solve_sequence())
        def request(p,q):
            nonlocal jobid
            p=int(p)
            if p not in P or q<0 or int(q)!=q:raise ValueError('Invalid production request')
            if q:
                jobid+=1;queue.append(dict(id=jobid,p=p,q=int(q),created=t));requested[p]+=q
                entity(f'JOB:{jobid}','PRODUCTION_JOB',p,int(q),t)
                event('PRODUCTION_REQUEST',p,int(q),f'JOB:{jobid}',DecisionSolveSequence=solve_sequence())
        def start_job(job,q):
            nonlocal execution
            p=job['p'];execution+=1;ex=f'EXEC:{execution}'
            if not 0<q<=job['q'] or int(q)!=q:raise ValueError('Invalid production start')
            entity(ex,'OPERATION_EXECUTION',p,q,t)
            relation(f"JOB:{job['id']}",ex,'HAS_OPERATION',p,q)
            for c,a,u in bom.children[p]:
                amount=q*a
                if c in stock:
                    if inv[c]<amount:raise ValueError(f'Insufficient material {c}')
                    inv[c]-=amount;used[c]+=amount
                else:external_draw(c,amount,f"JOB:{job['id']}",ReasonCode='UNLIMITED_BOM',ProductionExecutionCode=ex)
                consume[c]+=amount
                event('BOM_ISSUE',c,amount,f"JOB:{job['id']}",ProductionExecutionCode=ex,DecisionSolveSequence=solve_sequence())
            finish=finish_day(spec,t,job['created'],P[p]['lead_days']);pipe[finish].append((p,q));receipt_jobs[finish].append((job['id'],p,q,ex))
            wip[p]+=q;started[p]+=q;job['q']-=q
            event('PRODUCTION_START',p,q,f"JOB:{job['id']}",ProductionExecutionCode=ex,DecisionSolveSequence=solve_sequence())
        if action is None:
            waiting=Counter();dependent=Counter()
            for j in queue:
                waiting[j['p']]+=j['q']
                for c,a,u in bom.children[j['p']]:dependent[c]+=j['q']*a
            pending=Counter()
            for o in ob.active.values():
                for x in o['lines']:pending[x['p']]+=x['remaining']
            for p in data['topo']:
                ip=inv[p]+wip[p]+waiting[p]-pending[p]-dependent[p];v=P[p]['bom']
                q=max(0,math.ceil(v['ss']-ip)) if ip<v['rp'] else 0
                request(p,q);waiting[p]+=q
                for c,a,u in bom.children[p]:dependent[c]+=q*a
            for p in sorted(raw):
                ip=inv[p]+supply.pipeline[p]-dependent[p]-pending[p];v=data['rawparams'][p]
                supply.place(p,max(0,math.ceil(v['ss']-ip)) if ip<v['rp'] else 0,t)
            for job in sorted(queue,key=lambda j:(j['created'],j['p'],j['id'])):
                q=startable_quantity(data,inv,job)
                if q:start_job(job,q)
        else:
            for p,q in action['requests'].items():request(p,q)
            for p,q in action.get('purchases',{}).items():
                if supply.place(int(p),q,t)!=q:raise ValueError('Purchase decision violates original lot rules')
            for a in action['aged']:
                p,age,left=int(a['p']),int(a['age']),a['q']
                for job in sorted(queue,key=lambda j:(j['created'],j['id'])):
                    if job['p']==p and min(P[p]['lead_days']-1,t-job['created'])==age:
                        q=min(left,job['q'])
                        if q:start_job(job,q);left-=q
                if left:raise ValueError('Planned start has no matching request')
        queue=[j for j in queue if j['q']]
        assert_immediate_starts(data,inv,queue,t)
        cancelled=ob.cancel_due(today,t)
        if action and not spec['allow_backorders'] and set(cancelled)!=set(action['order_losses']):raise AssertionError('Loss decision/execution mismatch')
        for oid in cancelled:
            for x in ob.orders[oid]['lines']:
                loss[x['p']]+=x['lost']
                event('LOST_SALE',x['p'],x['lost'],f"SO_LINE:{x['id']}",OrderActionCode=f'SO:{oid}:LOST',
                    ReasonCode='DUE_DATE_UNFILLED',DecisionSolveSequence=solve_sequence())
        ob.check();queued=Counter();backlog=Counter()
        for j in queue:queued[j['p']]+=j['q']
        for o in ob.active.values():
            if o['due']<=today:
                for x in o['lines']:backlog[x['p']]+=x['remaining']
        if action:
            for p,q in action['projected_inventory'].items():
                if abs(inv[int(p)]-q)>1e-5:raise AssertionError('Optimizer/executor stock mismatch')
            for p,q in action['projected_actual_backlog'].items():
                if backlog[int(p)]!=q:raise AssertionError('Optimizer/executor backlog mismatch')
        for p in sorted(data['products']):
            if p in stock and (inv[p]!=initial[p]+received[p]+supply.good[p]-sold[p]-used[p] or inv[p]<0):raise AssertionError('Stock conservation')
            if p in P and (wip[p]!=started[p]-received[p] or requested[p]!=started[p]+queued[p]):raise AssertionError('Production conservation')
            cost=data['products'][p]['UnitCost'];valuation=cost is not None
            row=dict(Date=str(today),ProductID=p,LocationCode='SYSTEM_STOCK_POOL',OnHandQty=inv[p],ProductionWIPQty=wip[p],
                QueuedProductionQty=queued[p],PurchaseInTransitQty=0,CustomerBacklogQty=backlog[p],
                CustomerDueQty=due[p],OnTimeDeliveredQty=on_time[p],LateDeliveredQty=late[p],LostQty=loss[p],
                BOMConsumedQty=consume[p],PurchaseAcceptedQty=supply.good[p]-pg[p],PurchaseRejectedQty=supply.reject[p]-pr[p],
                ProductionGoodQty=arrive[p],OnHandValue=inv[p]*cost if valuation else 0 if inv[p]==0 else None,WIPValue=wip[p]*cost if valuation else 0 if wip[p]==0 else None,
                OwnedInTransitValue=0,OpenPurchaseQty=supply.pipeline[p],IsManufactured=p in P,IsFiniteStock=p in stock)
            emit('Fact_SimulationDaily',row)
            for key in ('OnHandQty','ProductionWIPQty','OpenPurchaseQty','CustomerBacklogQty'):
                product_sums[p][key]+=row[key]
            if row['OnHandValue'] is None or row['WIPValue'] is None:unvalued.add(p)
            else:product_sums[p]['InventoryValue']+=row['OnHandValue']+row['WIPValue']
            if not sink:ledger.append(row)
        daily.append(dict(Date=str(today),OnHandManufactured=sum(inv[p] for p in P),WIPManufactured=sum(wip.values()),
            OnHandPurchased=sum(inv[p] for p in raw),PurchaseInTransit=0,OpenPurchase=sum(supply.pipeline.values()),
            OnHandValueManufactured=sum(inv[p]*data['costs'][p] for p in P) if all(v is not None for v in data['costs'].values()) else None,
            InventoryWIPValueManufactured=sum((inv[p]+wip[p])*data['costs'][p] for p in P) if all(v is not None for v in data['costs'].values()) else None,
            InventoryWIPValueAll=sum((inv[p]+wip[p])*(data['products'][p]['UnitCost'] or 0) for p in stock)
                if all(data['products'][p]['UnitCost'] is not None or inv[p]+wip[p]==0 for p in stock) else None))
        if checkpoint_sink is not None and t==(end-start).days:
            checkpoint_sink(checkpoint_io.capture(data,spec,locals(),ob,supply,controller,executor_identity()))
        if progress:progress(t,daily[-1])
    supply.finish()
    for o in ob.orders.values():
        emit('Fact_SimulationOrder',dict(CustomerOrderCode=f"SO:{o['SalesOrderID']}",SourceSalesOrderID=o['SalesOrderID'],
            KnownAt=str(o['order']),DueAt=str(o['due']),ExpectedLineCount=len(o['lines']),
            OrderStatus={'SHIPPED':'FULFILLED','CANCELLED_DUE_DATE':'LOST'}.get(o['status'],'OPEN'),
            CompletedAt=str(o['completed']) if o['completed'] else None,CancelledAt=str(o['cancelled']) if o['cancelled'] else None,
            CancellationReason='DUE_DATE_UNFILLED' if o['cancelled'] else None,SourceRecordReference=f"SalesOrder:{o['SalesOrderID']}"))
    metrics=ob.metrics(start,end)
    for key in ('OnHandManufactured','WIPManufactured','OnHandPurchased','PurchaseInTransit','OpenPurchase','OnHandValueManufactured','InventoryWIPValueManufactured','InventoryWIPValueAll'):
        metrics['mean_'+key]=sum(r[key] for r in daily)/len(daily) if all(r[key] is not None for r in daily) else None
    metrics['calendar_days']=len(daily)
    metrics['late_unit_days_manufactured']=sum(product_sums[p]['CustomerBacklogQty'] for p in P)
    byproduct=defaultdict(list)
    for x in ob.lines:
        if start<=x['due']<=end:byproduct[x['p']].append(x)
    for p in sorted(data['products']):
        due_lines=byproduct[p];total=sum(x['q'] for x in due_lines);filled=sum(x['shipped'] for x in due_lines)
        ont=sum(x['on_time'] for x in due_lines);lost=sum(x['lost'] for x in due_lines);back=sum(x['remaining'] for x in due_lines)
        if total!=filled+lost+back:raise AssertionError('Product demand conservation')
        sums=product_sums[p];n=len(daily);value=None if p in unvalued else sums['InventoryValue']/n
        emit('Fact_PolicySimulation',dict(ProductID=p,SimulatedDays=n,InitialOnHandQty=initial[p],OpeningBacklogQty=0,
            TotalDemandQty=total,OnTimeDeliveredQty=ont,LateDeliveredQty=filled-ont,FilledQty=filled,LostQty=lost,
            EndingBacklogQty=back,LateUnitDays=sums['CustomerBacklogQty'],OnTimeUnitRate=ont/total if total else None,
            FillRate=filled/total if total else None,AvgOnHandQty=sums['OnHandQty']/n,AvgWIPQty=sums['ProductionWIPQty']/n,
            AvgInTransitQty=0,AvgInventoryValue=value,AvgInTransitValue=0,
            HoldingCost=None if value is None else sums['InventoryValue']*spec.get('holding_cost_rate_per_year',0)/365))
    return dict(metrics=metrics,daily=daily,ledger=ledger,states=ob.lines,order_states=list(ob.orders.values()),logs=dict(logs))

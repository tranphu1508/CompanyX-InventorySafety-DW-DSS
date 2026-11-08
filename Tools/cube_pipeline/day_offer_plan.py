"""Materialize two alternative plans at one verified ROP decision state."""
import argparse
from collections import Counter, defaultdict
from datetime import date, timedelta
import json, os, sys
from pathlib import Path

from settings import DEMO, PROJECT, GPT, sql, read, save
sys.path.insert(0, str(DEMO/'DSS/control'))
from dss_bridge import validate_input, inquiry_v2
from simulation import rolling_plan
inquiry_v2.runtime(PROJECT)
from native_path_worker import gurobi_native_paths

def dates(obj):
    if isinstance(obj,list): return [dates(v) for v in obj]
    if isinstance(obj,dict):
        return {k: date.fromisoformat(v) if k in ('order','due','activation') and isinstance(v,str)
                else dates(v) for k,v in obj.items()}
    return obj

def solve(source, request, folder, binding):
    from model_v3 import release
    from companyx_unified_v2.orders import OrderBook
    from companyx_unified_v2.supply import Supply
    _,_,_,inputs,legacy,_,_=inquiry_v2.runtime(PROJECT)
    base_scope=read(source/'scope.json')
    known=date.fromisoformat(request['known_at'])
    day=(known-date.fromisoformat(base_scope['start'])).days
    decision=read(source/'decisions'/f'{day:04d}.json')
    state=read(source/'solves'/f'{day:04d}'/'state.json')
    prefix=read(source/'prefix_proof.json')
    if (base_scope['known_at']!=str(known) or base_scope['base_run_key']!=request['base_run_key']
        or base_scope['synthetic_orders'] or prefix['status']!='PASSED'
        or legacy.digest(state)!=decision['state_hash'] or state['day']!=day
        or read(source.parents[2]/'input_binding.json')!=binding or state['public_purchases']):
        raise ValueError('Incompatible opening state or ACT input')
    output=[]
    for option in [c for c in request['candidates'] if c['kind']=='FULL']:
        label=option['candidate_id']
        prepared=inquiry_v2.build_request(request,label,PROJECT)
        if prepared['scope']['base_run_code']!=base_scope['base_run_code'] or prepared['spec']!=state['spec']:
            raise ValueError('State policy, solver or source changed')
        spec=prepared['spec']
        data=inputs.prepare(prepared['snapshot'],spec)
        synthetic=prepared['scope']['synthetic_sales_order_ids']
        if len(synthetic)!=1: raise ValueError('Expected one whole order')
        book=OrderBook([l for l in data['lines'] if l['SalesOrderID']==synthetic[0]], data['P'],data['external_ids'],data['start'],data['end'],'7C')
        book.reveal(day)
        orders=sorted(dates(state['orders'])+book.snapshot(),key=OrderBook.priority)
        demand=defaultdict(list,dict(dates(state['book'])))
        for pid,lines in book.manufactured_book().items():demand[pid].extend(lines)
        supply=Supply(data,dict(rep=spec['replication'],probs=spec['supply']['delay_probabilities'],p=spec['supply']['reject_probability']))
        dest=folder/label
        if not (dest/'decisions'/f'{day:04d}.json').exists():
            print('Solving',label,known,'due',option['tranches'][0]['due_date'],flush=True)
            dest.mkdir(parents=True,exist_ok=True)
            ctl=release.controller_factory()(data,spec,dest)
            with gurobi_native_paths(dest,False):
                ctl.decide(day,Counter(dict(state['inventory'])),dict(state['pipeline']),demand,state['queue'],orders,supply)
        solutions=list(rolling_plan.iter_accepted_plans(dest,prepared,PROJECT))
        if len(solutions)!=1: raise ValueError('Expected exactly one decision')
        version,rows,_=solutions[0]
        due=option['tranches'][0]['due_date']
        if version['DecisionAt']!=str(known) or version['HorizonEndAt']<due:raise ValueError('Deadline outside plan')
        line=option['tranches'][0]['lines'][0]
        allocation=[r for r in rows if r['SalesOrderID']==synthetic[0] and r['ProductID']==line['product_id'] and r['PlanAt']==due]
        shipped=sum(r['Quantity'] for r in allocation if r['ActionCode']=='ORDER_LINE_SHIPMENT')
        lost=sum(r['Quantity'] for r in allocation if r['ActionCode']=='ORDER_LINE_LOSS')
        if round(shipped+lost)!=line['quantity'] or (shipped and lost):raise ValueError('Invalid whole-order settlement')
        actions=[r for r in rows if r.get('Quantity') or r.get('OrderDecisionFlag')]
        result=dict(slot=label,due=due,plannedShip=int(round(shipped)),plannedLoss=int(round(lost)),version=version,actions=actions,
                    baseStateHash=decision['state_hash'],snapshotId=binding['snapshot_id'])
        save(dest/'plan.json',result)
        print(label,'planned ship',shipped,'loss',lost,flush=True)
        output.append(result)
    return output

def publish(request,results):
    if len(results)!=2 or len({r['baseStateHash'] for r in results})!=1:raise ValueError('Expected two plans from the same state')
    item=request['candidates'][1]['tranches'][0]['lines'][0]
    with sql('SIM',autocommit=False) as cn:
        cn.execute("""IF OBJECT_ID('cxdetail.DayOfferPlan','U') IS NULL
            CREATE TABLE cxdetail.DayOfferPlan(BaseRunKey int NOT NULL,ProductID int NOT NULL,Quantity int NOT NULL,
                KnownAt date NOT NULL,OriginalDue date NOT NULL,DueAt date NOT NULL,Slot char(1) NOT NULL,
                PlanJSON nvarchar(max) NOT NULL CHECK(ISJSON(PlanJSON)=1),
                PRIMARY KEY(BaseRunKey,ProductID,Quantity,KnownAt,OriginalDue,DueAt))""")
        for r in results:
            key=(request['base_run_key'],item['product_id'],item['quantity'],request['known_at'],results[0]['due'],r['due'])
            previous=cn.execute("SELECT PlanJSON FROM cxdetail.DayOfferPlan WITH(UPDLOCK,HOLDLOCK) WHERE BaseRunKey=? AND ProductID=? AND Quantity=? AND KnownAt=? AND OriginalDue=? AND DueAt=?",*key).fetchone()
            if previous:
                if json.loads(previous[0])!=r:raise ValueError('Another saved plan exists for this key')
            else:cn.execute("INSERT cxdetail.DayOfferPlan VALUES (?,?,?,?,?,?,?,?)",*key,r['slot'],json.dumps(r,separators=(',',':')))
        cn.commit()
    print('Committed both decision plans to SIM.',flush=True)

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    for arg in ['request','source','folder']:parser.add_argument('--'+arg,type=Path,required=True)
    args=parser.parse_args()
    if not all(GPT in p.resolve().parents for p in vars(args).values()):raise ValueError('Paths must be in GPT')
    os.environ['PYTHONPATH']=str(DEMO/'DSS/runtime/src')
    license_file=Path(r'E:\Gurobi\gurobi.lic')
    if license_file.is_file():os.environ.setdefault('GRB_LICENSE_FILE',str(license_file))
    args.folder.mkdir(parents=True,exist_ok=True)
    request=read(args.request)
    results=solve(args.source,request,args.folder,validate_input())
    publish(request,results)
    from priority_offer_plan import run as prepare_priority
    prepare_priority(args.source,request,args.folder/'priority')

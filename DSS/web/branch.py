"""Local what-if. All reads are scoped to the published run selected for this policy."""
from collections import Counter, defaultdict
from contextlib import closing
from datetime import date, timedelta
from pathlib import Path
import json, sys
ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT/'Tools/cube_pipeline'), str(ROOT/'DSS/control')]
from settings import sql, GPT, PROJECT, OUTPUT, read
from simulation.adapter import runtime
_, _, config, inputs, legacy, run, valuation = runtime(PROJECT)
from simulation import resumable_engine as engine, checkpoint_codec as codec
from companyx_unified_v2.orders import OrderBook
from companyx_unified_v2.supply import Supply
from companyx_unified_v2.production_timing import finish_day
from model_v3 import release

def records(c, query, *params):
    cur = c.execute(query,*params)
    keys = [x[0] for x in cur.description]
    return [dict(zip(keys,row)) for row in cur]

def bases(c):
    return records(c, """SELECT r.PlanningRunKey id,CONVERT(varchar(36),r.RunCode) code,r.PolicyCode policy,
        CASE WHEN a.AllowBackorders=1 THEN 1 ELSE 2 END scenario,
        CONVERT(char(8),e.SimulationStartDateKey) firstday,CONVERT(char(8),e.SimulationEndDateKey) lastday,
        d.ArtifactFolder folder
        FROM cxolap.DimRun r JOIN cxactive.RunScopeDecision a ON a.PlanningRunKey=r.PlanningRunKey
        JOIN cxdetail.RunDetail d ON d.PlanningRunKey=r.PlanningRunKey
        JOIN cxcontrol.EligibleRunSnapshot e ON e.PlanningRunKey=r.PlanningRunKey
        JOIN dss.Fact_RunSummary f ON f.PlanningRunKey=r.PlanningRunKey
        WHERE a.IsActive=1 AND a.SupplyMode='INSTANT_UNLIMITED' AND f.ValidationStatus='PASSED'
        AND r.PolicyCode IN ('ROP','QUETSCHLICH_ADAPT')
        AND NOT EXISTS(SELECT 1 FROM cxcontrol.Candidate ca WHERE ca.PlanningRunKey=r.PlanningRunKey)
        AND (EXISTS(SELECT 1 FROM cxcontrol.Baseline b WHERE b.PlanningRunKey=r.PlanningRunKey)
        OR (r.PolicyCode='QUETSCHLICH_ADAPT' AND e.SimulationStartDateKey<=20130701 AND e.SimulationEndDateKey>=20140630))""")

def catalog():
    with closing(sql('SIM')) as c:
        b=bases(c)
        items=records(c,"""SELECT DISTINCT p.ProductID id,p.ProductName name,CONVERT(int,p.MakeFlag) made
            FROM act_input.Dim_Product p JOIN act_input.BusinessSalesLine l ON l.ProductID=p.ProductID
            WHERE p.ProductKey>0 ORDER BY p.ProductName,p.ProductID""")
    ref=read(Path(read(OUTPUT/'baselines/catalog.json')['baselines'][0]['artifact_folder'])/'input.json')
    eligible={p['ProductID'] for p in ref['products']}
    return {'bases':[{k:v for k,v in row.items() if k not in ('folder','code')} for row in b],
            'products':[p for p in items if p['id'] in eligible]}

def prepare(payload):
    policy=payload['policy']; scenario=payload['scenario']
    if policy not in ('ROP','QUETSCHLICH_ADAPT') or type(scenario)!=int or scenario not in (1,2):
        raise ValueError('Chọn chính sách và kịch bản S1 hoặc S2.')
    x=date.fromisoformat(payload['known']); due=date.fromisoformat(payload['due'])
    if due<x:raise ValueError('Hạn giao phải từ ngày biết đơn trở đi.')
    if policy!='ROP' and x<date(2013,7,1):raise ValueError('Dự báo MILP khả dụng từ 01/07/2013.')
    lines=payload['lines']
    if not isinstance(lines,list) or not 1<=len(lines)<=200:raise ValueError('Cần 1 đến 200 dòng hàng.')
    order={}
    for row in lines:
        p,q=row['id'],row['qty']
        if type(p)!=int or type(q)!=int or not 1<=q<=2147483647 or p in order:raise ValueError('Mỗi sản phẩm cần một dòng với số lượng nguyên dương.')
        order[p]=q
    with closing(sql('SIM',autocommit=False)) as c:
        c.execute('SET TRANSACTION ISOLATION LEVEL REPEATABLE READ')
        matches=[b for b in bases(c) if b['scenario']==scenario and b['policy']==policy and date.fromisoformat(b['firstday'])<=x<=due<=date.fromisoformat(b['lastday'])]
        if len(matches)!=1:raise ValueError('Chưa có đúng một lượt vận hành của chính sách và kịch bản này phủ cả ngày biết đơn và hạn giao.')
        b=matches[0];key=b['id'];folder=Path(b['folder'])
        if policy=='ROP':
            folder=Path(next(a['artifact_folder'] for a in read(OUTPUT/'baselines/catalog.json')['baselines'] if a['PlanningRunKey']==key))
        if not folder.resolve().is_relative_to(GPT) or not (folder/'run.json').is_file():raise ValueError('Lượt nguồn cần bộ input.json, execution_spec.json và run.json đã xác minh trong GPT.')
        man=read(folder/'run.json');spec=read(folder/'execution_spec.json');snap=read(folder/'input.json')
        if (man['RunCode'].lower()!=b['code'].lower() or legacy.digest(spec)!=man['execution_spec_sha256'] or
            legacy.digest(snap)!=man['input_sha256'] or spec['policy']!=policy or spec['allow_backorders']!=(scenario==1) or
            spec['supply']['mode']!='INSTANT_UNLIMITED'):raise ValueError('Định danh hoặc cấu hình lượt nguồn không khớp.')
        if not set(order)<={p['ProductID'] for p in snap['products']} or not any(p['IsManufactured'] and p['ProductID'] in order for p in snap['products']):
            raise ValueError('Mô hình giao nguyên đơn cần ít nhất một mặt hàng tự sản xuất trong phạm vi mô phỏng.')
        names=dict(c.execute('SELECT ProductID,ProductName FROM act_input.Dim_Product WHERE ProductKey>0').fetchall())
        prev=x-timedelta(days=1);start=date.fromisoformat(snap['start'])
        if x<start or due>date.fromisoformat(snap['end']):raise ValueError('Ngoài phạm vi dữ liệu của lượt nguồn.')
        # Read on-hand and outstanding work at EOD X-1; receipts and today's known orders enter exactly once at X.
        stock=records(c,"""SELECT p.ProductID p,SUM(f.OnHandQty) inv,SUM(f.ProductionWIPQty) wip,SUM(f.QueuedProductionQty) queued
          FROM dss.Fact_SimulationDaily f JOIN act_input.Dim_Product p ON p.ProductKey=f.ProductKey
          WHERE f.PlanningRunKey=? AND f.DateKey=? GROUP BY p.ProductID""",key,int(prev.strftime('%Y%m%d')))
        jobs=records(c,'SELECT JobCode,ProductID,CreatedAt,QueuedQty,WIPQty FROM cxdetail.ProductionJobDay WHERE PlanningRunKey=? AND Date=? AND OpenJobFlag=1',key,prev)
        ex=records(c,"""SELECT e.ExecutionCode,e.JobCode,e.StartAt,e.StartedQty FROM cxdetail.ProductionExecution e
          JOIN cxdetail.ProductionJobDay j ON j.PlanningRunKey=e.PlanningRunKey AND j.JobCode=e.JobCode
          WHERE e.PlanningRunKey=? AND j.Date=? AND j.WIPQty>0 AND e.StartAt<?""",key,prev,x)
        olds=records(c,'SELECT SalesOrderID,SalesOrderDetailID,ProductID,KnownAt,DueAt,RemainingQty,OriginalQty FROM cxdetail.OrderLineDay WHERE PlanningRunKey=? AND Date=? AND OpenLineFlag=1',key,prev)
        if x>start and {r['p'] for r in stock}!={p['ProductID'] for p in snap['products']}:raise ValueError('Snapshot đầu ngày chưa đủ sản phẩm.')
        c.commit()
    live=[r for r in snap['sales_order_lines'] if r['OrderDate'][:10]==str(x)]
    for r in olds:
        if r['OriginalQty']!=r['RemainingQty']:raise ValueError('Dòng còn mở khác hợp đồng giao nguyên đơn.')
        live.append(dict(SalesOrderID=r['SalesOrderID'],SalesOrderDetailID=r['SalesOrderDetailID'],ProductID=r['ProductID'],OrderDate=str(r['KnownAt'])[:10],DueDate=str(r['DueAt'])[:10],OrderQty=int(r['RemainingQty'])))
    oid=max([r['SalesOrderID'] for r in live]+[1999999999])+1
    lid=max([r['SalesOrderDetailID'] for r in live]+[1999999999])+1
    for i,(p,q) in enumerate(order.items()):
        live.append(dict(SalesOrderID=oid,SalesOrderDetailID=lid+i,ProductID=p,OrderQty=q,OrderDate=str(x),DueDate=str(due)))
    snap['sales_order_lines']=live
    if policy!='ROP':snap,_,_=release.prepare_snapshot(snap,str(x),PROJECT)
    data=inputs.prepare(snap,spec)
    return dict(data=data,spec=spec,x=x,due=due,oid=oid,names=names,stock=stock,jobs=jobs,ex=ex,key=key,order=order)

def opening(b):
    data,spec,x=b['data'],b['spec'],b['x'];start=data['start']
    if x==start:return None
    from companyx_unified_v2.orders import OrderBook
    prev=x-timedelta(days=1); t=(prev-start).days
    inv=Counter({r['p']:int(r['inv']) for r in b['stock']})
    wip=Counter({r['p']:int(r['wip']) for r in b['stock']})
    queued=Counter({r['p']:int(r['queued']) for r in b['stock']})
    jobs={r['JobCode']:r for r in b['jobs']};queue=[]; pipe=defaultdict(list);receipts=defaultdict(list); trace=Counter()
    number=lambda s:int(s.split(':')[-1])
    for code,j in sorted(jobs.items(),key=lambda item:number(item[0])):
        if j['QueuedQty']:queue.append(dict(id=number(code),p=j['ProductID'],q=int(j['QueuedQty']),created=(j['CreatedAt']-start).days))
    for e in b['ex']:
        j=jobs[e['JobCode']];p=j['ProductID'];q=int(e['StartedQty'])
        end=finish_day(spec,(e['StartAt']-start).days,(j['CreatedAt']-start).days,data['P'][p]['lead_days'])
        if end>t:
            pipe[end].append((p,q));receipts[end].append((number(e['JobCode']),p,q,e['ExecutionCode']));trace[p]+=q
    jq=Counter()
    for j in queue:jq[j['p']]+=j['q']
    if jq!=queued or trace!=wip:raise ValueError('Chi tiết lệnh đang chờ hoặc WIP không khớp tồn theo sản phẩm tại đầu ngày.')
    ob=OrderBook(data['lines'],data['P'],data['external_ids'],start,data['end'],'7B' if spec['allow_backorders'] else '7C',data['raw'])
    for day in sorted(k for k in ob.events if k<=t):ob.reveal(day)
    conf=dict(rep=spec['replication'],probs=spec['supply']['delay_probabilities'],p=spec['supply']['reject_probability'])
    state=dict(t=t,inv=inv,initial=inv.copy(),wip=wip,received=Counter(),used=Counter(),sold=Counter(),requested=wip+queued,started=wip.copy(),pipe=pipe,receipt_jobs=receipts,queue=queue,jobid=max([number(j) for j in jobs]+[0]),execution=max([number(e['ExecutionCode']) for e in b['ex']]+[0]),sequence=0,product_sums=defaultdict(Counter),unvalued=set(),daily=[],ledger=[],logs=defaultdict(list))
    return codec.capture(data,spec,state,ob,Supply(data,conf),None,engine.executor_identity())

class ReachedOfferDate(Exception):pass

def evaluate(b,promised,folder):
    data,spec=b['data'],b['spec']; oid=b['oid']; names=b['names']
    for row in data['lines']:
        if row['SalesOrderID']==oid:row['due']=promised
    cp=opening(b); plan=[]; work={}; shipped=Counter()
    def emit(table,r):
        if table!='Fact_SimulationEvent':return
        kind=r['EventCode'];p=r['ProductID'];qty=int(r['Quantity']);job=r.get('EntityCode','')
        if kind in ('SHIP_ON_TIME','SHIP_LATE') and r.get('OrderActionCode')==f'SO:{oid}:SHIP':shipped[p]+=qty
        if kind in ('PRODUCTION_REQUEST','PRODUCTION_START','PRODUCTION_GOOD','BOM_ISSUE'):
            plan.append([r['EventAt'],kind,p,names.get(p,str(p)),qty,job])
        if kind=='PRODUCTION_REQUEST':work[job]=[job,r['EventAt'],p,names.get(p,str(p)),qty,None,None]
        if job in work and kind=='PRODUCTION_START':
            work[job][5]=work[job][5] or r['EventAt']
            day=(date.fromisoformat(r['EventAt'])-data['start']).days
            created=(date.fromisoformat(work[job][1])-data['start']).days
            work[job][6]=str(data['start']+timedelta(days=finish_day(spec,day,created,data['P'][p]['lead_days'])))
    def step(day,row):
        if data['start']+timedelta(days=day)>=promised:raise ReachedOfferDate
    folder.mkdir(parents=True,exist_ok=False)
    controller=release.controller_factory()(data,spec,folder,False,emit) if spec['policy']!='ROP' else None
    try:engine.simulate(data,spec,controller,emit,step,folder,checkpoint=cp)
    except ReachedOfferDate:pass
    return {'date':str(promised),'days':(promised-b['due']).days,'feasible':shipped==Counter(b['order']),'plan':plan,'work':list(work.values())}


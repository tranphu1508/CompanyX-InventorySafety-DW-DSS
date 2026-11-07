from collections import Counter, defaultdict
import math
from datetime import timedelta
from companyx_unified_v2.legacy import module
from .forecast import get_resale_forecast

def extend(model,meta,d,data,config,inv,queue,supply,t,orders,*,spec):
    old=module('companyx_active_days')
    raw=data['raw'];bom=data['bom'];P=data['P']
    vendor={p:supply.vendor(p) for p in raw}
    leads={p:math.ceil(vendor[p]['base_lead_days']+supply.expected_delay) for p in raw}
    H=meta['H'];accept=1-config['p']
    public=supply.public_pipeline(t);arrivals=defaultdict(Counter)
    for x in public:arrivals[x['p']][x['expected_day']-t]+=x['q']*accept
    external_parents=defaultdict(list);gross=Counter()
    for p in P:
        for c,a,u in bom.children[p]:
            if c in raw:external_parents[c].append((p,a))
    for p in d['roots']:
        need=sum(meta['da'][p].values())+sum(meta['df'][p].values())
        for (c,u),a in bom.explode(p).items():
            if c in raw:gross[c]+=need*a
    for job in queue:
        for (c,u),a in bom.explode(job['p']).items():
            if c in raw:gross[c]+=job['q']*a
    for order in orders:
        for line in order['lines']:
            if line['p'] in raw:gross[line['p']]+=line['remaining']
    # Direct resale demand is separate from indirect BOM consumption. Only
    # revealed orders offset the frozen, cutoff-safe direct forecast.
    today=data['start']+timedelta(days=t)
    resale_mu=get_resale_forecast(data,required=True,as_of=today)
    known=defaultdict(Counter);forecast=defaultdict(Counter)
    for order in orders:
        if order['order']>today:raise ValueError('Future order in resale forecast offset')
        due=max(0,(order['due']-today).days)
        for line in order['lines']:
            if line['p'] in raw:known[line['p']][due]+=line['remaining']
    for p,mu in resale_mu.items():
        if p not in raw:continue
        for k in range(1,H+1):
            forecast[p][k]=max(0,math.floor(mu*(t+k+1)+1e-9)-math.floor(mu*(t+k)+1e-9)-known[p][k])
        gross[p]+=sum(forecast[p].values())
    starts=defaultdict(list)
    for (kind,p,k,age),j in meta['av'].items():
        if kind=='a':starts[p,k].append(j)
    buys={};stocks={};lots={};forecast_ship={};forecast_short={}
    for p in sorted(raw):
        mn=vendor[p]['min_order_qty'];mx=vendor[p]['max_order_qty']
        # Finite technical bound covers demand, all minimum-lot overage and existing stock.
        M=math.ceil((gross[p]+inv[p]+sum(arrivals[p].values())+(H+1)*mx)/accept)+mx
        for k in range(H+1):
            stocks[p,k]=model.var(('raw_I',p,k),M,cost=old.WEIGHTS['inventory'])
            if p in forecast:
                # There is no hypothetical service at day zero. The future
                # flow affects purchase planning, never physical DES dispatch.
                demand_bound=max(1,sum(forecast[p].values()))
                forecast_ship[p,k]=model.var(('raw_yf',p,k),demand_bound)
                penalty=(spec['late_unit_day_penalty']+(spec['terminal_unserved_unit_penalty'] if k==H else 0)
                         if spec['allow_backorders'] else spec['lost_unit_penalty'])
                forecast_short[p,k]=model.var(('raw_Bf',p,k),demand_bound,cost=penalty)
            if k+leads[p]<=H:
                q=model.var(('buy',p,k),M,cost=old.WEIGHTS['flow'],integer=True)
                n=model.var(('lot_count',p,k),math.ceil(M/mn),integer=True)
                buys[p,k]=q;lots[p,k]=n
                # mn*n <= q <= mx*n; n=ceil(q/mx) when q>0.
                for terms,lo,hi,label in [({q:1,n:-mn},0,float('inf'),'purchase_min'),
                                          ({q:1,n:-mx},1-mx,0,'purchase_max_minimum_lots')]:
                    model.rows.append(terms);model.lo.append(lo);model.hi.append(hi);model.labels.append(label)
        for k in range(H+1):
            row={stocks[p,k]:1}
            if k:row[stocks[p,k-1]]=-1
            if (p,k-leads[p]) in buys:row[buys[p,k-leads[p]]]=-accept
            if (p,k) in forecast_ship:
                row[forecast_ship[p,k]]=1
                demand_row={forecast_short[p,k]:1,forecast_ship[p,k]:1}
                if k and spec['allow_backorders']:demand_row[forecast_short[p,k-1]]=-1
                model.row(demand_row,forecast[p][k],'raw_forecast')
            for parent,a in external_parents[p]:
                for j in starts[parent,k]:row[j]=row.get(j,0)+a
            for order in orders:
                j=meta['order_ship_vars'].get((order['SalesOrderID'],k))
                if j is not None:
                    q=sum(x['remaining'] for x in order['lines'] if x['p']==p)
                    if q:row[j]=row.get(j,0)+q
            model.row(row,inv[p] if k==0 else arrivals[p][k],'raw_inventory')
    meta.update(buys=buys,raw_stocks=stocks,lots=lots,public_purchase_pipeline=public,vendor=vendor,
                raw_df=forecast,raw_forecast_ship=forecast_ship,raw_forecast_short=forecast_short)
    return model,meta

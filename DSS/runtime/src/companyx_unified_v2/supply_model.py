from collections import Counter, defaultdict
import math
from .legacy import module

def extend(model,meta,d,data,config,inv,queue,supply,t,orders):
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
    starts=defaultdict(list)
    for (kind,p,k,age),j in meta['av'].items():
        if kind=='a':starts[p,k].append(j)
    buys={};stocks={};lots={}
    for p in sorted(raw):
        mn=vendor[p]['min_order_qty'];mx=vendor[p]['max_order_qty']
        # Finite technical bound covers demand, all minimum-lot overage and existing stock.
        M=math.ceil((gross[p]+inv[p]+sum(arrivals[p].values())+(H+1)*mx)/accept)+mx
        for k in range(H+1):
            stocks[p,k]=model.var(('raw_I',p,k),M,cost=old.WEIGHTS['inventory'])
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
            for parent,a in external_parents[p]:
                for j in starts[parent,k]:row[j]=row.get(j,0)+a
            for order in orders:
                j=meta['order_ship_vars'].get((order['SalesOrderID'],k))
                if j is not None:
                    q=sum(x['remaining'] for x in order['lines'] if x['p']==p)
                    if q:row[j]=row.get(j,0)+q
            model.row(row,inv[p] if k==0 else arrivals[p][k],'raw_inventory')
    meta.update(buys=buys,raw_stocks=stocks,lots=lots,public_purchase_pipeline=public,vendor=vendor)
    return model,meta

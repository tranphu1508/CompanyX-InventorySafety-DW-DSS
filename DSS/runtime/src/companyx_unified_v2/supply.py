"""Array-based purchase event ledger, preserving v0.1.1 lot identities and draws.

Orders remain distinct physical lots. Batching changes storage/computation only.
An order archive has id0, ordinal0 and quantity/delay/parent arrays; row i is one
lot, ID=id0+i and random ordinal=ordinal0+i. Uniforms are exactly reconstructible
from the frozen SHA256 rule. Receipts store their actual order IDs and rejects.
"""
from collections import Counter,defaultdict
from functools import lru_cache
from pathlib import Path
import hashlib,math,json
import numpy as np

def uniforms(rep,stream,p,v,day,purpose,ordinals):
    prefix=f'[20261026,{rep},"{stream}",[{p},{v},{day},"{purpose}",'.encode()
    return np.fromiter((((int.from_bytes(hashlib.sha256(prefix+str(int(i)).encode()+b']]').digest()[:8],'big')>>11)+.5)/2**53 for i in ordinals),dtype=np.float64,count=len(ordinals))

@lru_cache(None)
def quality_cdf(q,p):
    from scipy.stats import binom
    return binom.cdf(np.arange(q+1),q,p)

def rejects(q,u,p):
    if p==0:return np.zeros(len(q),dtype=np.int32)
    out=np.zeros(len(q),dtype=np.int32)
    for size in np.unique(q):
        mask=q==size;out[mask]=np.searchsorted(quality_cdf(int(size),p),u[mask],side='left')
    return out

class Supply:
    def __init__(self,data,config,folder=None):
        self.data=data;self.config=config;self.folder=folder;self.schedule=defaultdict(list)
        self.counts=Counter();self.ordered=Counter();self.arrived=Counter();self.good=Counter();self.reject=Counter()
        self.pipeline=Counter();self.public=Counter();self.num_orders=0;self.num_receipts=0;self.replacement_lots=0
        self.expected_delay=sum(i*p for i,p in enumerate(config['probs']));self.cdf=np.cumsum(config['probs'])
        self.chosen={p:min(rows,key=lambda v:(v['base_lead_days']+self.expected_delay,v['VendorID'])) for p,rows in data['vendors'].items()}
        self.batch_number=0;self.receipt_number=0;self.index=[];self.observer=None
        self.replacement_units=0;self.delay_counts=Counter()
        if folder:(folder/'purchase_events').mkdir(parents=True,exist_ok=True)
    def vendor(self,p):return self.chosen[p]
    def _place_arrays(self,p,q,t,purpose,parent=None):
        if not len(q):return 0
        v=self.vendor(p);n=len(q);id0=self.num_orders+1;counter=(p,v['VendorID'],t,purpose)
        ordinal0=self.counts[counter];self.counts[counter]+=n;self.num_orders+=n
        u=uniforms(self.config['rep'],'lead',p,v['VendorID'],t,purpose,np.arange(ordinal0,ordinal0+n))
        delay=np.searchsorted(self.cdf,u,side='right').astype(np.int8)
        for k,count in enumerate(np.bincount(delay,minlength=5)):self.delay_counts[k]+=int(count)
        expected=t+v['base_lead_days']+self.expected_delay
        q=np.asarray(q,dtype=np.int32);assert np.all((q>=v['min_order_qty'])&(q<=v['max_order_qty']))
        batch=dict(p=p,vendor=v['VendorID'],created=t,purpose=purpose,id0=id0,ordinal0=ordinal0,q=q,expected=expected)
        for k in np.unique(delay):
            ix=np.flatnonzero(delay==k)
            self.schedule[t+v['base_lead_days']+int(k)].append((batch,ix))
        total=int(q.sum());self.ordered[p]+=total;self.pipeline[p]+=total;self.public[p,v['VendorID'],expected]+=total
        if purpose=='replacement':self.replacement_lots+=n;self.replacement_units+=total
        self.batch_number+=1
        metadata=dict(kind='order',batch=self.batch_number,p=p,vendor=v['VendorID'],created=t,purpose=purpose,id0=id0,ordinal0=ordinal0,lots=n,quantity=total,expected_due=expected,base_lead=v['base_lead_days'],min=v['min_order_qty'],max=v['max_order_qty'])
        if self.folder:
            name=f'order_{self.batch_number:07d}.npz'
            np.savez_compressed(self.folder/'purchase_events'/name,q=q,delay=delay,parent=np.asarray(parent if parent is not None else [],dtype=np.int64))
            self.index.append(dict(metadata,file=name))
        if self.observer:self.observer('order',metadata,q,delay,parent)
        return total
    def place(self,p,needed,t,purpose='regular',parent=None):
        v=self.vendor(p);mn=v['min_order_qty'];mx=v['max_order_qty'];qty=max(0,math.ceil(needed-1e-9))
        if not qty:return 0
        n=math.ceil(qty/mx);total=max(qty,n*mn)
        q=np.full(n,mn,dtype=np.int32);extra=total-n*mn
        if mx>mn:
            full,rem=divmod(extra,mx-mn);q[:full]=mx
            if rem:q[full]+=rem
        else:assert extra==0
        return self._place_arrays(p,q,t,purpose,np.full(n,parent,dtype=np.int64) if parent is not None else None)
    def receive(self,t,inv):
        batches=sorted(self.schedule.pop(t,[]),key=lambda item:item[0]['id0'])
        for b,ix in batches:
            p=b['p'];q=b['q'][ix];ids=b['id0']+ix
            u=uniforms(self.config['rep'],'quality',p,b['vendor'],b['created'],b['purpose'],b['ordinal0']+ix)
            bad=rejects(q,u,self.config['p']);gross=int(q.sum());lost=int(bad.sum());good=gross-lost
            if hasattr(self,'draw_observer'):
                for i,oid,uniform,bad_qty in zip(ix,ids,u,bad):
                    self.draw_observer(dict(StreamCode='quality',DrawKey=f'PO:{int(oid)}',UniformValue=float(uniform),
                        AppliedValue=int(bad_qty),ProductID=p,EntityCode=f'PO:{int(oid)}',TrialQty=int(b['q'][i]),
                        DecisionAt=str(self.data['start']+__import__('datetime').timedelta(days=t)),
                        RandomKey=[20261026,self.config['rep'],'quality',[p,b['vendor'],b['created'],b['purpose'],int(b['ordinal0']+i)]]))
            inv[p]+=good;self.arrived[p]+=gross;self.good[p]+=good;self.reject[p]+=lost;self.pipeline[p]-=gross
            self.public[p,b['vendor'],b['expected']]-=gross;self.num_receipts+=len(ix)
            self.receipt_number+=1
            if self.folder:
                name=f'receipt_{self.receipt_number:07d}.npz'
                np.savez_compressed(self.folder/'purchase_events'/name,order_id=ids,q=q,reject=bad)
                self.index.append(dict(kind='receipt',file=name,day=t,p=p,vendor=b['vendor'],lots=len(ix),gross=gross,good=good,reject=lost))
            if self.observer:self.observer('receipt',dict(day=t,p=p,vendor=b['vendor']),ids,q,bad)
            mask=bad>0
            if np.any(mask):
                # Selected vendor is stable throughout each approved full case.
                # Each rejected amount <= original Max, so one compliant replacement
                # lot per failed receipt reproduces the original split_lots rule.
                v=self.vendor(p);needed=np.maximum(bad[mask],v['min_order_qty'])
                assert v['VendorID']==b['vendor'] and np.all(needed<=v['max_order_qty'])
                self._place_arrays(p,needed,t,'replacement',ids[mask])
    def quantities(self):return self.pipeline.copy()
    def public_pipeline(self,t):
        return [dict(id=i,p=p,vendor=v,q=q,expected_day=max(t+1,math.ceil(e)),acceptance=1-self.config['p']) for i,((p,v,e),q) in enumerate(sorted(self.public.items()),1) if q]
    def finish(self):
        if self.folder:
            from .legacy import save
            save(self.folder/'purchase_events/index.json',dict(schema='lot_arrays_v1',seed=20261026,rep=self.config['rep'],batches=self.index,
                uniform_rule='SHA256 JSON [20261026,rep,stream,[p,vendor,created,purpose,ordinal]]; first 64 bits >>11; (+0.5)/2^53',
                receipt_rule='good=q-reject; each row corresponds to actual order_id; order rows ID=id0+i, ordinal=ordinal0+i'))

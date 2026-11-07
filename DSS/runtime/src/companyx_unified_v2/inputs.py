"""Versioned JSON boundary; ProductID is a source natural key, never a DW key."""
from collections import defaultdict
from copy import deepcopy
from datetime import date
import math
from .legacy import RELEASE, read, inputs, module, digest
from .valuation import freeze as freeze_valuation,validate as validate_valuation

def frozen_snapshot():
    protocol,P,lines,edges,topo=inputs('nonopt')
    path=RELEASE.parent/'inputs/whole_order_siblings.json'
    import hashlib
    expected=read(RELEASE.parent/'input_manifest.json')['snapshot_sha256'][path.name]
    if hashlib.sha256(path.read_bytes()).hexdigest()!=expected:raise ValueError('Sibling snapshot changed')
    siblings=read(path)
    external={r['ProductID'] for r in siblings}
    for r in siblings:
        lines.append(dict(id=r['SalesOrderDetailID'],SalesOrderID=r['SalesOrderID'],p=r['ProductID'],q=r['OrderQty'],
                          order=r['OrderDate'][:10],due=r['DueDate'][:10]))
    products={r['ProductID']:r for r in read(RELEASE/'data/source_extracts/products.json')}
    costs={r['ProductID']:r['applied_StandardCost'] for r in read(RELEASE/'data/valuation/cost_basis.json')}
    purchased={e['ComponentID'] for e in edges if e['ComponentID'] not in P}|external
    accepted=read(RELEASE.parent/'inputs/purchase_vendor_master_accepted_fields.json')['pairs']
    full_vendor_path=RELEASE.parent/'productvendor-full-audit/productvendor.json'
    full_vendors=read(full_vendor_path)
    pairs={(x['ProductID'],x['BusinessEntityID']):x for x in full_vendors}
    accepted_ids={x['ProductID'] for x in accepted}
    for v in accepted:
        source=pairs[v['ProductID'],v['VendorID']]
        v.update(PurchaseUnit=source['UnitMeasureCode'].strip(),QuantityToStockFactor=1,
                 ConversionEvidence='LEGACY_NUMERIC_ASSUMPTION',KnownAt=source['ModifiedDate'])
    # Explicitly authorized by the group on 2026-10-27. This is a what-if
    # assumption, not evidence that the master values were known in 2013.
    additions=[]
    for v in full_vendors:
        if v['ProductID'] in purchased-accepted_ids:
            additions.append(dict(ProductID=v['ProductID'],VendorID=v['BusinessEntityID'],
                base_lead_days=v['AverageLeadTime'],min_order_qty=v['MinOrderQty'],max_order_qty=v['MaxOrderQty'],
                standard_price_raw=v['StandardPrice'],source='Purchasing.ProductVendor',
                source_modified_at=v['ModifiedDate'],KnownAt=v['ModifiedDate'],PurchaseUnit=v['UnitMeasureCode'].strip(),
                QuantityToStockFactor=1,ConversionEvidence='EA_TO_EA',
                EvidenceOrigin='GROUP_APPROVED_WHAT_IF_ASSUMPTION',
                Assumption='Use current vendor lead and Min/Max for non-BOM resale despite modification after simulation start; authorized 2026-10-27'))
    if len(additions)!=39 or any(v['PurchaseUnit']!='EA' for v in additions):raise ValueError('Expected 39 approved EA resale vendor rows')
    accepted+=additions
    costpath=RELEASE.parents[2]/'data/companyx/product_cost_history.json'
    history=read(costpath);cost_candidates=defaultdict(list)
    for x in history:
        if x['StartDate'][:10]<=protocol['start'][:10] and (x['EndDate'] is None or x['EndDate'][:10]>=protocol['start'][:10]):
            cost_candidates[x['ProductID']].append(x)
    rows=[];bom_units=defaultdict(set)
    for e in edges:bom_units[e['ComponentID']].add(e['UnitMeasureCode'].strip())
    for p in sorted(set(P)|purchased):
        x=products[p]
        effective=cost_candidates[p]
        if p not in P and len(effective)>1:raise ValueError('Ambiguous effective cost history')
        purchased_cost=effective[0]['StandardCost'] if effective and p in external else None
        if p not in P and p not in external and len(bom_units[p])!=1:raise ValueError('Ambiguous modeled stock unit')
        rows.append(dict(ProductID=p,IsManufactured=p in P,IsResale=p in external,
            StockUnit='EA' if p in P or p in external else next(iter(bom_units[p])),
            InitialQty=P[p]['initial'] if p in P else math.ceil((x['SafetyStockLevel']+x['ReorderPoint'])/2),
            SafetyStockQty=x['SafetyStockLevel'],ReorderPointQty=x['ReorderPoint'],
            UnitCost=costs.get(p) if p in P else purchased_cost,ManufacturingParameters=P.get(p)))
    snapshot=dict(schema='companyx.unified.input.v1',start=protocol['start'][:10],end=protocol['end'][:10],
        products=rows,sales_order_lines=[dict(SalesOrderDetailID=x['id'],SalesOrderID=x['SalesOrderID'],ProductID=x['p'],
            OrderQty=x['q'],OrderDate=str(x['order'])[:10],DueDate=str(x['due'])[:10]) for x in lines],
        bom=edges,topological_order=topo,
        supply_options=accepted,
        metadata=dict(source='immutable V1 + accepted purchase master + whole-order siblings',
            initial_stock='Assumed midpoint (SS+RP)/2, not reconstructed historical stock',
            unit_basis='Frozen accepted numerical stock-unit assumption; no inferred purchase conversion',
            cohort='Manufactured V1 SalesOrders with all siblings; not all source SalesOrders',
            forecast='Frozen pre-simulation direct_mu; no training or ML holdout unlock',
            legacy_manifest_sha256=digest(read(RELEASE/'manifest.json')),
            vendor_source_sha256=hashlib.sha256(full_vendor_path.read_bytes()).hexdigest(),
            cost_source_sha256=hashlib.sha256(costpath.read_bytes()).hexdigest(),
            added_vendor_assumption='39 non-BOM resale EA vendor rows used as group-approved what-if assumptions; source modified after simulation start.',
            purchased_cost_rule='Preserve effective resale ProductCostHistory; fill only 66 missing prices with frozen selected-vendor StandardPrice at approved 1:1 conversion.'))
    return freeze_valuation(snapshot,expected_fallback_count=66,existing_sources={p['ProductID']:
        'V1_FROZEN_MANUFACTURED_COST' if p['IsManufactured'] else 'EFFECTIVE_PRODUCT_COST_HISTORY' for p in rows})

def prepare(snapshot,spec):
    s=deepcopy(snapshot)
    if s.get('schema')!='companyx.unified.input.v1':raise ValueError('Unsupported input schema')
    if set(s)-{'schema','start','end','products','sales_order_lines','bom','topological_order','supply_options','metadata'}:
        raise ValueError('Unsupported input fields; opening entities/routes/calendar capabilities are not implemented')
    valuation_hash=validate_valuation(s)
    start,end=map(date.fromisoformat,(s['start'],s['end']))
    if end<start:raise ValueError('Empty interval')
    products={x['ProductID']:x for x in s['products']}
    if len(products)!=len(s['products']):raise ValueError('Duplicate product')
    P={p:x['ManufacturingParameters'] for p,x in products.items() if x['IsManufactured']}
    if not P or set(s['topological_order'])!=set(P) or len(s['topological_order'])!=len(P):raise ValueError('Invalid manufactured topology')
    for p,x in products.items():
        if type(p) is not int or type(x['IsManufactured']) is not bool or type(x['IsResale']) is not bool:
            raise ValueError('ProductID must be integer; classification flags must be booleans')
        if x['UnitCost'] is not None and (not math.isfinite(x['UnitCost']) or x['UnitCost']<0):raise ValueError('Invalid unit valuation')
        for key in ('InitialQty','SafetyStockQty','ReorderPointQty'):
            if not math.isfinite(x[key]) or x[key]<0 or int(x[key])!=x[key]:raise ValueError('Invalid stock quantity')
        if p in P:
            P[p]['initial']=x['InitialQty']
            if P[p]['lead_days']<1 or int(P[p]['lead_days'])!=P[p]['lead_days']:raise ValueError('Invalid manufacturing lead')
    bom=module('companyx_bom_graph').BOM(s['bom'])
    external={p for p,x in products.items() if x['IsResale']}
    bomraw={c for p in P for c,a,u in bom.children[p] if c not in P}
    for p in P:
        for c,a,u in bom.children[p]:
            if c not in products or not math.isfinite(a) or a<=0 or int(a)!=a:raise ValueError('Invalid component/stock-unit conversion')
            if c in P and s['topological_order'].index(p)>s['topological_order'].index(c):
                raise ValueError('Expected parent-before-child replenishment order')
    raw=set() if spec['supply']['mode']=='INSTANT_UNLIMITED' else (bomraw if spec['supply']['finite_scope']=='BOM' else bomraw|external)
    vendors=defaultdict(list)
    seen_options=set()
    for x in s['supply_options']:
        if x['ProductID'] not in raw:continue
        x=deepcopy(x)
        pair=(x['ProductID'],x['VendorID'])
        if pair in seen_options:raise ValueError('Duplicate product/vendor supply option')
        seen_options.add(pair)
        if x.get('QuantityToStockFactor',1)!=1:
            raise ValueError('Supply quantities must be normalized to stock units before simulation; nonunit conversion cannot be silently ignored')
        if any(type(x[k]) is not int or x[k]<1 for k in ('base_lead_days','min_order_qty','max_order_qty')) or x['min_order_qty']>x['max_order_qty']:
            raise ValueError('Invalid vendor lead/min/max')
        x['base_lead_days']=math.ceil(x['base_lead_days']*spec['supply']['lead_time_multiplier'])
        vendors[x['ProductID']].append(x)
    if raw-set(vendors):raise ValueError('Missing accepted supply options for finite ProductIDs: '+str(sorted(raw-set(vendors))))
    lines=[]
    for x in s['sales_order_lines']:
        if date.fromisoformat(x['OrderDate'])<start:raise ValueError('Opening customer orders require explicit opening-state support; do not silently drop them')
        if not start<=date.fromisoformat(x['OrderDate'])<=end:continue
        lines.append(dict(id=x['SalesOrderDetailID'],SalesOrderID=x['SalesOrderID'],p=x['ProductID'],q=x['OrderQty'],
                          order=date.fromisoformat(x['OrderDate']),due=date.fromisoformat(x['DueDate'])))
    return dict(P=P,params=P,edges=s['bom'],bom=bom,topo=s['topological_order'],start=start,end=end,
        lines=lines,raw=raw,external_ids=external,vendors=dict(vendors),products=products,
        rawparams={p:dict(initial=products[p]['InitialQty'],ss=products[p]['SafetyStockQty'],rp=products[p]['ReorderPointQty']) for p in raw},
        costs={p:products[p]['UnitCost'] for p in P},snapshot_sha256=digest(snapshot),valuation_sha256=valuation_hash)

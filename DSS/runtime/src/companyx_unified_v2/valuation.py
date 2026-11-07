"""Policy-independent frozen stock valuation; approved assumptions are evidence."""
from collections import defaultdict
from copy import deepcopy
import math
from .legacy import digest

RULE='VENDOR_STANDARDPRICE_SELECTED_BASELINE_1TO1_V1'
ASSUMPTION=('Group-approved on 2026-10-27: one purchase unit is treated as one model stock unit, '
    'including differing physical units. StandardPrice of the reference selected vendor is a fixed '
    'simulation valuation; no freight, duties or rejected-unit expense is added. '
    'This is not evidence of actual packaging conversion or historical landed cost.')

def freeze(snapshot,expected_fallback_count=None,existing_sources=None):
    """Choose the reference vendor BEFORE scenarios/policies; keep other costs intact."""
    s=deepcopy(snapshot)
    if s.get('metadata',{}).get('valuation'):
        validate(s);return s
    vendors=defaultdict(list)
    for v in s['supply_options']:vendors[v['ProductID']].append(v)
    sources=existing_sources or {};records=[];filled=[]
    for p in sorted(s['products'],key=lambda x:x['ProductID']):
        pid=p['ProductID'];price=p['UnitCost'];reference=None
        source=sources.get(pid,'INPUT_UNIT_COST')
        if price is None:
            if p['IsManufactured']:raise ValueError('Manufactured cost cannot be replaced by a vendor price')
            if not vendors[pid]:raise ValueError(f'No vendor available for valuation of {pid}')
            # Same earliest expected lead / VendorID selection under the reference
            # unscaled baseline. Price never changes because of scenario lead factors.
            reference=min(vendors[pid],key=lambda x:(x['base_lead_days'],x['VendorID']))
            price=reference.get('standard_price_raw')
            if price is None or not math.isfinite(price) or price<=0:raise ValueError(f'Invalid StandardPrice for {pid}')
            p['UnitCost']=price;source=RULE;filled.append(pid)
            for option in vendors[pid]:
                option.update(QuantityToStockFactor=1,ConversionEvidence='GROUP_APPROVED_1_TO_1',ConversionAssumption=ASSUMPTION)
        records.append(dict(ProductID=pid,UnitCost=price,StockUnit=p['StockUnit'],PriceSource=source,
            ReferenceVendorID=reference['VendorID'] if reference else None,
            PurchaseUnit=reference.get('PurchaseUnit') if reference else None,
            QuantityToStockFactor=1 if reference else None,
            StandardPrice=price if reference else None,
            SourceModifiedAt=reference.get('source_modified_at',reference.get('KnownAt')) if reference else None,
            Assumption=ASSUMPTION if reference else None))
    if expected_fallback_count is not None and len(filled)!=expected_fallback_count:
        raise ValueError(f'Expected {expected_fallback_count} vendor-price replacements, got {len(filled)}')
    body=dict(schema='companyx.frozen.valuation.v1',rule=RULE,
        reference_vendor_rule='Minimum unscaled base_lead_days, then VendorID; selected once before policy and what-if factors',
        fallback_product_ids=filled,assumption=ASSUMPTION,rows=records)
    body['sha256']=digest(body)
    s.setdefault('metadata',{})['valuation']=body
    s['metadata']['unit_basis']='Stock unit from active BOM (EA/IN/OZ), resale and manufactured EA; purchased-to-stock factor 1 per approved group assumption.'
    validate(s)
    return s

def validate(snapshot):
    contract=snapshot.get('metadata',{}).get('valuation')
    if contract is None:return None  # Older custom snapshots remain supported.
    if contract.get('schema')!='companyx.frozen.valuation.v1':raise ValueError('Unsupported valuation schema')
    if digest({k:v for k,v in contract.items() if k!='sha256'})!=contract.get('sha256'):raise ValueError('Frozen valuation hash mismatch')
    prices={r['ProductID']:r for r in contract['rows']}
    if len(prices)!=len(contract['rows']) or set(prices)!={p['ProductID'] for p in snapshot['products']}:raise ValueError('Frozen valuation scope mismatch')
    fallback={r['ProductID'] for r in contract['rows'] if r['PriceSource']==RULE}
    if fallback!=set(contract['fallback_product_ids']):raise ValueError('Frozen fallback scope mismatch')
    vendors={(v['ProductID'],v['VendorID']):v for v in snapshot['supply_options']}
    for p in snapshot['products']:
        row=prices[p['ProductID']]
        if row['UnitCost']!=p['UnitCost'] or row['StockUnit']!=p['StockUnit']:raise ValueError('Product cost/unit differs from frozen valuation')
        if row['UnitCost'] is None or not math.isfinite(row['UnitCost']) or row['UnitCost']<0:raise ValueError('Incomplete frozen valuation')
        if row['PriceSource']==RULE:
            if row['QuantityToStockFactor']!=1 or row['UnitCost']!=row['StandardPrice']:raise ValueError('Approved 1:1 valuation changed')
            vendor=vendors.get((p['ProductID'],row['ReferenceVendorID']))
            if vendor is None or vendor.get('standard_price_raw')!=row['StandardPrice'] or vendor.get('PurchaseUnit')!=row['PurchaseUnit']:
                raise ValueError('Frozen price does not match reference vendor')
    return contract['sha256']

def dwh_configuration(snapshot):
    """Natural-key handoff for existing V6.2 config columns; never invent DW keys."""
    fingerprint=validate(snapshot)
    if not fingerprint:raise ValueError('Frozen valuation required for config handoff')
    contract=snapshot['metadata']['valuation'];products={p['ProductID']:p for p in snapshot['products']}
    reference='valuation_basis.json#sha256='+fingerprint
    conversions={}
    for v in snapshot['supply_options']:
        pid=v['ProductID'];source=v.get('PurchaseUnit');target=products[pid]['StockUnit']
        if not source or v.get('QuantityToStockFactor')!=1:raise ValueError('Explicit unit conversion required for config handoff')
        conversions[pid,source,target]=dict(ProductID=pid,FromUnitMeasureCode=source,ToUnitMeasureCode=target,
            ConversionFactor=1,EvidenceOrigin='ASSUMED_USER',EvidenceReference=reference)
    return dict(schema='companyx.dwh.valuation_config.v1',status='REQUIRES_DW_KEY_MAPPING',valuation_sha256=fingerprint,
        InventoryValuationRule='FULL_STANDARD_COST_WIP',PriceSelectionRule=RULE,
        Scenario_Product=[dict(ProductID=r['ProductID'],StockUnitMeasureCode=r['StockUnit'],StandardCostUsed=r['UnitCost'],
            CostBasisNote=r['PriceSource']+('; reference VendorID='+str(r['ReferenceVendorID'])+'; '+ASSUMPTION if r['ReferenceVendorID'] is not None else ''),
            EvidenceOrigin='ASSUMED_USER' if r['ReferenceVendorID'] is not None else 'GENERATED_SCENARIO',
            EvidenceReference=reference) for r in contract['rows']],
        Scenario_UnitConversion=[conversions[k] for k in sorted(conversions)],
        required_keys=['ScenarioVersionKey','ProductKey','UnitMeasureKey'],database_written=False)

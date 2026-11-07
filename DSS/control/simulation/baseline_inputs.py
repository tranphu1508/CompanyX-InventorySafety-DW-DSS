"""SELECT-only source extraction and auditable full-history ROP input preparation.

Does not execute simulation or SQL writes. The frozen model remains unchanged;
its parameters are explicitly retrospective when replay starts before July 2013.
"""
from __future__ import annotations
from collections import Counter,defaultdict
from copy import deepcopy
from datetime import date,datetime,timezone
from decimal import Decimal
import argparse,json,os,sys
from pathlib import Path
sys.dont_write_bytecode=True
os.environ['PYTHONDONTWRITEBYTECODE']='1'
try:
    from .adapter import RequestError,runtime,project_path,file_sha256
except ImportError:
    from adapter import RequestError,runtime,project_path,file_sha256

DATABASE='CompanyX_DW_SIM_20261107'
START='2011-05-31'
END='2014-06-30'
SCENARIOS=tuple(range(17,25))
CONNECTION='DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost;DATABASE='+DATABASE+';Trusted_Connection=yes;TrustServerCertificate=yes;ApplicationIntent=ReadOnly;APP=CompanyX Baseline Source Audit;'
QUERIES={
 'sales':"""SELECT f.SalesOrderDetailID,f.SalesOrderID,f.ProductID,f.OrderQty,
 CONVERT(char(10),CONVERT(date,CONVERT(char(8),f.OrderDateKey),112),23) OrderDate,
 CONVERT(char(10),CONVERT(date,CONVERT(char(8),f.DueDateKey),112),23) DueDate,
 f.IsDemandEligible,f.MakeFlag,f.DQReasonCode,f.StatusCode,f.StatusName,f.OrderAt,f.DueAt
 FROM act_input.DSSSales f ORDER BY f.SalesOrderDetailID""",
 'products':"""SELECT ProductID,MakeFlag,FinishedGoodsFlag,SafetyStockLevel,ReorderPoint,DaysToManufacture,
 StandardCost,SellStartDate,SellEndDate,DiscontinuedDate FROM dw.Dim_Product WHERE ProductKey>0 ORDER BY ProductID""",
 'bom':"""SELECT a.ProductID ProductAssemblyID,c.ProductID ComponentID,b.PerAssemblyQty,
 RTRIM(u.UnitMeasureCode) UnitMeasureCode,b.StartDate,b.EndDate,b.IsStructureValid
 FROM dw.Bridge_BillOfMaterials b JOIN dw.Dim_Product a ON a.ProductKey=b.AssemblyProductKey
 JOIN dw.Dim_Product c ON c.ProductKey=b.ComponentProductKey
 JOIN dw.Dim_UnitMeasure u ON u.UnitMeasureKey=b.UnitMeasureKey
 ORDER BY a.ProductID,c.ProductID,b.StartDate""",
 'additional_vendors':"""SELECT ProductID,BusinessEntityID VendorID,AverageLeadTime,StandardPrice,
 MinOrderQty,MaxOrderQty,RTRIM(UnitMeasureCode) PurchaseUnit,ModifiedDate
 FROM etl_raw.ProductVendor WHERE ProductID IN (709,710,841,843,844,850,853,857,863)
 ORDER BY ProductID,BusinessEntityID""",
 'additional_cost_history':"""SELECT ProductID,StartDate,EndDate,StandardCost,ModifiedDate
 FROM etl_raw.ProductCostHistory WHERE ProductID IN (709,710,841,843,844,850,853,857,863)
 ORDER BY ProductID,StartDate"""}


def _json(value):
    if isinstance(value,Decimal):return int(value) if value==int(value) else float(value)
    if isinstance(value,(datetime,date)):return value.isoformat()
    return value


def extract_source():
    """Only static SELECT statements; application intent also requests read-only."""
    import pyodbc
    with pyodbc.connect(CONNECTION,autocommit=True,timeout=15) as connection:
        cursor=connection.cursor()
        cursor.execute("SELECT DB_NAME(),CONVERT(nvarchar(100),value) FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner'")
        guard=cursor.fetchone()
        if not guard or tuple(guard)!=(DATABASE,'companyx-split-20261107'):
            raise RequestError('SOURCE_OWNER_MISMATCH','The copied CompanyX database identity does not match.')
        result={}
        for name,query in QUERIES.items():
            cursor.execute(query)
            keys=[x[0] for x in cursor.description]
            result[name]=[{k:_json(v) for k,v in zip(keys,row)} for row in cursor]
    return result


def _physical_edges(rows,manufactured,asof=None):
    return Counter((r['ProductAssemblyID'],r['ComponentID'],float(r['PerAssemblyQty']),r['UnitMeasureCode'].strip())
        for r in rows if r['ProductAssemblyID'] in manufactured and (asof is None or
        r['StartDate'][:10]<=asof and (r['EndDate'] is None or r['EndDate'][:10]>=asof)))


def audit_source(source,project_root=None,start=START,end=END):
    project,demo,config,inputs,legacy,run,valuation=runtime(project_root)
    frozen_path=demo/'KetQua/Demo_01/input.json'
    frozen=legacy.read(frozen_path)
    manufactured={p['ProductID'] for p in frozen['products'] if p['IsManufactured']}
    products={p['ProductID']:p for p in frozen['products']}
    allrows=source['sales']
    bounds=dict(start=min(r['OrderDate'] for r in allrows),end=max(r['OrderDate'] for r in allrows))
    if start<bounds['start'] or end>bounds['end'] or start>end:
        raise RequestError('SOURCE_DATE_RANGE','Baseline interval exceeds observed source order dates.',bounds)
    period=[r for r in allrows if start<=r['OrderDate']<=end]
    grouped=defaultdict(list)
    for row in period:grouped[row['SalesOrderID']].append(row)
    cohort_ids={oid for oid,rows in grouped.items() if any(r['ProductID'] in manufactured for r in rows)}
    cohort=[r for r in period if r['SalesOrderID'] in cohort_ids]
    outside=sorted({r['ProductID'] for r in cohort}-set(products))
    excluded=sorted(set(grouped)-cohort_ids)
    older=[r for r in cohort if r['OrderDate']<frozen['start']]
    manufactured_outside=sorted({r['ProductID'] for r in period if r['MakeFlag'] and r['ProductID'] not in manufactured})
    rootless=sorted({r['ProductID'] for r in cohort if r['ProductID'] in manufactured and not products[r['ProductID']]['ManufacturingParameters']['root']})
    invalid=[r['SalesOrderDetailID'] for r in cohort if not r['IsDemandEligible'] or r['OrderQty']<=0 or r['DueDate']<r['OrderDate']]
    invalid_set=set(invalid)
    invalid_orders={r['SalesOrderID'] for r in cohort if r['SalesOrderDetailID'] in invalid_set}
    invalid_rows=[r for r in cohort if r['SalesOrderDetailID'] in invalid_set]
    data_quality=dict(invalid_lines=len(invalid),invalid_whole_orders=len(invalid_orders),
        whole_order_quarantine_line_count=sum(len(grouped[o]) for o in invalid_orders),
        eligibility_false_lines=sum(not r['IsDemandEligible'] for r in cohort),
        due_before_order_lines=sum(r['DueDate']<r['OrderDate'] for r in cohort),
        nonpositive_quantity_lines=sum(r['OrderQty']<=0 for r in cohort),
        order_datekey_vs_timestamp_mismatch_lines=sum(bool(r.get('OrderAt')) and r['OrderAt'][:10]!=r['OrderDate'] for r in cohort),
        invalid_by_status=dict(Counter(str(r.get('StatusName')) for r in invalid_rows)),
        invalid_by_dq_reason=dict(Counter(str(r.get('DQReasonCode')) for r in invalid_rows)),
        proposed_quarantine_order_ids=sorted(invalid_orders),invalid_rows=invalid_rows)
    inconsistent=[oid for oid in cohort_ids if len({(r['OrderDate'],r['DueDate']) for r in grouped[oid]})!=1]
    duplicate_ids=[identifier for identifier,n in Counter(r['SalesOrderDetailID'] for r in cohort).items() if n!=1]
    frozenedges=_physical_edges(frozen['bom'],manufactured)
    edges_start=_physical_edges(source['bom'],manufactured,start)
    edges_frozen=_physical_edges(source['bom'],manufactured,frozen['start'])
    missing_start=list((frozenedges-edges_start).elements())
    added_start=list((edges_start-frozenedges).elements())
    future_leads=[p for p in manufactured if (products[p]['ManufacturingParameters'].get('last_history_completion') or '')>=start]
    future_costs=[p for p in manufactured if (products[p]['ManufacturingParameters'].get('cost_start') or '')[:10]>start]
    future_vendors=[dict(ProductID=r['ProductID'],VendorID=r['VendorID'],KnownAt=r.get('KnownAt',r.get('source_modified_at')))
                    for r in frozen['supply_options'] if str(r.get('KnownAt',r.get('source_modified_at','')))[:10]>start]
    stock_conflicts=[]
    master={p['ProductID']:p for p in source['products']}
    for pid,p in products.items():
        if pid not in master or master[pid]['SafetyStockLevel']!=p['SafetyStockQty'] or master[pid]['ReorderPoint']!=p['ReorderPointQty']:
            stock_conflicts.append(pid)
    additions=[]
    for pid in outside:
        vendor=[r for r in source.get('additional_vendors',[]) if r['ProductID']==pid]
        costs=[r for r in source.get('additional_cost_history',[]) if r['ProductID']==pid]
        effective=[r for r in costs if r['StartDate'][:10]<=start and (r['EndDate'] is None or r['EndDate'][:10]>=start)]
        additions.append(dict(product_id=pid,product=master.get(pid),vendors=vendor,cost_history=costs,cost_effective_at_start=effective,
            verified_all_purchase_units_EA=bool(vendor) and all(r['PurchaseUnit']=='EA' for r in vendor),
            valid_vendor_limits=bool(vendor) and all(r['AverageLeadTime']>=1 and 1<=r['MinOrderQty']<=r['MaxOrderQty'] for r in vendor),
            first_cohort_order_date=min(r['OrderDate'] for r in cohort if r['ProductID']==pid)))
    blockers=[]
    if outside:blockers.append('UNMODELED_SIBLING_PRODUCTS')
    if manufactured_outside:blockers.append('MANUFACTURED_SOURCE_PRODUCTS_OUTSIDE_FROZEN_MODEL')
    if invalid:blockers.append('INVALID_DEMAND_LINES')
    if inconsistent:blockers.append('INCONSISTENT_WHOLE_ORDER_DATES')
    if duplicate_ids:blockers.append('DUPLICATE_LINE_IDS')
    if frozenedges!=edges_frozen:blockers.append('FROZEN_BOM_SOURCE_DRIFT')
    if stock_conflicts:blockers.append('STOCK_PARAMETER_SOURCE_DRIFT')
    audit=dict(schema='companyx.baseline.source_audit.v1',database=DATABASE,source_bounds=bounds,start=start,end=end,
        calendar_days=(date.fromisoformat(end)-date.fromisoformat(start)).days+1,
        source_line_count=len(allrows),period_line_count=len(period),period_order_count=len(grouped),
        cohort_order_count=len(cohort_ids),cohort_line_count=len(cohort),cohort_product_count=len({r['ProductID'] for r in cohort}),
        earlier_added_line_count=len(older),earlier_added_order_count=len({r['SalesOrderID'] for r in older}),
        earlier_added_demand_product_ids=sorted({r['ProductID'] for r in older}-{r['ProductID'] for r in frozen['sales_order_lines']}),
        modeled_product_count=len(products),modeled_manufactured_count=len(manufactured),
        unmodeled_sibling_product_ids=outside,manufactured_source_products_outside_model=manufactured_outside,
        purchased_only_orders_excluded=len(excluded),purchased_only_lines_excluded=sum(len(grouped[o]) for o in excluded),
        excluded_purchased_only_order_ids=excluded,manufactured_demand_not_forecast_roots=rootless,
        invalid_line_ids=invalid,inconsistent_order_dates=inconsistent,duplicate_line_ids=duplicate_ids,
        data_quality=data_quality,additional_product_evidence=additions,
        bom_edges_frozen=sum(frozenedges.values()),bom_edges_at_requested_start=sum(edges_start.values()),
        frozen_bom_matches_source_at_july2013=frozenedges==edges_frozen,
        bom_physical_edges_equal_at_start=frozenedges==edges_start,
        frozen_edges_not_active_at_start=missing_start,additional_edges_active_at_start=added_start,
        lead_parameters_with_history_at_or_after_start=future_leads,
        cost_basis_effective_after_start=future_costs,vendor_values_known_after_start=future_vendors,
        stock_parameter_source_mismatches=stock_conflicts,
        valuation_sha256=valuation.validate(frozen),base_snapshot_sha256=file_sha256(frozen_path),
        base_snapshot_content_sha256=legacy.digest(frozen),original_frozen_start=frozen['start'],
        runtime_code_sha256=run.code_hash(),builder_sha256=file_sha256(__file__),
        source_extract_sha256={k:legacy.digest(v) for k,v in source.items()},
        structural_blockers=blockers,structurally_runnable=not blockers,
        interpretation='Fixed-parameter retrospective what-if over historical order arrivals. Frozen July2013 manufacturing lead/stock/valuation/vendor/BOM assumptions are not asserted to have been known in May2011.',
        forecast_audit=dict(frozen_calibration_boundary='2013-07-01',direct_mu_used_by_ROP=False,
            direct_mu_reestimated=False,allow_MILP_before_calibration_boundary=False,
            note='ROP decisions use stock thresholds, known active orders and BOM commitments, not direct_mu. Manufacturing lead history and fixed valuations are still retrospective parameters. A separate cutoff-safe forecast and parameter design is required for causal early-period MILP.'),
        initial_state='SafetyStock on each finite-stock product at the first simulation day; zero opening WIP, queued jobs, purchase commitments and customer orders. Unlimited external inputs retain zero inventory.',
        no_sql_writes=True,no_simulation_launched=True)
    return audit,cohort,frozen


def source_path(project_root=None):
    return project_path(project_root)/'GPT/output/companyx-split-20261107/baselines/full_history_inputs/source_extract.json'


def _build_snapshot(source,project_root=None,start=START,end=END):
    project,demo,config,inputs,legacy,run,valuation=runtime(project_root)
    audit,cohort,frozen=audit_source(source,project,start,end)
    if set(audit['structural_blockers'])-{'UNMODELED_SIBLING_PRODUCTS','INVALID_DEMAND_LINES'}:
        raise RequestError('BASELINE_INPUT_BLOCKED','Source cohort requires an explicit model extension.',audit)
    quarantine=set(audit['data_quality']['proposed_quarantine_order_ids'])
    cohort=[r for r in cohort if r['SalesOrderID'] not in quarantine]
    snapshot=deepcopy(frozen)
    snapshot['start'],snapshot['end']=start,end
    snapshot['sales_order_lines']=[{k:r[k] for k in ('SalesOrderDetailID','SalesOrderID','ProductID','OrderQty','OrderDate','DueDate')} for r in cohort]
    added=[]
    for evidence in audit['additional_product_evidence']:
        p=evidence['product'];pid=evidence['product_id'];vendors=evidence['vendors']
        if (p is None or p['MakeFlag'] or not evidence['verified_all_purchase_units_EA'] or
            not evidence['valid_vendor_limits'] or len(vendors)!=1 or not evidence['cost_history']):
            raise RequestError('RESALE_EXTENSION_UNSUPPORTED','Additional resale product lacks unambiguous EA/vendor/cost evidence.',{'ProductID':pid})
        histories=sorted(evidence['cost_history'],key=lambda x:x['StartDate'])
        selected=evidence['cost_effective_at_start']
        if len(selected)>1:raise RequestError('AMBIGUOUS_ADDED_COST','Multiple effective cost records for an added product.')
        cost=selected[0] if selected else histories[0]
        if cost['StandardCost']!=p['StandardCost']:
            raise RequestError('ADDED_COST_MASTER_MISMATCH','Historical selected cost differs from fixed product master.',{'ProductID':pid})
        assumption=('Additional historical resale product. Fixed cost from exact ProductCostHistory record; '
                    'constant for this hypothetical simulation, including dates before its effective start. '
                    'EA item quantities use verified EA purchase units with factor 1; no package conversion is inferred.')
        product=dict(ProductID=pid,IsManufactured=False,IsResale=True,StockUnit='EA',InitialQty=p['SafetyStockLevel'],
            SafetyStockQty=p['SafetyStockLevel'],ReorderPointQty=p['ReorderPoint'],UnitCost=cost['StandardCost'],ManufacturingParameters=None)
        snapshot['products'].append(product)
        vendor=vendors[0]
        option=dict(ProductID=pid,VendorID=vendor['VendorID'],base_lead_days=vendor['AverageLeadTime'],
            min_order_qty=vendor['MinOrderQty'],max_order_qty=vendor['MaxOrderQty'],standard_price_raw=vendor['StandardPrice'],
            source='etl_raw.ProductVendor',source_modified_at=vendor['ModifiedDate'],KnownAt=vendor['ModifiedDate'],
            PurchaseUnit='EA',QuantityToStockFactor=1,ConversionEvidence='EA_TO_EA',
            EvidenceOrigin='FIXED_MASTER_RETROSPECTIVE_WHAT_IF',Assumption='Exact current master terms are fixed scenario assumptions, not reconstructed as-of historical vendor terms.')
        snapshot['supply_options'].append(option)
        value=dict(ProductID=pid,UnitCost=cost['StandardCost'],StockUnit='EA',PriceSource='FIXED_RETROSPECTIVE_PRODUCT_COST_HISTORY',
            ReferenceVendorID=None,PurchaseUnit=None,QuantityToStockFactor=None,StandardPrice=None,
            SourceModifiedAt=cost['ModifiedDate'],Assumption=assumption)
        snapshot['metadata']['valuation']['rows'].append(value)
        added.append(dict(ProductID=pid,product=product,supply_option=option,valuation_row=value,
                          cost_effective_start=cost['StartDate'],cost_effective_end=cost['EndDate'],
                          cost_is_effective_at_simulation_start=bool(selected)))
    snapshot['products'].sort(key=lambda p:p['ProductID'])
    value=snapshot['metadata']['valuation']
    value['rows'].sort(key=lambda r:r['ProductID'])
    value['sha256']=legacy.digest({k:v for k,v in value.items() if k!='sha256'})
    for p in snapshot['products']:
        p['InitialQty']=p['SafetyStockQty']
        if p['IsManufactured']:p['ManufacturingParameters']['initial']=p['InitialQty']
    scope=dict(schema='companyx.baseline.scope.v1',start=start,end=end,
        initial_state_rule='SAFETY_STOCK_LEVEL',product_scope_mode='FULL_FROZEN_MANUFACTURED_ORDER_COHORT',
        evaluation_scope='RETROSPECTIVE_FIXED_PARAMETER_ROP_BASELINE',original_base_start=frozen['start'],
        base_snapshot_sha256=audit['base_snapshot_sha256'],base_snapshot_content_sha256=audit['base_snapshot_content_sha256'],
        base_valuation_sha256=audit['valuation_sha256'],valuation_sha256=value['sha256'],source_extract_sha256=audit['source_extract_sha256'],
        builder_sha256=file_sha256(__file__),source_audit_sha256=legacy.digest(audit),
        effective_product_ids=sorted(p['ProductID'] for p in snapshot['products']),
        selected_sales_order_line_ids=sorted(r['SalesOrderDetailID'] for r in cohort),
        selected_sales_order_ids=sorted({r['SalesOrderID'] for r in cohort}),
        quarantine_rule='EXCLUDE_ENTIRE_ORDER_IF_ANY_LINE_CANCELLED_OR_DUE_BEFORE_ORDER_OR_NONPOSITIVE',
        quarantined_order_ids=sorted(quarantine),quarantined_line_ids=audit['invalid_line_ids'],
        quarantine_reasons=audit['data_quality']['invalid_by_dq_reason'],
        added_product_ids=[x['ProductID'] for x in added],added_product_evidence=added,
        parameter_interpretation=audit['interpretation'],forecast_audit=audit['forecast_audit'],
        source_scope_id='WHOLE_MANUFACTURED_ORDERS_20110531_20140630_SS_FIXED_MASTER_V1')
    scope['scope_sha256']=legacy.digest(scope)
    snapshot['metadata']['baseline_scope']=scope
    snapshot['metadata']['initial_stock']=audit['initial_state']
    snapshot['metadata']['forecast']='Frozen July2013 direct_mu retained byte-for-byte but inactive in ROP. Do not use for MILP before 2013-07-01.'
    valuation.validate(snapshot)
    provenance=dict(schema='companyx.baseline.input_provenance.v1',scope=scope,source_scope_id=scope['source_scope_id'],
        snapshot_sha256=legacy.digest(snapshot),runtime_code_sha256=run.code_hash(),builder_sha256=file_sha256(__file__),
        source_extract_path=str(source_path(project)),source_extract_file_sha256=file_sha256(source_path(project)),
        source_extract_content_sha256=legacy.digest(source),audit=audit)
    return dict(snapshot=snapshot,provenance=provenance)


def build_snapshot(project_root=None):
    """Rebuild shared full-history input only from the saved canonical SELECT extract."""
    project,_,_,_,legacy,_,_=runtime(project_root)
    return _build_snapshot(legacy.read(source_path(project)),project)


def build_scenario(scenario_index,project_root=None):
    if type(scenario_index)is not int or scenario_index not in SCENARIOS:
        raise RequestError('INVALID_BASELINE_SCENARIO','Choose safety-stock scenario index 17 through 24.')
    project,demo,config,inputs,legacy,run,_=runtime(project_root)
    built=build_snapshot(project)
    snapshot,provenance=built['snapshot'],built['provenance']
    choice=deepcopy(legacy.read(demo/'DSS/all_four_matrix.json')['scenarios'][scenario_index-1])
    name=choice.pop('name');rule=choice.pop('initial_state_rule')
    if rule!='SAFETY_STOCK_LEVEL':raise RequestError('SCENARIO_DRIFT','Selected matrix row is no longer safety stock.')
    choice['policy']='ROP';spec=config.resolve(choice)
    scope=snapshot['metadata']['baseline_scope']
    scope.update(scenario_index=scenario_index,scenario_name=name)
    scope['scope_sha256']=legacy.digest({k:v for k,v in scope.items() if k!='scope_sha256'})
    if spec['supply']['mode']=='INSTANT_UNLIMITED':
        for p in snapshot['products']:
            if not p['IsManufactured']:p['InitialQty']=0
    data=inputs.prepare(snapshot,spec)
    from companyx_unified_v2.orders import OrderBook
    OrderBook(data['lines'],data['P'],data['external_ids'],data['start'],data['end'],'7B' if spec['allow_backorders'] else '7C',data['raw'])
    provenance.update(scope=scope,scenario_index=scenario_index,snapshot_sha256=legacy.digest(snapshot),execution_spec_sha256=legacy.digest(spec))
    return dict(prepared_schema='companyx.baseline.prepared.v1',snapshot=snapshot,spec=spec,scope=scope,provenance=provenance,
        snapshot_sha256=legacy.digest(snapshot),execution_spec_sha256=legacy.digest(spec),runtime_code_sha256=run.code_hash())


def verify_snapshot(snapshot,provenance,project_root=None):
    from . import historical_baseline_inputs as historical
    project,_,_,_,legacy,run,valuation=runtime(project_root)
    contract=legacy.read(Path(__file__).resolve().parents[1]/'migration-contract.json')
    if file_sha256(historical.__file__)!=contract['historical_builder_sha256']:
        raise RequestError('HISTORICAL_BUILDER_CHANGED','Pinned historical baseline builder changed.')
    historical.source_path=lambda project_root=None: source_path(project_root)
    expected=historical.build_scenario(provenance['scenario_index'],project)
    original_path=contract['source_extract_original_path']
    if provenance['source_extract_path']!=original_path:
        raise RequestError('BASELINE_SOURCE_PATH_CHANGED','Unknown historical extract origin.')
    expected['provenance']['source_extract_path']=original_path
    if snapshot!=expected['snapshot'] or provenance!=expected['provenance']:
        raise RequestError('BASELINE_INPUT_CHANGED','Migrated baseline differs from its pinned original source and rules.')
    valuation.validate(snapshot)
    return dict(status='VERIFIED',snapshot_sha256=legacy.digest(snapshot),source_scope_id=provenance['source_scope_id'],runtime_code_sha256=run.code_hash())


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--output',required=True);p.add_argument('--source-cache');p.add_argument('--prepare',action='store_true')
    args=p.parse_args()
    project,_,_,_,legacy,_,_=runtime()
    output=Path(args.output).resolve()
    if not output.is_relative_to(project/'GPT'):raise RequestError('OUTPUT_OUTSIDE_GPT','Outputs must be under Project/GPT.')
    output.mkdir(parents=True,exist_ok=True)
    source=legacy.read(args.source_cache) if args.source_cache else extract_source()
    if not args.source_cache:legacy.save(output/'source_extract.json',source)
    audit,_,_=audit_source(source,project)
    legacy.save(output/'source_audit.json',audit)
    if args.prepare:
        shared=build_snapshot(project)
        legacy.save(output/'input.json',shared['snapshot'])
        legacy.save(output/'input_provenance.json',shared['provenance'])
        for index in SCENARIOS:
            built=build_scenario(index,project)
            legacy.save(output/f'prepared_scenario_{index}.json',built)
        legacy.save(output/'prepared_validation.json',dict(status='PREPARED_NOT_EXECUTED',scenarios=list(SCENARIOS),
            shared_verification=verify_snapshot(shared['snapshot'],shared['provenance'],project),
            effective_line_count=len(shared['snapshot']['sales_order_lines']),effective_order_count=len(shared['provenance']['scope']['selected_sales_order_ids']),
            quarantine_order_count=len(shared['provenance']['scope']['quarantined_order_ids']),added_product_ids=shared['provenance']['scope']['added_product_ids']))
    print(json.dumps({k:audit[k] for k in ('start','end','calendar_days','source_line_count','cohort_order_count','cohort_line_count',
        'earlier_added_line_count','unmodeled_sibling_product_ids','manufactured_source_products_outside_model',
        'purchased_only_orders_excluded','manufactured_demand_not_forecast_roots','bom_physical_edges_equal_at_start',
        'structurally_runnable','structural_blockers')},ensure_ascii=False,indent=2))


if __name__=='__main__':main()

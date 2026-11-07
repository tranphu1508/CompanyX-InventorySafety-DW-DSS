"""Explicit supported V6 execution profile; SQL enum meanings stay unchanged."""
from .legacy import digest

EVENT_ENTITY_TYPES={
    'BUY_ORDER':'PURCHASE_ORDER_LINE','BUY_RECEIVE_GOOD':'RECEIPT_LOT','BUY_REJECT':'RECEIPT_LOT',
    'PRODUCTION_REQUEST':'PRODUCTION_JOB','PRODUCTION_START':'PRODUCTION_JOB','PRODUCTION_GOOD':'PRODUCTION_JOB',
    'BOM_ISSUE':'PRODUCTION_JOB','SHIP_ON_TIME':'CUSTOMER_ORDER_LINE','SHIP_LATE':'CUSTOMER_ORDER_LINE',
    'LOST_SALE':'CUSTOMER_ORDER_LINE'}
RELATION_TYPES={'HAS_RECEIPT':('PURCHASE_ORDER_LINE','RECEIPT_LOT'),
                'HAS_OPERATION':('PRODUCTION_JOB','OPERATION_EXECUTION')}

def profile(snapshot,spec,data):
    """This versioned payload travels via V6 ExecutionSpecReference, not a new SQL field."""
    manufactured=sorted(data['P']);finite=sorted(set(data['P'])|data['raw'])
    external=sorted(set(data['products'])-set(finite))
    body=dict(schema='companyx.sql62.execution_profile.v1',
        ExternalSupplyMode=spec['supply']['mode'],SupplyLimitMode=spec['supply']['daily_limit_mode'],
        ProcurementLifecycle=spec['supply']['lifecycle'],
        SupplyModeMeaning='INSTANT_UNLIMITED bypasses procurement. PURCHASE_WITH_LEADTIME uses lots/lead/reject; SQL SupplyLimitMode UNLIMITED only means no daily dispatch cap.',
        ProcurementStateRule='Undelivered purchase quantities remain OpenPurchaseQty until inspection/receipt; no modeled vendor dispatch, no transfer lots, PurchaseInTransitQty=0.',
        ExternalDrawRule='Instant provision is recorded only in ExternalSupplyDraw audit. Never fabricate BUY_ORDER, receipt or dispatch events.',
        InitialStateRule='Explicit on-hand quantities; zero opening WIP/queue/purchases/customer obligations.',
        ProductionMode='AGGREGATE_LEAD_TIME',InventoryValuationRule='FULL_STANDARD_COST_WIP',
        InTransitOwnershipRule='NOT_OWNED_IN_TRANSIT',
        HoldingCostRatePerYear=spec['holding_cost_rate_per_year'],HoldingCostRateNote=spec['holding_cost_rate_note'],
        HoldingCostDayBasis=365,HoldingCostIncludesTransit=False,
        CustomerShipmentMode='COMPLETE_ORDER',ShortageHandlingMode='BACKORDER' if spec['allow_backorders'] else 'LOST_SALES',
        LostSalesScope=None if spec['allow_backorders'] else 'WHOLE_SALES_ORDER',
        ServiceProductIDs=manufactured,FiniteStockProductIDs=finite,InstantExternalProductIDs=external,
        valuation_sha256=data.get('valuation_sha256'),input_sha256=digest(snapshot),
        unsupported=['CALENDAR_LIMIT','ROUTED_TIME','PARTIAL_LINE','nonzero opening entities','nonunit quantity conversions'],
        EventEntityTypes=EVENT_ENTITY_TYPES)
    from .production_timing import mode, is_start_based
    body['ProductionLeadTimeMode']=mode(spec)
    body['ProductionLeadTimeFormula']='ActualStartDate + lead_days' if is_start_based(spec) else 'max(ActualStartDate + 1, RequestDate + lead_days)'
    body['ProductionStartRule']='MATERIAL_READY_IMMEDIATE_START_V1'
    body['ProductionStartRuleMeaning']='Both timing modes start issued quantity immediately when direct materials permit; partial starts and competition for materials are allowed. Completion follows the selected timing convention.'
    body['sha256']=digest(body)
    return body

def validate_profile(value,snapshot,spec,data):
    if value!=profile(snapshot,spec,data):raise ValueError('Execution profile differs from frozen input/spec')

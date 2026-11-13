"""Prune ACT metrics unused by the audited PBIX and DSS input contract.

Keep the historical Unified.source.xmla unchanged; apply this policy on every
ACT rebuild. Consumer requirements are covered by tests/test_act_metric_pruning.py;
audit reports are local artifacts, not rebuild inputs.
"""
import re

REMOVED_PUBLIC = frozenset('''Actual Sales Eligible Line Count
Actual Sales Line Amount
Actual Sales Eligible Line Amount
Actual Sales Ship Date Observed Lines
Actual Sales Recorded Ship By Due Lines
Actual Sales Recorded Ship Lag Days Sum
Actual Sales Order Count
Actual Sales Ordered Source Qty
Actual Sales Eligible Source Qty
Actual Sales Recorded Ship By Due Line Rate
Actual Purchase Line Count
Actual Purchase Declared Vendor Lines
Actual Purchase Line Amount
Actual Purchase Order Count
Actual Purchase Ordered Source Qty
Actual Purchase Received Source Qty
Actual Purchase Rejected Source Qty
Actual Purchase Stocked Source Qty
Actual Purchase Source Rejection Rate
Actual Inventory Positive Cost Positions
Actual WorkOrder Late Days Sum
Actual WorkOrder Planned Cost
Actual WorkOrder Recorded Cost
Actual WorkOrder Resource Hours
Actual WorkOrder Mean Observed Lead Days
Actual WorkOrder Source Scrap Rate
Actual Operation Count
Actual Operation Duration Observed Count
Actual Operation Duration Days Sum
Actual Operation Resource Hours
Actual Operation Planned Cost
Actual Operation Recorded Cost
Actual Operations Distinct WorkOrder Count
Actual Operation Mean Observed Duration Days'''.splitlines())
REMOVED_RAW = frozenset('Raw '+name for name in REMOVED_PUBLIC
                        if name.endswith('Source Qty'))
REMOVED_MEASURES = REMOVED_PUBLIC | REMOVED_RAW
REMOVED_GROUPS = frozenset({'ActualPurchases', 'ActualOperations'})
CREATE_MEMBER = re.compile(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^\]]+)\].*?;', re.S | re.I)
MEASURE_REF = re.compile(r'\[Measures\]\.\[([^\]]+)\]')


def prune_act_diagram(root):
    """Remove designer shapes/connectors for the two removed measure groups."""
    for dds in root.findall('.//{*}dds'):
        for control in list(dds):
            if control.tag.split('}')[-1] != 'ddscontrol':
                continue
            values = [p.get('value', '') for p in control.findall('.//{*}property')
                      if p.get('name') == 'LogicalObject']
            if any(v in ('OpsFactPurchases', 'OpsFactOperations') or
                   any(v.startswith('dataSet.Relations['+g+'_') for g in REMOVED_GROUPS)
                   for v in values):
                dds.remove(control)


def prune_unused_act_metrics(cube):
    """Idempotently remove audited definitions, references and empty groups."""
    if cube.findtext('{*}ID') != 'CompanyX_ACT_20261107':
        raise ValueError('Metric pruning is scoped to ACT only')
    groups = cube.find('{*}MeasureGroups')
    for group in list(groups):
        measures = group.find('{*}Measures')
        for measure in list(measures):
            if measure.findtext('{*}ID') in REMOVED_MEASURES:
                measures.remove(measure)
        if not len(measures):
            if group.findtext('{*}ID') not in REMOVED_GROUPS:
                raise ValueError('Unexpected empty measure group')
            groups.remove(group)
    for text in cube.findall('./{*}MdxScripts//{*}Text'):
        text.text = CREATE_MEMBER.sub(
            lambda m: '' if m[1] in REMOVED_MEASURES else m[0], text.text or '')
        text.text = re.sub(r'\n[ \t]*\n+', '\n', text.text)
    for parent in cube.findall('./{*}MdxScripts//{*}CalculationProperties'):
        for item in list(parent):
            ref = item.findtext('{*}CalculationReference', '')
            if ref.strip('[]') in REMOVED_MEASURES or set(MEASURE_REF.findall(ref)) & REMOVED_MEASURES:
                parent.remove(item)
    for perspective in cube.findall('./{*}Perspectives/{*}Perspective'):
        pgroups = perspective.find('{*}MeasureGroups')
        if pgroups is not None:
            for group in list(pgroups):
                if group.findtext('{*}MeasureGroupID') in REMOVED_GROUPS:
                    pgroups.remove(group)
                    continue
                measures = group.find('{*}Measures')
                if measures is not None:
                    for measure in list(measures):
                        if measure.findtext('{*}MeasureID') in REMOVED_MEASURES:
                            measures.remove(measure)
        calculations = perspective.find('{*}Calculations')
        if calculations is not None:
            for item in list(calculations):
                if set(MEASURE_REF.findall(item.findtext('{*}Name', ''))) & REMOVED_MEASURES:
                    calculations.remove(item)
    statements = '\n'.join(t.text or '' for t in cube.findall('./{*}MdxScripts//{*}Text'))
    physical = {m.findtext('{*}ID') for m in cube.findall('./{*}MeasureGroups/{*}MeasureGroup/{*}Measures/{*}Measure')}
    calculated = {m[1] for m in CREATE_MEMBER.finditer(statements)}
    dangling = set(MEASURE_REF.findall(statements)) - physical - calculated
    if dangling:
        raise ValueError('Dangling ACT measure references: '+str(sorted(dangling)))
    if (physical | calculated) & REMOVED_MEASURES:
        raise ValueError('Removed ACT metrics were recreated')
    prune_act_diagram(cube)
    return calculated

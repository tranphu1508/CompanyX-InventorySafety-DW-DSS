"""ACT quantities aggregate at the selected slice without key Min/Max guards.

Source-eligibility semantics are preserved. Inventory keeps the
underlying LastNonEmpty aggregation across time. SIM rules are out of scope.
"""
import re

ACT_GROUPS={'ActualSales','ActualPurchases','ActualInventory','ActualWorkOrders','ActualOperations'}
QUANTITIES=(
 'Actual Sales Ordered Source Qty','Actual Sales Eligible Source Qty',
 'Actual Purchase Ordered Source Qty','Actual Purchase Received Source Qty',
 'Actual Purchase Rejected Source Qty','Actual Purchase Stocked Source Qty',
 'Actual Inventory Source Qty','Actual WorkOrder Ordered Source Qty',
 'Actual WorkOrder Stocked Source Qty','Actual WorkOrder Scrapped Source Qty')

def simplify_act_quantities(cube):
 if cube.findtext('{*}ID')!='CompanyX_ACT_20261107':
  raise ValueError('This change is scoped to the isolated ACT cube only')
 groups=cube.findall('./{*}MeasureGroups/{*}MeasureGroup')
 removed=[]
 for group in groups:
  if group.findtext('{*}ID') not in ACT_GROUPS:continue
  measures=group.find('{*}Measures')
  for measure in list(measures):
   if measure.findtext('{*}AggregateFunction') not in ('Min','Max'):continue
   key=measure.findtext('./{*}Source/{*}Source/{*}ColumnID')
   if key not in ('ProductKey','VendorKey') or measure.findtext('{*}Visible')!='false':
    raise ValueError('Unexpected business Min/Max; do not remove it automatically')
   removed.append(measure.findtext('{*}ID'));measures.remove(measure)
 texts=cube.findall('./{*}MdxScripts/{*}MdxScript/{*}Commands/{*}Command/{*}Text')
 changed=[]
 for public in QUANTITIES:
  raw='Raw '+public;matches=0
  pattern=re.compile(r'(CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\['+re.escape(public)+r'\] AS )(.+?)(, FORMAT_STRING=)',re.S)
  for text in texts:
   def replace(match):
    nonlocal matches
    matches+=1
    if '[Measures].['+raw+']' not in match[2]:raise ValueError('Unexpected quantity formula: '+public)
    return match[1]+'([Measures].['+raw+'])'+match[3]
   text.text=pattern.sub(replace,text.text or '')
  if matches!=1:raise ValueError('Expected one quantity calculation: '+public)
  changed.append(public)
 for collection in cube.findall('./{*}Perspectives/{*}Perspective/{*}MeasureGroups/{*}MeasureGroup/{*}Measures'):
  for measure in list(collection):
   if measure.findtext('{*}MeasureID') in removed:collection.remove(measure)
 statements='\n'.join(t.text or '' for t in texts)
 for name in removed:
  if '[Measures].['+name+']' in statements:raise ValueError('Dangling helper reference: '+name)
 physical={m.findtext('{*}ID') for g in groups for m in g.findall('./{*}Measures/{*}Measure')}
 calculated=set(re.findall(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^\]]+)\]',statements))
 referenced=set(re.findall(r'\[Measures\]\.\[([^\]]+)\]',statements))
 if referenced-physical-calculated:raise ValueError('Unresolved measures after simplification')
 return {'removed':removed,'updated_calculations':changed}

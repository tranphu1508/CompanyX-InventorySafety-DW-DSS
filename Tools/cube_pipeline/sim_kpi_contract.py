"""Business KPI contract from Cong_thuc_KPI_DSS_CompanyX.docx, sections 1-8,10."""
from copy import deepcopy
import re
from detail_cube import E,XS,XSI,add,set_text,one

def apply_contract(db,cube):
 ann=one(db,'Annotations')
 for key,value in [('CompanyXKPIContract','Cong_thuc_KPI_DSS_CompanyX.docx'),('CompanyXKPIContractSHA256','ec054b645cd2814c9280b8b8c11111fe037c9b1953db1d446cb7e21e0fbd4f60')]:
  old=next((a for a in ann if a.findtext('{*}Name')==key),None)
  if old is not None:ann.remove(old)
  item=add(ann,'Annotation');add(item,'Name',key);add(item,'Value',value)
 script=cube.find('./{*}MdxScripts/{*}MdxScript/{*}Commands/{*}Command/{*}Text')
 text=script.text or ''
 names={d.findtext('{*}ID'):d.findtext('{*}Name') or d.findtext('{*}ID') for d in cube.findall('./{*}Dimensions/{*}Dimension')}
 sim='['+names['Simulation Date']+'].[Date]'
 due='['+names['Due Date']+'].[Date]'
 made='['+names['Product']+'].[Manufactured].&[1]'
 single='VALIDMEASURE([Measures].[Internal Audit Run Count])=1'
 units='NOT ISEMPTY(VALIDMEASURE([Measures].[Line Unit Key Min])) AND VALIDMEASURE([Measures].[Line Unit Key Min])=VALIDMEASURE([Measures].[Line Unit Key Max])'
 endday='TAIL(NONEMPTY(GENERATE(EXISTING '+due+'.[Date].MEMBERS,{LINKMEMBER('+due+'.CURRENTMEMBER,'+sim+')}),{[Measures].[Internal KPI Calendar Days]}),1)'
 definitions={}
 def calc(name,expr,group,fmt='#,##0.00',visible=True):
  definitions[name]=(expr,group,fmt,visible)
 calc('Internal KPI Calendar Days','VALIDMEASURE([Measures].[Internal Simulated Calendar Days])','RunDay','#,##0',False)
 for name,raw in [('Due Cohort Demand Qty','Raw Due Cohort Demand Qty'),('Due Cohort On Time Qty','Raw Due Cohort On Time Qty'),('Due Cohort Lost Qty','Raw Due Cohort Lost Qty')]:
  calc('All SKU '+name,'IIF('+single+' AND '+units+',VALIDMEASURE([Measures].['+raw+']),NULL)','OrderLineService')
  calc(name,'([Measures].[All SKU '+name+'],'+made+')','OrderLineService')
 b='COALESCEEMPTY(SUM('+endday+',VALIDMEASURE([Measures].[Internal Detail Open Customer Line Remaining Qty EOD])),0)'
 calc('All SKU Due Cohort Ending Backlog Qty','IIF('+single+' AND '+units+' AND COUNT('+endday+')=1,'+b+',NULL)','OrderLineService')
 calc('All SKU Due Cohort Filled Qty','[Measures].[All SKU Due Cohort Demand Qty]-[Measures].[All SKU Due Cohort Lost Qty]-[Measures].[All SKU Due Cohort Ending Backlog Qty]','OrderLineService')
 calc('All SKU Due Cohort Late Qty','[Measures].[All SKU Due Cohort Filled Qty]-[Measures].[All SKU Due Cohort On Time Qty]','OrderLineService')
 for name in ['Due Cohort Ending Backlog Qty','Due Cohort Filled Qty','Due Cohort Late Qty']:
  calc(name,'([Measures].[All SKU '+name+'],'+made+')','OrderLineService')
 for name,num in [('On Time Unit Rate','Due Cohort On Time Qty'),('Due Cohort Fill Rate','Due Cohort Filled Qty'),('Late Delivery Rate','Due Cohort Late Qty'),('Lost Unit Rate','Due Cohort Lost Qty'),('End Backlog Rate','Due Cohort Ending Backlog Qty')]:
  for prefix in ['', 'All SKU ']:
   calc(prefix+name,'IIF([Measures].['+prefix+'Due Cohort Demand Qty]>0,[Measures].['+prefix+num+']/[Measures].['+prefix+'Due Cohort Demand Qty],NULL)','OrderLineService','0.00%')
 calc('Open Due Order Count','IIF([Measures].[Due Order Count]>0 AND COUNT('+endday+')=1,COALESCEEMPTY(SUM('+endday+',VALIDMEASURE([Measures].[Internal Detail Due Open Customer Orders EOD])),0),NULL)','OrderService','#,##0')
 calc('Open Order Rate','IIF([Measures].[Due Order Count]>0,[Measures].[Open Due Order Count]/[Measures].[Due Order Count],NULL)','OrderService','0.00%')
 calc('Full By End Rate','IIF([Measures].[Due Order Count]>0,([Measures].[Due Order Count]-[Measures].[Lost Order Count]-[Measures].[Open Due Order Count])/[Measures].[Due Order Count],NULL)','OrderService','0.00%')
 dayunits='NOT ISEMPTY([Measures].[Daily Unit Key Min]) AND [Measures].[Daily Unit Key Min]=[Measures].[Daily Unit Key Max]'
 calc('All SKU Late Unit Days','IIF('+single+' AND '+dayunits+',SUM(EXISTING '+sim+'.[Date].MEMBERS,[Measures].[Backlog Qty EOD]),NULL)','SimulationDaily')
 calc('Late Unit Days','([Measures].[All SKU Late Unit Days],'+made+')','SimulationDaily')
 calc('Average Daily Production Good Qty','IIF(VALIDMEASURE([Measures].[Internal Simulated Calendar Days])>0,[Measures].[Production Good Qty]/VALIDMEASURE([Measures].[Internal Simulated Calendar Days]),NULL)','SimulationDaily')
 # Frozen annual holding rate, one value per run; no addition of rates across runs.
 summary=next(g for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup') if g.findtext('{*}ID')=='RunSummary')
 ms=summary.find('{*}Measures')
 if not any(m.findtext('{*}ID')=='Internal Holding Cost Annual Rate' for m in ms):
  m=deepcopy(next(iter(ms)))
  for tag,val in [('ID','Internal Holding Cost Annual Rate'),('Name','Internal Holding Cost Annual Rate'),('AggregateFunction','Max'),('DataType','Double'),('Visible','false')]:set_text(m,tag,val)
  source=m.find('{*}Source');set_text(source,'DataType','Double');set_text(source,'NullProcessing','Error')
  set_text(source.find('{*}Source'),'ColumnID','HoldingCostRatePerYear')
  ms.append(m)
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 table=dsv.find('.//{'+XS+'}choice/{'+XS+'}element[@name="FactRunSummary"]')
 seq=table.find('./{'+XS+'}complexType/{'+XS+'}sequence')
 if not any(c.get('name')=='HoldingCostRatePerYear' for c in seq):
  import xml.etree.ElementTree as ET
  ET.SubElement(seq,'{'+XS+'}element',{'name':'HoldingCostRatePerYear','type':'xs:decimal'})
 calc('Holding Cost','IIF('+single+',[Measures].[Inventory Value Day Sum]*VALIDMEASURE([Measures].[Internal Holding Cost Annual Rate])/365.0,NULL)','SimulationDaily')
 retained=[]
 for st in text.split(';'):
  st=st.strip()
  if not st:continue
  match=re.search(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^]]+)\]',st)
  if match and match[1] in definitions:continue
  retained.append(st+';')
 for name,(expr,group,fmt,visible) in definitions.items():
  retained.append(f"CREATE MEMBER CURRENTCUBE.[Measures].[{name}] AS {expr}, FORMAT_STRING='{fmt}', VISIBLE={int(visible)}, DISPLAY_FOLDER='{group}', ASSOCIATED_MEASURE_GROUP='{group}';")
 script.text='\n'.join(retained)
 return set(re.findall(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^]]+)\]',script.text))

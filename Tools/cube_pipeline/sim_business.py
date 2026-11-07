"""Business-only SIM cube surface; warehouse audit facts remain available."""
import re
from detail_cube import E,XS,MSDATA,add,one,set_text

DROP_GROUPS={'SolveAudit','ProductionActivity','InquiryWindow','RequestedWindowSummary','RequestedWindowLine','RequestedWindowTranche'}
DROP_ROLES={'Solve','Solver Status','Trace Method'}
DROP_ATTRIBUTES={
 'Run':{'Optimizer Version','Optimizer Hash','Result Model Status','Input Origin','ACT Input Snapshot','Experiment','Run Purpose'},
 'Plan Version':{'Decision Hash','Decision Version ID'},
 'RequestedWindow':{'Cache Action','Purpose','Window ID'},
}
def simplify_sim(db,cube):
 groups=cube.find('{*}MeasureGroups')
 removed_groups=[]
 for g in list(groups):
  if g.findtext('{*}ID') in DROP_GROUPS:
   removed_groups.append(g.findtext('{*}ID'));groups.remove(g);continue
  dims=g.find('{*}Dimensions')
  for d in list(dims):
   if d.findtext('{*}CubeDimensionID') in DROP_ROLES:dims.remove(d)
 roles={d.findtext('{*}CubeDimensionID') for g in groups for d in g.findall('./{*}Dimensions/{*}Dimension')}
 cdims=cube.find('{*}Dimensions')
 for d in list(cdims):
  if d.findtext('{*}ID') not in roles:cdims.remove(d)
 dids={d.findtext('{*}DimensionID') for d in cdims}
 removed_attrs={}
 dims=db.find('{*}Dimensions')
 for d in list(dims):
  did=d.findtext('{*}ID')
  if did not in dids:dims.remove(d);continue
  drop=DROP_ATTRIBUTES.get(did,set())
  attrs=d.find('{*}Attributes')
  removed_attrs[did]=[]
  for a in list(attrs):
   aid=a.findtext('{*}ID')
   if aid in drop:
    if a.findtext('{*}Usage')=='Key':raise ValueError('Cannot remove key')
    removed_attrs[did].append(aid);attrs.remove(a)
  for parent in d.iter():
   for ch in list(parent):
    if ch.tag in ('{'+E+'}AttributeRelationship','{'+E+'}Level') and ch.findtext('{*}AttributeID') in drop:parent.remove(ch)
  for cd in cdims:
   if cd.findtext('{*}DimensionID')==did:
    ca=cd.find('{*}Attributes')
    if ca is not None:
     for a in list(ca):
      if a.findtext('{*}AttributeID') in drop:ca.remove(a)
 scripts=cube.find('./{*}MdxScripts/{*}MdxScript')
 kept=[];removed_calcs=[]
 for cmd in scripts.findall('./{*}Commands/{*}Command'):
  for st in cmd.findtext('{*}Text','').split(';'):
   st=st.strip()
   if not st:continue
   mg=re.search(r"ASSOCIATED_MEASURE_GROUP\s*=\s*'([^']+)'",st)
   nm=re.search(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^]]+)\]',st)
   if mg and (mg[1] in DROP_GROUPS or (mg[1]=='RunSummary' and nm and nm[1].startswith('Audit '))):
    removed_calcs.append(nm[1] if nm else st[:80]);continue
   kept.append(st+';')
 # Same business definitions for both policies, based on published facts.
 date_role=next(d.findtext('{*}Name') or d.findtext('{*}ID') for d in cdims if d.findtext('{*}ID')=='Simulation Date')
 dayset='EXISTING ['+date_role+'].[Date].[Date].MEMBERS'
 guard="VALIDMEASURE([Measures].[Internal Audit Run Count])=1 AND NOT ISEMPTY([Measures].[Daily Unit Key Min]) AND [Measures].[Daily Unit Key Min]=[Measures].[Daily Unit Key Max] AND VALIDMEASURE([Measures].[Internal Simulated Calendar Days])>0"
 extras={
  'Average On Hand Qty':('SimulationDaily',"IIF("+guard+",SUM("+dayset+",[Measures].[On Hand Qty EOD])/VALIDMEASURE([Measures].[Internal Simulated Calendar Days]),NULL)",'#,##0.00'),
  'Average WIP Qty':('SimulationDaily',"IIF("+guard+",SUM("+dayset+",[Measures].[WIP Qty EOD])/VALIDMEASURE([Measures].[Internal Simulated Calendar Days]),NULL)",'#,##0.00'),
  'Average Inventory Qty':('SimulationDaily',"IIF("+guard+",SUM("+dayset+",[Measures].[On Hand Qty EOD]+[Measures].[WIP Qty EOD])/VALIDMEASURE([Measures].[Internal Simulated Calendar Days]),NULL)",'#,##0.00'),
  'Delivered Qty':('SimulationDaily','[Measures].[Daily On Time Delivered Qty]+[Measures].[Daily Late Delivered Qty]','#,##0.00'),
  'Lost Order Rate':('OrderService','IIF([Measures].[Due Order Count]>0,[Measures].[Lost Order Count]/[Measures].[Due Order Count],NULL)','0.00%')
 }
 for name,(group,expression,fmt) in extras.items():
  if not any('CURRENTCUBE.[Measures].['+name+'] AS' in statement for statement in kept):
   kept.append(f"CREATE MEMBER CURRENTCUBE.[Measures].[{name}] AS {expression}, FORMAT_STRING='{fmt}', VISIBLE=1, DISPLAY_FOLDER='{group}', ASSOCIATED_MEASURE_GROUP='{group}';")
 commands=scripts.find('{*}Commands');commands.clear();add(add(commands,'Command'),'Text','\n'.join(kept))
 from sim_kpi_contract import apply_contract
 apply_contract(db,cube)
 text=scripts.findtext('./{*}Commands/{*}Command/{*}Text','');calculated=set(re.findall(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^]]+)\]',text))
 props=scripts.find('{*}CalculationProperties')
 if props is not None:
  for x in list(props):
   if x.findtext('{*}CalculationReference','').strip('[]') in removed_calcs:props.remove(x)
 refs=set(re.findall(r'\[Measures\]\.\[([^]]+)\]',text))
 removed_measures=[]
 for g in groups:
  ms=g.find('{*}Measures')
  for m in list(ms):
   mid=m.findtext('{*}ID')
   if g.findtext('{*}ID')=='RunSummary' and m.findtext('{*}Visible','true')=='false' and mid not in refs:
    removed_measures.append(mid);ms.remove(m)
 physical={m.findtext('{*}ID') for g in groups for m in g.findall('./{*}Measures/{*}Measure')}
 if refs-physical-calculated:raise ValueError('Dangling measure references: '+str(refs-physical-calculated))
 # Remove unused source tables, relationships and key references from the DSV.
 used={n.text for d in [cube,*list(dims)] for n in d.findall('.//{*}TableID')}
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 ds=dsv.find('./{*}Schema/{'+XS+'}schema/{'+XS+'}element')
 choice=ds.find('./{'+XS+'}complexType/{'+XS+'}choice')
 removed_tables=[]
 for t in list(choice):
  if t.get('name') not in used:removed_tables.append(t.get('name'));choice.remove(t)
 for c in list(ds):
  if c.tag in ('{'+XS+'}unique','{'+XS+'}key','{'+XS+'}keyref'):
   s=c.find('{'+XS+'}selector')
   if s is None or s.get('xpath','').split('/')[-1] not in used:ds.remove(c)
 keys={c.get('name') for c in ds if c.tag in ('{'+XS+'}unique','{'+XS+'}key')}
 for c in list(ds):
  if c.tag=='{'+XS+'}keyref' and c.get('refer','').split(':')[-1] not in keys:ds.remove(c)
 for parent in dsv.iter():
  for c in list(parent):
   if c.tag=='{'+MSDATA+'}Relationship' and (c.get('{'+MSDATA+'}parent') not in used or c.get('{'+MSDATA+'}child') not in used):parent.remove(c)
 # Keep only bound columns plus declared relationship/primary-key columns in the designer.
 columns={t:set() for t in used}
 for obj in [cube,*list(dims)]:
  for binding in obj.iter():
   tid=binding.findtext('{*}TableID');col=binding.findtext('{*}ColumnID')
   if tid and col:columns.setdefault(tid,set()).add(col)
 for constraint in ds:
  if constraint.tag in ('{'+XS+'}unique','{'+XS+'}key','{'+XS+'}keyref'):
   selector=constraint.find('{'+XS+'}selector')
   if selector is not None:
    tid=selector.get('xpath','').split('/')[-1].split(':')[-1]
    columns.setdefault(tid,set()).update(f.get('xpath','').split('/')[-1].split(':')[-1] for f in constraint.findall('{'+XS+'}field'))
 for relation in dsv.findall('.//{'+MSDATA+'}Relationship'):
  for side in ('parent','child'):
   tid=relation.get('{'+MSDATA+'}'+side)
   cols=relation.get('{'+MSDATA+'}'+side+'key','').split()
   columns.setdefault(tid,set()).update(cols)
 removed_columns={}
 for t in choice:
  seq=t.find('./{'+XS+'}complexType/{'+XS+'}sequence')
  if seq is None:continue
  for col in list(seq):
   if col.get('name') not in columns.get(t.get('name'),set()):
    removed_columns.setdefault(t.get('name'),[]).append(col.get('name'));seq.remove(col)
 for tag in ('Perspectives',):
  n=cube.find('{*}'+tag)
  if n is not None:cube.remove(n)
 return calculated,dict(removed_groups=removed_groups,removed_calculations=removed_calcs,removed_physical_measures=removed_measures,removed_attributes={k:v for k,v in removed_attrs.items() if v},removed_tables=removed_tables,removed_columns=removed_columns,remaining_measure_groups=len(groups),remaining_dimensions=len(dims))

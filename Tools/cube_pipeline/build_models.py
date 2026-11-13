"""Build native ACT business MOLAP and SIM scenario cubes using existing providers."""
from copy import deepcopy
from pathlib import Path
import re,json,uuid,xml.etree.ElementTree as ET
from settings import *
from act_quantities import simplify_act_quantities
from act_metric_pruning import prune_unused_act_metrics
from act_analysis import simplify_act_analysis,apply_act_diagram
from detail_cube import E,XS,XSI,MSDATA,MSPROP,add,one,set_text,named,data_item,add_dsv_table,cube_dimension

SOURCE=DEMO/'Warehouse/Split/Reference/Unified.source.xmla'
TEMPLATE=DEMO/'Warehouse/Split/Reference'
ACT_GROUPS={'ActualSales','ActualPurchases','ActualInventory','ActualWorkOrders','ActualOperations'}
NS={'e':E,'xs':XS}

def sqlq(name):return '['+name.replace(']',']]')+']'



def prune(base,role):
 db=deepcopy(base);set_text(db,'ID',CUBES[role]);set_text(db,'Name',CUBES[role])
 set_text(db,'Description',('Actual operational warehouse analytics and versioned DSS input export.' if role=='ACT' else 'Simulation results only; scenario comparisons and detailed rolling-horizon plan analysis.'))
 ann=one(db,'Annotations');ann.clear()
 for name,value in (('CompanyXSplitOwner',OWNER),('CompanyXSplitRole',role)):
  a=add(ann,'Annotation');add(a,'Name',name);add(a,'Value',value)
 for ds in db.findall('./{*}DataSources/{*}DataSource'):
  set_text(ds,'Name','CompanyX '+role+' Warehouse')
  set_text(ds,'ConnectionString','Provider=MSOLEDBSQL;Data Source=localhost;Initial Catalog='+DATABASES[role]+';Integrated Security=SSPI;Persist Security Info=False;')
 cube=db.find('./{*}Cubes/{*}Cube');set_text(cube,'ID',CUBES[role]);set_text(cube,'Name','CompanyX '+role)
 groups=cube.find('{*}MeasureGroups')
 for g in list(groups):
  if (g.findtext('{*}ID') in ACT_GROUPS)!=(role=='ACT'):groups.remove(g)
 gids={g.findtext('{*}ID') for g in groups}
 if role=='ACT':simplify_act_analysis(db,cube)
 roles={x.findtext('{*}CubeDimensionID') for g in groups for x in g.findall('./{*}Dimensions/{*}Dimension')}
 dims=cube.find('{*}Dimensions')
 for dim in list(dims):
  if dim.findtext('{*}ID') not in roles:dims.remove(dim)
 dids={d.findtext('{*}DimensionID') for d in dims}
 dimensions=db.find('{*}Dimensions')
 for d in list(dimensions):
  if d.findtext('{*}ID') not in dids:dimensions.remove(d)
 # Keep only calculations associated with surviving measure groups; validate references.
 script=cube.find('./{*}MdxScripts/{*}MdxScript')
 texts=[]
 for command in script.findall('./{*}Commands/{*}Command'):
  text=re.sub(r'//[^\r\n]*','',command.findtext('{*}Text') or '')
  text=re.sub(r'/\*.*?\*/','',text,flags=re.S)
  for statement in text.split(';'):
   statement=statement.strip()
   if not statement:continue
   if statement=='CALCULATE':texts.append(statement+';');continue
   if statement.startswith('ALTER CUBE CURRENTCUBE UPDATE DIMENSION Measures, DEFAULT_MEMBER='):continue
   match=re.search(r"ASSOCIATED_MEASURE_GROUP\s*=\s*'([^']+)'",statement,re.I)
   if not match:raise ValueError('Unclassified MDX statement: '+statement[:120])
   if match[1] in gids:texts.append(statement+';')
 commands=script.find('{*}Commands');commands.clear();add(add(commands,'Command'),'Text','\n'.join(texts))
 if role=='ACT':
  prune_unused_act_metrics(cube)
  simplify_act_quantities(cube)
  # The historical template has Min/Max guards; simplifying removes the last
  # helpers in Purchases. Drop the now-empty group as well.
  prune_unused_act_metrics(cube)
  texts=[c.findtext('{*}Text','') for c in script.findall('./{*}Commands/{*}Command')]
 calculated=set(re.findall(r'CREATE MEMBER CURRENTCUBE\.\[Measures\]\.\[([^\]]+)\]', '\n'.join(texts),re.I))
 physical={m.findtext('{*}ID') for g in groups for m in g.findall('./{*}Measures/{*}Measure')}
 refs=set(re.findall(r'\[Measures\]\.\[([^\]]+)\]', '\n'.join(texts)))
 if refs-physical-calculated:raise ValueError('Dangling MDX measures: '+str(refs-physical-calculated))
 props=script.find('{*}CalculationProperties')
 if props is not None:
  for item in list(props):
   ref=item.findtext('{*}CalculationReference','').strip('[]')
   if ref not in calculated:props.remove(item)
 # Remove inherited perspectives/actions/KPIs and reconstruct explicit role views.
 for tag in ('Perspectives','Actions','Kpis','Translations'):
  element=cube.find('{*}'+tag)
  if element is not None:cube.remove(element)
 set_text(cube,'DefaultMeasure','[Measures].['+('Actual Sales Line Count' if role=='ACT' else 'Published Simulation Run Count')+']')
 # DSV schema must contain only actual dependencies of this cube and dimensions.
 used={n.text for d in [cube,*list(dimensions)] for n in d.findall('.//{*}TableID')}
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 dataset=dsv.find('./{*}Schema/{'+XS+'}schema/{'+XS+'}element')
 choice=dataset.find('./{'+XS+'}complexType/{'+XS+'}choice')
 for table in list(choice):
  if table.get('name') not in used:choice.remove(table);continue
  tid=table.get('name')
  if role=='ACT' and tid in ('DimDate','DimProduct','DimLocation','DimUnit'):
   table.set('{'+MSPROP+'}DbSchemaName','cxolap')
  if role=='SIM' and tid=='DimRun':table.set('{'+MSPROP+'}DbSchemaName','cxsim')
 for constraint in list(dataset):
  if constraint.tag in ('{'+XS+'}unique','{'+XS+'}keyref','{'+XS+'}key'):
   selector=constraint.find('{'+XS+'}selector')
   if selector is None or selector.get('xpath','').split('/')[-1] not in used:dataset.remove(constraint)
 # Remove constraints whose referenced parent was pruned.
 names={c.get('name') for c in dataset if c.tag in ('{'+XS+'}unique','{'+XS+'}key')}
 for c in list(dataset):
  if c.tag=='{'+XS+'}keyref' and c.get('refer','').split(':')[-1] not in names:dataset.remove(c)
 for parent in dsv.iter():
  for relation in list(parent):
   if relation.tag=='{'+MSDATA+'}Relationship' and (relation.get('{'+MSDATA+'}parent') not in used or relation.get('{'+MSDATA+'}child') not in used):parent.remove(relation)
 return db,cube,calculated


def perspective(cube,name,gids,calculated):
 p=add(one(cube,'Perspectives'),'Perspective');add(p,'ID',name);add(p,'Name',name)
 groups=[g for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup') if g.findtext('{*}ID') in gids]
 roles={d.findtext('{*}CubeDimensionID') for g in groups for d in g.findall('./{*}Dimensions/{*}Dimension')}
 dims=add(p,'Dimensions')
 for d in cube.findall('./{*}Dimensions/{*}Dimension'):
  if d.findtext('{*}ID') in roles:
   pd=add(dims,'Dimension');add(pd,'CubeDimensionID',d.findtext('{*}ID'))
   attrs=add(pd,'Attributes')
   for a in d.findall('./{*}Attributes/{*}Attribute'):add(add(attrs,'Attribute'),'AttributeID',a.findtext('{*}AttributeID'))
   hier=add(pd,'Hierarchies')
   for h in d.findall('./{*}Hierarchies/{*}Hierarchy'):add(add(hier,'Hierarchy'),'HierarchyID',h.findtext('{*}HierarchyID'))
 gs=add(p,'MeasureGroups')
 for g in groups:
  pg=add(gs,'MeasureGroup');add(pg,'MeasureGroupID',g.findtext('{*}ID'));ms=add(pg,'Measures')
  for m in g.findall('./{*}Measures/{*}Measure'):add(add(ms,'Measure'),'MeasureID',m.findtext('{*}ID'))
 calculations=add(p,'Calculations')
 for s in cube.findtext('./{*}MdxScripts/{*}MdxScript/{*}Commands/{*}Command/{*}Text','').split(';'):
  mg=re.search(r"ASSOCIATED_MEASURE_GROUP='([^']+)'",s);cm=re.search(r'CREATE MEMBER CURRENTCUBE\.(\[Measures\]\.\[[^\]]+\])',s)
  if mg and cm and mg[1] in gids:add(add(calculations,'Calculation'),'Name',cm[1])
 default=next((m for g in groups for m in g.findall('./{*}Measures/{*}Measure') if m.findtext('{*}Visible','true')!='false'),None)
 if default is not None:add(p,'DefaultMeasure','[Measures].['+default.findtext('{*}ID')+']')

def export_native(db,role):
 target=DEMO/'MOLAP'/('CompanyX.'+role+'.Analysis');target.mkdir(parents=True,exist_ok=True)
 name='CompanyX.'+role+'.Analysis';project=ET.parse(TEMPLATE/'Template.dwproj').getroot()
 for tag in ('Dimensions','Cubes','DataSources','DataSourceViews','Miscellaneous','Roles'):project.find(tag).clear()
 def item(tag,filename):
  i=ET.SubElement(project.find(tag),'ProjectItem');ET.SubElement(i,'Name').text=filename;ET.SubElement(i,'FullPath').text=filename;return i
 info=deepcopy(db)
 for child in list(info):
  if child.tag.split('}')[-1] in ('Dimensions','Cubes','DataSources','DataSourceViews','Roles','DatabasePermissions'):info.remove(child)
 ET.ElementTree(info).write(target/(name+'.database'),encoding='utf-8',xml_declaration=True)
 for node in project.find('Database'):node.text=name+'.database'
 origins=read(DEMO/'Warehouse/Split/Reference/classification.json')['prefix_maps']['database_dimension_ids']
 for dim in db.findall('./{*}Dimensions/{*}Dimension'):
  did=dim.findtext('{*}ID');prefix=origins.get(did,'ACT')
  filename=(prefix+'_' if prefix and not did.startswith('ACT ') else '')+did+'.dim'
  filename=filename.replace('ACT Input_','ACT_Input_');item('Dimensions',filename)
  ET.ElementTree(dim).write(target/filename,encoding='utf-8',xml_declaration=True)
 for tag,ext in (('DataSources','.ds'),('DataSourceViews','.dsv')):
  for obj in db.find('{*}'+tag):
   filename=obj.findtext('{*}ID')+ext;item(tag,filename);ET.ElementTree(obj).write(target/filename,encoding='utf-8',xml_declaration=True)
 cube=deepcopy(db.find('./{*}Cubes/{*}Cube'));cid=cube.findtext('{*}ID')
 part=ET.Element('{'+E+'}Cube');add(part,'ID',cid);groups=add(part,'MeasureGroups')
 for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup'):
  pg=add(groups,'MeasureGroup');add(pg,'ID',g.findtext('{*}ID'));partitions=g.find('{*}Partitions')
  if partitions is not None:pg.append(deepcopy(partitions));g.remove(partitions)
 ci=item('Cubes',cid+'.cube');deps=ET.SubElement(ci,'Dependencies');dep=ET.SubElement(deps,'ProjectItem')
 ET.SubElement(dep,'Name').text=cid+'.partitions';ET.SubElement(dep,'FullPath').text=cid+'.partitions'
 ET.ElementTree(cube).write(target/(cid+'.cube'),encoding='utf-8',xml_declaration=True)
 ET.ElementTree(part).write(target/(cid+'.partitions'),encoding='utf-8',xml_declaration=True)
 for opts in project.findall('./Configurations/Configuration/Options'):
  opts.find('OutputPath').text=str(OUTPUT/'native-build'/role)
  for key,value in [('DeploymentServerName',SSAS_SERVER),('DeploymentDatabaseName',CUBES[role])]:
   e=opts.find(key)
   if e is None:e=ET.SubElement(opts,key)
   e.text=value
 ET.ElementTree(project).write(target/((CUBES[role] if role=='ACT' else name)+'.dwproj'),encoding='utf-8',xml_declaration=True)
 return target/((CUBES[role] if role=='ACT' else name)+'.dwproj')

def add_sim_lineage(db,cube):
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 row=dsv.find('.//{'+XS+'}choice/{'+XS+'}element[@name="DimRun"]')
 seq=row.find('./{'+XS+'}complexType/{'+XS+'}sequence')
 dim=next(d for d in db.findall('./{*}Dimensions/{*}Dimension') if d.findtext('{*}ID')=='Run')
 key=next(a for a in dim.findall('./{*}Attributes/{*}Attribute') if a.findtext('{*}Usage')=='Key')
 role=next(d for d in cube.findall('./{*}Dimensions/{*}Dimension') if d.findtext('{*}ID')=='Run')
 for column,attribute,size in [('InputOrigin','Input Origin',40),('ACTSnapshotID','ACT Input Snapshot',64)]:
  el=ET.SubElement(seq,'{'+XS+'}element',{'name':column})
  st=ET.SubElement(el,'{'+XS+'}simpleType');rest=ET.SubElement(st,'{'+XS+'}restriction',{'base':'xs:string'});ET.SubElement(rest,'{'+XS+'}maxLength',{'value':str(size)})
  meta={'DimRun':{column:dict(sql_type='nvarchar',max_length=size*2,nullable=False)}}
  a=add(dim.find('{*}Attributes'),'Attribute');add(a,'ID',attribute);add(a,'Name',attribute)
  data_item(add(a,'KeyColumns'),'DimRun',column,meta,'KeyColumn');data_item(a,'DimRun',column,meta,'NameColumn')
  add(add(one(key,'AttributeRelationships'),'AttributeRelationship'),'AttributeID',attribute)
  add(add(role.find('{*}Attributes'),'Attribute'),'AttributeID',attribute)


def build(roles=('ACT','SIM')):
 # Version 2 uses natural business grains, not Input_* row-token subjects.
 base=ET.parse(SOURCE).find('./{*}ObjectDefinition/{*}Database');report=read(OUTPUT/'cube-models.json') if (OUTPUT/'cube-models.json').exists() else {}
 for role in roles:
  db,cube,calculated=prune(base,role)
  if role=='ACT':
   from act_business import build_business_model
   db,cube,calculated,contract=build_business_model()
   with sql('ACT',autocommit=False) as cn,lease(cn):
    try:
     for query in contract['views']:cn.execute(query)
     cn.commit()
    except BaseException:cn.rollback();raise
   save(CONTRACT,contract)
  else:
   add_sim_lineage(db,cube)
   from sim_business import simplify_sim
   calculated,cleanup=simplify_sim(db,cube)
   gids={g.findtext('{*}ID') for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup')}
   overview={'SimulationDaily','OrderLineService','OrderService','RunDay','RunSummary','OrderDaily','OrderLineDaily'}
   perspective(cube,'SIM Scenario Comparison',gids & overview,calculated)
   perspective(cube,'SIM Order and Production',gids,calculated)
  command=ET.Element('{'+E+'}Create',{'AllowOverwrite':'false'});add(command,'ObjectDefinition').append(db)
  target=DEMO/'MOLAP'/('CompanyX.'+role+'.create.xmla');target.parent.mkdir(parents=True,exist_ok=True)
  ET.ElementTree(command).write(target,encoding='utf-8',xml_declaration=True)
  project=export_native(db,role)
  report[role]={'database':CUBES[role],'warehouse':DATABASES[role],'cube':'CompanyX '+role,'xmla':str(target),'sha256':sha(target),'project':str(project),'dimensions':len(db.find('{*}Dimensions')),'cube_roles':len(cube.find('{*}Dimensions')),'measure_groups':len(cube.find('{*}MeasureGroups')),'calculated_measures':len(calculated)}
 save(OUTPUT/'cube-models.json',report);print(json.dumps(report,ensure_ascii=False,indent=2))

if __name__=='__main__':build()

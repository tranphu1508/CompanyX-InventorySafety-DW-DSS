"""Prototype only: natural-grain ACT model, no Input_* objects."""
from pathlib import Path
from copy import deepcopy
import sys,json,re,xml.etree.ElementTree as ET
from settings import *
T=TMP/"model";T.mkdir(parents=True,exist_ok=True)
from build_models import prune,SOURCE,perspective
from detail_cube import *
from act_attributes import extend

def meta(cn,q):
 rows=cn.execute('SELECT name,system_type_name,is_nullable,max_length FROM sys.dm_exec_describe_first_result_set(?,NULL,0) WHERE is_hidden=0',q).fetchall()
 if not rows or any(r[0] is None for r in rows):raise ValueError('Bad SQL metadata')
 return {r[0]:dict(sql_type=r[1].split('(')[0],declaration=r[1],max_length=r[3],nullable=bool(r[2])) for r in rows}

SPECS={
 'sales':dict(table='OpsFactSales',view='SalesLineDetail',dimension='Sales Line',key='SalesOrderLineKey',group='ActualSales',measure='Actual Sales Line Count',query='''SELECT s.*,f.IsDemandEligible,f.OrderAt,f.DueAt,f.DQReasonCode,p.ProductID,p.MakeFlag,ss.StatusCode,ss.StatusName
 FROM cxoperations.FactSales s JOIN dw.Fact_SalesOrderLine f ON f.SalesOrderLineKey=s.SalesOrderLineKey
 JOIN dw.Dim_Product p ON p.ProductKey=f.ProductKey LEFT JOIN dw.Dim_SalesStatus ss ON ss.SalesStatusKey=f.SalesStatusKey''',fields=['SalesOrderLineKey','SalesOrderDetailID','SalesOrderID','ProductKey','ProductID','OrderQty','OrderDateKey','DueDateKey','IsDemandEligible','MakeFlag','DQReasonCode','StatusCode','StatusName','OrderAt','DueAt']),
 'products':dict(table='DimProduct',view='ProductPlanning',dimension='Product',key='ProductKey',query='SELECT p.* FROM dw.Dim_Product p',fields=['ProductKey','ProductID','ProductName','ProductNumber','MakeFlag','FinishedGoodsFlag','SafetyStockLevel','ReorderPoint','DaysToManufacture','StandardCost','SellStartDate','SellEndDate','DiscontinuedDate']),
 'bom':dict(table='ACT_BillOfMaterials',view='BillOfMaterials',dimension='BOM Line',key='BOMKey',group='ActualBOM',measure='Actual BOM Relationship Count',query='''SELECT b.*,a.ProductID ProductAssemblyID,c.ProductID ComponentID,RTRIM(u.UnitMeasureCode) UnitMeasureCode,CONVERT(int,1) RelationshipCount
 FROM dw.Bridge_BillOfMaterials b JOIN dw.Dim_Product a ON a.ProductKey=b.AssemblyProductKey
 JOIN dw.Dim_Product c ON c.ProductKey=b.ComponentProductKey JOIN dw.Dim_UnitMeasure u ON u.UnitMeasureKey=b.UnitMeasureKey''',fields=['BOMKey','BillOfMaterialsID','AssemblyProductKey','ComponentProductKey','ProductAssemblyID','ComponentID','PerAssemblyQty','UnitMeasureCode','StartDate','EndDate','IsStructureValid']),
 'vendors':dict(table='ACT_VendorTerms',view='VendorTerms',dimension='Vendor Terms',key='VendorTermsKey',group='ActualVendorTerms',measure='Actual Vendor Terms Count',query='''SELECT CONVERT(nvarchar(70),CONCAT(r.ProductID,':',r.BusinessEntityID)) VendorTermsKey,r.ProductID,r.BusinessEntityID VendorID,p.ProductKey,v.VendorKey,r.AverageLeadTime,r.StandardPrice,r.MinOrderQty,r.MaxOrderQty,RTRIM(r.UnitMeasureCode) PurchaseUnit,r.ModifiedDate,CONVERT(int,1) TermsCount
 FROM etl_raw.ProductVendor r JOIN dw.Dim_Product p ON p.ProductID=r.ProductID AND p.ProductKey>0
 JOIN dw.Dim_Vendor v ON v.VendorID=r.BusinessEntityID AND v.VendorKey>0''',fields=['VendorTermsKey','ProductID','VendorID','ProductKey','VendorKey','AverageLeadTime','StandardPrice','MinOrderQty','MaxOrderQty','PurchaseUnit','ModifiedDate']),
 'costs':dict(table='ACT_ProductCostHistory',view='ProductCostHistory',dimension='Cost Period',key='CostPeriodKey',group='ActualProductCostHistory',measure='Actual Cost Period Count',query='''SELECT CONVERT(nvarchar(70),CONCAT(r.ProductID,':',CONVERT(nvarchar(33),r.StartDate,126))) CostPeriodKey,r.ProductID,p.ProductKey,r.StartDate,r.EndDate,r.StandardCost,r.ModifiedDate,CONVERT(int,1) PeriodCount
 FROM etl_raw.ProductCostHistory r JOIN dw.Dim_Product p ON p.ProductID=r.ProductID AND p.ProductKey>0''',fields=['CostPeriodKey','ProductID','ProductKey','StartDate','EndDate','StandardCost','ModifiedDate'])}


# Procurement is not an analysis subject in this model. The nine additional
# resale products have one reviewed replenishment source each. Carry only the
# parameters consumed by the unchanged DSS as Product properties, not as a
# separate vendor-terms fact/dimension. Never choose TOP 1 when a source becomes
# ambiguous: duplicate ProductKey is rejected by preflight / dimension process.
RESALE_IDS=(709,710,841,843,844,850,853,857,863)
VENDOR_PRODUCT_FIELDS={
 'VendorID':'ReplenishmentVendorID',
 'AverageLeadTime':'ReplenishmentBaseLeadDays',
 'StandardPrice':'ReplenishmentStandardPrice',
 'MinOrderQty':'ReplenishmentMinOrderQty',
 'MaxOrderQty':'ReplenishmentMaxOrderQty',
 'PurchaseUnit':'ReplenishmentUnit',
 'ModifiedDate':'ReplenishmentTermsModifiedAt'}
_VENDOR_SOURCE=SPECS.pop('vendors')
_product=SPECS['products']
_product['query']='SELECT pp.*, '+', '.join([
 'v.BusinessEntityID ReplenishmentVendorID',
 'v.AverageLeadTime ReplenishmentBaseLeadDays',
 'v.StandardPrice ReplenishmentStandardPrice',
 'v.MinOrderQty ReplenishmentMinOrderQty',
 'v.MaxOrderQty ReplenishmentMaxOrderQty',
 'RTRIM(v.UnitMeasureCode) ReplenishmentUnit',
 'v.ModifiedDate ReplenishmentTermsModifiedAt'])+' FROM ('+_product['query']+') pp LEFT JOIN etl_raw.ProductVendor v ON v.ProductID=pp.ProductID AND pp.ProductID IN ('+','.join(map(str,RESALE_IDS))+')'
_product['fields']+=list(VENDOR_PRODUCT_FIELDS.values())
_product['replenishment_scope']=list(RESALE_IDS)
_product['replenishment_export_mapping']=VENDOR_PRODUCT_FIELDS
_product['replenishment_note']='DSS input properties only, not a purchasing analysis subject. Multiple suppliers for these fixed-scope items must fail validation; no arbitrary supplier selection.'

def add_property(dim,tid,key,col,metadata):
 attrs=dim.find('{*}Attributes');keyattr=next(a for a in attrs if a.findtext('{*}Usage')=='Key')
 properties=[(col,col+'Text')]
 if metadata[tid][col]['nullable']:properties.append((col+' Is Null',col+'IsNull'))
 for prop,source in properties:
  a=add(attrs,'Attribute');add(a,'ID',prop);add(a,'Name',prop)
  data_item(add(a,'KeyColumns'),tid,key,metadata,'KeyColumn');data_item(a,tid,source,metadata,'NameColumn')
  add(a,'AttributeHierarchyVisible','false')
  add(add(one(keyattr,'AttributeRelationships'),'AttributeRelationship'),'AttributeID',prop)

def usage(group,role,attr,tid,col,metadata,kind='RegularMeasureGroupDimension'):
 u=add(one(group,'Dimensions'),'Dimension',**{'{'+XSI+'}type':kind});add(u,'CubeDimensionID',role)
 a=add(add(u,'Attributes'),'Attribute');add(a,'AttributeID',attr);data_item(add(a,'KeyColumns'),tid,col,metadata,'KeyColumn');add(a,'Type','Granularity')

def new_group(cube,gid,measure,tid,count_col,metadata,query):
 g=add(cube.find('{*}MeasureGroups'),'MeasureGroup');add(g,'ID',gid);add(g,'Name',gid)
 m=add(add(g,'Measures'),'Measure');add(m,'ID',measure);add(m,'Name',measure);data_item(m,tid,count_col,metadata);add(m,'DisplayFolder','Operations\\Planning master data')
 add(g,'StorageMode','Molap');add(g,'IgnoreUnrelatedDimensions','false');add(g,'Dimensions')
 p=add(add(g,'Partitions'),'Partition');add(p,'ID',gid);add(p,'Name',gid);src=add(p,'Source',**{'{'+XSI+'}type':'QueryBinding'});add(src,'DataSourceID','CompanyXSource');add(src,'QueryDefinition',query);add(p,'StorageMode','Molap');return g

def replace_dsv_table(dsv,tid,columns,key,view):
 dataset=dsv.find('./{*}Schema/{'+XS+'}schema/{'+XS+'}element');choice=dataset.find('./{'+XS+'}complexType/{'+XS+'}choice')
 for x in list(choice):
  if x.get('name')==tid:choice.remove(x)
 for x in list(dataset):
  sel=x.find('{'+XS+'}selector')
  if sel is not None and sel.get('xpath','').split('/')[-1]==tid:dataset.remove(x)
 add_dsv_table(dsv,tid,columns,key)
 node=next(t for t in choice if t.get('name')==tid);node.set('{'+MSPROP+'}DbSchemaName','cxoperations');node.set('{'+MSPROP+'}DbTableName',view)

def build_business_model():
 base=ET.parse(SOURCE).find('./{*}ObjectDefinition/{*}Database');db,cube,calculated=prune(base,'ACT');dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 queries=[];specs=deepcopy(SPECS)
 with sql('ACT') as cn:
  for name,s in specs.items():
   tid=s['table'];original=meta(cn,s['query']);s['types']={k:original[k] for k in s['fields']}
   extra=[]
   for col in s['fields']:
    # Nullable result columns need explicit presence; NOT NULL columns do not.
    extra.append(f'CONVERT(nvarchar(1000),q.[{col}],126) [{col}Text]')
    if original[col]['nullable']:
     extra.append(f'CONVERT(nvarchar(1),CASE WHEN q.[{col}] IS NULL THEN 1 ELSE 0 END) [{col}IsNull]')
   extra.append(f'CONVERT(nvarchar(160),q.[{s["key"]}]) DetailCaption')
   q='SELECT q.*, '+','.join(extra)+' FROM ('+s['query']+') q';s['view_query']=q
   columns=meta(cn,q);metadata={tid:columns};replace_dsv_table(dsv,tid,columns,s['key'],s['view'])
   queries.append('CREATE OR ALTER VIEW cxoperations.['+s['view']+'] AS '+q)
   if name=='products':dim=next(d for d in db.find('{*}Dimensions') if d.findtext('{*}ID')=='Product')
   else:
    dim=create_dimension(dict(id=s['dimension'],table=tid,key=s['key'],name='DetailCaption'),metadata);db.find('{*}Dimensions').append(dim)
   for col in s['fields']:add_property(dim,tid,s['key'],col,metadata)
   for role in list(cube.find('{*}Dimensions')):
    if role.findtext('{*}DimensionID')==s['dimension']:cube.find('{*}Dimensions').remove(role)
   cube.find('{*}Dimensions').append(cube_dimension(s['dimension'],dim))
   if name=='products':continue
   qpart='SELECT * FROM cxoperations.['+s['view']+']'
   if name=='sales':
    g=next(g for g in cube.find('{*}MeasureGroups') if g.findtext('{*}ID')==s['group']);g.find('./{*}Partitions/{*}Partition/{*}Source/{*}QueryDefinition').text=qpart
   else:g=new_group(cube,s['group'],s['measure'],tid,{'bom':'RelationshipCount','vendors':'TermsCount','costs':'PeriodCount'}[name],metadata,qpart)
   usage(g,s['dimension'],s['dimension'],tid,s['key'],metadata,'DegenerateMeasureGroupDimension')
   if name in ('vendors','costs'):usage(g,'Product','Product',tid,'ProductKey',metadata)
   if name=='vendors':usage(g,'Vendor','Vendor',tid,'VendorKey',metadata)
   if name=='bom':
    pd=next(d for d in db.find('{*}Dimensions') if d.findtext('{*}ID')=='Product')
    for role,col in [('Assembly Product','AssemblyProductKey'),('Component Product','ComponentProductKey')]:cube.find('{*}Dimensions').append(cube_dimension(role,pd));usage(g,role,'Product',tid,col,metadata)
  # Actual observed demand at Product x Date x RuleVersion, with native business measures.
  dq='SELECT DateKey,ProductKey,DemandRuleVersion,IndependentQty,DependentQty,TotalDemandQty,EligibleSalesLineCount,ExcludedSalesLineCount,ParentWorkOrderCount,IsInSellWindow,LoadBatchID,LoadedAt,CONVERT(int,1) ProductDayCount FROM dss.Fact_DemandDaily';dm=meta(cn,dq);tid='ACT_DemandDaily';replace_dsv_table(dsv,tid,dm,None,'DemandDaily');queries.append('CREATE OR ALTER VIEW cxoperations.DemandDaily AS '+dq)
  rq='SELECT DISTINCT DemandRuleVersion FROM dss.Fact_DemandDaily';rm=meta(cn,rq);replace_dsv_table(dsv,'ACT_DemandRule',rm,'DemandRuleVersion','DemandRule');queries.append('CREATE OR ALTER VIEW cxoperations.DemandRule AS '+rq)
  dr=create_dimension(dict(id='Demand Rule',table='ACT_DemandRule',key='DemandRuleVersion',name='DemandRuleVersion'),{'ACT_DemandRule':rm});db.find('{*}Dimensions').append(dr);cube.find('{*}Dimensions').append(cube_dimension('Demand Rule',dr))
  date=next(d for d in db.find('{*}Dimensions') if d.findtext('{*}ID')=='Date');cube.find('{*}Dimensions').append(cube_dimension('Demand Date',date))
  g=new_group(cube,'ActualDemandDaily','Actual Demand Product Day Count',tid,'ProductDayCount',{tid:dm},'SELECT * FROM cxoperations.DemandDaily')
  for role,attr,col in [('Product','Product','ProductKey'),('Demand Date','Date','DateKey'),('Demand Rule','Demand Rule','DemandRuleVersion')]:usage(g,role,attr,tid,col,{tid:dm})
  for col in ['IndependentQty','DependentQty','TotalDemandQty','EligibleSalesLineCount','ExcludedSalesLineCount','ParentWorkOrderCount']:
   mid='Actual Demand '+col;m=add(g.find('{*}Measures'),'Measure');add(m,'ID',mid);add(m,'Name',mid);data_item(m,tid,col,{tid:dm});add(m,'DisplayFolder','Operations\\Demand Daily')
  # Alternative demand-rule versions must never be added together.
  demand_names = {
   'Actual Demand Product Day Count':'Actual Demand Product Day Count',
   'Actual Demand IndependentQty':'Actual Independent Demand Qty',
   'Actual Demand DependentQty':'Actual Dependent Demand Qty',
   'Actual Demand TotalDemandQty':'Actual Total Demand Qty',
   'Actual Demand EligibleSalesLineCount':'Actual Demand Eligible Sales Line Count',
   'Actual Demand ExcludedSalesLineCount':'Actual Demand Excluded Sales Line Count',
   'Actual Demand ParentWorkOrderCount':'Actual Demand Parent Work Order Count'}
  script=cube.find('./{*}MdxScripts/{*}MdxScript/{*}Commands/{*}Command/{*}Text')
  for m in g.findall('./{*}Measures/{*}Measure'):
   old_id=m.findtext('{*}ID');public=demand_names[old_id];raw='Raw '+public
   m.find('{*}ID').text=raw;m.find('{*}Name').text=raw
   add(m,'Visible','false');m.find('{*}DisplayFolder').text='Operations\\Demand Daily'
   fmt='#,##0.####' if public.endswith('Qty') else '#,##0'
   script.text += "\nCREATE MEMBER CURRENTCUBE.[Measures].["+public+"] AS IIF(COUNT(EXISTING [Demand Rule].[Demand Rule].[Demand Rule].MEMBERS)=1, [Measures].["+raw+"], NULL), FORMAT_STRING='"+fmt+"', VISIBLE=1, DISPLAY_FOLDER='Operations\\Demand Daily', ASSOCIATED_MEASURE_GROUP='ActualDemandDaily';"
   calculated.add(public)
  s=specs['demand']=dict(table=tid,view='DemandDaily',group='ActualDemandDaily',measure='Raw Actual Demand Product Day Count',query=dq,types=dm,fields=list(dm),grain=['DateKey','ProductKey','DemandRuleVersion'],version_aggregation='Public measures require exactly one rule version in the current context; otherwise NULL.',promotion='No separate promotion dimension or measure. Valid promotional sales remain included in IndependentQty.')
 with sql('ACT') as cn:
  extend(db,cube,specs,queries,cn)
 # Distinct business relationships in DSV (no disconnected export shadows).
 schema=dsv.find('./{*}Schema/{'+XS+'}schema');app=schema.find('./{'+XS+'}annotation/{'+XS+'}appinfo')
 if app is None:
  an=ET.SubElement(schema,'{'+XS+'}annotation');app=ET.SubElement(an,'{'+XS+'}appinfo')
 relations=[('ACT_BillOfMaterials','DimProduct','AssemblyProductKey','ProductKey'),('ACT_BillOfMaterials','DimProduct','ComponentProductKey','ProductKey'),('ACT_ProductCostHistory','DimProduct','ProductKey','ProductKey'),('ACT_DemandDaily','DimProduct','ProductKey','ProductKey'),('ACT_DemandDaily','DimDate','DateKey','DateKey'),('ACT_DemandDaily','ACT_DemandRule','DemandRuleVersion','DemandRuleVersion')]
 for child,parent,ck,pk in relations:ET.SubElement(app,'{'+MSDATA+'}Relationship',{'name':child+'_'+ck,'{'+MSDATA+'}parent':parent,'{'+MSDATA+'}child':child,'{'+MSDATA+'}parentkey':pk,'{'+MSDATA+'}childkey':ck})
 perspective(cube,'ACT Operations',{g.findtext('{*}ID') for g in cube.find('{*}MeasureGroups')},calculated)
 for name,s in specs.items():
  s['keys']=[s['key']] if name!='demand' else ['DateKey','ProductKey','DemandRuleVersion']
  s['transport']='dimension' if name in ('products','dates','locations','vendors','units') else 'drillthrough'
  if name=='demand':
   s['fields']=['DateKey','ProductKey','DemandRuleVersion','IndependentQty','DependentQty','TotalDemandQty','EligibleSalesLineCount','ExcludedSalesLineCount','ParentWorkOrderCount','ProductDayCount'];s['types']={k:s['types'][k] for k in s['fields']};s['transport']='demand'
 return db,cube,calculated,{'schema':'companyx.business-input-contract.v2','datasets':specs,'views':queries}

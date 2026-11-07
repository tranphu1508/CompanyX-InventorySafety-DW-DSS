"""Enrich business dimensions; source-detail properties stay hidden."""
import re,xml.etree.ElementTree as ET
from detail_cube import *
AUDIT={'DQStatus','DQReasonCode','DQRuleVersion','LoadBatchID','LoadedAt'}

def relationship(dim,child,parent):
 a=next(a for a in dim.findall('./{*}Attributes/{*}Attribute') if a.findtext('{*}ID')==child)
 if parent not in [r.findtext('{*}AttributeID') for r in a.findall('./{*}AttributeRelationships/{*}AttributeRelationship')]:add(add(one(a,'AttributeRelationships'),'AttributeRelationship'),'AttributeID',parent)

def bind(a,tid,key,label,md,value=None):
 for tag in ('KeyColumns','NameColumn','ValueColumn'):
  e=a.find('{*}'+tag)
  if e is not None:a.remove(e)
 data_item(add(a,'KeyColumns'),tid,key,md,'KeyColumn')
 if label:data_item(a,tid,label,md,'NameColumn')
 if value:data_item(a,tid,value,md,'ValueColumn')

def attribute(dim,aid,tid,key,label,md,folder=None):
 a=add(dim.find('{*}Attributes'),'Attribute');add(a,'ID',aid);add(a,'Name',aid);bind(a,tid,key,label,md)
 if folder:add(a,'AttributeHierarchyDisplayFolder',folder)
 primary=next(x.findtext('{*}ID') for x in dim.findall('./{*}Attributes/{*}Attribute') if x.findtext('{*}Usage')=='Key');relationship(dim,primary,aid)
 return a

def extend(db,cube,specs,queries,cn):
 from act_business import meta,replace_dsv_table,usage,RESALE_IDS,VENDOR_PRODUCT_FIELDS
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView');dims=db.find('{*}Dimensions')
 productmeta=meta(cn,'SELECT * FROM dw.Dim_Product');business=[k for k in productmeta if k not in AUDIT|{'ProductKey','ProductCategoryID','CategoryName','ProductSubcategoryID','SubcategoryName','SupplyType','ProductRole','MakeFlag'}]
 extras=["CONVERT(nvarchar(160),CONCAT(COALESCE(d.ProductNumber,N'?'),N' | ',COALESCE(d.ProductName,N'Unknown'))) ProductCaption",'COALESCE(d.ProductCategoryID,-1) CategoryKey','COALESCE(d.ProductSubcategoryID,-1) SubcategoryKey',"COALESCE(d.CategoryName,N'Unclassified') CategoryCaption","COALESCE(d.SubcategoryName,N'Unclassified') SubcategoryCaption","COALESCE(d.SupplyType,N'UNKNOWN') SupplyCaption","COALESCE(d.ProductRole,N'UNKNOWN') RoleCaption",'CONVERT(int,COALESCE(d.MakeFlag,0)) MakeFlagDisplay']
 for c in business:
  t=productmeta[c]['sql_type']
  if t in ('nvarchar','varchar','nchar','char'):exp="COALESCE(NULLIF(RTRIM(d.["+c+"]),N''),N'N/A')"
  elif t in ('date','datetime','datetime2'):exp="COALESCE(d.["+c+"],CONVERT(date,'19000101'))"
  else:exp='COALESCE(CONVERT('+('int' if t=='bit' else productmeta[c]['declaration'])+',d.['+c+']),-1)'
  extras += [exp+' [B_'+c+']',"CONVERT(nvarchar(160),CASE WHEN d.["+c+"] IS NULL THEN N'N/A' ELSE CONVERT(nvarchar(160),d.["+c+"],126) END) [L_"+c+']']
 extras += ['v.BusinessEntityID ReplenishmentVendorID','v.AverageLeadTime ReplenishmentBaseLeadDays','v.StandardPrice ReplenishmentStandardPrice','v.MinOrderQty ReplenishmentMinOrderQty','v.MaxOrderQty ReplenishmentMaxOrderQty','RTRIM(v.UnitMeasureCode) ReplenishmentUnit','v.ModifiedDate ReplenishmentTermsModifiedAt']
 s=specs['products'];s['query']='SELECT d.*,'+','.join(extras)+' FROM dw.Dim_Product d LEFT JOIN etl_raw.ProductVendor v ON v.ProductID=d.ProductID AND d.ProductID IN ('+','.join(map(str,RESALE_IDS))+')';s['fields']=list(productmeta)+list(VENDOR_PRODUCT_FIELDS.values())
 specs['dates']=dict(table='DimDate',view='DatePlanning',dimension='Date',key='DateKey',query="""SELECT d.*,
 CONVERT(nvarchar(40),CASE WHEN DateKey=-1 THEN N'Not applicable' WHEN DateKey=0 THEN N'Unknown / not completed' ELSE CONVERT(nvarchar(10),CalendarDate,23) END) DateName,
 COALESCE(CalendarYear,0) YearKey,
 COALESCE(CalendarYear*100+CalendarMonth,0) MonthKey,COALESCE(CONVERT(nvarchar(7),CalendarDate,23),N'N/A') MonthName,
 COALESCE(CalendarYear*10+CalendarQuarter,0) QuarterKey,CONVERT(nvarchar(20),CASE WHEN CalendarYear IS NULL THEN N'N/A' ELSE CONCAT(CalendarYear,N'-Q',CalendarQuarter) END) QuarterName
 FROM dw.Dim_Date d""",fields=list(meta(cn,'SELECT * FROM dw.Dim_Date')),property_codec='json-row-v1')
 specs['locations']=dict(table='DimLocation',view='LocationPlanning',dimension='Location',key='LocationKey',query="SELECT d.*,COALESCE(LocationName,N'Unknown') LocationCaption FROM dw.Dim_Location d",fields=list(meta(cn,'SELECT * FROM dw.Dim_Location')))
 specs['vendors']=dict(table='OpsDimVendor',view='VendorPlanning',dimension='Vendor',key='VendorKey',query="SELECT d.*,COALESCE(VendorName,N'Unknown') VendorCaption,COALESCE(CreditRatingName,N'Unknown') RatingCaption,COALESCE(CreditRating,-1) RatingKey,COALESCE(VendorID,-1) BusinessID FROM dw.Dim_Vendor d",fields=list(meta(cn,'SELECT * FROM dw.Dim_Vendor')))
 specs['units']=dict(table='DimUnit',view='UnitPlanning',dimension='Unit',key='UnitMeasureKey',query="SELECT d.*,CONVERT(nvarchar(160),CONCAT(COALESCE(UnitMeasureCode,N'?'),N' | ',COALESCE(UnitMeasureName,N'Unknown'))) UnitCaption FROM dw.Dim_UnitMeasure d",fields=list(meta(cn,'SELECT * FROM dw.Dim_UnitMeasure')))
 for c in ('UnitMeasureKey','BOMLevel','DQReasonCode','DQRuleVersion','LoadBatchID','LoadedAt'):
  if c not in specs['bom']['fields']:specs['bom']['fields'].append(c)
 for name,s in specs.items():
  if name=='demand':continue
  tid=s['table'];base=meta(cn,s['query']);s['types']={k:base[k] for k in s['fields']};extra=[]
  # A single hidden property preserves exact values/NULLs for the cube export.
  s['property_codec']='json-row-v1';s['property_max_chars']=16384;s['null_flags']=[]
  fields=[]
  for c in s['fields']:
   v='q.['+c+']'
   if base[c]['sql_type'] in ('char','nchar'):v='RTRIM('+v+')'
   fields.append('CONVERT(nvarchar(1000),'+v+',126) ['+c+']')
  extra.append('(SELECT '+','.join(fields)+' FOR JSON PATH,INCLUDE_NULL_VALUES,WITHOUT_ARRAY_WRAPPER) SourceRow')
  if name in ('sales','bom','costs'):extra.append('CONVERT(nvarchar(160),q.['+s['key']+']) DetailCaption')
  q='SELECT q.*,'+','.join(extra)+' FROM ('+s['query']+') q';s['view_query']=q;columns=meta(cn,q)
  columns['SourceRow']['max_length']=2*s['property_max_chars']
  md={tid:columns};replace_dsv_table(dsv,tid,columns,s['key'],s['view'])
  queries[:]=[x for x in queries if not re.search(r'VIEW cxoperations\.\[?'+re.escape(s['view'])+r'\]?(?:\s|$)',x)]
  queries.append('CREATE OR ALTER VIEW cxoperations.['+s['view']+'] AS '+q)
  dim=next((d for d in dims if d.findtext('{*}ID')==s['dimension']),None)
  if dim is None:dim=create_dimension(dict(id=s['dimension'],table=tid,key=s['key'],name='UnitCaption'),md);dims.append(dim)
  attrs=dim.find('{*}Attributes');hidden={a.findtext('{*}ID') for a in attrs if a.findtext('{*}AttributeHierarchyVisible')=='false'}
  for a in list(attrs):
   if a.findtext('{*}ID') in hidden:attrs.remove(a)
  for a in attrs:
   rels=a.find('{*}AttributeRelationships')
   if rels is not None:
    for r in list(rels):
     if r.findtext('{*}AttributeID') in hidden:rels.remove(r)
  mapping=[]
  if name=='products':
   mapping=[('Product','ProductKey','ProductCaption'),('Category','CategoryKey','CategoryCaption'),('Subcategory','SubcategoryKey','SubcategoryCaption'),('Supply Type','SupplyCaption','SupplyCaption'),('Product Role','RoleCaption','RoleCaption'),('Manufactured','MakeFlagDisplay',None)]
   for c in business:attribute(dim,c,tid,'B_'+c,'L_'+c,md,'Product details')
  elif name=='dates':
   mapping=[('Date','DateKey','DateName'),('Year','YearKey',None),('Quarter','QuarterKey','QuarterName'),('Month','MonthKey','MonthName')]
  elif name=='locations':mapping=[('Location','LocationKey','LocationCaption')]
  elif name=='vendors':mapping=[('Vendor','VendorKey','VendorCaption'),('Credit Rating','RatingKey','RatingCaption'),('Vendor ID','BusinessID',None)]
  for aid,k,l in mapping:
   a=next(a for a in attrs if a.findtext('{*}ID')==aid);bind(a,tid,k,l,md,'CalendarDate' if name=='dates' and aid=='Date' else None)
  a=attribute(dim,'Source Row',tid,s['key'],'SourceRow',md);add(a,'AttributeHierarchyVisible','false')
  roles=cube.find('{*}Dimensions');matched=[r for r in roles if r.findtext('{*}DimensionID')==s['dimension']]
  for r in matched:
   i=list(roles).index(r);rid=r.findtext('{*}ID');roles.remove(r);roles.insert(i,cube_dimension(rid,dim))
  if not matched:roles.append(cube_dimension(s['dimension'],dim))
  if name=='bom':
   g=next(g for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup') if g.findtext('{*}ID')==s['group']);usage(g,'Unit','Unit',tid,'UnitMeasureKey',md)
 compact_attribute_columns(db,specs,queries,cn)
 # The unit relation supports actual BOM quantity interpretation, not an input table.
 schema=dsv.find('./{*}Schema/{'+XS+'}schema');app=schema.find('./{'+XS+'}annotation/{'+XS+'}appinfo')
 if app is None:app=ET.SubElement(ET.SubElement(schema,'{'+XS+'}annotation'),'{'+XS+'}appinfo')
 ET.SubElement(app,'{'+MSDATA+'}Relationship',{'name':'ACT_BillOfMaterials_Unit','{'+MSDATA+'}parent':'DimUnit','{'+MSDATA+'}child':'ACT_BillOfMaterials','{'+MSDATA+'}parentkey':'UnitMeasureKey','{'+MSDATA+'}childkey':'UnitMeasureKey'})


def compact_attribute_columns(db,specs,queries,cn):
 """Reuse key columns as labels and expose each business value only once.

 Raw source fields stay in the contract query and hidden SourceRow. This only
 changes the presentation view/DSV bindings; all dimension member keys survive.
 """
 from act_business import meta,replace_dsv_table
 dsv=db.find('./{*}DataSourceViews/{*}DataSourceView')
 product=next(d for d in db.findall('./{*}Dimensions/{*}Dimension') if d.findtext('{*}ID')=='Product')
 raw=specs['products']['types'];aliases={}
 for a in product.findall('./{*}Attributes/{*}Attribute'):
  k=a.find('./{*}KeyColumns/{*}KeyColumn/{*}Source/{*}ColumnID')
  if k is None or not k.text.startswith('B_'):continue
  col=k.text[2:];aliases[k.text]=col
  label=a.find('{*}NameColumn')
  if raw[col]['sql_type'] in ('nvarchar','varchar','nchar','char') or not raw[col]['nullable']:
   # Text key already supplies its caption, including the N/A member.
   # Required numeric fields can use their native key caption.
   if label is not None:a.remove(label)
  else:aliases['L_'+col]=col+'Caption'
 aliases.update(CategoryKey='ProductCategoryID',CategoryCaption='CategoryName',SubcategoryKey='ProductSubcategoryID',SubcategoryCaption='SubcategoryName',SupplyCaption='SupplyType',RoleCaption='ProductRole',MakeFlagDisplay='MakeFlag')
 maps={'products':aliases,'dates':{'YearKey':'CalendarYear'},'locations':{'LocationCaption':'LocationName'},'vendors':{'VendorCaption':'VendorName','RatingCaption':'CreditRatingName','RatingKey':'CreditRating','BusinessID':'VendorID'},'sales':{},'bom':{},'costs':{}}
 for name,rename in maps.items():
  s=specs[name];tid=s['table']
  if name in ('sales','bom','costs'):
   dim=next(d for d in db.findall('./{*}Dimensions/{*}Dimension') if d.findtext('{*}ID')==s['dimension'])
   for a in dim.findall('./{*}Attributes/{*}Attribute'):
    label=a.find('{*}NameColumn')
    if label is not None and label.findtext('./{*}Source/{*}ColumnID')=='DetailCaption':a.remove(label)
  bindings=[n for n in db.iter() if n.findtext('{*}TableID')==tid and n.find('{*}ColumnID') is not None]
  used={n.findtext('{*}ColumnID') for n in bindings}
  for src,dst in rename.items():
   if src!=dst and dst in used:raise ValueError('Unsafe alias merge: '+tid+'.'+dst)
  for n in bindings:
   col=n.find('{*}ColumnID');col.text=rename.get(col.text,col.text)
  old=meta(cn,s['view_query'])
  if name=='products':keep=[x for x in old if x in used]
  else:keep=[x for x in old if x not in set(rename.values()) and x!='DetailCaption']
  assert used<=set(keep),(name,used-set(keep))
  projection=','.join('v.['+col+'] AS ['+rename.get(col,col)+']' for col in keep)
  q='SELECT '+projection+' FROM ('+s['view_query']+') v'
  columns=meta(cn,q);columns['SourceRow']['max_length']=2*s['property_max_chars']
  replace_dsv_table(dsv,tid,columns,s['key'],s['view'])
  s['view_query']=q
  prefix='CREATE OR ALTER VIEW cxoperations.['+s['view']+'] AS '
  matches=[i for i,x in enumerate(queries) if x.startswith(prefix)]
  if len(matches)!=1:raise ValueError('Expected one view definition: '+s['view'])
  queries[matches[0]]=prefix+q

"""Business-grain ACT MOLAP -> MDX -> atomic SIM inputs (contract v2).
SQL ACT access is validation only. Every imported value comes from the cube.
Historical input tables and simulation records are preserved.
"""
from pathlib import Path
from decimal import Decimal
from datetime import datetime,timezone
import argparse,hashlib,json,re,uuid,xml.etree.ElementTree as ET
from settings import *
from msolap import connect,query,query_fast
from ssas import process,metadata
TABLES={'products':'BusinessProduct','dates':'BusinessDate','locations':'BusinessLocation','vendors':'BusinessVendor','units':'BusinessUnit','sales':'BusinessSalesLine','bom':'BusinessBOM','costs':'BusinessCostHistory','demand':'BusinessDemandDaily'}
MASTERS={'products':'Dim_Product','dates':'Dim_Date','locations':'Dim_Location','vendors':'Dim_Vendor','units':'Dim_UnitMeasure'}
DEMAND_MEASURES={'IndependentQty':'Raw Actual Independent Demand Qty','DependentQty':'Raw Actual Dependent Demand Qty','TotalDemandQty':'Raw Actual Total Demand Qty','EligibleSalesLineCount':'Raw Actual Demand Eligible Sales Line Count','ExcludedSalesLineCount':'Raw Actual Demand Excluded Sales Line Count','ParentWorkOrderCount':'Raw Actual Demand Parent Work Order Count','ProductDayCount':'Raw Actual Demand Product Day Count'}
def quote(x):return '['+x.replace(']',']]')+']'
def contract():
 c=read(CONTRACT)
 if c.get('schema')!='companyx.business-input-contract.v2' or set(c['datasets'])!=set(TABLES):raise ValueError('Expected nine business-grain datasets')
 return c

def order_rows(rows,s):
 indices=[s['fields'].index(k) for k in s['keys']]
 def key(row):
  values=[]
  for k,i in zip(s['keys'],indices):
   if row[i] is None:raise ValueError('NULL grain key: '+k)
   values.append(int(row[i]) if s['types'][k]['sql_type'] in ('int','bigint','smallint','tinyint') else row[i])
  return tuple(values)
 result=sorted(rows,key=key)
 if len({key(r) for r in result})!=len(result):raise ValueError('Duplicate business grain: '+s['view'])
 return result

def digest_rows(rows):
 h=hashlib.sha256()
 for r in rows:h.update((json.dumps(list(r),ensure_ascii=False,separators=(',',':'))+'\n').encode('utf-8'))
 return h.hexdigest()

def sql_scalar(col,meta):
 v=quote(col)
 if meta['sql_type'] in ('char','nchar'):v='RTRIM('+v+')'
 return 'CONVERT(nvarchar(1000),'+v+',126)'

def sql_rows(cn,s,source):
 cols=','.join(sql_scalar(c,s['types'][c]) for c in s['fields'])
 return order_rows([list(r) for r in cn.execute('SELECT '+cols+' FROM '+source)],s)

def source_manifest(cn,c):
 result={}
 for name,s in c['datasets'].items():
  source='('+s['query']+') raw'
  if s.get('property_codec')=='json-row-v1':
   size=cn.execute('SELECT MAX(DATALENGTH(SourceRow)) FROM ('+s['view_query']+') packed').fetchval() or 0
   if size>2*s['property_max_chars']:raise ValueError('Source row exceeds cube property capacity: '+name)
  if name!='demand':
   maxes=cn.execute('SELECT '+','.join('MAX(DATALENGTH(CONVERT(nvarchar(max),'+quote(f)+',126)))' for f in s['fields'])+' FROM '+source).fetchone()
   if any((v or 0)>2000 for v in maxes):raise ValueError('Source property exceeds 1000 characters: '+name)
  rows=sql_rows(cn,s,source);result[name]={'rows':len(rows),'sha256':digest_rows(rows)}
 state=cn.execute('SELECT LastBatchID,LastVersion FROM etl_v2.State WHERE Id=1').fetchone()
 return {'datasets':result,'etl_batch':state[0],'source_version':state[1],'contract_sha256':sha(CONTRACT)}

def prepare_act():
 c=contract()
 with sql('ACT') as cn,lease(cn):
  expected=source_manifest(cn,c);receipt=process('ACT')
  if source_manifest(cn,c)!=expected:raise RuntimeError('ACT source changed while processing')
  m={'schema':'companyx.act-cube-snapshot.v2',**expected,'cube':receipt,'input_origin':'PROCESSED_ACT_BUSINESS_MOLAP'}
  m['snapshot_id']=hashlib.sha256(json.dumps(m,sort_keys=True,default=str).encode()).hexdigest();save(OUTPUT/'act-snapshot.json',m)
  return m

def numeric_text(v,m):
 if v is None:return None
 t=m['sql_type']
 if t in ('int','bigint','smallint','tinyint'):return str(int(v))
 if t in ('decimal','numeric','money','smallmoney'):
  digits=4 if 'money' in t else int(re.search(r',\s*(\d+)\)',m['declaration']).group(1))
  return format(Decimal(str(v)).quantize(Decimal(1).scaleb(-digits)),'f')
 return str(v)

def source_properties(s):
 # Contracts written before this cleanup contain a flag for every source field.
 flags=s.get('null_flags',s['fields'])
 if len(flags)!=len(set(flags)) or not set(flags).issubset(s['fields']):
  raise ValueError('Invalid nullable field contract: '+s['view'])
 if 'null_flags' in s and set(flags)!={c for c in s['fields'] if s['types'][c]['nullable']}:
  raise ValueError('NULL flags disagree with source metadata: '+s['view'])
 return [p for c in s['fields'] for p in (['Source '+c,'Source '+c+' Is Null'] if c in flags else ['Source '+c])],set(flags)

def decode_properties(values,fields,flags,name):
 if len(values)!=len(fields)+len(flags):raise ValueError('Unexpected source property width: '+name)
 row=[];offset=0
 for c in fields:
  value=values[offset];offset+=1
  if c in flags:
   flag=values[offset];offset+=1
   if flag not in ('0','1'):raise ValueError('Invalid NULL flag: '+name+'.'+c)
   if flag=='1':row.append(None);continue
  if value is None:raise ValueError('Unexpected NULL without presence flag: '+name+'.'+c)
  row.append(value)
 return row

def decode_source_row(value,s):
 # JSON null survives SSAS member captions; no missing/empty-value guessing.
 try:row=json.loads(value)
 except (TypeError,ValueError) as exc:raise ValueError('Invalid source row: '+s['view']) from exc
 if not isinstance(row,dict) or set(row)!=set(s['fields']):raise ValueError('Unexpected source fields: '+s['view'])
 result=[]
 for field in s['fields']:
  v=row[field]
  if v is None:
   if not s['types'][field]['nullable']:raise ValueError('Unexpected NULL: '+field)
  elif not isinstance(v,str):raise ValueError('Expected canonical source text: '+field)
  result.append(v)
 return result


def fetch(cn,name,s,expected,folder):
 n=expected['rows'];fields=s['fields']
 if s['transport']=='demand':
  cols=[]
  for c in fields:
   cols.append({'DateKey':'KEY([$Demand Date].[Date])','ProductKey':'KEY([$Product].[Product])','DemandRuleVersion':'NAME([$Demand Rule].[Demand Rule])'}.get(c,'[ActualDemandDaily].'+quote(DEMAND_MEASURES[c]) if c in DEMAND_MEASURES else ''))
  mdx='DRILLTHROUGH MAXROWS '+str(n+1)+' SELECT ([Measures].[Raw Actual Demand Product Day Count]) ON 0 FROM [CompanyX ACT] RETURN '+','.join(cols)
  names,data=query_fast(cn,mdx);rows=[[numeric_text(v,s['types'][c]) for c,v in zip(fields,r)] for r in data]
 else:
  packed=s.get('property_codec')=='json-row-v1'
  if s.get('property_codec') not in (None,'json-row-v1'):raise ValueError('Unknown member property codec')
  if packed:
   props,flags=['Source Row'],set()
  else:props,flags=source_properties(s)
  dim=s['dimension']
  if s['transport']=='dimension':
   role=s.get('cube_role','Demand Date' if dim=='Date' else dim)
   h=quote(role)+'.'+quote(dim)+'.'+quote(dim)
   mdx='SELECT {[Measures].[Actual Sales Line Count]} ON 0, '+h+'.MEMBERS DIMENSION PROPERTIES '+','.join(h+'.'+quote(p) for p in props)+' ON 1 FROM [CompanyX ACT]'
   names,data=query_fast(cn,mdx);indices=[]
   for p in props:
    found=[i for i,v in enumerate(names) if v.endswith('.'+quote(p))]
    if len(found)!=1:raise ValueError('Missing named member property: '+p)
    indices.append(found[0])
   values=[[r[i] for i in indices] for r in data]
  else:
   mdx='DRILLTHROUGH MAXROWS '+str(n+1)+' SELECT ([Measures].'+quote(s['measure'])+') ON 0 FROM [CompanyX ACT] RETURN '+','.join('NAME([$'+dim+'].'+quote(p)+')' for p in props)
   names,values=query_fast(cn,mdx)
   if names!=['[$'+dim+'].'+quote(p) for p in props]:raise ValueError('Unexpected drillthrough columns: '+name)
  rows=([decode_source_row(v[0],s) for v in values] if packed else [decode_properties(v,fields,flags,name) for v in values])
 rows=order_rows(rows,s);h=digest_rows(rows)
 if len(rows)!=n or h!=expected['sha256']:
  save(folder/(name+'-mismatch.json'),{'expected':expected,'actual_rows':len(rows),'actual_sha256':h,'first_rows':rows[:2]})
  raise ValueError('MOLAP row/NULL/value mismatch: '+name)
 path=folder/(name+'.jsonl')
 with path.open('w',encoding='utf-8',newline='\n') as stream:
  for row in rows:stream.write(json.dumps(row,ensure_ascii=False,separators=(',',':'))+'\n')
 (folder/(name+'.mdx')).write_text(mdx,encoding='utf-8')
 return {'rows':n,'sha256':h,'file':str(path),'transport':s['transport']}

def declarations(s):
 result=[]
 for col in s['fields']:
  d=s['types'][col]['declaration']
  if not re.fullmatch(r'(?:n?varchar|n?char|decimal|numeric|datetime2|datetimeoffset|varbinary|binary|float|real|money|smallmoney|int|bigint|smallint|tinyint|bit|date|datetime|smalldatetime)(?:\((?:max|\d+)(?:,\s*\d+)?\))?',d):raise ValueError('Unsupported SQL declaration '+d)
  result.append(quote(col)+' '+d+(' NOT NULL' if col in s['keys'] else ' NULL'))
 return ','.join(result)

def stage(cn,name,s,path):
 table='act_input.'+quote('__BusinessStage_'+uuid.uuid4().hex[:12]+'_'+name);cn.execute('CREATE TABLE '+table+' ('+declarations(s)+',PRIMARY KEY('+','.join(quote(k) for k in s['keys'])+'))')
 cur=cn.cursor();cur.fast_executemany=True;cur.setinputsizes([(pyodbc.SQL_WVARCHAR,1000,0)]*len(s['fields']))
 insert='INSERT '+table+' ('+','.join(quote(c) for c in s['fields'])+') VALUES ('+','.join('?' for _ in s['fields'])+')'
 batch=[]
 for line in Path(path).open(encoding='utf-8'):
  batch.append(tuple(json.loads(line)))
  if len(batch)==2000:cur.executemany(insert,batch);batch=[]
 if batch:cur.executemany(insert,batch)
 cur.close();return table

def sync_master(cn,name,s,stage):
 target='act_input.'+quote(MASTERS[name]);key=s['keys'][0]
 cols=[r[0] for r in cn.execute('SELECT name FROM sys.columns WHERE object_id=OBJECT_ID(?) ORDER BY column_id','act_input.'+MASTERS[name])]
 if any(c not in s['fields'] for c in cols):raise ValueError('Missing conformed dimension columns: '+name)
 natural={'products':'ProductID','dates':'CalendarDate','locations':'LocationID','vendors':'VendorID','units':'UnitMeasureCode'}[name]
 mismatch=cn.execute('SELECT COUNT(*) FROM '+target+' d JOIN '+stage+' s ON d.'+quote(key)+'=s.'+quote(key)+' WHERE NOT EXISTS(SELECT d.'+quote(natural)+' INTERSECT SELECT s.'+quote(natural)+')').fetchval()
 if mismatch:raise ValueError('Refuse to rebind existing conformed key: '+name)
 cn.execute('UPDATE d SET '+','.join('d.'+quote(c)+'=s.'+quote(c) for c in cols if c!=key)+' FROM '+target+' d JOIN '+stage+' s ON d.'+quote(key)+'=s.'+quote(key))
 identity=cn.execute('SELECT COUNT(*) FROM sys.identity_columns WHERE object_id=OBJECT_ID(?)','act_input.'+MASTERS[name]).fetchval()
 if identity:cn.execute('SET IDENTITY_INSERT '+target+' ON')
 cn.execute('INSERT '+target+' ('+','.join(quote(c) for c in cols)+') SELECT '+','.join('s.'+quote(c) for c in cols)+' FROM '+stage+' s WHERE NOT EXISTS(SELECT 1 FROM '+target+' d WHERE d.'+quote(key)+'=s.'+quote(key)+')')
 if identity:cn.execute('SET IDENTITY_INSERT '+target+' OFF')

def install_compatibility_views(cn):
 # Repoint only the DSS source interfaces. Old physical snapshots remain intact.
 cn.execute('CREATE OR ALTER VIEW dw.Fact_SalesOrderLine AS SELECT * FROM act_input.BusinessSalesLine')
 cn.execute('CREATE OR ALTER VIEW dw.Bridge_BillOfMaterials AS SELECT * FROM act_input.BusinessBOM')
 cn.execute('CREATE OR ALTER VIEW etl_raw.ProductCostHistory AS SELECT ProductID,StartDate,EndDate,StandardCost,ModifiedDate FROM act_input.BusinessCostHistory')
 cn.execute('''CREATE OR ALTER VIEW etl_raw.ProductVendor AS SELECT ProductID,ReplenishmentVendorID BusinessEntityID,ReplenishmentBaseLeadDays AverageLeadTime,ReplenishmentStandardPrice StandardPrice,ReplenishmentMinOrderQty MinOrderQty,ReplenishmentMaxOrderQty MaxOrderQty,ReplenishmentUnit UnitMeasureCode,ReplenishmentTermsModifiedAt ModifiedDate FROM act_input.BusinessProduct WHERE ReplenishmentVendorID IS NOT NULL''')
 # Status labels are carried at sales-line grain, avoiding stale status lookup joins.
 cn.execute('CREATE OR ALTER VIEW act_input.DSSSales AS SELECT * FROM act_input.BusinessSalesLine')

def verify_dss_source(cn):
 import ast
 from datetime import date,datetime
 source=ast.parse((DEMO/'DSS/control/simulation/baseline_inputs.py').read_text(encoding='utf-8-sig'))
 queries=ast.literal_eval(next(n.value for n in source.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='QUERIES' for t in n.targets)))
 reference=read(GPT/'output/companyx-split-20261107/baselines/full_history_inputs/source_extract.json')
 def scalar(v):
  if isinstance(v,Decimal):return int(v) if v==int(v) else float(v)
  if isinstance(v,(date,datetime)):return v.isoformat()
  return v
 for name,q in queries.items():
  cur=cn.execute(q);cols=[x[0] for x in cur.description];actual=[{k:scalar(v) for k,v in zip(cols,row)} for row in cur]
  if actual!=reference[name]:raise ValueError('New snapshot requires regenerated DSS parameter baseline: '+name)
 return {'canonical_DSS_datasets':len(queries),'status':'EXACT_MATCH'}

def import_sim(m,exports,c):
 cn=sql('SIM',autocommit=False)
 try:
  cn.execute('SET XACT_ABORT ON');stages={}
  for name,s in c['datasets'].items():
   stages[name]=stage(cn,name,s,exports[name]['file'])
   if digest_rows(sql_rows(cn,s,stages[name]))!=m['datasets'][name]['sha256']:raise ValueError('SQL typed roundtrip mismatch '+name)
  for name in MASTERS:sync_master(cn,name,c['datasets'][name],stages[name])
  for name,s in c['datasets'].items():
   table='act_input.'+quote(TABLES[name]);cols=','.join(quote(f) for f in s['fields'])
   if cn.execute('SELECT OBJECT_ID(?)','act_input.'+TABLES[name]).fetchval() is None:cn.execute('CREATE TABLE '+table+' ('+declarations(s)+',PRIMARY KEY('+','.join(quote(k) for k in s['keys'])+'))')
   cn.execute('DELETE FROM '+table);cn.execute('INSERT '+table+' ('+cols+') SELECT '+cols+' FROM '+stages[name])
  for fact,pk in [('BusinessSalesLine','ProductKey'),('BusinessCostHistory','ProductKey'),('BusinessDemandDaily','ProductKey'),('BusinessBOM','AssemblyProductKey'),('BusinessBOM','ComponentProductKey')]:
   if cn.execute('SELECT COUNT(*) FROM act_input.'+quote(fact)+' f LEFT JOIN act_input.BusinessProduct p ON p.ProductKey=f.'+quote(pk)+' WHERE p.ProductKey IS NULL').fetchval():raise ValueError('Missing product key: '+fact)
  if cn.execute('SELECT COUNT(*) FROM act_input.BusinessDemandDaily f LEFT JOIN act_input.BusinessDate d ON d.DateKey=f.DateKey WHERE d.DateKey IS NULL').fetchval():raise ValueError('Missing demand date')
  install_compatibility_views(cn)
  for name,s in c['datasets'].items():
   if digest_rows(sql_rows(cn,s,'act_input.'+quote(TABLES[name])))!=m['datasets'][name]['sha256']:raise ValueError('Stored snapshot mismatch '+name)
  cn.execute('UPDATE act_input.SnapshotManifest SET IsCurrent=0')
  if cn.execute('SELECT 1 FROM act_input.SnapshotManifest WHERE SnapshotID=?',m['snapshot_id']).fetchone():cn.execute('UPDATE act_input.SnapshotManifest SET IsCurrent=1 WHERE SnapshotID=?',m['snapshot_id'])
  else:cn.execute('INSERT act_input.SnapshotManifest(SnapshotID,IsCurrent,ACTCube,ACTProcessedAt,ETLBatchID,ManifestJSON) VALUES (?,1,?,?,?,?)',m['snapshot_id'],CUBES['ACT'],m['cube']['processed'],m['etl_batch'],json.dumps(m,ensure_ascii=False))
  verify_dss_source(cn)
  for temporary in stages.values():cn.execute('DROP TABLE '+temporary)
  cn.commit()
 except BaseException:cn.rollback();raise
 finally:cn.close()

def export_act():
 c=contract();m=read(OUTPUT/'act-snapshot.json')
 if m['schema']!='companyx.act-cube-snapshot.v2' or m['contract_sha256']!=sha(CONTRACT):raise ValueError('Prepare current business ACT snapshot first')
 folder=evidence(OUTPUT/'snapshots'/m['snapshot_id'])
 with sql('ACT') as act,lease(act),sql('SIM') as sim,lease(sim),connect(SSAS_SERVER,CUBES['ACT']) as cube:
  before,_=metadata(cube,'ACT')
  if before.findtext('{*}State')!='Processed' or before.findtext('{*}LastProcessed')!=m['cube']['processed']:raise ValueError('ACT cube process version mismatch')
  exports={name:fetch(cube,name,s,m['datasets'][name],folder) for name,s in c['datasets'].items()}
  after,_=metadata(cube,'ACT')
  if before.findtext('{*}LastProcessed')!=after.findtext('{*}LastProcessed'):raise ValueError('Cube changed during export')
  if source_manifest(act,c)['datasets']!=m['datasets']:raise ValueError('ACT source differs from processed snapshot')
  save(folder/'export-verified.json',{'snapshot_id':m['snapshot_id'],'processed':m['cube']['processed'],'datasets':exports})
  import_sim(m,exports,c)
  result={'status':'VERIFIED','schema':'companyx.business-input-import.v2','snapshot_id':m['snapshot_id'],'from_cube':CUBES['ACT'],'to_warehouse':DATABASES['SIM'],'transport':'Processed business MOLAP / native MDX; exact scalar and SQL type roundtrip','datasets':exports,'at':datetime.now(timezone.utc).isoformat()}
  save(folder/'import-receipt.json',result);save(OUTPUT/'input-current.json',result);return result

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=['prepare-act','export-act']);a=p.parse_args();evidence(TMP/'cube-inputs')
 result=(prepare_act if a.action=='prepare-act' else export_act)();print(json.dumps({'status':result.get('status','PREPARED'),'snapshot_id':result['snapshot_id']}))

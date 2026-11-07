"""Publish verified typed detail atomically; never reconstruct reservations."""
from __future__ import annotations
import argparse
from datetime import date,datetime,timezone
from decimal import Decimal
from functools import lru_cache
import hashlib,json,sys
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from publish.publisher import CONNECTION,read,sha,canonical
from publish.detail_schema import TABLES,ensure_schema
from publish.operation_gate import publish_operation_gate

CONTRACT='companyx.execution-detail.v1'

def prepare_detail(folder,project=None):
 from publish.detail_extract import export_detail
 folder=Path(folder).resolve()
 detail=export_detail(folder,project_root=project)
 target=Path(detail['detail_folder']).resolve()
 if not target.is_relative_to(folder):raise ValueError('Published detail must be inside its artifact directory')
 manifest_path=target/'detail_manifest.json'
 if read(manifest_path)!=detail:raise ValueError('Detail manifest mismatch')
 sources={name.removesuffix('.jsonl'):dict(path=target/name,**entry) for name,entry in detail['tables'].items()}
 applicable=read(folder/'execution_spec.json')['policy']=='QUETSCHLICH_ADAPT'
 rolling=None
 if applicable:
  from simulation.rolling_plan import verify_rolling_plan
  rolling=read(folder/'rolling_plan_manifest.json')
  verify_rolling_plan(folder,rolling,project)
  for t,k in [('PlanVersion','versions'),('PlanAction','actions')]:
   entry=rolling[k];sources[t]={'path':folder/entry['path'],'sha256':entry['sha256'],'rows':entry['rows']}
 for name,entry in sources.items():
  if name not in TABLES or sha(entry['path'])!=entry['sha256']:raise ValueError('Detail file/table identity mismatch: '+name)
 binding=dict(schema=CONTRACT,RunCode=read(folder/'run.json')['RunCode'],detail_manifest_sha256=sha(manifest_path),
  rolling_manifest_sha256=sha(folder/'rolling_plan_manifest.json') if applicable else None,
  sources={t:{k:v for k,v in e.items() if k!='path'} for t,e in sources.items()},
  source_artifact=str(folder),is_plan_applicable=applicable)
 return detail,sources,binding,hashlib.sha256(canonical(binding).encode('utf-8')).hexdigest()

@lru_cache(maxsize=4096)
def _date_value(value):
 return date.fromisoformat(value)

@lru_cache(maxsize=16384)
def _decimal_value(value):
 d=Decimal(value)
 if not d.is_finite():raise ValueError('Non-finite detail decimal')
 return d.quantize(Decimal('0.00000001'))

def convert(value,kind,name):
 if value is None:
  if kind.endswith('?'):return None
  raise ValueError('Missing non-null detail field '+name)
 kind=kind.rstrip('?')
 if kind=='str':return str(value)
 if kind=='date':return _date_value(str(value)[:10])
 if kind=='bool':
  if value not in (True,False,0,1):raise ValueError('Non-boolean '+name)
  return bool(value)
 if kind=='int':
  if type(value) is int:return value
  d=Decimal(str(value))
  if not d.is_finite() or d!=d.to_integral_value():raise ValueError('Non-integer '+name)
  return int(d)
 return _decimal_value(str(value))

def stream_rows(source,fields,run_code,run_key):
 count=0;digest=hashlib.sha256()
 with Path(source['path']).open('rb') as stream:
  for raw in stream:
   digest.update(raw)
   if not raw.strip():continue
   row=json.loads(raw)
   if 'RunCode' in row and row['RunCode']!=run_code:raise ValueError('Cross-run detail row')
   yield (run_key,*(convert(row.get(n),kind,n) for n,kind in fields.items()))
   count+=1
 if count!=source['rows'] or digest.hexdigest()!=source['sha256']:raise ValueError('Detail changed during insertion')

def _validate(conn,key,applicable):
 # Relational references must resolve, not silently become Unknown members.
 checks={
  'unmapped product':"SELECT COUNT_BIG(*) FROM (SELECT ProductID FROM cxdetail.OrderLineDay WHERE PlanningRunKey=? UNION SELECT ProductID FROM cxdetail.ProductionJobDay WHERE PlanningRunKey=? UNION SELECT ProductID FROM cxdetail.PlanAction WHERE PlanningRunKey=? AND ProductID IS NOT NULL) q WHERE q.ProductID>0 AND NOT EXISTS(SELECT 1 FROM cxolap.DimProduct p WHERE p.ProductID=q.ProductID)",
  'material parent missing':"SELECT COUNT_BIG(*) FROM cxdetail.MaterialTrace f WHERE PlanningRunKey=? AND NOT EXISTS(SELECT 1 FROM cxolap.DimProduct p WHERE p.ProductID=f.ParentProductID)",
  'plan version missing':"SELECT COUNT_BIG(*) FROM cxdetail.PlanAction f WHERE PlanningRunKey=? AND NOT EXISTS(SELECT 1 FROM cxdetail.PlanVersion p WHERE p.PlanningRunKey=f.PlanningRunKey AND p.DecisionVersionID=f.DecisionVersionID)",
  'allocation imbalance':"SELECT COUNT_BIG(*) FROM cxdetail.PlanSupplyBalance WHERE PlanningRunKey=? AND (ABS(SupplyQty-AllocatedQty-ResidualQty)>0.00001 OR ResidualQty < -0.00001)",
  'allocation before supply':"SELECT COUNT_BIG(*) FROM cxdetail.AdvisoryAllocation WHERE PlanningRunKey=? AND (SupplyAvailableAt>PlanAt OR IsAdvisory<>1)",
  'mixed flag/quantity':"SELECT COUNT_BIG(*) FROM cxdetail.PlanAction WHERE PlanningRunKey=? AND ((Quantity IS NULL AND OrderDecisionFlag IS NULL) OR (Quantity IS NOT NULL AND OrderDecisionFlag IS NOT NULL) OR IsObservedExecution<>0)",
  'open line negative':"SELECT COUNT_BIG(*) FROM cxdetail.OrderLineDay WHERE PlanningRunKey=? AND (RemainingQty < -0.00001 OR Date<KnownAt)",
 }
 for label,sql in checks.items():
  if conn.execute(sql,*([key]*sql.count('?'))).fetchval():raise ValueError('Detail DQ: '+label)
 for table,fields in TABLES.items():
  for column,kind in fields.items():
   if column.endswith('ProductID'):
    sql=f'SELECT COUNT_BIG(*) FROM cxdetail.[{table}] f WHERE PlanningRunKey=? AND f.[{column}]>0 AND NOT EXISTS(SELECT 1 FROM cxolap.DimProduct p WHERE p.ProductID=f.[{column}])'
    if conn.execute(sql,key).fetchval():raise ValueError('Unmapped detail product: '+table+'.'+column)
   if kind.rstrip('?')=='date':
    sql=f'SELECT COUNT_BIG(*) FROM cxdetail.[{table}] f WHERE PlanningRunKey=? AND f.[{column}] IS NOT NULL AND NOT EXISTS(SELECT 1 FROM cxolap.DimDate d WHERE d.DateKey=CONVERT(int,CONVERT(char(8),f.[{column}],112)))'
    if conn.execute(sql,key).fetchval():raise ValueError('Date dimension does not cover detail: '+table+'.'+column)
 if conn.execute('''SELECT COUNT_BIG(*) FROM (
   SELECT DecisionVersionID,ComponentConsumerActionRowNumber,ComponentSupplyCode,SUM(AttributedQty) Qty
   FROM cxdetail.PlanOrderMaterial WHERE PlanningRunKey=? GROUP BY DecisionVersionID,ComponentConsumerActionRowNumber,ComponentSupplyCode) m
   LEFT JOIN cxdetail.AdvisoryAllocation a ON a.PlanningRunKey=? AND a.DecisionVersionID=m.DecisionVersionID
     AND a.ConsumerActionRowNumber=m.ComponentConsumerActionRowNumber AND a.SupplyCode=m.ComponentSupplyCode
   WHERE a.AllocationNo IS NULL OR m.Qty>a.AllocatedQty+0.00001''',key,key).fetchval():raise ValueError('Order material attribution exceeds its source edge')
 if applicable and not conn.execute('SELECT COUNT_BIG(*) FROM cxdetail.PlanVersion WHERE PlanningRunKey=?',key).fetchval():raise ValueError('MILP has no accepted plan versions')

def publish_detail(folder,run_key=None,*,project_root=None):
 import pyodbc
 folder=Path(folder).resolve()
 detail,sources,binding,binding_hash=prepare_detail(folder,project_root)
 with publish_operation_gate(),pyodbc.connect(CONNECTION,autocommit=False,timeout=15) as conn:
  conn.timeout=1800
  ensure_schema(conn)
  found=conn.execute('SELECT PlanningRunKey FROM dss.Dim_PlanningRun WHERE RunCode=?',binding['RunCode']).fetchall()
  if len(found)!=1 or (run_key is not None and int(found[0][0])!=int(run_key)):raise ValueError('Detail RunCode/PlanningRunKey does not match published run')
  key=int(found[0][0])
  old=conn.execute('SELECT ManifestHash FROM cxdetail.RunDetail WITH(UPDLOCK,HOLDLOCK) WHERE PlanningRunKey=?',key).fetchone()
  if old:
   if old[0]!=binding_hash:raise ValueError('Existing detail has different provenance; do not overwrite')
   for name,entry in sources.items():
    if conn.execute(f'SELECT COUNT_BIG(*) FROM cxdetail.[{name}] WHERE PlanningRunKey=?',key).fetchval()!=entry['rows']:raise ValueError('Published detail count changed')
   status='ALREADY_LOADED'
  else:
   for name,fields in TABLES.items():
    if name not in sources:continue
    if conn.execute(f'SELECT COUNT_BIG(*) FROM cxdetail.[{name}] WHERE PlanningRunKey=?',key).fetchval():raise ValueError('Uncommitted orphan detail rows found')
    columns=['PlanningRunKey',*fields];q=','.join('?' for _ in columns)
    sql=f'INSERT cxdetail.[{name}]('+','.join('['+n+']' for n in columns)+f') VALUES({q})'
    cur=conn.cursor();cur.fast_executemany=True;batch=[]
    for row in stream_rows(sources[name],fields,binding['RunCode'],key):
     batch.append(row)
     if len(batch)>=5000:cur.executemany(sql,batch);batch=[]
    if batch:cur.executemany(sql,batch)
    cur.close()
   _validate(conn,key,binding['is_plan_applicable'])
   conn.execute('INSERT cxdetail.RunDetail(PlanningRunKey,ContractVersion,ManifestHash,ManifestJSON,ArtifactFolder,IsPlanApplicable) VALUES(?,?,?,?,?,?)',key,CONTRACT,binding_hash,json.dumps(binding,ensure_ascii=False),str(folder),binding['is_plan_applicable'])
   status='LOADED'
  conn.commit()
 result=dict(schema='companyx.execution-detail.publication.v1',status=status,PlanningRunKey=key,
  manifest_sha256=binding_hash,artifact_folder=str(folder),tables={n:s['rows'] for n,s in sources.items()},
  plan_applicable=binding['is_plan_applicable'],published_at=datetime.now(timezone.utc).isoformat())
 target=folder/'detail_publication_attempts';target.mkdir(exist_ok=True)
 (target/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%f')+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
 return result

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('folder',type=Path);p.add_argument('--run-key',type=int);p.add_argument('--prepare-only',action='store_true');a=p.parse_args()
 print(json.dumps(prepare_detail(a.folder)[2] if a.prepare_only else publish_detail(a.folder,a.run_key),ensure_ascii=False))

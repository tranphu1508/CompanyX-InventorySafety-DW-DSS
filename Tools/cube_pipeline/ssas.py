"""Deploy/process only the isolated ACT SSAS database."""
import argparse,xml.etree.ElementTree as ET
from datetime import datetime,timezone
from settings import *
from msolap import connect,query,read_recordset
E='http://schemas.microsoft.com/analysisservices/2003/engine'

def metadata(cn,role):
 require_cube_role(role)
 with cn.call('OpenSchema',-1,[CUBES[role]],'{3444B255-171E-4CB9-AD98-19E57888A75F}') as rs:
  names,rows=read_recordset(rs)
 if len(rows)!=1:raise ValueError('Expected one isolated SSAS database')
 xml=rows[0][names.index('METADATA')]
 root=ET.fromstring(xml);db=root if root.tag.endswith('Database') else root.find('.//{*}Database')
 annotations={a.findtext('{*}Name'):a.findtext('{*}Value') for a in db.findall('./{*}Annotations/{*}Annotation')}
 if annotations.get('CompanyXSplitOwner')!=OWNER or annotations.get('CompanyXSplitRole')!=role:raise ValueError('SSAS owner/role mismatch')
 return db,xml

def execute(cn,xml):
 try:
  result=cn.call('Execute',xml)
  if result is not None:result.release()
 except Exception as original:
  descriptions=[]
  with cn.get('Errors') as errors:
   for i in range(errors.get('Count')):
    with errors.get('Item',i) as err:descriptions.append(err.get('Description'))
  raise RuntimeError(str(original)+'\n'+'\n'.join(descriptions)) from original

def deploy(role):
 require_cube_role(role)
 file=DEMO/'MOLAP'/('CompanyX.'+role+'.create.xmla')
 root=ET.parse(file).getroot();db=root.find('./{*}ObjectDefinition/{*}Database')
 if db.findtext('{*}ID')!=CUBES[role]:raise ValueError('Unexpected XMLA target')
 for ds in db.findall('./{*}DataSources/{*}DataSource'):
  if 'Initial Catalog='+DATABASES[role]+';' not in ds.findtext('{*}ConnectionString'):raise ValueError('Incorrect SQL binding')
 with connect(SSAS_SERVER,'') as cn:
  names,rows=query(cn,'SELECT [CATALOG_NAME] FROM $SYSTEM.DBSCHEMA_CATALOGS')
  exists=any(r[0]==CUBES[role] for r in rows)
  if exists:metadata(cn,role);root.set('AllowOverwrite','true')
  execute(cn,ET.tostring(root,encoding='unicode'))
  _,xml=metadata(cn,role)
 evidence(TMP/'ssas')
 (TMP/'ssas'/('deployed-'+role+'.xml')).write_text(xml,encoding='utf-8')
 print('Deployed '+CUBES[role],flush=True)

def process(role):
 require_cube_role(role)
 with connect(SSAS_SERVER,CUBES[role]) as cn:
  metadata(cn,role)
  command=f'<Batch xmlns="{E}" Transaction="true"><Parallel MaxParallel="2"><Process><Object><DatabaseID>{CUBES[role]}</DatabaseID></Object><Type>ProcessFull</Type></Process></Parallel></Batch>'
  execute(cn,command);db,xml=metadata(cn,role)
  states=[p.findtext('{*}State') for p in db.findall('.//{*}Partition')]
  if not states or any(s!='Processed' for s in states):raise RuntimeError('Not all partitions are processed: '+str(states))
  receipt={'role':role,'database':CUBES[role],'warehouse':DATABASES[role],'state':db.findtext('{*}State'),'processed':db.findtext('{*}LastProcessed'),'partitions':len(states),'model_sha256':sha(DEMO/'MOLAP'/('CompanyX.'+role+'.create.xmla')),'at':datetime.now(timezone.utc).isoformat()}
  save(OUTPUT/('process-'+role+'.json'),receipt)
  (TMP/'ssas'/('processed-'+role+'.xml')).write_text(xml,encoding='utf-8')
  print(receipt,flush=True);return receipt

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=['deploy','process']);p.add_argument('role',choices=['ACT']);a=p.parse_args()
 evidence(TMP/'ssas')
 (deploy if a.action=='deploy' else process)(a.role)

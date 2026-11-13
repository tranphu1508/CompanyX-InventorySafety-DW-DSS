"""Batch DSS adapter for the isolated SIM warehouse. No web/Power BI runtime."""
import argparse,json,sys,hashlib,re
from datetime import datetime,timezone
from pathlib import Path
from settings import *
sys.path.insert(0,str(DEMO/'DSS/control'))
from simulation import baseline_inputs,inquiry_v2
from publish.inquiry_storage import prepare_candidate_storage
from publish.inquiry_v2_publisher import publish_v2
from publish.operation_gate import publish_operation_gate

def canonical(value):return json.dumps(value,sort_keys=True,ensure_ascii=False,separators=(',',':'),allow_nan=False)
def digest(value):return hashlib.sha256(canonical(value).encode()).hexdigest()

def validate_input():
 current=read(OUTPUT/'input-current.json');manifest=read(OUTPUT/'act-snapshot.json')
 if current['status']!='VERIFIED' or current['snapshot_id']!=manifest['snapshot_id']:raise ValueError('Missing verified ACT cube snapshot')
 with sql('SIM') as cn:
  row=cn.execute('SELECT SnapshotID,ACTCube FROM act_input.SnapshotManifest WHERE IsCurrent=1').fetchall()
 if len(row)!=1 or tuple(row[0])!=(current['snapshot_id'],CUBES['ACT']):raise ValueError('SIM current snapshot does not match the imported ACT cube')
 from ssas import metadata
 from msolap import connect
 with connect(SSAS_SERVER,CUBES['ACT']) as cube:
  model,_=metadata(cube,'ACT')
  if model.findtext('{*}State')!='Processed' or model.findtext('{*}LastProcessed')!=manifest['cube']['processed']:raise ValueError('ACT cube changed; export its new snapshot before DSS')
 reference=read(baseline_inputs.source_path(PROJECT));actual=baseline_inputs.extract_source()
 mismatch=[k for k in reference if digest(reference[k])!=digest(actual[k])]
 if set(reference)!=set(actual) or mismatch:raise ValueError('ACT inputs changed; regenerate the ROP/frozen parameter baseline before reuse: '+str(mismatch))
 return {'snapshot_id':current['snapshot_id'],'source_cube':CUBES['ACT'],'source_hashes':{k:digest(v) for k,v in actual.items()},'parameter_basis':'Existing reviewed fixed historical parameters; source equality verified against imported ACT snapshot'}

def run_request(path,purpose='ORDER_INQUIRY'):
 path=Path(path).resolve()
 if GPT not in path.parents:raise ValueError('Requests and results must be in GPT')
 request=read(path);rid=request['request_id']
 if not rid or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in rid):raise ValueError('Unsafe request ID')
 folder=OUTPUT/'runs'/rid
 resuming=folder.exists()
 with sql('SIM') as lock,lease(lock):
  binding=validate_input()
  prepared=inquiry_v2.build_request(request,request['candidates'][0]['candidate_id'],PROJECT)
  request=prepared['request']
  if resuming:
   if read(folder/'request.json')!=request or read(folder/'input_binding.json')!=binding or read(folder/'metadata.json')['purpose']!=purpose:raise ValueError('Existing request/input binding changed; choose a new request ID')
  else:
   evidence(folder);save(folder/'request.json',request);save(folder/'input_binding.json',binding)
   save(folder/'metadata.json',{'schema':'companyx.inquiry.metadata.v2','purpose':purpose,'request_payload_sha256':digest(request),'created_at':datetime.now(timezone.utc).isoformat(),'execution_surface':'SSIS_PYTHON_BATCH'})
  results=[]
  for candidate in request['candidates']:
   cid=candidate['candidate_id'];print('DSS candidate '+cid,flush=True)
   prepared=inquiry_v2.build_request(request,cid,PROJECT)
   artifacts=folder/'candidates'/cid/'artifacts'
   if artifacts.exists():
    if not (artifacts/'completion.json').is_file():raise ValueError('Incomplete candidate requires inspection: '+str(artifacts))
    print('Reusing completed candidate; verification follows.',flush=True)
   else:inquiry_v2.execute_prepared(prepared,artifacts,PROJECT)
   prepare_candidate_storage(artifacts,project_root=PROJECT)
   receipt=publish_v2(artifacts,project_root=PROJECT)
   with sql('SIM') as cn:
    previous=cn.execute('SELECT ACTSnapshotID FROM cxsim.RunInputSnapshot WHERE PlanningRunKey=?',receipt['PlanningRunKey']).fetchone()
    if previous and previous[0]!=binding['snapshot_id']:raise ValueError('Run snapshot lineage changed')
    if not previous:cn.execute("INSERT cxsim.RunInputSnapshot(PlanningRunKey,InputOrigin,ACTSnapshotID,BindingJSON) VALUES (?,'ACT_CUBE',?,?)",receipt['PlanningRunKey'],binding['snapshot_id'],json.dumps(binding,ensure_ascii=False))
   results.append({'candidate_id':cid,'publication':receipt})
   save(folder/'result.json',{'status':'PUBLISHING','input_binding':binding,'candidates':results})
  result={'status':'PUBLISHED','input_binding':binding,'candidates':results}
  save(folder/'result.json',result);print('All candidates published only to SIM.',flush=True);return result

if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('action',choices=['run','validate-input','refresh-sim']);p.add_argument('--request',type=Path);p.add_argument('--purpose',choices=['ORDER_INQUIRY','PIPELINE_SMOKE'],default='ORDER_INQUIRY');a=p.parse_args()
 evidence(TMP/'dss')
 if a.action=='run':run_request(a.request,a.purpose)
 elif a.action=='validate-input':print(json.dumps(validate_input(),indent=2))
 else:
  from sim_sql_refresh import refresh_sim
  refresh_sim()

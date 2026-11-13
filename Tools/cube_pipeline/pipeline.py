"""SSIS Execute Process entry point. Python + native SQL/SSAS providers only."""
import argparse,sys,uuid,traceback,contextlib
from datetime import datetime
from settings import *

def main():
 p=argparse.ArgumentParser();p.add_argument('--stage',required=True,choices=['etl-act','prepare-act','export-act','dss','refresh-sim','validate-request']);p.add_argument('--request',type=Path);p.add_argument('--purpose',choices=['ORDER_INQUIRY','PIPELINE_SMOKE'],default='ORDER_INQUIRY');a=p.parse_args()
 folder=evidence(OUTPUT/'pipeline-attempts'/(datetime.now().strftime('%Y%m%dT%H%M%S')+'-'+a.stage+'-'+uuid.uuid4().hex[:8]))
 status={'stage':a.stage,'status':'RUNNING','log':str(folder/'stage.log')};save(folder/'status.json',status)
 try:
  with (folder/'stage.log').open('w',encoding='utf-8') as stream,contextlib.redirect_stdout(stream),contextlib.redirect_stderr(stream):
   if a.stage=='etl-act':
    from upstream.etl import run
    run(folder)
   elif a.stage=='prepare-act':
    from cube_inputs import prepare_act
    prepare_act()
   elif a.stage=='export-act':
    from cube_inputs import export_act
    export_act()
   elif a.stage=='dss':
    from dss_bridge import run_request
    run_request(a.request,a.purpose)
   elif a.stage=='refresh-sim':
    from sim_sql_refresh import refresh_sim
    refresh_sim()
   else:
    if a.request is None or not a.request.is_file() or GPT not in a.request.resolve().parents:raise ValueError('Choose a request JSON inside E:/Study-BKU/GPT before running the full flow')
    from dss_bridge import inquiry_v2
    request=read(a.request)
    prepared=inquiry_v2.build_request(request,request['candidates'][0]['candidate_id'],PROJECT)
    if (OUTPUT/'runs'/prepared['request']['request_id']).exists():raise ValueError('Full flow needs a new RequestID; use package 80 with its unchanged snapshot to resume an existing request')
  status['status']='SUCCEEDED'
 except BaseException as exc:
  status.update(status='FAILED',error=str(exc))
  with (folder/'stage.log').open('a',encoding='utf-8') as stream:traceback.print_exc(file=stream)
  print(str(exc)+'; log: '+str(folder/'stage.log'),file=sys.stderr);return 1
 finally:save(folder/'status.json',status)
 print(a.stage+' succeeded; log: '+str(folder/'stage.log'));return 0

if __name__=='__main__':raise SystemExit(main())

"""Refresh SIM SQL caches and active scope consumed by the web, without SSAS."""
import re,sys,uuid
from datetime import datetime
from settings import *
sys.path.insert(0,str(DEMO/'DSS/control'))
from publish.operation_gate import publish_operation_gate

def refresh_sim():
 from rop_checkpoints import install
 install()
 from publish.active_sql_scope import refresh_active_sql_scope
 folder=evidence(OUTPUT/'refresh-sim'/(datetime.now().strftime('%Y%m%dT%H%M%S')+'-'+uuid.uuid4().hex[:8]))
 with sql('SIM') as version_lock,lease(version_lock),publish_operation_gate():
  with sql('SIM') as cn:
   for name in ('FactSourceCache.sql','BaselineActivitySourceCache.sql','RunDayCache.sql','ControlSourcePreflight.sql','RefreshOrderCache.sql'):
    script=(DEMO/'DSS/control/publish'/name).read_text(encoding='utf-8-sig')
    # GO is a SQL client batch delimiter, not a T-SQL statement.
    for batch in re.split(r'(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?$',script):
     if batch.strip():
      cursor=cn.execute(batch)
      while cursor.nextset():pass
  refresh_active_sql_scope(folder/'active-scope.json',project_root=PROJECT,gate_held=True)
  receipt={'status':'SUCCEEDED','warehouse':DATABASES['SIM'],'refresh':'SQL_ONLY'}
  save(folder/'refresh.json',receipt);return receipt

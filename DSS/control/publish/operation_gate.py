"""Serialize final warehouse publication with SIM SQL cache/scope refresh."""
from contextlib import contextmanager
import math

RESOURCE='companyx-control-publish-process'


@contextmanager
def publish_operation_gate(*,timeout_ms=600000):
    import pyodbc
    from .publisher import CONNECTION
    if not isinstance(timeout_ms,int) or not 0<=timeout_ms<=600000:
        raise ValueError('Publication/process gate timeout must be 0..600000 milliseconds.')
    connection=CONNECTION.replace('APP=CompanyX Control Publisher;','APP=CompanyX Publish Process Gate;')
    conn=pyodbc.connect(connection,autocommit=True,timeout=15)
    acquired=False
    try:
        conn.timeout=max(30,math.ceil(timeout_ms/1000)+20);cur=conn.cursor()
        cur.execute("""SET NOCOUNT ON;
        IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
         THROW 51000,'Requires owned MOLAP source copy',1;
        DECLARE @result int;
        EXEC @result=sys.sp_getapplock @Resource=?,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=?,@DbPrincipal='public';
        SELECT @result LockResult,@@SPID GateSessionID;""",RESOURCE,timeout_ms)
        result=cur.fetchone()
        if result is None or result[0]<0:
            raise TimeoutError('Publication/process gate could not be acquired: '+str(None if result is None else result[0]))
        acquired=True
        yield {'resource':RESOURCE,'session_id':result[1],'lock_result':result[0]}
    finally:
        try:
            if acquired:
                cur=conn.cursor();cur.execute("EXEC sys.sp_releaseapplock @Resource=?,@LockOwner='Session',@DbPrincipal='public'",RESOURCE)
        finally:
            conn.close()

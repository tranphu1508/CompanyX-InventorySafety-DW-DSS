"""Isolated ACT/SIM deployment. No fallback to the shared warehouse or cube."""
from pathlib import Path
from contextlib import contextmanager
import hashlib,json,os,pyodbc

DEMO=Path(__file__).resolve().parents[2]
PROJECT=DEMO
GPT=DEMO/'_local'
OUTPUT=GPT/'output/companyx-split-20261107'
TMP=GPT/'tmp/companyx-split-20261107'
OWNER='companyx-split-20261107'
SQL_SERVER='localhost'
SSAS_SERVER=r'localhost\COMPANYXOLAP'
DATABASES={r:'CompanyX_DW_'+r+'_20261107' for r in ('ACT','SIM')}
CUBES={r:'CompanyX_'+r+'_20261107' for r in ('ACT','SIM')}
SQL_DATA=DEMO/'Warehouse/Data'
CONTRACT=DEMO/'Warehouse/Split/input-contract.json'

def save(path,data):
 path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
 tmp=path.with_suffix(path.suffix+'.pending')
 tmp.write_text(json.dumps(data,ensure_ascii=False,indent=2,default=str),encoding='utf-8');tmp.replace(path)

def read(path):return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def evidence(path):
 path=Path(path).resolve()
 if GPT not in path.parents:raise ValueError('Logs and intermediate files must be inside Project/GPT')
 path.mkdir(parents=True,exist_ok=True)
 temp=path/'tmp';temp.mkdir(exist_ok=True)
 os.environ.update(TMP=str(temp),TEMP=str(temp),PYTHONDONTWRITEBYTECODE='1',PYTHONUTF8='1')
 return path

def sql(role,*,autocommit=True):
 if role not in DATABASES:raise ValueError('ACT or SIM required')
 cn=pyodbc.connect('DRIVER={ODBC Driver 17 for SQL Server};SERVER='+SQL_SERVER+';DATABASE='+DATABASES[role]+';Trusted_Connection=yes;TrustServerCertificate=yes;APP=CompanyX isolated '+role,autocommit=autocommit,timeout=15)
 cn.timeout=1800
 rows=dict(cn.execute("SELECT name,CONVERT(nvarchar(100),value) FROM sys.extended_properties WHERE class=0 AND name IN('CompanyXSplitOwner','CompanyXSplitRole')").fetchall())
 if rows!={'CompanyXSplitOwner':OWNER,'CompanyXSplitRole':role}:
  cn.close();raise ValueError('Wrong isolated database owner/role')
 return cn

@contextmanager
def lease(cn,resource='CompanyX.Split.InputVersion'):
 cn.execute("DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=?,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0; IF @r<0 THROW 51000,'Another split operation is using this version.',1;",resource)
 try:yield
 finally:cn.execute("EXEC sys.sp_releaseapplock @Resource=?,@LockOwner='Session'",resource)

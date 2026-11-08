"""Local-only control paths and atomic receipts. Uses the existing Python stack."""
from __future__ import annotations
import json, os, re, tempfile
from datetime import datetime, timezone
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[2]
CODE = Path(__file__).resolve().parent
OUTPUT = PROJECT / '_local/output/companyx-split-20261107'
JOBS = OUTPUT / 'runs'
def demo_folder(project=PROJECT):
    candidate = Path(project).resolve()
    if (candidate/'DSS/runtime/src').is_dir(): return candidate
    own = Path(__file__).resolve().parents[2]
    if candidate == own.parent: return own
    return candidate / 'New Inventory Safety'

DEMO = demo_folder()
PYTHON = DEMO / '.venv/Scripts/python.exe'
DTEXEC = Path(r'C:\Program Files\Microsoft SQL Server\160\DTS\Binn\DTExec.exe')
CONTROL_PACKAGE = DEMO / 'CompanyX.Split.Integration/80_DSS_to_SIM_Cube.dtsx'
WORKFLOW_RUNTIME = 'ssis-python-act-sim-v1'

def stamp(): return datetime.now(timezone.utc).isoformat()
def read(path): return json.loads(Path(path).read_text(encoding='utf-8-sig'))
def save(path, value):
    path=Path(path); path.parent.mkdir(parents=True,exist_ok=True)
    fd,tmp=tempfile.mkstemp(prefix=path.name+'.',suffix='.tmp',dir=path.parent)
    try:
        with os.fdopen(fd,'w',encoding='utf-8') as f:
            json.dump(value,f,ensure_ascii=False,allow_nan=False,indent=2,default=str)
            f.flush();os.fsync(f.fileno())
        os.replace(tmp,path)
    finally:
        if os.path.exists(tmp):os.unlink(tmp)

def safe_id(value):
    if not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',value):
        raise ValueError('Invalid request/candidate identifier')
    return value

def job_path(request_id):
    p=(JOBS/safe_id(request_id)).resolve()
    if p.parent!=JOBS.resolve():raise ValueError('Request path escapes owned output folder')
    return p

def environment(folder):
    e=os.environ.copy(); folder=Path(folder)/'tmp';folder.mkdir(parents=True,exist_ok=True)
    e.update(PYTHONDONTWRITEBYTECODE='1',PYTHONUTF8='1',PYTHONIOENCODING='utf-8',TMP=str(folder),TEMP=str(folder))
    return e

def update_status(folder, **values):
    p=Path(folder)/'status.json';state=read(p) if p.exists() else {}
    state.update(values,updated_at=stamp());save(p,state);return state

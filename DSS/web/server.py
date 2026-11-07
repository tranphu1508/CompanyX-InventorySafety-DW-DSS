"""Run with the project .venv. Browser and data service stay on loopback."""
import json, threading, uuid, os, traceback, webbrowser
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from pathlib import Path
import branch
HERE=Path(__file__).resolve().parent
PORT=int(os.getenv('COMPANYX_WEB_PORT','8876'))
ORIGIN=f'http://127.0.0.1:{PORT}'
JOBS=branch.GPT/'output/companyx-local-inquiry'
POOL=ThreadPoolExecutor(max_workers=1)
LOCK=threading.Lock()
ACTIVE=False
def dump(p,data):
    temp=p.with_suffix('.pending')
    temp.write_text(json.dumps(data,ensure_ascii=False),encoding='utf-8')
    temp.replace(p)
def execute(folder,b):
    global ACTIVE
    status=lambda **kw:dump(folder/'status.json',kw)
    try:
        offers=[]
        for delta in range(0,min(14,(b['data']['end']-b['due']).days)+1):
            target=b['due']+timedelta(days=delta)
            status(state='running',message=f'Đang kiểm tra giao trọn đơn ngày {target:%d/%m/%Y}…',offers=offers)
            r=branch.evaluate(b,target,folder/str(delta))
            if delta==0 or r['feasible']:
                dump(folder/f'plan-{delta}.json',{'plan':r.pop('plan'),'work':r.pop('work')})
                offers.append(r)
            if delta>0 and r['feasible']:break
        status(state='done',offers=offers,through=str(target),base=b['key'])
    except Exception:
        (folder/'error.txt').write_text(traceback.format_exc(),encoding='utf-8')
        status(state='error',message='Không hoàn tất lượt tính. Xem error.txt trong thư mục yêu cầu '+folder.name+'.')
    finally:
        with LOCK:ACTIVE=False
def submit(obj):
    global ACTIVE
    with LOCK:
        if ACTIVE:raise ValueError('Đang tính một đơn khác trên máy này.')
        ACTIVE=True
    try:
        b=branch.prepare(obj)
        folder=JOBS/uuid.uuid4().hex;folder.mkdir(parents=True)
        dump(folder/'request.json',dict(obj,source_run=b['key']))
        dump(folder/'status.json',dict(state='running',message='Đang chuẩn bị kế hoạch…',offers=[]))
        POOL.submit(execute,folder,b)
        return {'id':folder.name}
    except BaseException:
        with LOCK:ACTIVE=False
        raise
def report_url():
    s=os.getenv('COMPANYX_POWERBI_EMBED_URL','').strip() or branch.read(HERE/'powerbi.json')['embed_url'].strip()
    if not s:return ''
    u=urlsplit(s)
    if u.scheme=='https' and u.hostname and (u.hostname=='app.powerbi.com' or u.hostname.endswith('.powerbi.com')) and u.path.rstrip('/')=='/reportEmbed':return s
    if u.scheme in ('https','http') and u.hostname in ('localhost','127.0.0.1') and u.path.lower().startswith('/reports/'):return s
    raise ValueError('URL cần là reportEmbed của Power BI hoặc Report Server trên localhost.')
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def send(self,code,data,mime='application/json'):
        raw=json.dumps(data,ensure_ascii=False).encode() if mime=='application/json' else data
        self.send_response(code);self.send_header('Content-Type',mime+'; charset=utf-8')
        self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
    def handle_api(self,post=False):
        import re
        if self.headers.get('Host') not in (f'127.0.0.1:{PORT}',f'localhost:{PORT}'):return self.send(403,{'error':'Local only'})
        path=urlsplit(self.path).path
        if post:
            if path!='/api/order' or self.headers.get('Origin')!=f"http://{self.headers['Host']}" or self.headers.get_content_type()!='application/json':return self.send(403,{'error':'Yêu cầu không hợp lệ.'})
            length=int(self.headers.get('Content-Length',0))
            if not 0<length<=32768:raise ValueError('Kích thước yêu cầu không hợp lệ.')
            return self.send(202,submit(json.loads(self.rfile.read(length))))
        if path=='/':return self.send(200,(HERE/'index.html').read_bytes(),'text/html')
        if path=='/api/catalog':return self.send(200,branch.catalog())
        if path=='/api/report':return self.send(200,{'url':report_url()})
        m=re.fullmatch(r'/api/order/([0-9a-f]{32})(?:/plan/([0-9]{1,2}))?',path)
        if m:
            f=JOBS/m[1]/('status.json' if m[2] is None else f'plan-{int(m[2])}.json')
            if f.is_file():return self.send(200,branch.read(f))
        self.send(404,{'error':'Không tìm thấy kết quả.'})
    def dispatch(self,post=False):
        try:self.handle_api(post)
        except (ValueError,KeyError,TypeError) as e:self.send(400,{'error':str(e)})
        except Exception as e:self.send(500,{'error':'Không đọc được dữ liệu hoặc cấu hình DSS: '+str(e)[:280]})
    def do_GET(self):self.dispatch()
    def do_POST(self):self.dispatch(True)
if __name__=='__main__':
    with ThreadingHTTPServer(('127.0.0.1',PORT),Handler) as app:
        print(ORIGIN,flush=True)
        if '--open' in __import__('sys').argv:webbrowser.open(ORIGIN)
        app.serve_forever()


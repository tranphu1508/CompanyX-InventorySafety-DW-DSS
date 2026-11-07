# MÔ HÌNH QUESTCHLICH ADAPT VÀ BỘ THỰC THI QUYẾT ĐỊNH TỐI ƯU
#
# Cấu trúc file:
#   1. WEIGHTS, SPEC: trọng số mục tiêu và giả định của lượt chạy.
#   2. Model: lưu biến, cận, hệ số mục tiêu và các phương trình tuyến tính.
#   3. dataset: dựng BOM và thông tin thời gian phục vụ lập kế hoạch.
#   4. build: tạo bài toán kế hoạch nhiều ngày từ trạng thái của ngày hiện tại.
#   5. solve: chuyển mô hình sang HiGHS, giải và kiểm tra nghiệm.
#   6. action_from_plan: lấy riêng quyết định của ngày đầu để thực thi.
#   7. Controller: điều phối giải mới, lưu kế hoạch và đọc checkpoint.
#   8. simulate: cập nhật vật tư, đơn hàng và các nhật ký theo quyết định đã chọn.
#
# Luồng một ngày: simulate -> Controller.decide -> build -> solve
#   -> action_from_plan -> thực thi -> sang ngày sau và lập lại kế hoạch.
# Khi phát lại, run.py thay Controller bằng SavedController để đọc quyết định cũ.
#
# Ký hiệu quan trọng:
#   t = chỉ số ngày trong toàn kỳ, k = ngày tương đối trong lượt kế hoạch, k=0 là hôm nay.
#   p = mã sản phẩm, a = tuổi yêu cầu chờ, H = ngày cuối của tầm nhìn kế hoạch.
#   I = tồn sẵn có dự kiến, q = yêu cầu mới, u = yêu cầu còn chờ cuối ngày.
#   Khóa 'a' trong biến tối ưu là lượng khởi công, khác với chỉ số tuổi a.
#   ya/yf = lượng đáp ứng nhu cầu thực/dự kiến, Ba/Bf = lượng tương ứng còn thiếu.
#   inv/pipe/book/queue = trạng thái thực, v/av = chỉ số cột của biến kế hoạch.
#
# Nhu cầu direct_mu đã được xét SellEndDate trong dữ liệu đóng gói. build() không
# đọc Product hay tự lọc ngày kết thúc bán lần nữa. Gói hiện chỉ có các ngày kết
# thúc bán trước đầu kỳ, chưa có xử lý tổng quát cho dừng bán giữa kỳ.
# Không có giới hạn công suất location hoặc quyết định mua hàng nhà cung cấp.
# Thay trọng số ở WEIGHTS để thiết kế một thí nghiệm khác, không sửa trên bản
# đang chạy dở. StandardCost không tham gia hàm mục tiêu này.
"""Portable release. Core functions copied unchanged from the completed experiment."""
from pathlib import Path
from datetime import date,timedelta
from collections import Counter,defaultdict
from functools import lru_cache
import csv,gzip,hashlib,json,math,os,time
import numpy as np
from scipy.sparse import coo_matrix
import highspy as hs
import companyx_nonopt_mid2013 as sim
from companyx_bom_graph import BOM
# Hệ số mục tiêu: tổng khởi công + tổng tồn kế hoạch + 1.000 cho mỗi đơn vị-ngày thiếu
# + thêm 3.000 cho mỗi đơn vị còn thiếu ở cuối tầm nhìn. Đây không phải giá thành tiền.
# unused_capacity=0 chỉ được giữ trong cấu hình, hiện không có biến/công suất location.
WEIGHTS=dict(flow=1,inventory=1,unserved=3000,late=1000,unused_capacity=0)
SPEC=dict(name='joint_dispatch',family='bom',policy='weighted',timing='due',lead_mode='inclusive')
# Ghi trạng thái mới nhất để theo dõi tiến độ. Không tác động tới nghiệm hoặc vật tư.
def status(folder,**kw):
    z=sim.read(folder/'status.json') if (folder/'status.json').exists() else {}
    z.update(kw,pid=os.getpid(),updated_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
    save(folder/'status.json',z)


# Ghi JSON qua tệp tạm rồi thay thế đích để giảm nguy cơ đọc trúng tệp đang ghi dở.
def save(p,x):
    p.parent.mkdir(parents=True,exist_ok=True)
    tmp=p.with_suffix(p.suffix+'.tmp');tmp.write_text(json.dumps(x,ensure_ascii=False,indent=2,default=str),encoding='utf-8');tmp.replace(p)

# Biểu diễn trung gian của bài toán. Một biến là một cột và một phương trình là một hàng.
# keys/index nối ký hiệu nghiệp vụ với số thứ tự cột cho solver.
class Model:
    # Khởi tạo danh sách biến, mục tiêu, cận, tính nguyên và các hàng ràng buộc.
    def __init__(self):
        self.keys=[]; self.index={}; self.cost=[]; self.lb=[]; self.ub=[]; self.integer=[]
        self.rows=[]; self.lo=[]; self.hi=[]; self.labels=[]
    # Thêm biến không âm với cận trên ub, hệ số mục tiêu cost và cờ integer.
    # Trả chỉ số cột, không trả giá trị nghiệm.
    def var(self, key, ub, cost=0, integer=False):
        j=len(self.keys); self.keys.append(key); self.index[key]=j
        self.cost.append(cost); self.lb.append(0); self.ub.append(ub); self.integer.append(integer)
        return j
    # Thêm phương trình sum(terms[j]*x[j]) = rhs. Các cận biến nằm riêng ở Model.var.
    # label chỉ ghi loại phương trình để đọc/đối soát, không thay đổi ràng buộc.
    def row(self, terms, rhs, label):
        self.rows.append({j:a for j,a in terms.items() if a}); self.lo.append(rhs); self.hi.append(rhs); self.labels.append(label)

# Dựng danh sách cha cho mỗi linh kiện và các mức lead time dùng chọn tầm nhìn H.
# roots là các mã có bán. Chỉ linh kiện tự sản xuất tạo giới hạn vật tư trong mô hình.
def dataset(params, edges, start):
    bom=BOM(edges); parents=defaultdict(list); roots=sorted(p for p,v in params.items() if v['root'])
    for p in params:
        for c,a,u in bom.children[p]:
            if c in params:
                assert int(a)==a, 'Integer state proof requires integer manufactured BOM coefficients'
                parents[c].append((p,int(a)))
    # Tính thời gian hiệu dụng qua BOM theo giả định chờ linh kiện nằm trong lead time.
    # Lấy max giữa lead riêng và 1 + lead lớn nhất của con, không cộng toàn bộ lead của mọi tầng.
    @lru_cache(None)
    def lead(p):
        return max(params[p]['lead_days'], 1+max([lead(c) for c,_,_ in bom.children[p] if c in params]+[0]))
    return dict(P=params, bom=bom, parents=parents, roots=roots, start=start,
                effective_lead=max(lead(p) for p in roots), maxown=max(v['lead_days'] for v in params.values()))

# Dựng một lượt kế hoạch từ trạng thái sau khi đã nhận hàng và mở đơn hôm nay.
# Chỉ book chứa đơn đã biết, không đọc các đơn tương lai chưa tới OrderDate.
# Trả (m, meta), gồm mô hình tuyến tính nguyên hỗn hợp và ánh xạ biến để lấy quyết định.
# reduced bỏ các biến chắc chắn không thể dùng. all_integer là lựa chọn kiểm tra, mặc định
# chỉ các quyết định vật lý cần nguyên, các trạng thái được suy ra từ cân bằng.
def build(d, inv, pipe, book, queue, t, reduced=True, all_integer=False, horizon=None):
    P=d['P']; roots=d['roots']; today=d['start']+timedelta(days=t)
    pending=[o for p in roots for o in book[p] if o['remaining']]
    # 1. Chọn tầm nhìn đủ chứa lead qua BOM, đơn đã biết còn thiếu và các lần nhận WIP.
    # H là chỉ số cuối, nên có H+1 ngày từ 0 tới H. Đây không phải bài toán giải một lần cho cả năm.
    H=horizon if horizon is not None else max(28,d['effective_lead']+7,
        max([(o['due']-today).days+d['maxown'] for o in pending]+[0]),max([k-t for k in pipe]+[0]))
    # 2. da là nhu cầu thực đã biết, df là phần dự kiến bổ sung.
    # Đơn quá hạn gộp vào k=0. Dự báo chỉ tạo cho k>=1 để không giao đơn giả hôm nay.
    da=defaultdict(Counter); df=defaultdict(Counter); receipts=defaultdict(Counter); initial=Counter()
    for o in pending: da[o['p']][max(0,(o['due']-today).days)]+=o['remaining']
    # Hiệu hai giá trị sàn tạo lượng dự kiến nguyên theo ngày từ bình quân direct_mu.
    # Trừ đơn thực tại đúng ngày đó để tránh đếm trùng, chặn phần dự kiến không âm.
    for p in roots:
        mu=P[p]['direct_mu']
        for k in range(1,H+1):
            df[p][k]=max(0,math.floor(mu*(t+k+1)+1e-9)-math.floor(mu*(t+k)+1e-9)-da[p][k])
    # 3. Các lần nhận từ WIP cũ là nguồn cung đã cam kết, không cần quyết định khởi công lại.
    for day, rows in pipe.items():
        for p,q in rows: receipts[p][day-t]+=q
    # Gom hàng chờ theo tuổi. Chặn tuổi ở L-1 vì thời gian sau khởi công không giảm dưới một ngày.
    for j in queue: initial[j['p'],min(P[j['p']]['lead_days']-1,t-j['created'])]+=j['q']
    # 4. Nổ tổng nhu cầu để đặt cận trên kỹ thuật M. Cận này giúp solver,
    # không biểu diễn năng lực nhà máy và không phải nhu cầu giao hàng cộng thêm lần nữa.
    gross=Counter()
    for p in roots:
        q=sum(da[p].values())+sum(df[p].values()); gross[p]+=q
        for (c,u),a in d['bom'].explode(p).items():
            if c in P:gross[c]+=q*a
    for job in queue:
        gross[job['p']]+=job['q']
        for (c,u),a in d['bom'].explode(job['p']).items():
            if c in P:gross[c]+=job['q']*a
    # 5. Tạo biến. v chứa (loại,p,k), av chứa (loại,p,k,tuổi).
    # complete/startvars nối biến khởi công với ngày nhận và nhu cầu tiêu hao linh kiện.
    m=Model(); v={}; av={}; complete=defaultdict(list); startvars=defaultdict(list); counts=Counter()
    for p in sorted(P):
        L=P[p]['lead_days']; A=L-1; M=int(max(1,gross[p]+inv[p]+sum(receipts[p].values())))
        # Tồn I chịu phạt 1. Ba/Bf chịu phạt trễ mỗi ngày và thêm phạt nếu còn ở k=H.
        # Yêu cầu q chỉ được tạo khi còn đủ khoảng thời gian hoàn thành trong kế hoạch.
        for k in range(H+1):
            v['I',p,k]=m.var(('I',p,k),M,WEIGHTS['inventory'],all_integer)
            for key in (['ya','yf','Ba','Bf'] if p in roots else []):
                cost=(WEIGHTS['late']+(WEIGHTS['unserved'] if k==H else 0)) if key in ['Ba','Bf'] else 0
                v[key,p,k]=m.var((key,p,k),0 if key=='yf' and k==0 else M,cost,all_integer or key in ['ya','yf'])
            if not reduced or k+L<=H:
                v['q',p,k]=m.var(('q',p,k),M if k+L<=H else 0,integer=True)
        # Chỉ tạo các nhóm tuổi có thể đạt tới từ hàng chờ đầu kỳ hoặc yêu cầu mới.
        # Biến u giữ yêu cầu còn chờ, biến a chọn lượng khởi công từ nhóm tuổi đó.
        # Reachability is structural: initial cohorts plus all possible new requests.
        reachable={a for (pp,a),q in initial.items() if pp==p and q}
        for k in range(H+1):
            if k+L<=H:reachable.add(0)
            for a in range(L):
                for kind in ['u','a']:
                    # Không để hàng chờ ở ngày cuối. Khởi công phải có ngày nhận nằm trong tầm nhìn.
                    allowed=(k<H if kind=='u' else k+max(1,L-a)<=H)
                    if reduced and (a not in reachable or not allowed):continue
                    cost=WEIGHTS['flow'] if kind=='a' else 0
                    av[kind,p,k,a]=m.var((kind,p,k,a),M if allowed else 0,cost,all_integer or kind=='a')
                    if kind=='a':
                        complete[p,k+max(1,L-a)].append(av[kind,p,k,a]);startvars[p,k].append(av[kind,p,k,a])
            reachable={min(A,a+1) for a in reachable}
        for k in range(H+1):
            # 6. Cân bằng hàng chờ theo tuổi: chờ + khởi công = lượng chuyển từ hôm trước
            # + yêu cầu mới ở tuổi 0. Lượng không khởi công tăng tuổi một ngày, tối đa L-1.
            for a in range(L):
                row={}
                for kind in ['u','a']:
                    if (kind,p,k,a) in av:row[av[kind,p,k,a]]=1
                if a==0 and ('q',p,k) in v:row[v['q',p,k]]=-1
                if k:
                    for aa in range(L):
                        if min(A,aa+1)==a and ('u',p,k-1,aa) in av:row[av['u',p,k-1,aa]]=-1
                rhs=initial[p,a] if k==0 else 0
                if row or rhs:m.row(row,rhs,'request_age')
    # 7. Cân bằng tồn cho từng mã/ngày: tồn cuối = tồn trước + nhận hoàn tất
    # - giao khách - lượng xuất làm linh kiện cho khởi công của các mã cha.
    # Cận I>=0 buộc mọi quyết định dùng cùng một nguồn vật tư khả dụng.
    for p in sorted(P):
        for k in range(H+1):
            row={v['I',p,k]:1}
            if k:row[v['I',p,k-1]]=-1
            for j in complete[p,k]:row[j]=-1
            for parent,a in d['parents'][p]:
                for j in startvars[parent,k]:row[j]=row.get(j,0)+a
            if p in roots:
                row[v['ya',p,k]]=1; row[v['yf',p,k]]=1
                # Cân bằng nhu cầu còn thiếu riêng cho thực và dự kiến. Không cho giá trị âm
                # nên không thể giao vượt nhu cầu. Các khoản thiếu chuyển sang ngày kế tiếp.
                for key,ship,arr in [('Ba','ya',da),('Bf','yf',df)]:
                    rr={v[key,p,k]:1,v[ship,p,k]:1}
                    if k:rr[v[key,p,k-1]]=-1
                    m.row(rr,arr[p][k],key)
            m.row(row,inv[p] if k==0 else receipts[p][k],'inventory')
    meta=dict(H=H,v=v,av=av,da=da,df=df,initial=initial,
              dense_equivalent_variables=(H+1)*sum(2+2*x['lead_days']+(4 if x['root'] else 0) for x in P.values()))
    return m,meta

# Chuyển dữ liệu của Model sang ma trận thưa CSC và gọi HiGHS.
# Chỉ nhận trạng thái optimal. Sau đó kiểm tra tính nguyên, cận, phương trình và mục tiêu.
# Trả vector nghiệm cùng nhật ký solver. Không có phương án dự phòng khi giải thất bại.
def solve(m, log_path=None):
    begin=time.perf_counter(); rr=[]; cc=[]; vv=[]
    for r,row in enumerate(m.rows):
        for j,a in row.items():rr.append(r);cc.append(j);vv.append(a)
    # Chuyển các phương trình có ít hệ số khác 0 thành ma trận thưa để tiết kiệm bộ nhớ.
    A=coo_matrix((vv,(rr,cc)),shape=(len(m.rows),len(m.keys))).tocsc()
    lp=hs.HighsLp();lp.num_col_=len(m.keys);lp.num_row_=len(m.rows)
    lp.col_cost_=np.asarray(m.cost,dtype=float);lp.col_lower_=np.asarray(m.lb,dtype=float);lp.col_upper_=np.asarray(m.ub,dtype=float)
    lp.row_lower_=np.asarray(m.lo,dtype=float);lp.row_upper_=np.asarray(m.hi,dtype=float)
    lp.a_matrix_.format_=hs.MatrixFormat.kColwise;lp.a_matrix_.start_=A.indptr.astype(np.int32)
    lp.a_matrix_.index_=A.indices.astype(np.int32);lp.a_matrix_.value_=A.data
    lp.integrality_=[hs.HighsVarType.kInteger if b else hs.HighsVarType.kContinuous for b in m.integer]
    h=hs.Highs();h.setOptionValue('output_flag',bool(log_path));h.setOptionValue('log_to_console',False)
    # ASCII relative path also works with HiGHS builds whose C++ log sink cannot
    # open a Windows absolute path containing Vietnamese characters.
    if log_path:h.setOptionValue('log_file',os.path.relpath(log_path,Path.cwd()))
    # Các lựa chọn solver có thể ảnh hưởng thời gian giải và nghiệm khi có nhiều đáp án tối ưu.
    # Bản phát hành yêu cầu gap bằng 0, không giới hạn thời gian và cố định seed=0.
    h.setOptionValue('threads',min(8,max(1,(os.cpu_count() or 4)//2)));h.setOptionValue('parallel','on')
    h.setOptionValue('time_limit',float('inf'));h.setOptionValue('mip_rel_gap',0.0);h.setOptionValue('mip_abs_gap',0.0)
    h.setOptionValue('random_seed',0);h.passModel(lp);h.run()
    info=h.getInfo(); st=h.getModelStatus()
    if st!=hs.HighsModelStatus.kOptimal:raise RuntimeError(h.modelStatusToString(st))
    # Làm tròn sai số số thực rồi kiểm tra lại. Nếu trạng thái không gần số nguyên hoặc
    # vi phạm cân bằng/cận thì dừng, không âm thầm đưa nghiệm sai vào mô phỏng.
    raw=np.array(h.getSolution().col_value);z=np.rint(raw)
    error=float(np.max(np.abs(raw-z)));act=A@z
    violation=max(float(np.max(np.abs(act-np.array(m.lo)))),float(np.max(np.maximum(z-np.array(m.ub),0))),float(np.max(np.maximum(-z,0))))
    assert error<1e-5 and violation<1e-5,(error,violation)
    # Tách mục tiêu thành tồn, khởi công, thiếu tích lũy và thiếu cuối kỳ để đối chiếu solver.
    components=Counter()
    H=max(key[2] for key in m.keys if key[0]=='I')
    for key,q in zip(m.keys,z):
        if key[0]=='I':components['inventory']+=int(q)
        if key[0]=='a':components['flow']+=int(q)
        if key[0] in ['Ba','Bf']:
            components['late']+=int(q)
            if key[2]==H:components['unserved']+=int(q)
    objective=sum(WEIGHTS[k]*v for k,v in components.items())
    assert abs(objective-h.getObjectiveValue())<1e-4
    return z,dict(seconds=time.perf_counter()-begin,variables=len(m.keys),integer_variables=sum(m.integer),constraints=len(m.rows),
        status='optimal',gap=info.mip_gap,nodes=info.mip_node_count,objective=objective,components=dict(components),
        max_integer_error=error,max_constraint_violation=violation)

# Lọc nghiệm kế hoạch về k=0 để lấy giao hàng, tạo yêu cầu và khởi công theo tuổi.
# Các quyết định k>0 chỉ dùng định hướng hôm nay và sẽ được tính lại ở ngày sau.
def action_from_plan(m,meta,z,t):
    assert all(z[j]==0 for (kind,p,k),j in meta['v'].items() if kind=='yf' and k==0)
    return dict(day=t,
        shipments={p:int(z[j]) for (kind,p,k),j in meta['v'].items() if kind=='ya' and k==0 and z[j]},
        requests={p:int(z[j]) for (kind,p,k),j in meta['v'].items() if kind=='q' and k==0 and z[j]},
        aged=[dict(p=p,age=a,q=int(z[j])) for (kind,p,k,a),j in meta['av'].items() if kind=='a' and k==0 and z[j]],
        projected_inventory={p:int(z[j]) for (kind,p,k),j in meta['v'].items() if kind=='I' and k==0},
        projected_actual_backlog={p:int(z[j]) for (kind,p,k),j in meta['v'].items() if kind=='Ba' and k==0})

# Bộ điều phối một lượt chạy tối ưu. Kết nối trạng thái mô phỏng với build/solve và lưu checkpoint.
class Controller:
    # Giữ dữ liệu mô hình, thư mục ghi, quyết định đã giải khi resume và nhật ký các lượt giải.
    def __init__(self,d,folder,replay=None):self.d=d;self.folder=folder;self.replay=replay or {};self.logs=[]
    # Nếu ngày t đã có checkpoint thì dùng lại. Nếu chưa, dựng/giải kế hoạch,
    # lưu toàn bộ nghiệm rồi ghi quyết định ngày hiện tại để có thể tiếp tục về sau.
    def decide(self,t,inv,pipe,book,queue):
        # Resume: các ngày đã giải được phát lại để dựng đúng trạng thái, không giải lần nữa.
        if t in self.replay:
            action,log=self.replay[t]
            assert 'shipments' in action and 'projected_inventory' in action,'Legacy production-only replay is prohibited'
            assert (self.folder/'plans'/f'day_{t:03d}.json.gz').exists(),'Full plan missing for checkpoint'
            self.logs.append(log);return action
        status(self.folder,state='building',day=t+1,completed_days=t)
        began=time.perf_counter();m,meta=build(self.d,inv,pipe,book,queue,t);build_secs=time.perf_counter()-began
        status(self.folder,state='solving',day=t+1,variables=len(m.keys),constraints=len(m.rows))
        z,log=solve(m,self.folder/'solver_current.log');log.update(day=t,H=meta['H'],build_seconds=build_secs)
        action=action_from_plan(m,meta,z,t)
        # Ghi toàn bộ kế hoạch trước, rồi mới ghi dòng quyết định thực thi.
        # plans dùng kiểm tra nghiệm nhiều ngày, decisions.jsonl dùng tái lập và resume.
        plans=self.folder/'plans';plans.mkdir(exist_ok=True)
        target=plans/f'day_{t:03d}.json.gz';tmp=target.with_suffix('.gz.tmp')
        with gzip.open(tmp,'wt',encoding='utf-8') as f:
            json.dump(dict(day=t,H=meta['H'],weights=WEIGHTS,values=[dict(key=key,value=int(q)) for key,q in zip(m.keys,z) if q]),f)
        tmp.replace(target)
        if t==0:save(self.folder/'first_plan.json',[dict(key=key,value=int(q)) for key,q in zip(m.keys,z) if q])
        with (self.folder/'decisions.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(dict(action=action,solver=log))+'\n')
        self.logs.append(log);status(self.folder,state='executing',last_solver=log)
        print('DAY',t+1,'penalty',WEIGHTS['late'],'solve',round(log['seconds'],3),'obj',log['objective'],'ship',sum(action['shipments'].values()),flush=True)
        return action

# Thực thi lượng giao và khởi công do controller chọn, rồi ghi trạng thái thực theo ngày.
# Khác bộ máy chính sách: không tự giao hết tồn cho khách trước khi quyết định dùng làm linh kiện.
# Đầu ra có thêm allocation để đối soát việc phân chia tồn giữa hai mục đích.
def simulate(params,orders,edges,topo,spec,start,end,controller):
    family=spec['family'];roots={p for p,v in params.items() if v['root']}
    ids=sorted(params if family=='bom' else roots);P={p:params[p] for p in ids}
    bom=BOM(edges if family=='bom' else [])
    components={c for p in P for c,_,_ in bom.children[p] if c in P}
    active={o['p'] for o in orders};inv=Counter({p:P[p]['initial'] for p in P});initial=inv.copy()
    wip=Counter();received=Counter();sold=Counter();used=Counter();started=Counter();requested=Counter()
    # Khởi tạo trạng thái thực, tách khỏi các biến kế hoạch trong build().
    pipe=defaultdict(list);events=defaultdict(list);book=defaultdict(list);states=[];queue=[];jid=0
    # Ghi lịch mở đơn. Chỉ khi tới activation thì đơn mới được đưa vào book cho bộ tối ưu thấy.
    for o in orders:
        assert o['p'] in roots and start<=sim.dt(o['order'])<=end and sim.dt(o['due'])>=sim.dt(o['order'])
        z=dict(o,order=sim.dt(o['order']),due=sim.dt(o['due']),remaining=o['q'],on_time=0,immediate=0)
        z['activation']=z['due'] if family=='refill' and spec['timing']=='due' else z['order']
        states.append(z);events[(z['activation']-start).days].append(z)
    daily=[];ledger=[];starts=[];requests=[];delivery=[];consumption=[];receipt_log=[];allocation=[]
    for t in range((end-start).days+1):
        today=start+timedelta(days=t);arrive=Counter();sales=Counter();consume=Counter();startqty=Counter();req=Counter();dep=Counter();waiting=Counter()
        # Bước 1: nhận hàng từ WIP cũ trước khi ra quyết định hôm nay.
        for p,q in pipe.pop(t,[]):
            inv[p]+=q;wip[p]-=q;received[p]+=q;arrive[p]+=q
            receipt_log.append(dict(day=t,date=today,ProductID=p,quantity=q))
        # Bước 2: mở đơn mới. Lưu tồn và lượng đến hạn trước phân bổ để có thể đối soát.
        for o in events[t]:book[o['p']].append(o)
        before_inv=inv.copy()
        due_before={p:sum(o['remaining'] for o in book[p] if o['due']<=today) for p in roots}
        # Bước 3: lấy chung quyết định giao và sản xuất. Với controller phát lại, đọc từ kết quả lưu.
        action=controller.decide(t,inv,pipe,book,queue)
        assert action['day']==t
        # Bước 4: chỉ giao đúng lượng solver chọn. Một phần tồn có thể được giữ để làm linh kiện.
        # Trong lượng đã chọn, ưu tiên dòng đến hạn sớm, rồi mã dòng. Không giao trước DueDate.
        # Only the optimizer's selected amount is dispatched. Physical execution
        # order does not grant customers extra priority over material allocation.
        for pp,amount in action['shipments'].items():
            p=int(pp);assert p in roots and int(amount)==amount and 0<=amount<=due_before[p]
            assert amount<=inv[p]
            left=amount
            for o in sorted(book[p],key=lambda o:(o['due'],o['id'])):
                if o['due']>today:continue
                q=min(left,o['remaining'])
                if not q:continue
                inv[p]-=q;o['remaining']-=q;sold[p]+=q;sales[p]+=q;left-=q
                if today<=o['due']:o['on_time']+=q
                if today==o['activation']:o['immediate']+=q
                delivery.append(dict(day=t,date=today,id=o['id'],ProductID=p,quantity=q))
            assert left==0
        for p in roots:book[p]=[o for o in book[p] if o['remaining']]
        # Bước 5: tạo yêu cầu mới. Thao tác này tăng queue, chưa tạo hàng sẵn có hoặc WIP.
        for pp,q in action['requests'].items():
            p=int(pp);assert p in P and int(q)==q and q>=0
            if q:
                jid+=1;queue.append(dict(id=jid,p=p,q=q,created=t));requested[p]+=q;req[p]+=q
                requests.append(dict(day=t,date=today,ProductID=p,quantity=q,request_id=jid))
        # Bước 6: khởi công đúng lượng theo mã và tuổi mà kế hoạch chọn.
        # Trong cùng nhóm tuổi, lấy yêu cầu cũ trước và có thể khởi công một phần.
        for planned in action['aged']:
            p=planned['p'];age=planned['age'];left=planned['q']
            assert p in P and left>0 and int(left)==left
            for job in sorted(queue,key=lambda j:(j['created'],j['id'])):
                if job['p']!=p or min(P[p]['lead_days']-1,t-job['created'])!=age:continue
                q=min(left,job['q'])
                if not q:continue
                # Xuất linh kiện trực tiếp từ tồn. Mã ngoài P được ghi nhận tiêu hao nhưng không
                # bị giới hạn nguồn mua. Muốn thêm nhà cung cấp phải bổ sung trạng thái và quyết định tương ứng.
                for c,a,u in bom.children[p]:
                    amount=q*a
                    if c in P:
                        assert inv[c]>=amount,(t,p,c,inv[c],amount)
                        inv[c]-=amount;used[c]+=amount;consume[c]+=amount
                    consumption.append(dict(day=t,date=today,parent=p,component=c,unit=u,quantity=amount,manufactured=c in P))
                # Lịch nhận giống bộ máy chính sách: tính lead từ lúc tạo yêu cầu, tối thiểu
                # một ngày sau khởi công. Số lượng rời queue, vào WIP và được đặt vào pipe[finish].
                finish=max(t+1,job['created']+P[p]['lead_days'])
                started[p]+=q;startqty[p]+=q;wip[p]+=q;pipe[finish].append((p,q));job['q']-=q;left-=q
                starts.append(dict(day=t,date=today,ProductID=p,quantity=q,created_day=job['created'],receipt_day=finish,request_id=job['id'],lots=1))
                if not left:break
            assert left==0,(t,p,age,left)
        queue=[j for j in queue if j['q']]
        # Bước 7: trạng thái sau thực thi phải trùng lượng tồn và thiếu thực mà solver dự kiến ở k=0.
        assert {int(p):q for p,q in action['projected_inventory'].items()}==dict(inv)
        projected_backlog={int(p):q for p,q in action['projected_actual_backlog'].items()}
        assert projected_backlog=={p:sum(o['remaining'] for o in book[p] if o['due']<=today) for p in roots}
        for p in sorted(roots):
            allocation.append(dict(day=t,date=today,ProductID=p,available_before_allocation=before_inv[p],due_before=due_before[p],chosen_shipment=sales[p],used_in_production=consume[p],inventory_end=inv[p],actual_backlog=projected_backlog[p],withheld_vs_greedy=max(0,min(before_inv[p],due_before[p])-sales[p])))
        # Kiểm tra ba cân bằng vật lý mỗi ngày, rồi lưu ledger từng mã.
        # Đây cũng là nơi phát hiện trừ linh kiện hai lần hoặc ghi nhận hoàn tất sai ngày.
        queueqty=Counter()
        for j in queue:queueqty[j['p']]+=j['q']
        for p in ids:
            assert inv[p]==initial[p]+received[p]-sold[p]-used[p] and inv[p]>=0
            assert wip[p]==(requested[p] if family=='refill' else started[p])-received[p] and wip[p]>=0
            assert family=='refill' or requested[p]==started[p]+queueqty[p]
            ledger.append(dict(day=t,date=today,ProductID=p,inventory=inv[p],pipeline=wip[p],queued=queueqty[p],received=arrive[p],sold=sales[p],consumed=consume[p],started=startqty[p],requested=req[p]))
        outstanding=[o for pp in roots for o in book[pp]]
        # Tổng hợp trạng thái thực của ngày. Giá trị tiền ở đây là cột lịch sử của engine.
        # run.py:valuation() tính lại giá trị báo cáo theo bảng giá hiện hành, bao gồm WIP.
        row=dict(day=t,date=today,inventory_sales190=sum(inv[p] for p in roots),inventory_all_modeled=sum(inv.values()),
            WIP_all=None if family=='refill' else sum(wip.values()),pending_refill=sum(wip.values()) if family=='refill' else None,
            queue=sum(queueqty.values()),due_backlog=sum(o['remaining'] for o in outstanding if o['due']<=today),
            activated_backlog=sum(o['remaining'] for o in outstanding) if family=='refill' else None,
            received=sum(arrive.values()),shipped=sum(sales.values()),started=sum(startqty.values()),requested=sum(req.values()),
            value_sales190=sum(inv[p]*P[p]['valuation_cost'] for p in roots),
            value_all_known=sum(inv[p]*P[p]['valuation_cost'] for p in P if P[p]['valuation_cost'] is not None),
            unvalued_stock=sum(inv[p] for p in P if P[p]['valuation_cost'] is None),
            inventory_roots_without_window_demand=sum(inv[p] for p in roots-active))
        daily.append(row)
        status(controller.folder,state='running',completed_days=t+1,day=t+1,last_daily=row)
        if (t+1)%7==0:save(controller.folder/'daily_progress.json',daily)
    return dict(states=states,daily=daily,ledger=ledger,starts=starts,requests=requests,delivery=delivery,consumption=consumption,receipts=receipt_log,queue=queue,allocation=allocation)

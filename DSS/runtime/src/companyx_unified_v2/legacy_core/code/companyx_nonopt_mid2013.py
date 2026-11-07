# BỘ MÁY MÔ PHỎNG CÁC CHÍNH SÁCH TỒN KHO THEO NGÀY
#
# Cấu trúc file:
#   1. read/save/csvout/dt: đọc ghi và chuyển đổi ngày.
#   2. simulate: quản lý đơn hàng, tồn, hàng chờ, WIP và lịch nhận.
#   3. metrics: tính chỉ tiêu phục vụ và tồn bình quân trên một cửa sổ đánh giá.
#
# simulate() xử lý mỗi ngày theo thứ tự:
#   nhận hoàn tất -> mở đơn mới -> giao các dòng đến hạn -> tạo yêu cầu bổ sung
#   -> kiểm tra linh kiện và khởi công -> ghi trạng thái cuối ngày.
#
# Biến trạng thái:
#   P[p] = tham số của mã p, roots = tập mã có bán, không có nghĩa là mã cuối BOM.
#   inv[p] = hàng sẵn có, wip[p] = lượng đã khởi công nhưng chưa nhận hoàn tất.
#   queue = yêu cầu chưa khởi công, mỗi phần có p, q, created và id.
#   pipe[ngày] = các lượng (p,q) sẽ hoàn tất vào ngày đó.
#   book[p] = các dòng đơn đã biết nhưng còn thiếu, events = lịch mở đơn.
#   waiting[p] = tổng yêu cầu đang chờ, dep[p] = linh kiện cam kết cho hàng chờ.
#   ledger = trạng thái từng mã/ngày, daily = tổng toàn hệ thống mỗi ngày.
#
# Gói V1 chỉ chạy family='bom'. Hai nhánh refill/single được giữ từ bộ máy gốc
# để truy nguyên, không phải phương án chính trong báo cáo.
# Công suất chưa bị giới hạn. Đầu vào mua ngoài có sẵn khi tiêu hao.
# Phương pháp chọn lượng yêu cầu nằm ở release_qty(), không nằm trong metrics().
"""Portable release. Core functions copied unchanged from the completed experiment."""
from pathlib import Path
from datetime import date,timedelta
from collections import Counter,defaultdict
import csv,json,math
from companyx_bom_graph import BOM
from companyx_workorder_median import release_qty


# Đọc JSON UTF-8, chấp nhận BOM ở đầu tệp.
def read(p):return json.loads(p.read_text(encoding='utf-8-sig'))

# Ghi JSON. Thư mục đích phải được điểm chạy tạo sẵn.
def save(p,x):p.write_text(json.dumps(x,ensure_ascii=False,indent=2,default=str),encoding='utf-8')

# Ghi danh sách bản ghi thành CSV UTF-8 có BOM để dễ mở tiếng Việt bằng Excel.
# Không tạo tệp nếu danh sách rỗng. Các cột lấy từ bản ghi đầu tiên.
def csvout(p,rows):
    if not rows:return
    with p.open('w',encoding='utf-8-sig',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(rows[0]));w.writeheader();w.writerows(rows)

# Nhận chuỗi ngày ISO hoặc đối tượng date và trả về date để so sánh ngày.
def dt(s):return date.fromisoformat(s[:10]) if isinstance(s,str) else s

# Đầu vào: tham số theo mã, đơn hàng, BOM, topo, spec và khoảng ngày bao gồm hai đầu.
# Đầu ra: dict các danh sách nhật ký. Hàm chỉ tính và trả dữ liệu, run.py chịu trách nhiệm lưu.
# Không có ngẫu nhiên. Trình tự giao hàng/khởi công quyết định cách chia linh kiện khan hiếm.
def simulate(params,orders,edges,topo,spec,start,end):
    family=spec['family'];roots={p for p,v in params.items() if v['root']}
    ids=sorted(params if family=='bom' else roots);P={p:params[p] for p in ids}
    bom=BOM(edges if family=='bom' else [])
    components={c for p in P for c,_,_ in bom.children[p] if c in P}
    active={o['p'] for o in orders};inv=Counter({p:P[p]['initial'] for p in P});initial=inv.copy()
    wip=Counter();received=Counter();sold=Counter();used=Counter();started=Counter();requested=Counter()
    # Khởi tạo ba trạng thái tách biệt. Tạo yêu cầu chỉ làm queue tăng, chưa tạo hàng sẵn có.
    pipe=defaultdict(list);events=defaultdict(list);book=defaultdict(list);states=[];queue=[];jid=0
    # Chuẩn bị lịch sự kiện. Các đơn tương lai có trong tệp nhưng chưa nằm trong book hôm nay.
    for o in orders:
        assert o['p'] in roots and start<=dt(o['order'])<=end and dt(o['due'])>=dt(o['order'])
        z=dict(o,order=dt(o['order']),due=dt(o['due']),remaining=o['q'],on_time=0,immediate=0)
        z['activation']=z['due'] if family=='refill' and spec['timing']=='due' else z['order']
        states.append(z);events[(z['activation']-start).days].append(z)
    daily=[];ledger=[];starts=[];requests=[];delivery=[];consumption=[];receipt_log=[]
    for t in range((end-start).days+1):
        today=start+timedelta(days=t);arrive=Counter();sales=Counter();consume=Counter();startqty=Counter();req=Counter();dep=Counter();waiting=Counter()
        # Bước 1: nhận hoàn tất đầu ngày, chuyển lượng từ WIP sang tồn có thể sử dụng ngay.
        for p,q in pipe.pop(t,[]):
            inv[p]+=q;wip[p]-=q;received[p]+=q;arrive[p]+=q
            receipt_log.append(dict(day=t,date=today,ProductID=p,quantity=q))
        # Bước 2: mở các đơn được biết hôm nay. Với family BOM, activation chính là OrderDate.
        for o in events[t]:book[o['p']].append(o)
        # Bước 3: giao khách đến hạn theo DueDate, hòa thì theo mã dòng.
        # Có thể giao từng phần. Việc này xảy ra trước phân bổ linh kiện cho sản xuất.
        # Customer deliveries before component allocation, preserving the previous engine.
        for p in roots:
            book[p].sort(key=lambda o:(o['due'],o['id']))
            for o in book[p]:
                if not (family=='refill' and spec['timing']=='order') and o['due']>today:continue
                q=min(inv[p],o['remaining'])
                if not q:continue
                inv[p]-=q;o['remaining']-=q;sold[p]+=q;sales[p]+=q
                if today<=o['due']:o['on_time']+=q
                if today==o['activation']:o['immediate']+=q
                delivery.append(dict(day=t,date=today,id=o['id'],ProductID=p,quantity=q))
            book[p]=[o for o in book[p] if o['remaining']]
        # Các nhánh refill và single dưới đây là nhánh cũ. Gói hiện chọn BOM nên đi vào else.
        if family=='refill':
            for p in ids:
                net=inv[p]-sum(o['remaining'] for o in book[p])
                target=P[p][{'safety':'ss','midpoint':'initial','reorder':'rp'}[spec['policy']]]
                q=target-net if net<P[p]['rp'] else 0
                assert isinstance(q,int) and q>=0
                if q:
                    requested[p]+=q;req[p]+=q;wip[p]+=q;pipe[t+1].append((p,q))
                    requests.append(dict(day=t,date=today,ProductID=p,quantity=q,request_id=len(requests)+1))
        elif family=='single':
            for p in ids:
                ip=inv[p]+wip[p]-sum(o['remaining'] for o in book[p])
                q=release_qty(spec['policy'],int(ip),P[p]['single'],t)
                if q:
                    requested[p]+=q;req[p]+=q;started[p]+=q;startqty[p]+=q;wip[p]+=q
                    finish=t+P[p]['lead_days'];pipe[finish].append((p,q));jid+=1
                    requests.append(dict(day=t,date=today,ProductID=p,quantity=q,request_id=jid))
                    starts.append(dict(day=t,date=today,ProductID=p,quantity=q,created_day=t,receipt_day=finish,request_id=jid,lots=math.ceil(q/P[p]['max_lot'])))
        else:
            # Bước 4a: tính lại lượng chờ và nhu cầu linh kiện đã cam kết từ các yêu cầu chưa khởi công.
            for job in queue:
                waiting[job['p']]+=job['q']
                for c,a,u in bom.children[job['p']]:
                    if c in P:dep[c]+=job['q']*a
            # Bước 4b: xét cha trước con. IP = tồn + WIP + hàng chờ - đơn còn thiếu - linh kiện cam kết.
            # Đơn chưa đến hạn nhưng đã biết vẫn làm giảm IP, giúp chuẩn bị trước DueDate.
            for p in topo:
                pending=sum(o['remaining'] for o in book[p]);ip=inv[p]+wip[p]+waiting[p]-pending-dep[p]
                # ATO giữ linh kiện bằng (R,S), còn mã cuối chuỗi dùng MTO.
                # Một mã vừa bán vừa làm linh kiện vẫn thuộc nhóm được dự trữ.
                rule=('periodic_S' if p in components else 'MTO') if spec['policy']=='ATO' else spec['policy']
                q=release_qty(rule,int(ip),P[p]['bom'],t)
                if q:
                    jid+=1;queue.append(dict(id=jid,p=p,q=q,created=t));waiting[p]+=q;requested[p]+=q;req[p]+=q
                    requests.append(dict(day=t,date=today,ProductID=p,quantity=q,request_id=jid))
                    # Yêu cầu cha mới lập tức tạo nhu cầu con. Đến lượt xét con trong topo,
                    # chính sách đã thấy nhu cầu này. Đây là truyền nhu cầu, chưa phải xuất vật tư.
                    for c,a,u in bom.children[p]:
                        if c in P:dep[c]+=q*a
            # Bước 5: ưu tiên yêu cầu tạo sớm, hòa thì theo mã sản phẩm và mã yêu cầu.
            # Lượng khởi công có thể chỉ là một phần do linh kiện tự sản xuất chưa đủ.
            for job in sorted(queue,key=lambda j:(j['created'],j['p'],j['id'])):
                p=job['p'];q=min([job['q']]+[int(inv[c]//a) for c,a,u in bom.children[p] if c in P])
                if not q:continue
                # Chỉ trừ các con trực tiếp khi thực khởi công. Mã ngoài P là vật tư mua,
                # chỉ ghi tiêu hao và giả định luôn sẵn có. Đây là chỗ cần bổ sung kho/mua hàng nếu mở rộng.
                for c,a,u in bom.children[p]:
                    amount=q*a
                    if c in P:
                        assert inv[c]>=amount
                        inv[c]-=amount;used[c]+=amount;consume[c]+=amount
                    consumption.append(dict(day=t,date=today,parent=p,component=c,unit=u,quantity=amount,manufactured=c in P))
                # inclusive: thời gian chờ đã nằm trong lead time, nhưng vẫn cần ít nhất một ngày sau khởi công.
                # after_material: quy tắc thử nghiệm cũ, tính toàn bộ lead từ ngày khởi công.
                # Hiện chưa có giới hạn số việc hoặc số giờ theo location tại bước khởi công.
                finish=max(t+1,job['created']+P[p]['lead_days']) if spec['lead_mode']=='inclusive' else t+P[p]['lead_days']
                started[p]+=q;startqty[p]+=q;wip[p]+=q;pipe[finish].append((p,q));job['q']-=q
                starts.append(dict(day=t,date=today,ProductID=p,quantity=q,created_day=job['created'],receipt_day=finish,request_id=job['id'],lots=1))
            queue=[j for j in queue if j['q']]
        # Bước 6: kiểm tra bảo toàn vật tư, WIP và yêu cầu chờ trước khi ghi cuối ngày.
        queueqty=Counter()
        for j in queue:queueqty[j['p']]+=j['q']
        for p in ids:
            assert inv[p]==initial[p]+received[p]-sold[p]-used[p] and inv[p]>=0
            assert wip[p]==(requested[p] if family=='refill' else started[p])-received[p] and wip[p]>=0
            assert family=='refill' or requested[p]==started[p]+queueqty[p]
            ledger.append(dict(day=t,date=today,ProductID=p,inventory=inv[p],pipeline=wip[p],queued=queueqty[p],received=arrive[p],sold=sales[p],consumed=consume[p],started=startqty[p],requested=req[p]))
        outstanding=[o for pp in roots for o in book[pp]]
        # Các value_* dưới đây là định giá lịch sử của engine. Định giá cập nhật 238 mã và WIP
        # được tính lại bởi run.py:valuation(), từ ledger và cost_basis.json.
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
    return dict(states=states,daily=daily,ledger=ledger,starts=starts,requests=requests,delivery=delivery,consumption=consumption,receipts=receipt_log,queue=queue)

# Tổng hợp trên window. Đơn thuộc nhóm đánh giá khi DueDate nằm trong cửa sổ.
# OTU tính theo số đơn vị giao đúng hạn, UD tính số đơn vị còn thiếu nhân số ngày.
# Tồn và WIP lấy bình quân các trạng thái cuối ngày, không bình quân theo số dòng đơn.
def metrics(z,spec,params,window):
    a,b=dt(window['start']),dt(window['end']);daily=[x for x in z['daily'] if a<=dt(x['date'])<=b]
    # Nhóm đơn được chọn theo DueDate. Dòng giao nhiều lần vẫn chỉ có một tổng nhu cầu.
    cohort={o['id']:o for o in z['states'] if a<=o['due']<=b};deliveries=defaultdict(list)
    for x in z['delivery']:
        if dt(x['date'])<=b:deliveries[x['id']].append(x)
    total=sum(o['q'] for o in cohort.values());on=late=short=0;complete=0
    for i,o in cohort.items():
        dd=deliveries[i];ontime=sum(x['quantity'] for x in dd if dt(x['date'])<=o['due']);on+=ontime;complete+=ontime==o['q']
        remaining=o['q']-sum(x['quantity'] for x in dd);short+=remaining
        # UD cộng thời gian chờ theo từng lượng giao. Phần chưa giao tính tới hết ngày cuối,
        # vì vậy dùng b+1 cho phần còn thiếu, tránh mất một ngày thiếu của cuối kỳ.
        late+=sum(x['quantity']*max(0,(dt(x['date'])-max(a,o['due'])).days) for x in dd)
        late+=remaining*max(0,(b+timedelta(days=1)-max(a,o['due'])).days)
    # Lấy bình quân chỉ tiêu ngày, giữ None nếu chỉ tiêu không áp dụng cho family này.
    def mean(k):return sum(x[k] for x in daily)/len(daily) if daily[0][k] is not None else None
    initial190=sum(x['initial'] for x in params.values() if x['root'])
    return dict(scenario=spec['name'],family=spec['family'],policy=spec['policy'],timing=spec['timing'],lead_mode=spec['lead_mode'],window=window['name'],window_start=a,window_end=b,days=len(daily),
        due_lines=len(cohort),due_demand_units=total,on_time_units=on,on_time_unit_rate=on/total if total else None,on_time_complete_line_rate=complete/len(cohort) if cohort else None,
        late_unit_days=late,end_unfulfilled_due_units=short,
        initial_inventory_sales190=initial190,initial_inventory_all=sum(x['initial'] for x in params.values()) if spec['family']=='bom' else initial190,
        mean_inventory_sales190=mean('inventory_sales190'),mean_inventory_all_modeled=mean('inventory_all_modeled'),
        mean_WIP_all=mean('WIP_all'),mean_pending_refill=mean('pending_refill'),mean_queue=mean('queue'),
        mean_value_sales190=mean('value_sales190'),mean_value_all_known=mean('value_all_known'),mean_unvalued_stock=mean('unvalued_stock'),
        mean_inventory_roots_without_window_demand=mean('inventory_roots_without_window_demand'),
        received_units=sum(x['received'] for x in daily),started_units=sum(x['started'] for x in daily),requested_units=sum(x['requested'] for x in daily),
        terminal_inventory_sales190=daily[-1]['inventory_sales190'],terminal_inventory_all_modeled=daily[-1]['inventory_all_modeled'],
        terminal_WIP_all=daily[-1]['WIP_all'],terminal_pending_refill=daily[-1]['pending_refill'],terminal_queue=daily[-1]['queue'])

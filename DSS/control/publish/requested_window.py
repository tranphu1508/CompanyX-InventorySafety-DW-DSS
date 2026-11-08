"""Bind a requested interval to verified warehouse runs; never alter source runs."""
from __future__ import annotations
from datetime import date,datetime
from decimal import Decimal
from pathlib import Path
import json
from common import PROJECT,read,save,stamp
from cache_identity import canonical,digest,verify_identity
from publish.publisher import CONNECTION
from publish.operation_gate import publish_operation_gate

def connect():
    import pyodbc
    return pyodbc.connect(CONNECTION,autocommit=False,timeout=15)

def publish_window(folder,assignments,*,project_root=None):
    # Registry/window changes share the warehouse snapshot gate used by cube
    # processing. Individual candidate/detail publications finish before this.
    with publish_operation_gate():
        return _publish_window(folder,assignments,project_root=project_root)


def _publish_window(folder,assignments,*,project_root=None):
    folder=Path(folder).resolve();project=Path(project_root).resolve() if project_root else PROJECT
    if not folder.is_relative_to(project/'_local'):raise ValueError('Window folder must be under GPT')
    request=read(folder/'request.json');identity=verify_identity(read(folder/'cache_identity.json'))
    metadata=read(folder/'metadata.json');plan=read(folder/'cache_plan.json')
    if folder.name!=request['request_id']:raise ValueError('Window request path mismatch')
    expected={c['candidate_id'] for c in request['candidates']}
    if {r['candidate_id'] for r in assignments}!=expected or len(assignments)!=len(expected):raise ValueError('Window needs exactly one source for each candidate')
    conn=connect()
    try:
        conn.timeout=120;cur=conn.cursor()
        cur.execute("SET XACT_ABORT ON; IF DB_NAME()<>'CompanyX_DW_SIM_20261107' THROW 51000,'Wrong database',1;")
        cur.execute("DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=?,@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=60000; IF @r<0 THROW 51000,'Window lock failed',1;",'companyx.control.window.'+request['request_id'])
        requesthash=digest(request);record=cur.execute('SELECT WindowKey,RequestHash,FamilyHash FROM cxcontrol.RequestedWindow WHERE WindowID=?',request['request_id']).fetchone()
        if record:
            if record.RequestHash!=requesthash or record.FamilyHash!=identity['family_hash']:raise ValueError('Existing window identity differs')
            windowkey=record.WindowKey
        else:
            windowkey=cur.execute('''INSERT cxcontrol.RequestedWindow(WindowID,FamilyHash,KnownAt,AnalysisEnd,Purpose,CacheAction,RequestHash,RequestJSON)
              OUTPUT INSERTED.WindowKey VALUES(?,?,?,?,?,?,?,?)''',request['request_id'],identity['family_hash'],request['known_at'],request['analysis_end'],metadata['purpose'],plan['action'],requesthash,canonical(request)).fetchone()[0]
        for item in assignments:
            key=int(item['PlanningRunKey']);cid=item['candidate_id']
            record=cur.execute('''SELECT e.CoveredEnd,c.CandidateKey FROM cxcontrol.VerifiedCoverageExecution e
               JOIN cxcontrol.Candidate c ON c.PlanningRunKey=e.PlanningRunKey
               WHERE e.PlanningRunKey=? AND e.FamilyHash=? AND e.CandidateID=? AND e.KnownAt=? AND e.Purpose=?''',
               key,identity['family_hash'],cid,request['known_at'],metadata['purpose']).fetchone()
            if not record or record.CoveredEnd.isoformat()<request['analysis_end']:raise ValueError('Source run is not verified, compatible or covering the requested interval')
            previous=cur.execute('SELECT PlanningRunKey,CandidateKey,CacheAction,SourceEnd FROM cxcontrol.WindowCandidate WHERE WindowKey=? AND CandidateID=?',windowkey,cid).fetchone()
            if previous:
                if (previous.PlanningRunKey,previous.CandidateKey,previous.CacheAction,previous.SourceEnd)!=(key,record.CandidateKey,item['cache_action'],record.CoveredEnd):raise ValueError('Existing source binding differs')
            else:cur.execute('INSERT cxcontrol.WindowCandidate(WindowKey,CandidateKey,PlanningRunKey,CandidateID,CacheAction,SourceEnd) VALUES(?,?,?,?,?,?)',windowkey,record.CandidateKey,key,cid,item['cache_action'],record.CoveredEnd)
        if cur.execute('SELECT COUNT(*) FROM cxcontrol.WindowCandidate WHERE WindowKey=?',windowkey).fetchone()[0]!=len(expected):raise ValueError('Unexpected window member count')
        conn.commit()
        receipt={'schema':'companyx.requested.window.publication.v1','status':'PUBLISHED','WindowID':request['request_id'],'WindowKey':windowkey,
                 'request_hash':requesthash,'family_hash':identity['family_hash'],'assignments':assignments,'at':stamp()}
        save(folder/'window_publication_receipt.json',receipt);return receipt
    except BaseException:
        conn.rollback();raise
    finally:conn.close()

def _value(v):
    if isinstance(v,(date,datetime)):return v.isoformat()
    if isinstance(v,Decimal):return float(v)
    return v

def _rows(cursor,sql,*args):
    cursor.execute(sql,*args);names=[x[0] for x in cursor.description]
    return [{k:_value(v) for k,v in zip(names,row)} for row in cursor.fetchall()]

def read_results(window_id):
    conn=connect()
    try:
        conn.timeout=180;cur=conn.cursor()
        windows=_rows(cur,'SELECT WindowKey,WindowID,KnownAt,AnalysisEnd,CacheAction,Purpose,RequestJSON FROM cxcontrol.RequestedWindow WHERE WindowID=?',window_id)
        if len(windows)!=1:raise ValueError('Requested window was not published')
        w=windows[0];key=w['WindowKey'];request=json.loads(w['RequestJSON'])
        summaries=_rows(cur,'''SELECT f.*,c.CandidateID,c.CacheAction,c.SourceEnd FROM cxcontrol.FactRequestedWindowSummary f
          JOIN cxcontrol.WindowCandidate c ON c.WindowKey=f.WindowKey AND c.CandidateKey=f.CandidateKey WHERE f.WindowKey=?''',key)
        lines=_rows(cur,'''SELECT f.*,p.ProductID FROM cxcontrol.FactRequestedWindowLine f
          JOIN dw.Dim_Product p ON p.ProductKey=f.ProductKey WHERE f.WindowKey=?''',key)
        tranches=_rows(cur,'SELECT f.*,t.TrancheNumber,t.DueDate FROM cxcontrol.FactRequestedWindowTranche f JOIN cxcontrol.Tranche t ON t.TrancheKey=f.TrancheKey WHERE f.WindowKey=?',key)
        original=_rows(cur,'''SELECT c.CandidateID,f.CustomerOrderCode,f.SourceSalesOrderID,f.DueAt,
           CASE WHEN f.CompletedAt IS NOT NULL AND CONVERT(date,f.CompletedAt)<=w.AnalysisEnd THEN 'FULFILLED'
           WHEN f.CancelledAt IS NOT NULL AND CONVERT(date,f.CancelledAt)<=w.AnalysisEnd THEN 'LOST' ELSE 'OPEN' END OrderStatus,
           CASE WHEN CONVERT(date,f.CompletedAt)<=w.AnalysisEnd THEN f.CompletedAt END CompletedAt,
           CASE WHEN CONVERT(date,f.CancelledAt)<=w.AnalysisEnd THEN f.CancelledAt END CancelledAt
           FROM cxcontrol.RequestedWindow w JOIN cxcontrol.WindowCandidate c ON c.WindowKey=w.WindowKey
           JOIN dss.Fact_SimulationOrder f ON f.PlanningRunKey=c.PlanningRunKey
           WHERE w.WindowKey=? AND CONVERT(date,f.KnownAt)<=w.AnalysisEnd
           AND NOT EXISTS(SELECT 1 FROM cxcontrol.Tranche t WHERE t.CandidateKey=c.CandidateKey AND t.SourceSalesOrderID=f.SourceSalesOrderID)''',key)
        control={r['CustomerOrderCode']:{k:v for k,v in r.items() if k!='CandidateID'} for r in original if r['CandidateID']=='baseline'}
        output=[]
        for summary in summaries:
            ck=summary['CandidateKey'];cid=summary['CandidateID'];candidate_tranches=[r for r in tranches if r['CandidateKey']==ck]
            changes=[]
            for r in original:
                if r['CandidateID']!=cid:continue
                after={k:v for k,v in r.items() if k!='CandidateID'};before=control.get(r['CustomerOrderCode'])
                if before!=after:changes.append({'order':r['CustomerOrderCode'],'without_inquiry':before,'with_inquiry':after})
            output.append({'candidate_id':cid,'source_run_key':summary['PlanningRunKey'],'cache_action':summary['CacheAction'],
                           'source_end':summary['SourceEnd'],'metrics':summary,'lines':[r for r in lines if r['CandidateKey']==ck],
                           'tranches':candidate_tranches,'existing_commitment_changes_vs_milp_control':changes,
                           'tested_offer_meets_deadlines':bool(candidate_tranches) and all(r['OnTimeCompleteTrancheCount']==1 for r in candidate_tranches)})
        return {'schema':'companyx.requested.window.result.v1','request_id':window_id,'status':'PROCESSED',
                'result_scope':{'start':w['KnownAt'],'end':w['AnalysisEnd'],'as_of_end':w['AnalysisEnd']},
                'comparison_context':{'initialization_mode':request['initialization_mode'],
                    'initial_stock_rule':request['initial_stock_rule'],'rop_reference_run_key':request['base_run_key'],
                    'note':('Các nhánh MILP tiếp nối cùng trạng thái ROP tại ngày bắt đầu. Chênh lệch là kết quả của đường mô phỏng này, chưa phải ước lượng xác suất.'
                        if request['initialization_mode']=='BASELINE_AT_START' else
                        'Các nhánh MILP khởi tạo một thí nghiệm mới. ROP tham chiếu tiếp tục lịch sử từ 2011, nên trạng thái đầu kỳ và cam kết có thể khác; chênh lệch với ROP không tách riêng tác động của chính sách.')},
                'cache':{'action':w['CacheAction']},'window_results':output,
                'interpretation':'Kết quả chỉ đến ngày kết thúc đã chọn. Các phương án được kiểm thử trên một đường mô phỏng; chưa giao được không chứng minh bất khả thi.'}
    finally:conn.close()

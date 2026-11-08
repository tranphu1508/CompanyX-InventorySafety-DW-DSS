"""Active procurement scope for the owned cube; historical facts stay immutable."""
from pathlib import Path
from datetime import datetime,timezone
from contextlib import nullcontext
import argparse,base64,gzip,hashlib,json,sys
import pyodbc
PROJECT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(PROJECT/'DSS/control'))
from active_scope import read_active_scope
from publish.publisher import CONNECTION,sha
from publish.operation_gate import publish_operation_gate

FACT_SOURCES={
 'FactSimulationDaily':'cxcontrol','FactOrderLineService':'cxcontrol','FactOrderService':'cxolap',
 'FactSolveAudit':'cxolap','FactRunDay':'cxcontrol','FactRunSummary':'cxolap',
 'FactInquiryLineDelivery':'cxcontrol','FactInquiryTranche':'cxcontrol','FactProductionActivity':'cxcontrol',
 'FactBaselineActivity':'cxcontrol','FactInquiryWindowSummary':'cxcontrol','FactRequestedWindowSummary':'cxcontrol',
 'FactRequestedWindowLine':'cxcontrol','FactRequestedWindowTranche':'cxcontrol'}
PASS_DIMENSIONS=['DimDate','DimProduct','DimLocation','DimUnit','DimEvaluationCohort','DimOrderStatus','DimSolveStatus']
SCHEMA_SQL="""
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Requires owned warehouse copy',1;
IF SCHEMA_ID('cxactive') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=3 AND major_id=SCHEMA_ID('cxactive') AND name='CompanyXControlOwner' AND CONVERT(nvarchar(100),value)='companyx-control-20261105') THROW 51000,'Unowned active schema',1;
IF SCHEMA_ID('cxactive') IS NULL BEGIN
 EXEC('CREATE SCHEMA cxactive AUTHORIZATION dbo');
 EXEC sys.sp_addextendedproperty @name='CompanyXControlOwner',@value='companyx-control-20261105',@level0type='SCHEMA',@level0name='cxactive';
END;
IF OBJECT_ID('cxactive.ScopePolicy','U') IS NULL CREATE TABLE cxactive.ScopePolicy(
 ScopeKey int NOT NULL PRIMARY KEY CHECK(ScopeKey=1),PolicyHash char(64) NOT NULL,PolicyID nvarchar(200) NOT NULL,
 PolicyJSON nvarchar(max) NOT NULL CHECK(ISJSON(PolicyJSON)=1),AppliedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
IF OBJECT_ID('cxactive.RunScopeDecision','U') IS NULL CREATE TABLE cxactive.RunScopeDecision(
 PolicyHash char(64) NOT NULL,PlanningRunKey int NOT NULL REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 ExecutionSpecHash char(64) NOT NULL REFERENCES dss.ArtifactObject(ArtifactHash),SupplyMode nvarchar(60) NOT NULL,
 AllowBackorders bit NOT NULL,IsActive bit NOT NULL,VerifiedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
 PRIMARY KEY(PolicyHash,PlanningRunKey));
"""

def view_definitions():
    views={'ActiveRunScope':"SELECT d.PlanningRunKey,d.ExecutionSpecHash,d.SupplyMode,d.AllowBackorders,d.PolicyHash FROM cxactive.RunScopeDecision d JOIN cxactive.ScopePolicy p ON p.PolicyHash=d.PolicyHash AND p.ScopeKey=1 JOIN cxdetail.RunDetail ready ON ready.PlanningRunKey=d.PlanningRunKey AND ready.ContractVersion='companyx.execution-detail.v1' WHERE d.IsActive=1"}
    views['DimRun']='SELECT r.* FROM cxcontrol.DimControlRun r JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=r.PlanningRunKey'
    views.update({name:'SELECT * FROM cxolap.'+name for name in PASS_DIMENSIONS})
    views['DimActivity']='SELECT * FROM cxcontrol.DimActivity'
    views['DimSolveKey']='SELECT d.* FROM cxolap.DimSolveKey d JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=d.PlanningRunKey'
    views['DimCandidate']='SELECT d.* FROM cxcontrol.DimCandidate d JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=d.PlanningRunKey'
    views['DimInquiry']='SELECT d.* FROM cxcontrol.DimInquiry d WHERE EXISTS(SELECT 1 FROM cxactive.DimCandidate c WHERE c.InquiryKey=d.InquiryKey)'
    views['DimTranche']='SELECT d.* FROM cxcontrol.DimTranche d JOIN cxactive.DimCandidate c ON c.CandidateKey=d.CandidateKey'
    views['DimRequestedWindow']='SELECT d.* FROM cxcontrol.DimRequestedWindow d WHERE EXISTS(SELECT 1 FROM cxcontrol.WindowCandidate c JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=c.PlanningRunKey WHERE c.WindowKey=d.WindowKey)'
    views['DimBaseline']='SELECT d.* FROM cxcontrol.DimBaseline d JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=d.PlanningRunKey'
    views['VerifiedCoverageExecution']='SELECT d.* FROM cxcontrol.VerifiedCoverageExecution d JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=d.PlanningRunKey'
    for name,source in FACT_SOURCES.items():
        views[name]='SELECT f.* FROM '+source+'.'+name+' f JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=f.PlanningRunKey'
    views['FactRunSummary']='SELECT f.*,r.HoldingCostRatePerYear FROM cxolap.FactRunSummary f JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=f.PlanningRunKey JOIN cxolap.DimRun r ON r.PlanningRunKey=f.PlanningRunKey'
    return {name:'CREATE OR ALTER VIEW cxactive.'+name+' AS\n'+select+';' for name,select in views.items()}

def classify_specs(conn,policy):
    cur=conn.execute('SELECT r.PlanningRunKey,r.ExecutionSpecHash,a.Encoding,a.PayloadBase64 FROM dss.Dim_PlanningRun r JOIN cxolap.DimRun e ON e.PlanningRunKey=r.PlanningRunKey LEFT JOIN dss.ArtifactObject a ON a.ArtifactHash=r.ExecutionSpecHash ORDER BY r.PlanningRunKey')
    rows=[]
    for key,expected,encoding,payload in cur:
        if encoding!='GZIP_JSON_UTF8_BASE64' or not payload:raise ValueError('Missing authoritative spec: '+str(key))
        raw=gzip.decompress(base64.b64decode(payload,validate=True))
        if hashlib.sha256(raw).hexdigest()!=expected:raise ValueError('Authoritative execution spec SHA differs: '+str(key))
        spec=json.loads(raw.decode('utf-8'));mode=spec['supply']['mode'];backorders=spec['allow_backorders']
        if not isinstance(mode,str) or not isinstance(backorders,bool):raise ValueError('Invalid supply-mode spec types')
        rows.append({'PlanningRunKey':key,'ExecutionSpecHash':expected,'SupplyMode':mode,'AllowBackorders':backorders,'IsActive':mode==policy['required_supply_mode']})
    return rows

def refresh_active_cube_scope(output_file,*,project_root=None,gate_held=False):
    project=Path(project_root).resolve() if project_root else PROJECT
    output_file=Path(output_file).resolve();output_file.relative_to(project/'_local')
    if output_file.exists():raise ValueError('Scope receipt must be new')
    policy=read_active_scope(project);policy_path=project/'RuntimeData/active-scope.json';policy_hash=sha(policy_path)
    gate=nullcontext({'caller_holds_gate':True}) if gate_held else publish_operation_gate()
    with gate as gate_receipt:
        with pyodbc.connect(CONNECTION,autocommit=False,timeout=15) as conn:
            conn.timeout=180
            rows=classify_specs(conn,policy)
            conn.execute(SCHEMA_SQL)
            for row in rows:
                values=(row['ExecutionSpecHash'],row['SupplyMode'],row['AllowBackorders'],row['IsActive'])
                old=conn.execute('SELECT ExecutionSpecHash,SupplyMode,AllowBackorders,IsActive FROM cxactive.RunScopeDecision WHERE PolicyHash=? AND PlanningRunKey=?',policy_hash,row['PlanningRunKey']).fetchone()
                if old is not None and tuple(old)!=values:raise ValueError('Previously attested run semantics changed')
                if old is None:conn.execute('INSERT cxactive.RunScopeDecision(PolicyHash,PlanningRunKey,ExecutionSpecHash,SupplyMode,AllowBackorders,IsActive) VALUES(?,?,?,?,?,?)',policy_hash,row['PlanningRunKey'],*values)
            conn.execute('IF EXISTS(SELECT 1 FROM cxactive.ScopePolicy WHERE ScopeKey=1) UPDATE cxactive.ScopePolicy SET PolicyHash=?,PolicyID=?,PolicyJSON=?,AppliedAt=SYSUTCDATETIME() WHERE ScopeKey=1 ELSE INSERT cxactive.ScopePolicy(ScopeKey,PolicyHash,PolicyID,PolicyJSON) VALUES(1,?,?,?)',policy_hash,policy['policy_id'],json.dumps(policy,ensure_ascii=False),policy_hash,policy['policy_id'],json.dumps(policy,ensure_ascii=False))
            for statement in view_definitions().values():conn.execute(statement)
            conn.execute('GRANT SELECT ON SCHEMA::cxactive TO [CompanyXMOLAPReader]')
            actual=[r[0] for r in conn.execute('SELECT PlanningRunKey FROM cxactive.ActiveRunScope ORDER BY PlanningRunKey')]
            detail_ready={int(r[0]) for r in conn.execute("SELECT PlanningRunKey FROM cxdetail.RunDetail WHERE ContractVersion='companyx.execution-detail.v1'")}
            expected=[r['PlanningRunKey'] for r in rows if r['IsActive'] and r['PlanningRunKey'] in detail_ready]
            if actual!=expected:raise ValueError('Active run scope differs from verified execution specs')
            if sha(policy_path)!=policy_hash:raise ValueError('Active policy changed during refresh')
            conn.commit()
    result={'schema':'companyx.active-cube-scope.v1','status':'VERIFIED','at':datetime.now(timezone.utc).isoformat(),'policy_id':policy['policy_id'],'policy_sha256':policy_hash,'active_run_keys':expected,'retired_run_keys':[r['PlanningRunKey'] for r in rows if not r['IsActive']],'detail_ineligible_run_keys':[r['PlanningRunKey'] for r in rows if r['IsActive'] and r['PlanningRunKey'] not in detail_ready],'required_detail_contract':'companyx.execution-detail.v1','decisions':rows,'gate':gate_receipt,'historical_facts_modified':False,'production_duration_policy':'PRESERVE_EXISTING'}
    output_file.parent.mkdir(parents=True,exist_ok=True);output_file.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
    return result

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--output',required=True,type=Path);p.add_argument('--gate-held',action='store_true');args=p.parse_args()
    result=refresh_active_cube_scope(args.output,gate_held=args.gate_held)
    print(json.dumps({k:result[k] for k in ('status','policy_id','active_run_keys','retired_run_keys')}))

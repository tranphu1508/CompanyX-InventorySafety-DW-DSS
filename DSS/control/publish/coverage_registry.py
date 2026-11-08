"""Register only verified, published checkpoint executions for warehouse reuse."""
from datetime import datetime,timezone
from pathlib import Path
import json
from .publisher import CONNECTION,read,sha,canonical,immutable_write
from .operation_gate import publish_operation_gate


def register_cache_execution(artifact_folder,identity,*,project_root=None):
    import pyodbc
    from cache_identity import verify_identity,build_identity
    from .continuation_storage import verify_stored_continuation
    from .inquiry_purpose import build_publication_purpose
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    folder=Path(artifact_folder).resolve();verify_identity(identity)
    verified=verify_stored_continuation(folder,project_root=project)
    receipt=verified['continuation']['receipt'];scope=verified['prepared']['scope'];request=verified['prepared']['request']
    purpose=build_publication_purpose(folder,project_root=project)
    if read(folder/'publication_purpose.json')!=purpose:
        raise ValueError('Owned job purpose metadata changed after publication.')
    if read(folder.parents[2]/'cache_identity.json')!=identity:
        raise ValueError('Coverage identity differs from the owned job identity.')
    expected=build_identity(request,purpose['purpose'],project_root=project,executor_hash=receipt['effective_executor_hash'])
    if expected!=identity or receipt['family_hash']!=identity['family_hash']:
        raise ValueError('Coverage family does not reproduce from the actual source/configuration/executor.')
    published=read(folder/'publication_receipt.json');run_doc=read(folder/'run.json')
    if (published.get('status') not in ('LOADED','ALREADY_LOADED') or published.get('RunStatus')!='SUCCEEDED'
        or published.get('database')!='CompanyX_DW_SIM_20261107' or published.get('RunCode')!=run_doc['RunCode']
        or published.get('publication_purpose_sha256')!=sha(folder/'publication_purpose.json')):
        raise ValueError('Successful exact V2 publication is required for cache registration.')
    entry=dict(PlanningRunKey=published['PlanningRunKey'],FamilyHash=identity['family_hash'],CandidateID=scope['candidate_id'],
        SourceRequestID=request['request_id'],ArtifactFolder=str(folder),KnownAt=receipt['known_at'],CoveredEnd=receipt['covered_end'],
        CheckpointHash=receipt['checkpoint']['sha256'],ExecutorHash=receipt['effective_executor_hash'],
        FamilyJSON=canonical(identity['family_contract']),Purpose=purpose['purpose'],ParentRunKey=None,
        VerificationHash=sha(folder/'continuation_storage_receipt.json'))
    with publish_operation_gate(),pyodbc.connect(CONNECTION,autocommit=False,timeout=15) as conn:
        conn.timeout=60;cur=conn.cursor()
        cur.execute("SET XACT_ABORT ON; IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Requires owned source copy',1;")
        cur.execute("""SELECT r.PlanningRunKey FROM cxolap.DimRun r
        JOIN cxcontrol.Candidate c ON c.PlanningRunKey=r.PlanningRunKey
        JOIN cxcontrol.InquiryPurpose p ON p.InquiryKey=c.InquiryKey
        JOIN cxcontrol.InquiryPublication ip ON ip.PlanningRunKey=r.PlanningRunKey
        LEFT JOIN cxcontrol.CandidateRequestIdentity cri ON cri.PlanningRunKey=r.PlanningRunKey
        WHERE r.PlanningRunKey=? AND r.RunCode=? AND c.CandidateID=?
          AND JSON_VALUE(c.ScopeJSON,'$.request_id')=? AND p.Purpose=?
          AND ((cri.PlanningRunKey IS NOT NULL AND cri.InquiryKey=c.InquiryKey
                AND cri.PurposeBindingHash=? AND cri.RequestFileHash=? AND cri.CanonicalRequestHash=? AND cri.MetadataHash=p.MetadataHash)
               OR (cri.PlanningRunKey IS NULL AND p.BindingHash=?))
          AND ip.ArtifactFolder=? AND ip.ProjectionHash=? AND ip.ArchiveHash=?
          AND JSON_VALUE(c.ScopeJSON,'$.known_at')=? AND JSON_VALUE(c.ScopeJSON,'$.analysis_end')=?""",
          entry['PlanningRunKey'],run_doc['RunCode'],entry['CandidateID'],entry['SourceRequestID'],entry['Purpose'],
          sha(folder/'publication_purpose.json'),sha(folder/'request.json'),purpose['request_canonical_sha256'],
          sha(folder/'publication_purpose.json'),str(folder),sha(folder/'inquiry_projection.json'),
          read(folder/'inquiry_archive_manifest.json')['archive_sha256'],entry['KnownAt'],entry['CoveredEnd'])
        if len(cur.fetchall())!=1:raise ValueError('SQL run is not exactly published/succeeded/passed for this verified cache artifact.')
        if receipt['parent'] is not None:
            parent=receipt['parent']
            cur.execute("""SELECT ce.PlanningRunKey FROM cxcontrol.VerifiedCoverageExecution ce
            JOIN dss.Dim_PlanningRun r ON r.PlanningRunKey=ce.PlanningRunKey
            WHERE r.RunCode=? AND ce.FamilyHash=? AND ce.CandidateID=? AND ce.KnownAt=?
              AND ce.CoveredEnd=? AND ce.CoveredEnd<? AND ce.CheckpointHash=? AND ce.ExecutorHash=?
              AND ce.ArtifactFolder=? AND ce.Purpose=?""",parent['run_code'],entry['FamilyHash'],entry['CandidateID'],entry['KnownAt'],
              parent['covered_end'],entry['CoveredEnd'],parent['checkpoint_sha256'],entry['ExecutorHash'],parent['artifact_folder'],entry['Purpose'])
            parents=cur.fetchall()
            if len(parents)!=1:raise ValueError('Continuation parent is not a verified published member of the same cache family.')
            entry['ParentRunKey']=parents[0][0]
        columns=list(entry)
        cur.execute('SELECT '+','.join(columns)+' FROM cxcontrol.CoverageExecution WITH(UPDLOCK,HOLDLOCK) WHERE PlanningRunKey=?',entry['PlanningRunKey'])
        old=cur.fetchone();status='ALREADY_REGISTERED' if old else 'REGISTERED'
        if old:
            actual=dict(zip(columns,old))
            for key in ('KnownAt','CoveredEnd'):actual[key]=actual[key].isoformat()
            if actual!=entry:raise ValueError('Existing immutable coverage registration differs.')
        else:
            cur.execute('INSERT cxcontrol.CoverageExecution('+','.join(columns)+') VALUES('+','.join('?' for _ in columns)+')',*entry.values())
        cur.execute('SELECT * FROM cxcontrol.VerifiedCoverageExecution WHERE PlanningRunKey=?',entry['PlanningRunKey'])
        names=[x[0] for x in cur.description];row=cur.fetchone()
        if row is None:raise ValueError('New cache registry record failed eligibility view.')
        record=dict(zip(names,row));conn.commit()
    result=dict(schema='companyx.coverage.registration.v1',status=status,record=record,registered_at=datetime.now(timezone.utc).isoformat())
    target=folder/'coverage_registration_receipt.json'
    if target.exists():
        target=folder/'coverage_registration_attempts'/(datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.json');target.parent.mkdir(exist_ok=True)
    immutable_write(target,json.dumps(result,ensure_ascii=False,indent=2,default=str))
    return result

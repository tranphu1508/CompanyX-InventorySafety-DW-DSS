"""Bind V2 publication purpose to the controller's owned job metadata."""
from datetime import datetime
import hashlib,json,re
from pathlib import Path


def _read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def _canonical(value):
    return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False,allow_nan=False)


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_publication_purpose(artifact_folder,*,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[4]
    folder=Path(artifact_folder).resolve()
    request=_read(folder/'request.json');scope=_read(folder/'scope.json')
    request_id=request.get('request_id');candidate_id=scope.get('candidate_id')
    if any(not isinstance(value,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',value)
           for value in (request_id,candidate_id)):
        raise ValueError('Invalid owned job/candidate identity for purpose binding.')
    job=(project/'GPT/output/companyx-split-20261107/runs'/request_id).resolve()
    expected=job/'candidates'/candidate_id/'artifacts'
    if folder!=expected.resolve() or not folder.is_relative_to(job):
        raise ValueError('Purpose metadata requires the exact owned job/candidate artifact path.')
    parent_request=_read(job/'request.json');metadata=_read(job/'metadata.json')
    if (request.get('schema')!='companyx.inquiry.request.v2'
        or scope.get('schema')!='companyx.inquiry.scope.v2'
        or scope.get('request_id')!=request_id or scope.get('inquiry_id')!=request.get('inquiry_id')
        or not request.get('inquiry_id') or _canonical(parent_request)!=_canonical(request)
        or _canonical(scope.get('request'))!=_canonical(request)):
        raise ValueError('Parent request, candidate request and scope must match for purpose binding.')
    if sum(c.get('candidate_id')==candidate_id for c in request.get('candidates',[]))!=1:
        raise ValueError('Candidate must occur exactly once in its owned request.')
    if (metadata.get('schema')!='companyx.inquiry.metadata.v2'
        or metadata.get('purpose') not in ('ORDER_INQUIRY','PIPELINE_SMOKE')
        or not isinstance(metadata.get('request_payload_sha256'),str)
        or not re.fullmatch(r'[0-9a-f]{64}',metadata['request_payload_sha256'])):
        raise ValueError('Explicit validated controller metadata purpose is required.')
    try:
        created=datetime.fromisoformat(metadata['created_at'].replace('Z','+00:00'))
    except (KeyError,AttributeError,ValueError,TypeError) as exc:
        raise ValueError('Controller metadata timestamp is invalid.') from exc
    if created.tzinfo is None:
        raise ValueError('Controller metadata timestamp must include its timezone.')
    return dict(schema='companyx.inquiry.publication_purpose.v1',purpose=metadata['purpose'],
        request_id=request_id,inquiry_id=request['inquiry_id'],job_folder=str(job),
        request_file_sha256=_sha(folder/'request.json'),parent_request_file_sha256=_sha(job/'request.json'),
        request_canonical_sha256=hashlib.sha256(_canonical(request).encode('utf-8')).hexdigest(),
        metadata_file_sha256=_sha(job/'metadata.json'),metadata=metadata,
        purpose_source='OWNED_JOB_METADATA_V2')

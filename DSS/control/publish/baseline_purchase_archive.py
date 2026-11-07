"""Exact ZIP storage for verified baseline/inquiry NPZ; index.json stays in place."""
from contextlib import contextmanager
from datetime import datetime,timezone
import hashlib,io,json,os,re,shutil,zipfile
from pathlib import Path
from .baseline_archive import _scope,_member,_save,read,sha

MANIFEST='purchase_members.jsonl'


def _name(value):
    if not isinstance(value,str) or not re.fullmatch(r'(order|receipt)_[0-9]+\.npz',value):
        raise ValueError('Unsafe purchase NPZ member name.')
    return value


def verify_purchase_archive(folder,*,project_root=None):
    _,folder=_scope(folder,project_root);record=read(folder/'purchase_archive_manifest.json')
    if record.get('schema') not in ('companyx.baseline.purchase_archive.v1','companyx.inquiry.purchase_archive.v1') or record['RunCode']!=read(folder/'run.json')['RunCode']:
        raise ValueError('Purchase archive identity mismatch.')
    if (sha(_member(folder,record['archive_file']))!=record['archive_sha256']
        or sha(folder/'purchase_events/index.json')!=record['purchase_index_sha256']):
        raise ValueError('Purchase archive or original index changed.')
    if record['schema']=='companyx.inquiry.purchase_archive.v1':
        for field,name in [('storage_receipt_sha256','inquiry_storage_receipt.json'),
                           ('continuation_attestation_sha256','continuation_storage_attestation.json'),
                           ('continuation_receipt_sha256','continuation_receipt.json')]:
            if record.get(field)!=sha(folder/name):raise ValueError('Inquiry purchase archive verification lineage changed.')
    return record


def archive_purchase_events(folder,*,project_root=None,progress=None):
    project,folder=_scope(folder,project_root);purchase=folder/'purchase_events'
    if not purchase.exists():return {'status':'NOT_APPLICABLE','npz_count':0}
    receipt=read(folder/'baseline_publication_receipt.json');run=read(folder/'run.json')
    if (receipt.get('schema')!='companyx.baseline.publication.v1'
        or receipt.get('status') not in ('LOADED','ALREADY_LOADED')
        or receipt.get('database')!='CompanyX_MOLAP_Source_20261105'
        or receipt.get('verification_status')!='PASSED' or receipt.get('RunStatus')!='SUCCEEDED'
        or receipt.get('RunCode')!=run['RunCode']):raise ValueError('Verified baseline publication is required.')
    return _archive_verified_npz(folder,project_root=project,progress=progress,
        archive_schema='companyx.baseline.purchase_archive.v1',planning_run_key=receipt['PlanningRunKey'],provenance={})


def _validate_inquiry_storage(folder,project):
    from .inquiry_storage import verify_stored_inquiry
    from .continuation_storage import _verified_continuation,_attestation
    verified=verify_stored_inquiry(folder,project_root=project)
    continuation=_verified_continuation(folder,project)
    if read(folder/'continuation_storage_attestation.json')!=_attestation(folder,continuation):
        raise ValueError('Verified continuation attestation is required for inquiry purchase archival.')
    if verified['storage_receipt']['status']!='VERIFIED_UNPUBLISHED':raise ValueError('Verified inquiry raw storage receipt is required.')
    return {field:sha(folder/name) for field,name in [('storage_receipt_sha256','inquiry_storage_receipt.json'),
        ('continuation_attestation_sha256','continuation_storage_attestation.json'),('continuation_receipt_sha256','continuation_receipt.json')]}


def archive_inquiry_purchase_events(folder,*,project_root=None,progress=None):
    project,folder=_scope(folder,project_root);purchase=folder/'purchase_events'
    if not purchase.exists():return {'status':'NOT_APPLICABLE','npz_count':0}
    provenance=_validate_inquiry_storage(folder,project)
    return _archive_verified_npz(folder,project_root=project,progress=progress,
        archive_schema='companyx.inquiry.purchase_archive.v1',planning_run_key=None,provenance=provenance)


def _archive_verified_npz(folder,*,project_root,progress,archive_schema,planning_run_key,provenance):
    project,folder=_scope(folder,project_root);purchase=folder/'purchase_events';run=read(folder/'run.json')
    if any((folder/name).exists() for name in ('RUNNING.lock','DW_PUBLISH.lock')):raise ValueError('Artifact is still running.')
    marker=folder/'purchase_archive_manifest.json';archive=folder/'purchase_events.zip'
    if marker.exists():
        existing=verify_purchase_archive(folder,project_root=project)
        if existing['schema']!=archive_schema:raise ValueError('Existing purchase archive has a different verification contract.')
        if existing['status']=='ARCHIVED':return existing
        raise ValueError('Partial purchase archive requires inspection; do not overwrite evidence.')
    index=purchase/'index.json'
    if not index.exists():
        if any(purchase.iterdir()):raise ValueError('Purchase files exist without a completed index.')
        return {'status':'NOT_APPLICABLE','npz_count':0}
    index_doc=read(index)
    if index_doc.get('schema')!='lot_arrays_v1':raise ValueError('Unknown purchase index schema.')
    names=[_name(row['file']) for row in index_doc['batches']];del index_doc
    if not names:return {'status':'NOT_APPLICABLE','npz_count':0}
    if len(names)!=len(set(names)):raise ValueError('Duplicate purchase index member.')
    actual=set()
    with os.scandir(purchase) as entries:
        for entry in entries:
            if entry.name=='index.json':continue
            if entry.is_symlink() or not entry.is_file(follow_symlinks=False):raise ValueError('Unexpected purchase directory entry.')
            actual.add(_name(entry.name))
    if actual!=set(names):raise ValueError('Purchase NPZ files differ from the exact index member set.')
    del actual
    pending=folder/'purchase_events.pending.zip';manifest=folder/'purchase_members.pending.jsonl'
    if any(path.exists() for path in (archive,pending,manifest)):raise ValueError('Unregistered purchase archive files already exist.')
    raw_bytes=rounded=0;index_hash=sha(index);manifest_hash=hashlib.sha256()
    # NPZ is already compressed. ZIP_STORED avoids repeated compression while
    # coalescing hundreds of thousands of small NTFS allocations into one file.
    with zipfile.ZipFile(pending,'x',compression=zipfile.ZIP_STORED,allowZip64=True) as zipped,manifest.open('xb') as log:
        for count,name in enumerate(names,1):
            path=_member(purchase,name);stat=path.stat();data=path.read_bytes()
            if len(data)!=stat.st_size:raise ValueError('Purchase file changed while reading.')
            entry={'name':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'mtime_ns':stat.st_mtime_ns}
            zipped.writestr('purchase_events/'+name,data)
            line=(json.dumps(entry,separators=(',',':'))+'\n').encode('utf-8');log.write(line);manifest_hash.update(line)
            raw_bytes+=len(data);rounded+=((len(data)+4095)//4096)*4096
            if count%25000==0:
                event={'stage':'purchase_archived','members':count,'total':len(names),'updated_at':datetime.now(timezone.utc).isoformat()}
                _save(folder/'purchase_archive_progress.json',event)
                if progress:progress(event)
        log.flush();zipped.write(manifest,MANIFEST,compress_type=zipfile.ZIP_DEFLATED,compresslevel=1)
    del names
    checked=0
    with zipfile.ZipFile(pending) as zipped:
        if len(zipped.infolist())!=len(zipped.NameToInfo):raise ValueError('Duplicate ZIP member.')
        digest=hashlib.sha256()
        with zipped.open(MANIFEST) as lines:
            for line in lines:
                digest.update(line);entry=json.loads(line);name=_name(entry['name'])
                data=zipped.read('purchase_events/'+name) # checks CRC independently
                if len(data)!=entry['bytes'] or hashlib.sha256(data).hexdigest()!=entry['sha256']:
                    raise ValueError('Independent purchase NPZ verification failed.')
                path=_member(purchase,name);stat=path.stat()
                if stat.st_size!=entry['bytes'] or stat.st_mtime_ns!=entry['mtime_ns']:
                    raise ValueError('Original purchase NPZ changed after archival.')
                checked+=1
                if checked%25000==0:
                    event={'stage':'purchase_verified','members':checked,'updated_at':datetime.now(timezone.utc).isoformat()}
                    _save(folder/'purchase_archive_progress.json',event)
                    if progress:progress(event)
        if checked+1!=len(zipped.infolist()) or digest.hexdigest()!=manifest_hash.hexdigest():
            raise ValueError('Purchase archive member/manifest mismatch.')
    if sha(index)!=index_hash:raise ValueError('Purchase index changed during archival.')
    pending.rename(archive)
    record=dict(schema=archive_schema,status='VERIFIED_PENDING_RAW_REMOVAL',RunCode=run['RunCode'],
        PlanningRunKey=planning_run_key,archive_file=archive.name,archive_sha256=sha(archive),archive_bytes=archive.stat().st_size,
        npz_count=checked,raw_content_bytes=raw_bytes,rounded_4KiB_clusters_bytes=rounded,
        purchase_index_sha256=index_hash,member_manifest_sha256=manifest_hash.hexdigest(),created_at=datetime.now(timezone.utc).isoformat())
    record.update(provenance)
    _save(marker,record)
    # Manifest already has independent source/decompressed SHA checks. Recheck
    # each contained path's size/mtime immediately before individual removal.
    with manifest.open('rb') as lines:
        for count,line in enumerate(lines,1):
            entry=json.loads(line);path=_member(purchase,_name(entry['name']));stat=path.stat()
            if stat.st_size!=entry['bytes'] or stat.st_mtime_ns!=entry['mtime_ns']:raise ValueError('Purchase file changed; retained.')
            path.unlink()
            if count%25000==0:_save(folder/'purchase_archive_progress.json',{'stage':'verified_originals_removed','members':count,'updated_at':datetime.now(timezone.utc).isoformat()})
    manifest.unlink() # exact verified manifest remains inside the completed ZIP
    record['status']='ARCHIVED';record['raw_removed_at']=datetime.now(timezone.utc).isoformat();_save(marker,record)
    _save(folder/'purchase_archive_progress.json',{'stage':'COMPLETE','members':checked,'updated_at':record['raw_removed_at']})
    return record


@contextmanager
def purchase_archive_reader(folder,*,project_root=None):
    """Verify once and keep ZIP open for efficient bulk historical NPZ access."""
    _,folder=_scope(folder,project_root);record=verify_purchase_archive(folder,project_root=project_root)
    with zipfile.ZipFile(_member(folder,record['archive_file'])) as zipped:
        yield zipped


@contextmanager
def open_purchase_member(folder,relative,*,project_root=None):
    """Yield binary NPZ bytes; for many members prefer purchase_archive_reader."""
    _,folder=_scope(folder,project_root);name=_name(str(relative).replace('\\','/').removeprefix('purchase_events/'))
    path=_member(folder,'purchase_events/'+name)
    if path.exists():
        with path.open('rb') as stream:yield stream
    else:
        with purchase_archive_reader(folder,project_root=project_root) as zipped:
            with zipped.open('purchase_events/'+name) as stream:yield stream

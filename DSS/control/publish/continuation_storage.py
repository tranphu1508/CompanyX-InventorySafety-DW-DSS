"""Extra continuation evidence around the unchanged V2 artifact storage contract."""
from pathlib import Path
import json
from .publisher import read,sha,immutable_write


def _verified_continuation(folder,project):
    from simulation.continuation import verify_continuation_artifact
    return verify_continuation_artifact(folder,project_root=project,verify_core_artifact=False,verify_prefix=True)


def _attestation(folder,verified):
    r=verified['receipt']
    return dict(schema='companyx.continuation.storage.attestation.v1',status='VERIFIED',
        RunCode=r['artifact_run_code'],family_hash=r['family_hash'],effective_executor_hash=r['effective_executor_hash'],
        continuation_receipt_sha256=sha(folder/'continuation_receipt.json'),
        checkpoint_file=r['checkpoint']['file'],checkpoint_sha256=sha(folder/r['checkpoint']['file']),
        table_manifest_sha256=sha(folder/'table_manifest.json'),scope_sha256=sha(folder/'scope.json'),
        known_at=r['known_at'],covered_end=r['covered_end'],mode=r['mode'],parent=r['parent'],
        reused_days=r['reused_days'],simulated_days=r['simulated_days'])


def prepare_continuation_storage(artifact_folder,*,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    folder=Path(artifact_folder).resolve()
    # Independent checkpoint, effective code and full inherited-prefix checks
    # precede any removal of raw table files by the frozen storage module.
    continuation=_verified_continuation(folder,project)
    attestation=_attestation(folder,continuation)
    immutable_write(folder/'continuation_storage_attestation.json',json.dumps(attestation,ensure_ascii=False,indent=2))
    from .inquiry_storage import prepare_candidate_storage
    storage=prepare_candidate_storage(folder,project_root=project)
    from .baseline_purchase_archive import archive_inquiry_purchase_events
    purchase_archive=archive_inquiry_purchase_events(folder,project_root=project)
    receipt=dict(schema='companyx.continuation.storage.v1',status='VERIFIED_UNPUBLISHED',
        RunCode=attestation['RunCode'],family_hash=attestation['family_hash'],
        attestation_sha256=sha(folder/'continuation_storage_attestation.json'),
        base_storage_receipt_sha256=sha(folder/'inquiry_storage_receipt.json'),
        projection_sha256=sha(folder/'inquiry_projection.json'),
        archive_manifest_sha256=sha(folder/'inquiry_archive_manifest.json'),
        checkpoint_sha256=attestation['checkpoint_sha256'])
    if purchase_archive.get('status')=='ARCHIVED':
        receipt['purchase_archive_manifest_sha256']=sha(folder/'purchase_archive_manifest.json')
    immutable_write(folder/'continuation_storage_receipt.json',json.dumps(receipt,ensure_ascii=False,indent=2))
    return receipt


def verify_stored_continuation(artifact_folder,*,project_root=None):
    project=Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]
    folder=Path(artifact_folder).resolve()
    from .inquiry_storage import verify_stored_inquiry
    base=verify_stored_inquiry(folder,project_root=project)
    continuation=_verified_continuation(folder,project)
    expected=_attestation(folder,continuation)
    if read(folder/'continuation_storage_attestation.json')!=expected:
        raise ValueError('Continuation storage attestation differs from independently verified evidence.')
    receipt=read(folder/'continuation_storage_receipt.json')
    if (receipt.get('schema')!='companyx.continuation.storage.v1' or receipt.get('status')!='VERIFIED_UNPUBLISHED'
        or receipt.get('RunCode')!=expected['RunCode'] or receipt.get('family_hash')!=expected['family_hash']
        or receipt.get('checkpoint_sha256')!=expected['checkpoint_sha256']):
        raise ValueError('Continuation storage identity differs.')
    for field,name in [('attestation_sha256','continuation_storage_attestation.json'),
                       ('base_storage_receipt_sha256','inquiry_storage_receipt.json'),
                       ('projection_sha256','inquiry_projection.json'),('archive_manifest_sha256','inquiry_archive_manifest.json')]:
        if receipt.get(field)!=sha(folder/name):raise ValueError('Continuation storage evidence changed: '+name)
    purchase_marker=folder/'purchase_archive_manifest.json'
    if purchase_marker.exists() or 'purchase_archive_manifest_sha256' in receipt:
        from .baseline_purchase_archive import verify_purchase_archive
        if not purchase_marker.exists() or receipt.get('purchase_archive_manifest_sha256')!=sha(purchase_marker):
            raise ValueError('Continuation purchase archive binding differs.')
        purchase=verify_purchase_archive(folder,project_root=project)
        if purchase['schema']!='companyx.inquiry.purchase_archive.v1' or purchase['status']!='ARCHIVED':
            raise ValueError('Continuation requires a completed inquiry purchase archive.')
    base.update(continuation=continuation,continuation_storage_receipt=receipt,continuation_attestation=expected)
    return base

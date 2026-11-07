"""Read-only verification of pre-v3 inquiry archives; never cache admission.

The original storage verifier and old V2 adapter bytes remain preserved. This
reader verifies their existing attestations and archive hashes without claiming
that an old optimizer checkpoint can execute under the corrected model.
"""
from pathlib import Path
import hashlib
import json
from .adapter import project_path
from . import inquiry_v2_legacy_20261105 as historical
from . import checkpoint_codec as codec
from publish import inquiry_storage as storage


def verify_historical_inquiry(folder, project_root=None):
    project = project_path(project_root)
    project, folder = storage._scope(folder, project)
    scope = storage.read(folder / 'scope.json')
    if 'optimizer_release' in scope:
        raise ValueError('Use the current verifier for corrected optimizer artifacts')
    pinned = storage.read(Path(__file__).with_name('historical_v2_identity.json'))
    if storage.sha(historical.__file__) != pinned['execution_files']['inquiry_v2.py']:
        raise ValueError('Historical preparation adapter bytes changed')
    prepared = historical.build_request(storage.read(folder / 'request.json'), scope['candidate_id'], project)
    for name, expected in [('input', prepared['snapshot']), ('input_source', prepared['snapshot']),
                           ('execution_spec', prepared['spec']), ('scope', prepared['scope'])]:
        if storage.read(folder / (name + '.json')) != expected:
            raise ValueError('Historical preparation identity differs: ' + name)
    attestation = storage._check_attestation(folder)
    stored = storage.read(folder / 'inquiry_storage_receipt.json')
    run = storage.read(folder / 'run.json')
    completion = storage.read(folder / 'completion.json')
    table_manifest = storage.read(folder / 'table_manifest.json')
    execution = storage.read(folder / 'control_execution_receipt.json')
    if (completion.get('status') != 'COMPLETE' or execution.get('status') != 'COMPLETE'
            or completion['RunCode'] != run['RunCode'] or execution['run_code'] != run['RunCode']
            or table_manifest['RunCode'] != run['RunCode'] or attestation['RunCode'] != run['RunCode']
            or stored['RunCode'] != run['RunCode']
            or run['input_sha256'] != prepared['snapshot_sha256']
            or run['execution_spec_sha256'] != prepared['execution_spec_sha256']
            or execution['scope_sha256'] != scope['scope_sha256']
            or execution['adapter_sha256'] != prepared['adapter_sha256']
            or run['code_sha256'] != prepared['runtime_code_sha256']):
        raise ValueError('Historical execution identity mismatch')
    for field, name in [('table_manifest_sha256', 'table_manifest.json'), ('metrics_sha256', 'metrics.json')]:
        if completion[field] != storage.sha(folder / name):
            raise ValueError('Historical completion artifact changed: ' + name)
    archive = storage._verify_archive(folder, full=False)
    storage._verify_zip_members(folder / archive['archive_file'], archive['members'], folder=None)
    for field, name in [('archive_manifest_sha256', 'inquiry_archive_manifest.json'),
                        ('projection_sha256', 'inquiry_projection.json'),
                        ('verification_attestation_sha256', 'inquiry_storage_verification.json')]:
        if stored[field] != storage.sha(folder / name):
            raise ValueError('Historical storage evidence changed: ' + name)
    if stored['archive_sha256'] != archive['archive_sha256'] or stored['storage_module_sha256'] != storage.sha(storage.__file__):
        raise ValueError('Historical archive or storage verifier differs')
    projection = storage.read(folder / 'inquiry_projection.json')
    storage._verify_projection(folder, projection)
    for name, item in table_manifest['tables'].items():
        if any(projection['raw_tables'][name][key] != item[key] for key in ('sha256', 'rows')):
            raise ValueError('Historical projection source differs: ' + name)
    continuation = storage.read(folder / 'continuation_receipt.json')
    if continuation['effective_executor_hash'] != pinned['effective_executor_hash']:
        raise ValueError('Unsupported historical continuation executor')
    if continuation['artifact_run_code'] != run['RunCode'] or continuation.get('status') != 'COMPLETE':
        raise ValueError('Historical continuation identity differs')
    for name, expected in continuation['bound_files'].items():
        if Path(name).name != name or storage.sha(folder / name) != expected:
            raise ValueError('Historical continuation bound artifact changed: ' + name)
    for name, expected in {**continuation.get('copied_solver_evidence', {}), **continuation.get('solver_evidence', {})}.items():
        path = storage._member(folder, name)
        if storage.sha(path) != expected:
            raise ValueError('Historical solver evidence changed: ' + name)
    checkpoint = continuation['checkpoint']
    if checkpoint['file'] != 'des_checkpoint.json.gz':
        raise ValueError('Historical checkpoint filename differs')
    cp = codec.load_checkpoint(folder / checkpoint['file'], checkpoint['sha256'])
    if (cp['executor_sha256'] != pinned['checkpoint_executor_hash']
            or cp['payload_sha256'] != codec.digest(cp['payload'])
            or cp['through'] != continuation['covered_end']
            or cp['next_day'] != continuation['reused_days'] + continuation['simulated_days']):
        raise ValueError('Historical checkpoint integrity/coverage differs')
    return {'status': 'VERIFIED_HISTORICAL_READ_ONLY', 'RunCode': run['RunCode'],
        'model': 'PRE_V3_HISTORICAL', 'current_model_reuse_allowed': False,
        'current_model_extension_allowed': False, 'solver_called': False,
        'artifact_folder': str(folder), 'archive': archive,
        'verified_table_count': len(table_manifest['tables']),
        'known_at': continuation['known_at'], 'covered_end': continuation['covered_end'],
        'method': 'Pinned historical preparation; existing raw attestation; full archive bytes/rows; projection and continuation bound hashes; historical checkpoint identity. No re-simulation or claim of corrected-model validity.'}

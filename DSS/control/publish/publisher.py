"""Publish one verified new scoped run atomically into the owned MOLAP source copy."""
from __future__ import annotations
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import os
import sys

sys.dont_write_bytecode = True
os.environ['PYTHONDONTWRITEBYTECODE'] = '1'
DATABASE = 'CompanyX_DW_SIM_20261107'
SOURCE = 'CompanyX_Demo'
CONNECTION = ('DRIVER={ODBC Driver 17 for SQL Server};SERVER=localhost;DATABASE=' + DATABASE
              + ';Trusted_Connection=yes;TrustServerCertificate=yes;APP=CompanyX Control Publisher;')


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'), default=str, allow_nan=False)


def immutable_write(path, content):
    path = Path(path)
    raw = content.encode('utf-8')
    if path.exists():
        if path.read_bytes() != raw:
            raise ValueError('Refusing to replace existing artifact: ' + str(path))
    else:
        with path.open('xb') as stream:
            stream.write(raw)


def prepare_publication(artifact_folder, *, project_root=None):
    if read(Path(artifact_folder)/'scope.json').get('schema')=='companyx.inquiry.scope.v2':
        from publish.inquiry_v2_publisher import prepare_v2
        return prepare_v2(artifact_folder,project_root=project_root)
    project = Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[4]
    demo = project / 'New Inventory Safety'
    folder = Path(artifact_folder).resolve()
    if not folder.is_relative_to(project / 'GPT') or folder == project / 'GPT':
        raise ValueError('Only dedicated new artifacts under Project/GPT may be published.')
    sys.path.insert(0, str(project / 'New Inventory Safety/DSS/control'))
    from simulation.adapter import build_request, runtime
    runtime(project)
    from companyx_unified_v2.dwh import validate_artifact
    from companyx_unified_v2.run import code_hash
    from publish.derive_publish import build, build_inquiry
    run, manifest = validate_artifact(folder)
    scope, request = read(folder / 'scope.json'), read(folder / 'request.json')
    if not scope.get('request_id') or len(str(scope['request_id'])) > 100:
        raise ValueError('A bounded unique request_id is mandatory for publishing.')
    inquiry = scope.get('schema') == 'companyx.inquiry.scope.v1'
    if inquiry:
        from simulation.inquiry import verify_inquiry_artifact
        verification = verify_inquiry_artifact(folder, project)
        rebuilt = verification['prepared']
    else:
        rebuilt = build_request(request, project)
    if rebuilt['scope'] != scope or rebuilt['snapshot'] != read(folder / 'input_source.json'):
        raise ValueError('Scope/source does not reproduce from the pinned frozen base and request.')
    if rebuilt['spec'] != read(folder / 'execution_spec.json') or rebuilt['snapshot'] != read(folder / 'input.json'):
        raise ValueError('Executed input/spec differ from the exact validated request.')
    identity = read(demo / 'SSIS/core_identity.json')
    if code_hash() != identity['code_sha256'] or run['code_sha256'] != identity['code_sha256']:
        raise ValueError('Frozen core identity mismatch.')
    for relative, expected in read(demo / 'SSIS/core_hashes.json').items():
        item = (demo / relative).resolve()
        if not item.is_relative_to(demo) or sha(item) != expected:
            raise ValueError('Frozen core changed: ' + relative)
    # Derivation includes a strict SHA pin on the original SQL, and never edits it.
    sql = build_inquiry(project) if inquiry else build(project)
    generated = Path(__file__).with_name('PublishInquiry.sql' if inquiry else 'PublishScoped.sql')
    if not generated.exists() or generated.read_text(encoding='utf-8') != sql:
        raise ValueError('PublishScoped.sql differs from its reviewed derivation.')
    keys = ('input_source.json', 'input.json', 'execution_spec.json', 'execution_profile.json', 'run.json')
    hashes = {}
    for name in keys:
        target = folder / (name + '.canonical')
        immutable_write(target, canonical(read(folder / name)))
        hashes[name] = sha(target)
    spec = read(folder / 'execution_spec.json')
    selection = dict(policy=spec['policy'], solver=spec['solver']['name'],
                     timing=spec['production_lead_time_mode'], scenario=scope.get('scenario_index', 1),
                     initial_state_rule=scope.get('initial_stock_rule', scope['initial_state_mode']), source_sha256=sha(folder / 'input_source.json'))
    export = dict(status='COMPLETE', schema='companyx.control.v1', selection=selection,
                  core_sha256=identity['code_sha256'], completion_sha256=sha(folder / 'completion.json'),
                  canonical_files=hashes, scope_file_sha256=sha(folder / 'scope.json'))
    if inquiry:
        export.update(prefix_proof_sha256=sha(folder / 'prefix_proof.json'),
                      branch_state_sha256=sha(folder / 'branch_state.json'))
    base_proof = read(demo / 'KetQua/Demo_01/dw_source_proof.json')
    proof = dict(schema='companyx.control.v1', status='SCOPED_SOURCE_PENDING_SQL_RECHECK',
                 database=DATABASE, source_database=SOURCE, etl_batch=base_proof['etl_batch'],
                 base_snapshot_sha256=scope['base_snapshot_sha256'],
                 snapshot_file_sha256=sha(folder / 'input_source.json'), scope_sha256=scope['scope_sha256'],
                 frozen_parameters=scope.get('temporal_basis', 'Replay saved state with unchanged frozen BOM, vendor, valuation and lead assumptions.'),
                 frozen_lead_input_hash=hashlib.sha256(canonical(read(demo / 'KetQua/Demo_01/input_source.json')).encode('utf-8')).hexdigest())
    for name, value in (('simulation_selection.json', selection), ('simulation_export.json', export), ('dw_source_proof.json', proof)):
        immutable_write(folder / name, json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False))
    return project, demo, folder, sql, run


def publish_run(artifact_folder, *, project_root=None):
    """Returns native LOADED/ALREADY_LOADED receipt; rollback on every SQL DQ failure."""
    if read(Path(artifact_folder)/'scope.json').get('schema')=='companyx.inquiry.scope.v2':
        from publish.inquiry_v2_publisher import publish_v2
        return publish_v2(artifact_folder,project_root=project_root)
    import pyodbc
    project, demo, folder, sql, run = prepare_publication(artifact_folder, project_root=project_root)
    with pyodbc.connect(CONNECTION, autocommit=True, timeout=15) as connection:
        connection.timeout = 900
        cursor = connection.cursor()
        cursor.execute(sql, str(demo), str(folder), SOURCE)
        receipt = None
        while True:
            if cursor.description:
                names = [column[0] for column in cursor.description]
                for row in cursor.fetchall():
                    if 'PublicationReceipt' in names:
                        receipt = json.loads(row[names.index('PublicationReceipt')])
            if not cursor.nextset():
                break
        if not receipt or receipt.get('status') not in ('LOADED', 'ALREADY_LOADED'):
            raise RuntimeError('SQL did not return a successful atomic publication receipt.')
    receipt.update(RunCode=run['RunCode'], scope_sha256=read(folder / 'scope.json')['scope_sha256'],
                   published_at=datetime.now(timezone.utc).isoformat(),
                   publisher_sql_sha256=hashlib.sha256(sql.encode('utf-8')).hexdigest())
    # Each attempt is retained; canonical receipt remains the first successful publication.
    first = folder / 'publication_receipt.json'
    if not first.exists():
        immutable_write(first, json.dumps(receipt, ensure_ascii=False, indent=2))
    else:
        attempts = folder / 'publication_attempts'
        attempts.mkdir(exist_ok=True)
        immutable_write(attempts / (datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ') + '.json'), json.dumps(receipt, ensure_ascii=False, indent=2))
    return receipt


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('artifact_folder')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    if args.prepare_only:
        *_, run = prepare_publication(args.artifact_folder)
        print(json.dumps({'status': 'READY_FOR_SQL', 'RunCode': run['RunCode']}))
    else:
        print(json.dumps(publish_run(args.artifact_folder), ensure_ascii=False))

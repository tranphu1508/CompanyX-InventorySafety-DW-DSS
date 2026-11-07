"""Verified ZIP64 archival/streaming for new baseline artifacts under Project/GPT.

The immutable demo is never a permitted source or destination. Raw files are
removed only after successful baseline SQL publication and two hash checks:
source-to-manifest while writing ZIP, then independent decompression-to-manifest.
"""
from __future__ import annotations
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import shutil
import zipfile


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
            value.update(block)
    return value.hexdigest()


def _scope(folder, project_root=None):
    project = Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[4]
    path = Path(folder).resolve()
    if not path.is_relative_to(project / 'GPT') or path == project / 'GPT':
        raise ValueError('Baseline archive paths must be dedicated folders under Project/GPT.')
    return project, path


def _member(folder, relative):
    name = Path(relative)
    if name.is_absolute() or '..' in name.parts or ':' in str(name):
        raise ValueError('Unsafe archive member: ' + str(relative))
    path = (folder / name).resolve()
    if not path.is_relative_to(folder):
        raise ValueError('Archive member escaped its dedicated folder.')
    return path


def _save(path, value):
    pending = Path(path).with_suffix(Path(path).suffix + '.pending')
    pending.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    pending.replace(path)


def archive_baseline(artifact_folder, *, project_root=None, progress=None):
    """Archive exact raw outputs, then remove only their verified GPT originals."""
    project, folder = _scope(artifact_folder, project_root)
    if (folder/'stream_storage_manifest.json').exists():
        from .baseline_gzip_storage import archive_streamed_baseline
        return archive_streamed_baseline(folder,project_root=project,progress=progress)
    receipt_path = folder / 'baseline_publication_receipt.json'
    receipt = read(receipt_path)
    run = read(folder / 'run.json')
    if (receipt.get('schema') != 'companyx.baseline.publication.v1'
            or receipt.get('status') not in ('LOADED', 'ALREADY_LOADED')
            or receipt.get('database') != 'CompanyX_MOLAP_Source_20261105'
            or receipt.get('RunCode') != run['RunCode']
            or receipt.get('RunStatus') != 'SUCCEEDED'
            or receipt.get('verification_status') != 'PASSED'):
        raise ValueError('A verified successful baseline publication is required before archival.')
    if any((folder / name).exists() for name in ('RUNNING.lock', 'DW_PUBLISH.lock')):
        raise ValueError('Artifact still has an execution/publication lock.')
    archive = folder / 'raw_artifacts.zip'
    manifest_path = folder / 'archive_manifest.json'
    if manifest_path.exists():
        existing = verify_archive(folder, project_root=project)
        if existing.get('status') == 'ARCHIVED':
            from .baseline_purchase_archive import archive_purchase_events
            archive_purchase_events(folder,project_root=project,progress=progress)
            return existing
        raise ValueError('An incomplete earlier archival requires inspection; raw files are retained.')
    if archive.exists() or archive.with_suffix('.pending.zip').exists():
        raise ValueError('An unregistered archive already exists; do not overwrite it.')
    table_manifest = read(folder / 'table_manifest.json')
    expected = {}
    for name, entry in table_manifest['tables'].items():
        if Path(name).name != name or not name.endswith('.jsonl'):
            raise ValueError('Unsafe table manifest path.')
        relative = 'tables/' + name
        path = _member(folder, relative)
        stat = path.stat()
        expected[relative] = dict(sha256=entry['sha256'], rows=entry['rows'],
                                  bytes=stat.st_size, mtime_ns=stat.st_mtime_ns)
    daily = folder / 'daily_totals.json'
    if daily.exists():
        stat = daily.stat()
        expected['daily_totals.json'] = dict(sha256=sha(daily), bytes=stat.st_size, mtime_ns=stat.st_mtime_ns)
    pending = archive.with_suffix('.pending.zip')
    with zipfile.ZipFile(pending, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=1, allowZip64=True) as zipped:
        for relative, entry in expected.items():
            digest = hashlib.sha256(); length = 0; newlines = 0; last = b''
            source = _member(folder, relative)
            with source.open('rb') as src, zipped.open(relative, 'w', force_zip64=True) as dst:
                for block in iter(lambda: src.read(4 * 1024 * 1024), b''):
                    dst.write(block); digest.update(block); length += len(block)
                    newlines += block.count(b'\n'); last = block[-1:]
            row_count = newlines + int(bool(last) and last != b'\n')
            if digest.hexdigest() != entry['sha256'] or length != entry['bytes'] or ('rows' in entry and row_count != entry['rows']):
                raise ValueError('Raw artifact changed or row count differs: ' + relative)
            if progress:
                progress({'stage': 'compressed', 'member': relative, 'bytes': length})
    # Independent read-back checks ZIP CRC and SHA256 of every decompressed member.
    with zipfile.ZipFile(pending, 'r') as zipped:
        if set(zipped.namelist()) != set(expected):
            raise ValueError('Unexpected archive member set.')
        for relative, entry in expected.items():
            digest = hashlib.sha256(); length = 0
            with zipped.open(relative, 'r') as src:
                for block in iter(lambda: src.read(4 * 1024 * 1024), b''):
                    digest.update(block); length += len(block)
            if digest.hexdigest() != entry['sha256'] or length != entry['bytes']:
                raise ValueError('Independent archive verification failed: ' + relative)
            entry['compressed_bytes'] = zipped.getinfo(relative).compress_size
            if progress:
                progress({'stage': 'verified', 'member': relative, 'bytes': length})
    pending.rename(archive)
    record = dict(schema='companyx.baseline.archive.v1', status='VERIFIED_PENDING_RAW_REMOVAL',
                  RunCode=run['RunCode'], PlanningRunKey=receipt['PlanningRunKey'], archive_file=archive.name,
                  archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  raw_bytes=sum(e['bytes'] for e in expected.values()), members=expected,
                  table_manifest_sha256=sha(folder / 'table_manifest.json'),
                  publication_receipt_sha256=sha(receipt_path), created_at=datetime.now(timezone.utc).isoformat())
    _save(manifest_path, record)
    for relative, entry in expected.items():
        source = _member(folder, relative)
        stat = source.stat()
        if stat.st_size != entry['bytes'] or stat.st_mtime_ns != entry['mtime_ns']:
            raise ValueError('Raw file changed after verification; retained: ' + relative)
    # Individual checked paths only; no recursive deletion or directory removal.
    for relative in expected:
        _member(folder, relative).unlink()
    record['status'] = 'ARCHIVED'
    record['raw_removed_at'] = datetime.now(timezone.utc).isoformat()
    _save(manifest_path, record)
    from .baseline_purchase_archive import archive_purchase_events
    archive_purchase_events(folder,project_root=project,progress=progress)
    return record


def verify_archive(artifact_folder, *, project_root=None):
    _, folder = _scope(artifact_folder, project_root)
    manifest = read(folder / 'archive_manifest.json')
    if manifest.get('schema') != 'companyx.baseline.archive.v1' or manifest['RunCode'] != read(folder / 'run.json')['RunCode']:
        raise ValueError('Archive identity mismatch.')
    archive = _member(folder, manifest['archive_file'])
    if sha(archive) != manifest['archive_sha256'] or sha(folder / 'table_manifest.json') != manifest['table_manifest_sha256']:
        raise ValueError('Archive or original table manifest checksum changed.')
    table_manifest = read(folder / 'table_manifest.json')
    for name, entry in table_manifest['tables'].items():
        member = manifest['members'].get('tables/' + name)
        if not member or member['sha256'] != entry['sha256'] or member['rows'] != entry['rows']:
            raise ValueError('Archive member differs from original table manifest.')
    return manifest


@contextmanager
def open_artifact_text(artifact_folder, relative, *, project_root=None):
    """Read a raw or archived UTF-8 artifact without restoring gigabytes to disk."""
    _, folder = _scope(artifact_folder, project_root)
    path = _member(folder, relative)
    if path.exists():
        with path.open('r', encoding='utf-8-sig') as stream:
            yield stream
        return
    manifest = verify_archive(folder, project_root=project_root)
    relative = str(Path(relative)).replace('\\', '/')
    if relative not in manifest['members']:
        raise FileNotFoundError(relative)
    with zipfile.ZipFile(_member(folder, manifest['archive_file']), 'r') as zipped:
        with zipped.open(relative, 'r') as binary, io.TextIOWrapper(binary, encoding='utf-8-sig') as stream:
            yield stream


def restore_archive(artifact_folder, destination_folder, *, project_root=None):
    """Restore into a NEW GPT folder; never overwrite original or existing files."""
    project, source = _scope(artifact_folder, project_root)
    _, destination = _scope(destination_folder, project)
    if destination.exists():
        raise ValueError('Restore destination must be a new dedicated GPT directory.')
    manifest = verify_archive(source, project_root=project)
    destination.mkdir(parents=True)
    with zipfile.ZipFile(_member(source, manifest['archive_file']), 'r') as zipped:
        for relative, entry in manifest['members'].items():
            target = _member(destination, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256(); length = 0
            with zipped.open(relative, 'r') as src, target.open('xb') as dst:
                for block in iter(lambda: src.read(4 * 1024 * 1024), b''):
                    dst.write(block); digest.update(block); length += len(block)
            if digest.hexdigest() != entry['sha256'] or length != entry['bytes']:
                raise ValueError('Restore checksum mismatch: ' + relative)
    for item in source.iterdir():
        if item.is_file() and item.name not in ('archive_manifest.json',) and (item.suffix == '.json' or item.name.endswith('.canonical')) and not (destination / item.name).exists():
            shutil.copy2(item, destination / item.name)
    _save(destination / 'restored_from.json', dict(source=str(source), archive_sha256=manifest['archive_sha256'], restored_at=datetime.now(timezone.utc).isoformat()))
    return destination

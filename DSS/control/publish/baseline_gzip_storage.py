"""Bounded-disk JSONL storage for new baselines; the physical engine is unchanged.

Logical table rows/hashes have the original contract. Gzip containers are an
explicit intermediate storage layer, then converted to the standard verified
baseline ZIP archive after successful analytical publication.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
import gzip, hashlib, json, os, zipfile

TABLES = ('RunEntity','Fact_SimulationDaily','Fact_SimulationEvent','Fact_SimulationOrder',
          'Fact_OptimizationSolve','Fact_StochasticDraw','RunSummary','ProductScope','ValuationBasis',
          'Fact_PolicySimulation','Bridge_RunEntityRelation','ExternalSupplyDraw')


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def sha(path):
    value = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''): value.update(block)
    return value.hexdigest()


def _path(folder, relative):
    folder = Path(folder).resolve(); relative = Path(relative)
    if relative.is_absolute() or '..' in relative.parts or ':' in str(relative):
        raise ValueError('Unsafe streamed baseline member')
    result = (folder / relative).resolve()
    if not result.is_relative_to(folder): raise ValueError('Streamed member escapes baseline')
    return result


class GzipSink:
    """Same row serialization/counting as frozen run.Sink; no plain large files."""
    def __init__(self, folder, run_code):
        self.folder = Path(folder); self.folder.mkdir(parents=True, exist_ok=False)
        self.run_code = run_code; self.files = {}; self.raw = {}; self.counts = {}; self.hashes = {}; self.sizes = {}
        self.closed = False
        for table in TABLES:
            self.raw[table] = (self.folder / (table + '.jsonl.gz')).open('xb')
            self.files[table] = gzip.GzipFile(filename='', mode='wb', fileobj=self.raw[table], compresslevel=1, mtime=0)
            self.counts[table] = 0; self.hashes[table] = hashlib.sha256(); self.sizes[table] = 0

    def __call__(self, table, row):
        if table not in self.files: raise ValueError('Unexpected physical table: ' + table)
        value = (json.dumps(dict(RunCode=self.run_code, **row), ensure_ascii=False, default=str,
                            allow_nan=False, separators=(',', ':')) + os.linesep).encode('utf-8')
        self.files[table].write(value); self.hashes[table].update(value)
        self.sizes[table] += len(value); self.counts[table] += 1

    def flush(self):
        if self.closed: return
        for table in self.files:
            self.files[table].flush(); self.raw[table].flush(); os.fsync(self.raw[table].fileno())

    def close(self):
        if self.closed: return
        for table in self.files:
            self.files[table].close(); self.raw[table].flush(); os.fsync(self.raw[table].fileno()); self.raw[table].close()
        self.closed = True

    def logical_manifest(self):
        if not self.closed: raise ValueError('Close streamed sink before manifest')
        return {table+'.jsonl': {'rows': self.counts[table], 'sha256': self.hashes[table].hexdigest()}
                for table in sorted(self.files)}

    def storage_manifest(self, baseline_folder):
        if not self.closed: raise ValueError('Close streamed sink before manifest')
        folder = Path(baseline_folder)
        return {'schema': 'companyx.baseline.raw_gzip.v1', 'RunCode': self.run_code,
                'table_manifest_sha256': sha(folder / 'table_manifest.json'),
                'frozen_core_sha256': read(folder / 'run.json')['code_sha256'],
                'storage_adapter_sha256': sha(Path(__file__)),
                'serialization': 'Frozen Sink JSON encoding and platform newline; compression only changes storage.',
                'tables': {table+'.jsonl': {'gzip_file': str(path.relative_to(folder)).replace('\\','/'),
                                          'gzip_sha256': sha(path), 'gzip_bytes': path.stat().st_size,
                                          'bytes': self.sizes[table], 'rows': self.counts[table],
                                          'sha256': self.hashes[table].hexdigest()}
                           for table in sorted(self.files)
                           for path in [self.folder / (table+'.jsonl.gz')]}}


def verify_storage_header(folder):
    folder = Path(folder); path = folder / 'stream_storage_manifest.json'
    storage = read(path); run = read(folder / 'run.json'); manifest = read(folder / 'table_manifest.json')
    execution = read(folder / 'baseline_execution_receipt.json')
    if (storage.get('schema') != 'companyx.baseline.raw_gzip.v1' or storage.get('RunCode') != run['RunCode']
        or storage.get('frozen_core_sha256') != run['code_sha256']
        or storage.get('table_manifest_sha256') != sha(folder / 'table_manifest.json')
        or execution.get('stream_storage_manifest_sha256') != sha(path)
        or set(storage['tables']) != set(manifest['tables'])):
        raise ValueError('Streamed baseline storage identity mismatch')
    for name, entry in manifest['tables'].items():
        if Path(name).name != name or not name.endswith('.jsonl'): raise ValueError('Unsafe logical table name')
        binding = storage['tables'][name]
        if binding['rows'] != entry['rows'] or binding['sha256'] != entry['sha256'] or binding['bytes'] < 0:
            raise ValueError('Streamed logical table differs from manifest')
        _path(folder, binding['gzip_file'])
    return storage


@contextmanager
def open_raw_binary(folder, name):
    folder = Path(folder).resolve()
    if Path(name).name != name or not name.endswith('.jsonl'): raise ValueError('Unsafe raw table name')
    plain = _path(folder, 'tables/' + name)
    if plain.exists():
        with plain.open('rb') as stream: yield stream
        return
    if (folder / 'stream_storage_manifest.json').exists():
        storage = verify_storage_header(folder); binding = storage['tables'][name]
        compressed = _path(folder, binding['gzip_file'])
        if compressed.exists():
            if compressed.stat().st_size != binding['gzip_bytes'] or sha(compressed) != binding['gzip_sha256']:
                raise ValueError('Gzip source container changed: ' + name)
            with gzip.open(compressed, 'rb') as stream: yield stream
            return
    from .baseline_archive import verify_archive
    archive = verify_archive(folder)
    relative = 'tables/' + name
    if relative not in archive['members']: raise ValueError('Missing raw table in verified archive')
    with zipfile.ZipFile(_path(folder, archive['archive_file']), 'r') as zipped:
        with zipped.open(relative, 'r') as stream: yield stream


def raw_sha(folder, name):
    value = hashlib.sha256()
    with open_raw_binary(folder, name) as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b''): value.update(block)
    return value.hexdigest()


def archive_streamed_baseline(folder, *, project_root=None, progress=None):
    from .baseline_archive import _scope, _save, verify_archive
    from .baseline_purchase_archive import archive_purchase_events
    project, folder = _scope(folder, project_root)
    if (folder / 'archive_manifest.json').exists():
        record = verify_archive(folder, project_root=project)
        if record['status'] != 'ARCHIVED': raise ValueError('Incomplete archive needs inspection')
        archive_purchase_events(folder, project_root=project, progress=progress)
        return record
    receipt_path = folder / 'baseline_publication_receipt.json'; receipt = read(receipt_path); run = read(folder / 'run.json')
    if (receipt.get('schema') != 'companyx.baseline.publication.v1' or receipt.get('status') not in ('LOADED','ALREADY_LOADED')
        or receipt.get('database') != 'CompanyX_MOLAP_Source_20261105' or receipt.get('RunStatus') != 'SUCCEEDED'
        or receipt.get('verification_status') != 'PASSED' or receipt.get('RunCode') != run['RunCode']):
        raise ValueError('Successful verified SQL publication required before gzip retirement')
    if any((folder / name).exists() for name in ('RUNNING.lock','DW_PUBLISH.lock')): raise ValueError('Baseline is still executing')
    storage = verify_storage_header(folder); archive = folder / 'raw_artifacts.zip'; pending = folder / 'raw_artifacts.pending.zip'
    if archive.exists() or pending.exists(): raise ValueError('Existing unregistered archive is preserved')
    expected = {'tables/'+name: {key: binding[key] for key in ('sha256','rows','bytes')}
                for name,binding in storage['tables'].items()}
    daily = folder / 'daily_totals.json'
    if daily.exists(): expected['daily_totals.json'] = {'sha256': sha(daily), 'bytes': daily.stat().st_size}
    gzip_sources = {}
    for name,binding in storage['tables'].items():
        source = _path(folder,binding['gzip_file']); stat = source.stat()
        gzip_sources[binding['gzip_file']] = {'sha256': binding['gzip_sha256'], 'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns}
    with zipfile.ZipFile(pending,'x',compression=zipfile.ZIP_DEFLATED,compresslevel=1,allowZip64=True) as zipped:
        for relative, entry in expected.items():
            source_context = open_raw_binary(folder, Path(relative).name) if relative.startswith('tables/') else daily.open('rb')
            digest=hashlib.sha256(); size=0; rows=0; last=b''
            with source_context as source, zipped.open(relative,'w',force_zip64=True) as target:
                for block in iter(lambda: source.read(4*1024*1024),b''):
                    target.write(block);digest.update(block);size+=len(block);rows+=block.count(b'\n');last=block[-1:]
            rows += int(bool(last) and last != b'\n')
            if digest.hexdigest()!=entry['sha256'] or size!=entry['bytes'] or ('rows' in entry and rows!=entry['rows']):
                raise ValueError('Logical gzip table hash/count changed: '+relative)
            if progress: progress({'stage':'streamed_to_zip','member':relative,'bytes':size})
    with zipfile.ZipFile(pending,'r') as zipped:
        if set(zipped.namelist())!=set(expected): raise ValueError('Unexpected archive member set')
        for relative,entry in expected.items():
            digest=hashlib.sha256();size=0
            with zipped.open(relative) as source:
                for block in iter(lambda:source.read(4*1024*1024),b''):digest.update(block);size+=len(block)
            if digest.hexdigest()!=entry['sha256'] or size!=entry['bytes']:raise ValueError('Independent ZIP readback failed')
            entry['compressed_bytes']=zipped.getinfo(relative).compress_size
    pending.rename(archive)
    record={'schema':'companyx.baseline.archive.v1','status':'VERIFIED_PENDING_RAW_REMOVAL',
            'RunCode':run['RunCode'],'PlanningRunKey':receipt['PlanningRunKey'],'archive_file':archive.name,
            'archive_sha256':sha(archive),'archive_bytes':archive.stat().st_size,
            'raw_bytes':sum(entry['bytes'] for entry in expected.values()),'members':expected,
            'table_manifest_sha256':sha(folder/'table_manifest.json'),'publication_receipt_sha256':sha(receipt_path),
            'source_storage':'STREAMED_GZIP_JSONL','source_storage_manifest_sha256':sha(folder/'stream_storage_manifest.json'),
            'retired_gzip_sources':gzip_sources,'created_at':datetime.now(timezone.utc).isoformat()}
    _save(folder/'archive_manifest.json',record)
    for relative,entry in gzip_sources.items():
        source=_path(folder,relative);stat=source.stat()
        if stat.st_size!=entry['bytes'] or stat.st_mtime_ns!=entry['mtime_ns'] or sha(source)!=entry['sha256']:
            raise ValueError('Gzip source changed after archive verification; retained')
    # Only checked new GPT duplicates are removed; standard ZIP is now authoritative.
    for relative in gzip_sources:_path(folder,relative).unlink()
    if daily.exists():
        if sha(daily)!=expected['daily_totals.json']['sha256']:raise ValueError('Daily totals changed; retained')
        daily.unlink()
    record['status']='ARCHIVED';record['raw_removed_at']=datetime.now(timezone.utc).isoformat()
    _save(folder/'archive_manifest.json',record)
    archive_purchase_events(folder,project_root=project,progress=progress)
    return record

"""Frozen, cutoff-safe direct resale demand rates for corrected MILP planning.

This module neither fits a new manufacturing forecast nor reads future orders
from an execution snapshot. A separately materialized historical artifact is
attached to a copied snapshot before the immutable input adapter prepares it.
"""
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import date
import hashlib
import json
import math
from pathlib import Path

SCHEMA = 'companyx.resale.direct-forecast.v1'
PARAM_SCHEMA = 'companyx.resale.direct-forecast.parameter.v1'
CUTOFF = '2013-07-01'
HISTORY_START = '2012-07-01'
ARTIFACT_RELATIVE = 'RuntimeData/resale-forecast-artifact.json'


def _project(project_root=None):
    return Path(project_root).resolve() if project_root else Path(__file__).resolve().parents[3]


def _canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'), allow_nan=False)


def _digest(value):
    return hashlib.sha256(_canonical(value).encode('utf-8')).hexdigest()


def _day(value):
    if isinstance(value, date):
        return value
    return date.fromisoformat(str(value)[:10])


def _read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def build_artifact(source, model_products):
    """Fit the declared historical mean, quarantining whole invalid orders.

    The numerator uses OrderDate, as in the frozen manufacturing estimator.
    Only orders revealed strictly before the cutoff can affect the fit. The
    rate is a simple fixed demand signal, not a claimed calibrated ML forecast.
    """
    cutoff = _day(CUTOFF)
    history_start = _day(HISTORY_START)
    products = {p['ProductID']: p for p in model_products}
    master = {p['ProductID']: p for p in source['products']}
    manufactured = {p for p, row in products.items() if row['IsManufactured']}
    resale = {p for p, row in products.items() if row['IsResale'] and not row['IsManufactured']}
    if len(products) != len(model_products) or resale - set(master):
        raise ValueError('Forecast product scope is duplicate or absent from source master')
    history = [row for row in source['sales'] if history_start <= _day(row['OrderDate']) < cutoff]
    by_order = defaultdict(list)
    for row in history:
        by_order[row['SalesOrderID']].append(row)
    cohort = {oid: rows for oid, rows in by_order.items()
              if any(row['ProductID'] in manufactured for row in rows)}
    invalid = set()
    for oid, rows in cohort.items():
        if len({(row['OrderDate'], row['DueDate']) for row in rows}) != 1:
            invalid.add(oid)
        for row in rows:
            q = row['OrderQty']
            if (not row.get('IsDemandEligible', False) or type(q) not in (int, float)
                    or not math.isfinite(q) or q <= 0 or int(q) != q
                    or _day(row['DueDate']) < _day(row['OrderDate'])):
                invalid.add(oid)
    selected = [row for oid, rows in cohort.items() if oid not in invalid
                for row in rows if row['ProductID'] in resale]
    ids = [row['SalesOrderDetailID'] for row in selected]
    if len(ids) != len(set(ids)):
        raise ValueError('Duplicate historical resale line ID')
    history_rows = sorted(({key: row[key] for key in
                           ('SalesOrderDetailID', 'SalesOrderID', 'ProductID', 'OrderQty', 'OrderDate', 'DueDate')}
                          for row in selected), key=lambda row: row['SalesOrderDetailID'])
    history_hash = _digest(history_rows)
    quantities = Counter()
    counts = Counter()
    for row in selected:
        pid = row['ProductID']
        sell_start = _day(master[pid]['SellStartDate'])
        if _day(row['OrderDate']) < sell_start:
            raise ValueError(f'Historical resale demand precedes SellStartDate: {pid}')
        quantities[pid] += int(row['OrderQty'])
        counts[pid] += 1
    rows = []
    for pid in sorted(resale):
        sell_start = _day(master[pid]['SellStartDate'])
        exposure_start = min(cutoff, max(history_start, sell_start))
        days = (cutoff - exposure_start).days
        units = quantities[pid]
        if not days and units:
            raise ValueError(f'Positive resale history without selling exposure: {pid}')
        historical_mu = units / days if days else 0.0
        end = master[pid].get('SellEndDate')
        # Only an end already preceding the cutoff changes the frozen rate.
        # A future end date in the retrospective master is not used as a gate.
        ended = bool(end and _day(end) < cutoff)
        value = dict(schema=PARAM_SCHEMA, ProductID=pid, direct_mu=0.0 if ended else historical_mu,
                     historical_mu=historical_mu, historical_units=units, historical_lines=counts[pid],
                     history_start=HISTORY_START, cutoff=CUTOFF,
                     exposure_start=exposure_start.isoformat(), exposure_days=days,
                     observed_end_before_cutoff=str(end)[:10] if ended else None,
                     reason='ENDED_BEFORE_CUTOFF' if ended else
                            ('NO_HISTORICAL_DEMAND' if not units else 'FROZEN_HISTORICAL_MEAN'),
                     method='ORDER_DATE_UNITS_PER_ACTIVE_SELLING_CALENDAR_DAY',
                     demand_date_basis='ORDER_DATE_FROZEN_DAILY_RATE',
                     cohort='VALID_WHOLE_ORDERS_WITH_MODELED_MANUFACTURED_PRODUCT',
                     stock_unit=products[pid]['StockUnit'], historical_rows_sha256=history_hash)
        value['sha256'] = _digest(value)
        rows.append(value)
    artifact = dict(schema=SCHEMA, cutoff=CUTOFF, history_start=HISTORY_START,
                    method='FROZEN_HISTORICAL_MEAN_WITH_ACTIVE_SELLING_EXPOSURE',
                    rows=rows, parameter_rows_sha256=_digest(rows),
                    historical_rows_sha256=history_hash,
                    selected_historical_line_count=len(history_rows),
                    quarantined_whole_order_ids=sorted(invalid),
                    manufactured_product_ids=sorted(manufactured),
                    resale_product_ids=sorted(resale),
                    interpretation='Fixed historical resale rate for the same manufactured-order cohort. '
                        'Includes calendar zero-demand days and only OrderDate before 2013-07-01. '
                        'Known future due demand is subtracted once during planning. '
                        'Manufactured rates, physical state, BOM and prices are unchanged. '
                        'Master selling dates are retrospective source attributes; no claim of an untouched holdout '
                        'or experimentally validated forecast accuracy is made.',
                    no_history_policy='Explicit zero rate with NO_HISTORICAL_DEMAND provenance; no guessed demand.',
                    estimator_reference='Project/GPT/src/prepare_companyx_active_days.py; '
                        'same 2012-07-01 to 2013-07-01 OrderDate window and exposure convention')
    artifact['sha256'] = _digest(artifact)
    return artifact


def _load_artifact(project_root=None):
    path = _project(project_root) / ARTIFACT_RELATIVE
    raw = path.read_bytes()
    artifact = json.loads(raw.decode('utf-8-sig'))
    if (artifact.get('schema') != SCHEMA or artifact.get('cutoff') != CUTOFF
            or artifact.get('history_start') != HISTORY_START
            or artifact.get('sha256') != _digest({k: v for k, v in artifact.items() if k != 'sha256'})
            or artifact.get('parameter_rows_sha256') != _digest(artifact.get('rows'))):
        raise ValueError('Resale forecast artifact integrity mismatch')
    rows = {row['ProductID']: row for row in artifact['rows']}
    if len(rows) != len(artifact['rows']) or set(rows) != set(artifact['resale_product_ids']):
        raise ValueError('Resale forecast artifact scope mismatch')
    for row in rows.values():
        _validate_parameter(row, row['ProductID'], _day(CUTOFF))
    return artifact, dict(schema=SCHEMA, path=str(path), sha256=hashlib.sha256(raw).hexdigest(),
                          content_sha256=artifact['sha256'],
                          parameter_rows_sha256=artifact['parameter_rows_sha256'], cutoff=CUTOFF)


def artifact_identity(project_root=None):
    """Cache/release binding without constructing or executing a candidate."""
    return _load_artifact(project_root)[1]


def _validate_parameter(row, pid, as_of):
    if not isinstance(row, dict) or row.get('schema') != PARAM_SCHEMA or row.get('ProductID') != pid:
        raise ValueError(f'Invalid direct resale forecast parameter: {pid}')
    if row.get('sha256') != _digest({k: v for k, v in row.items() if k != 'sha256'}):
        raise ValueError(f'Direct resale forecast parameter hash mismatch: {pid}')
    if _day(row['cutoff']) > as_of:
        raise ValueError(f'Resale forecast cutoff is after decision date: {pid}')
    mu = row.get('direct_mu')
    if type(mu) not in (int, float) or not math.isfinite(mu) or mu < 0:
        raise ValueError(f'Invalid direct resale forecast mean: {pid}')
    return float(mu)


def prepare_snapshot(snapshot, known_at, project_root=None):
    """Copy/enrich a snapshot; its ROP prefix may start before forecast cutoff."""
    known_at = _day(known_at)
    if known_at < _day(CUTOFF):
        raise ValueError('Corrected MILP requires known_at on or after resale forecast cutoff 2013-07-01')
    artifact, identity = _load_artifact(project_root)
    available = {row['ProductID']: row for row in artifact['rows']}
    result = deepcopy(snapshot)
    used = []
    for product in result['products']:
        if product['IsManufactured'] or not product['IsResale']:
            continue
        pid = product['ProductID']
        if pid not in available:
            raise ValueError(f'Resale ProductID has no explicit historical forecast provenance: {pid}')
        row = available[pid]
        if product['StockUnit'] != row['stock_unit']:
            raise ValueError(f'Resale forecast stock unit differs from snapshot: {pid}')
        if product.get('DirectForecastParameters') not in (None, row):
            raise ValueError(f'Existing resale forecast differs from pinned artifact: {pid}')
        product['DirectForecastParameters'] = deepcopy(row)
        used.append(row)
    provenance = dict(schema=SCHEMA, artifact=identity, known_at=known_at.isoformat(),
                      selected_product_ids=sorted(row['ProductID'] for row in used),
                      selected_parameter_rows_sha256=_digest(sorted(used, key=lambda row: row['ProductID'])),
                      training_history_start=HISTORY_START, training_cutoff=CUTOFF,
                      manufactured_forecast_preserved=True,
                      execution_snapshot_future_orders_used_for_fit=False)
    provenance['sha256'] = _digest(provenance)
    result.setdefault('metadata', {})['resale_forecast'] = provenance
    return result, provenance


def get_resale_forecast(data, *, required=False, as_of=None):
    """Read direct rates from prepared products at the actual decision date.

    Missing explicit rates are rejected when required. A baseline-start hybrid
    must pass its actual MILP decision date, not the historical ROP start date.
    """
    as_of = _day(data['start'] if as_of is None else as_of)
    result = {}
    products = data.get('products', {})
    candidates = set(data.get('external_ids', ()))
    if required:
        candidates &= set(data.get('raw', ()))
    for pid in sorted(candidates):
        product = products.get(pid)
        if product is None:
            raise ValueError(f'Resale product metadata missing: {pid}')
        if product.get('IsManufactured'):
            continue
        row = product.get('DirectForecastParameters')
        if row is None:
            if required:
                raise ValueError(f'Finite resale planning requires explicit direct forecast parameters: {pid}')
            continue
        if row.get('stock_unit') != product['StockUnit']:
            raise ValueError(f'Direct resale forecast unit mismatch: {pid}')
        result[pid] = _validate_parameter(row, pid, as_of)
    return result

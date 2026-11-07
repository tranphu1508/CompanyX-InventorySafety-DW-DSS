"""Strengthen a copy of a daily MOLAP model without changing its variable order or costs."""
from copy import copy
import math

import numpy as np


def propagate(model, passes=8):
    """Propagate interval bounds through sparse rows, rounding outwards for floating point."""
    sizes = np.asarray([len(row) for row in model.rows], dtype=np.int64)
    nnz = int(sizes.sum())
    if not nnz:
        return 0
    rows = np.repeat(np.arange(len(sizes)), sizes)
    cols = np.fromiter((j for row in model.rows for j in row), np.int64, count=nnz)
    a = np.fromiter((v for row in model.rows for v in row.values()), float, count=nnz)
    lo, hi = np.asarray(model.lo), np.asarray(model.hi)
    lower, upper = model.lb, model.ub
    # I and u follow integer stock/production balances. Never round expected purchased stock.
    integer = np.asarray(model.integer, dtype=bool) | np.array([k[0] in ('I', 'u') for k in model.keys])
    updated = 0
    for _ in range(passes):
        left, right = a * lower[cols], a * upper[cols]
        minimum, maximum = np.minimum(left, right), np.maximum(left, right)
        good = np.isfinite(minimum) & np.isfinite(maximum) & (a != 0)
        bad_rows = np.bincount(rows, weights=~good, minlength=len(sizes)) > 0
        valid = good & ~bad_rows[rows]
        mn = np.bincount(rows, weights=np.where(good, minimum, 0), minlength=len(sizes))
        mx = np.bincount(rows, weights=np.where(good, maximum, 0), minlength=len(sizes))
        mag = np.bincount(rows, weights=np.where(good, np.maximum(abs(minimum), abs(maximum)), 0),
                          minlength=len(sizes))
        rhs_size = np.maximum(np.where(np.isfinite(lo), abs(lo), 0), np.where(np.isfinite(hi), abs(hi), 0))
        margin = 1e-8 + 8 * np.finfo(float).eps * (sizes + 3) * (mag + rhs_size + 1)
        rv, cv, av = rows[valid], cols[valid], a[valid]
        from_lo = (lo[rv] - (mx[rv] - maximum[valid]) - margin[rv]) / av
        from_hi = (hi[rv] - (mn[rv] - minimum[valid]) + margin[rv]) / av
        new_lower, new_upper = lower.copy(), upper.copy()
        np.maximum.at(new_lower, cv, np.where(av > 0, from_lo, from_hi))
        np.minimum.at(new_upper, cv, np.where(av > 0, from_hi, from_lo))
        new_lower[integer] = np.ceil(new_lower[integer] - 1e-9)
        new_upper[integer] = np.floor(new_upper[integer] + 1e-9)
        if np.any(new_lower > new_upper + 1e-7):
            # Leave infeasibility certification to the unrestricted native solver.
            break
        tighten_lo = (new_lower > lower + 1e-7) & (new_lower <= new_upper)
        tighten_hi = (new_upper < upper - 1e-7) & (new_lower <= new_upper)
        n = int(tighten_lo.sum() + tighten_hi.sum())
        if not n:
            break
        lower[tighten_lo], upper[tighten_hi] = new_lower[tighten_lo], new_upper[tighten_hi]
        updated += n
    return updated


def shipping_covers(model, limit=512):
    """For ya=sum(q*s), every cover whose weight exceeds UB(ya) cannot ship together."""
    seen = set()
    def add(cols, rhs):
        key = (tuple(sorted(cols)), rhs)
        if len(cols) < 2 or key in seen or len(seen) >= limit:
            return
        seen.add(key)
        model.rows.append(dict.fromkeys(cols, 1.0))
        model.lo.append(-math.inf)
        model.hi.append(rhs)
        model.labels.append('fast_shipping_cover')

    for i in range(len(model.labels)):
        if model.labels[i] != 'whole_order_product_link' or model.lo[i] != 0 or model.hi[i] != 0:
            continue
        row = model.rows[i]
        actual = [j for j, a in row.items() if model.keys[j][0] == 'ya' and a == 1]
        ships = [(j, -a) for j, a in row.items() if model.keys[j][0] == 'order_ship'
                 and a < 0 and model.integer[j] and model.lb[j] >= 0 and model.ub[j] <= 1]
        if len(actual) != 1 or len(ships) + 1 != len(row):
            continue
        items = sorted(((j, w) for j, w in ships if model.ub[j] > 0), key=lambda x: (-x[1], x[0]))
        cap = model.ub[actual[0]]
        threshold = cap + 1e-8 * max(1, abs(cap))
        clique = [j for j, w in items if 2 * w > threshold]
        add(clique, 1)
        cover, total = [], 0.0
        for j, weight in items:
            cover.append(j)
            total += weight
            if total > threshold:
                add(cover, len(cover) - 1)
                break
        if len(seen) >= limit:
            break
    return len(seen)


def strengthen(original):
    m = copy(original)
    m.lb, m.ub = np.array(original.lb, dtype=float), np.array(original.ub, dtype=float)
    m.rows, m.lo, m.hi, m.labels = map(list, (original.rows, original.lo, original.hi, original.labels))
    updates = propagate(m)
    smaller = 0
    for i, (label, row) in enumerate(zip(m.labels, m.rows)):
        if label == 'immediate_start_material_shortage':
            inv = next(j for j in row if m.keys[j][0] in ('I', 'raw_I'))
            flag = next(j for j in row if m.keys[j][0] == 'material_short')
            old = row[flag]
            if old <= 0:
                continue
            # Preserve the original implication, including the fractional raw-stock cutoff.
            cutoff = m.hi[i] - old
            if m.keys[inv][0] == 'I':
                cutoff = math.floor(cutoff + 1e-8)
            new = max(0.0, m.ub[inv] - cutoff)
            if new < old - 1e-8 or cutoff < m.hi[i] - old - 1e-8:
                m.rows[i] = {inv: 1.0, flag: new}
                m.hi[i] = max(m.ub[inv], cutoff)
                smaller += int(new < old - 1e-8)
        elif label == 'immediate_start_no_idle':
            wait = next(j for j in row if m.keys[j][0] == 'u')
            bound = m.ub[wait]
            if any(-a > bound + 1e-8 for j, a in row.items() if j != wait):
                m.rows[i] = {j: (a if j == wait else -min(-a, bound)) for j, a in row.items()}
                smaller += sum(-a > bound + 1e-8 for j, a in row.items() if j != wait)
    cuts = shipping_covers(m)
    return m, dict(bound_updates=updates, smaller_big_m=int(smaller), shipping_cover_cuts=cuts,
                   original_rows=len(original.rows), strengthened_rows=len(m.rows), columns=len(m.keys))

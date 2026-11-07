"""Whole-order planning with all-SKU loss weights.

The binary loss settles the complete SalesOrder. Its objective coefficient counts
every ordered stock unit, including purchased resale. Production flow balances
continue to contain manufactured products only. Historical runtime is read-only.
"""
from collections import Counter, defaultdict
from datetime import timedelta

from companyx_unified_v2.legacy import module


def build_model(data, inv, pipe, book, queue, orders, day, case,
                lost_penalty=3000, horizon=None):
    legacy = module('companyx_active_days')
    model, meta = legacy.build(data, inv, pipe, book, queue, day, horizon=horizon)
    meta.update(case=case, order_ship_vars={}, order_loss_vars={}, order_weights={})
    if case == '7A':
        return model, meta
    if case not in ('7B', '7C') or lost_penalty <= 0:
        raise ValueError('Invalid atomic optimization configuration')
    today = data['start'] + timedelta(days=day)
    actual_rows = {}
    for index, (label, row) in enumerate(zip(model.labels, model.rows)):
        if label == 'Ba':
            for variable, coefficient in row.items():
                key = model.keys[variable]
                if key[0] == 'Ba' and coefficient == 1:
                    actual_rows[key[1], key[2]] = index
    contributions = defaultdict(dict)
    seen = set()
    for order in orders:
        oid = int(order['SalesOrderID'])
        if oid in seen or order['order'] > today:
            raise ValueError('Duplicate order or future information in optimizer input')
        seen.add(oid)
        quantities = Counter()
        all_sku_units = 0
        for line in order['lines']:
            if line['shipped'] or line['lost'] or line['remaining'] != line['q']:
                raise ValueError('Optimizer requires unsettled whole orders for 7B/7C')
            all_sku_units += line['remaining']
            if line['manufactured']:
                quantities[line['p']] += line['remaining']
        if not quantities:
            raise ValueError('Order has no manufactured demand')
        due = max(0, (order['due'] - today).days)
        if due > meta['H'] or (case == '7C' and order['due'] < today):
            raise ValueError('Deadline outside optimization horizon or expired order')
        # Keep total loss weight separate from manufactured-only flow quantities.
        meta['order_weights'][oid] = all_sku_units
        settled = {}
        for k in ([due] if case == '7C' else range(due, meta['H'] + 1)):
            variable = model.var(('order_ship', oid, k), 1, integer=True)
            meta['order_ship_vars'][oid, k] = variable
            settled[variable] = 1
            for p, quantity in quantities.items():
                contributions[p, k][variable] = -quantity
        if case == '7C':
            loss = model.var(('order_loss', oid, due), 1,
                             cost=lost_penalty * all_sku_units, integer=True)
            meta['order_loss_vars'][oid, due] = loss
            settled[loss] = 1
            for p, quantity in quantities.items():
                # Manufactured balance: Ba(k)+ya(k)+lost(k)-Ba(k-1)=known demand.
                model.rows[actual_rows[p, due]][loss] = quantity
        else:
            settled[model.var(('order_unserved', oid, meta['H']), 1, integer=True)] = 1
        model.row(settled, 1, 'whole_order_settlement')
    for p in data['roots']:
        for k in range(meta['H'] + 1):
            terms = {meta['v']['ya', p, k]: 1, **contributions[p, k]}
            model.row(terms, 0, 'whole_order_product_link')
    return model, meta


def action_from_plan(model, meta, z, day):
    action = module('companyx_active_days').action_from_plan(model, meta, z, day)
    action['order_shipments'] = [oid for (oid, k), j in meta['order_ship_vars'].items() if k == 0 and z[j]]
    action['order_losses'] = [oid for (oid, k), j in meta['order_loss_vars'].items() if k == 0 and z[j]]
    return action

"""SalesOrder grouping, atomic dispatch, deadline cancellation and service KPIs.

External resale is drawn only for a shipment that is actually committed. The
virtual source has no infinite stock record and is shared with BOM supply.
"""
from collections import Counter, defaultdict
from copy import deepcopy
from datetime import date, timedelta

CASES = {'7A': 'partial_backorder', '7B': 'full_order_backorder',
         '7C': 'full_order_lost_at_due_eod'}

def as_date(value):
    return date.fromisoformat(value[:10]) if isinstance(value, str) else value

class OrderBook:
    def __init__(self, lines, manufactured, external, start, end, case, finite_external=()):
        if case not in CASES:
            raise ValueError(f'Unsupported case {case}')
        self.case, self.start = case, start
        self.finite_external = set(finite_external)
        self.manufactured, self.external = set(manufactured), set(external)
        if self.manufactured & self.external:
            raise ValueError('A product cannot have both finite and unlimited supply')
        self.lines, self.orders, self.events = [], {}, defaultdict(list)
        self.audit, self.delivery, self.external_draws = [], [], []
        self.active = {}
        identifiers = set()
        for original in lines:
            line = deepcopy(original)
            line['order'], line['due'] = as_date(line['order']), as_date(line['due'])
            if line['id'] in identifiers:
                raise ValueError('Duplicate SalesOrderDetailID')
            identifiers.add(line['id'])
            if line['p'] not in self.manufactured | self.external:
                raise ValueError(f'Unclassified product {line["p"]}')
            if line['q'] <= 0 or int(line['q']) != line['q']:
                raise ValueError('Positive integer SKU quantity required')
            if not start <= line['order'] <= end or line['due'] < line['order']:
                raise ValueError('Invalid order dates or run cohort')
            line.update(q=int(line['q']), remaining=int(line['q']), lost=0,
                        on_time=0, immediate=0, activation=line['order'], shipped=0,
                        manufactured=line['p'] in self.manufactured)
            oid = int(line['SalesOrderID'])
            if oid not in self.orders:
                order = dict(SalesOrderID=oid, order=line['order'], due=line['due'],
                             lines=[], status='UNREVEALED', completed=None, cancelled=None)
                self.orders[oid] = order
                self.events[(line['order']-start).days].append(order)
            order = self.orders[oid]
            if order['order'] != line['order'] or order['due'] != line['due']:
                raise ValueError('Header dates differ among sibling lines')
            order['lines'].append(line)
            self.lines.append(line)
        for order in self.orders.values():
            if not any(line['manufactured'] for line in order['lines']):
                raise ValueError('Scenario 7 cohort requires a manufactured line in every SalesOrder')

    @staticmethod
    def priority(order):
        return order['due'], order['order'], order['SalesOrderID']

    def event(self, day, order, kind, **values):
        self.audit.append(dict(event_sequence=len(self.audit)+1, day=day,
                               date=self.start+timedelta(days=day),
                               SalesOrderID=order['SalesOrderID'], event_type=kind, **values))

    def reveal(self, day):
        for order in self.events.get(day, []):
            order['status'] = 'OPEN'
            self.active[order['SalesOrderID']] = order
            self.event(day, order, 'ORDER_REVEALED')

    def manufactured_book(self):
        book = defaultdict(list)
        for order in self.active.values():
            for line in order['lines']:
                if line['manufactured'] and line['remaining']:
                    book[line['p']].append(line)
        return book

    def snapshot(self):
        # The controller gets only revealed, unclosed orders, not the future calendar.
        orders = deepcopy(sorted(self.active.values(), key=self.priority))
        for order in orders:
            for line in order['lines']:
                # Historical ShipDate/status are evaluation evidence, not known demand.
                for field in ('ship', 'ShipDate', 'Status'):
                    line.pop(field, None)
        return orders

    def _ship_line(self, line, amount, inv, today, day):
        if not amount:
            return
        if not 0 < amount <= line['remaining'] or today < line['due']:
            raise ValueError('Invalid or early shipment')
        if line['manufactured'] or line['p'] in self.finite_external:
            if inv[line['p']] < amount:
                raise ValueError('Insufficient manufactured inventory')
            inv[line['p']] -= amount
        else:
            self.external_draws.append(dict(day=day, date=today, ProductID=line['p'],
                unit='SKU', quantity=amount, purpose='CUSTOMER_SHIPMENT',
                SalesOrderID=line['SalesOrderID'], line_id=line['id'], parent=None))
        line['remaining'] -= amount
        line['shipped'] += amount
        line['on_time'] += amount if today <= line['due'] else 0
        line['immediate'] += amount if today == line['order'] else 0
        self.delivery.append(dict(day=day, date=today, id=line['id'],
            SalesOrderID=line['SalesOrderID'], ProductID=line['p'], quantity=amount,
            manufactured=line['manufactured']))

    def _close_shipped(self, order, today, day):
        if all(line['remaining'] == 0 for line in order['lines']):
            order.update(status='SHIPPED', completed=today)
            self.event(day, order, 'ORDER_SHIPPED', on_time=today <= order['due'])
            self.active.pop(order['SalesOrderID'])
        elif any(line['shipped'] for line in order['lines']):
            order['status'] = 'PARTIALLY_SHIPPED'

    def dispatch_partial(self, inv, today, day, planned=None):
        if self.case != '7A':
            raise ValueError('Partial dispatch is only supported in 7A')
        lines = [line for order in self.active.values() for line in order['lines']
                 if line['remaining'] and line['due'] <= today]
        budgets = None if planned is None else Counter({int(p): q for p, q in planned.items()})
        for line in sorted(lines, key=lambda x: (x['p'], x['due'], x['id'])):
            amount = line['remaining']
            if line['manufactured']:
                amount = min(amount, inv[line['p']])
                if budgets is not None:
                    amount = min(amount, budgets[line['p']])
                    budgets[line['p']] -= amount
            self._ship_line(line, amount, inv, today, day)
        if budgets is not None and any(budgets.values()):
            raise ValueError('Optimizer shipment exceeds eligible line demand')
        for order in list(self.active.values()):
            self._close_shipped(order, today, day)

    def dispatch_atomic(self, inv, today, day, selected=None):
        if self.case == '7A':
            raise ValueError('Atomic dispatch is not the partial baseline')
        selected = None if selected is None else set(map(int, selected))
        if selected is not None and not selected <= self.active.keys():
            raise ValueError('Optimizer selected an unknown/closed order')
        for order in sorted(list(self.active.values()), key=self.priority):
            oid = order['SalesOrderID']
            if selected is not None and oid not in selected:
                continue
            eligible = order['due'] <= today and (self.case != '7C' or order['due'] == today)
            if not eligible:
                if selected is not None:
                    raise ValueError('Optimizer selected early/expired shipment')
                continue
            needed = Counter()
            for line in order['lines']:
                if line['shipped'] or line['lost']:
                    raise ValueError('Atomic order has already been partially settled')
                if line['manufactured'] or line['p'] in self.finite_external:
                    needed[line['p']] += line['remaining']
            # Aggregate repeated ProductIDs before checking. No mutation on failure.
            if any(inv[p] < quantity for p, quantity in needed.items()):
                if selected is not None:
                    raise ValueError('Optimizer full-order shipment is infeasible')
                continue
            for line in order['lines']:
                self._ship_line(line, line['remaining'], inv, today, day)
            self._close_shipped(order, today, day)

    def cancel_due(self, today, day):
        if self.case != '7C':
            return []
        cancelled = []
        for order in sorted(list(self.active.values()), key=self.priority):
            if order['due'] > today:
                continue
            if order['due'] < today:
                raise ValueError('Expired order survived its end-of-day deadline')
            for line in order['lines']:
                if line['shipped'] or line['lost']:
                    raise ValueError('Cannot lose an already partially shipped atomic order')
                line['lost'] = line['remaining']
                line['remaining'] = 0
            order.update(status='CANCELLED_DUE_DATE', cancelled=today)
            self.event(day, order, 'ORDER_CANCELLED_DUE_DATE',
                lost_manufactured_units=sum(x['lost'] for x in order['lines'] if x['manufactured']),
                lost_all_sku_units=sum(x['lost'] for x in order['lines']))
            cancelled.append(order['SalesOrderID'])
            self.active.pop(order['SalesOrderID'])
        return cancelled

    def check(self):
        for line in self.lines:
            if line['q'] != line['shipped'] + line['lost'] + line['remaining']:
                raise AssertionError('Order quantity conservation failed')
            if min(line['shipped'], line['lost'], line['remaining']) < 0:
                raise AssertionError('Negative line state')
        if self.case != '7A':
            for order in self.orders.values():
                for field in ('shipped', 'lost'):
                    values = [x[field] == x['q'] for x in order['lines']]
                    if any(values) and not all(values):
                        raise AssertionError('Whole-order atomicity failed')

    def metrics(self, start, end):
        cohort = [o for o in self.orders.values() if start <= o['due'] <= end]
        result = dict(due_orders=len(cohort),
            orders_full_on_time=sum(o['status']=='SHIPPED' and o['completed']<=o['due'] for o in cohort),
            lost_orders=sum(o['status']=='CANCELLED_DUE_DATE' for o in cohort),
            open_due_orders=sum(o['status'] in ('OPEN','PARTIALLY_SHIPPED') for o in cohort))
        result['full_order_on_time_rate'] = result['orders_full_on_time']/len(cohort) if cohort else None
        result['lost_order_rate'] = result['lost_orders']/len(cohort) if cohort else None
        for name, filt in [('manufactured', lambda x:x['manufactured']), ('all_sku', lambda x:True)]:
            lines=[x for o in cohort for x in o['lines'] if filt(x)]
            total=sum(x['q'] for x in lines)
            result.update({f'due_units_{name}':total,
                           f'on_time_units_{name}':sum(x['on_time'] for x in lines),
                           f'shipped_units_{name}':sum(x['shipped'] for x in lines),
                           f'lost_units_{name}':sum(x['lost'] for x in lines),
                           f'backlog_units_{name}':sum(x['remaining'] for x in lines)})
            result[f'on_time_unit_rate_{name}']=result[f'on_time_units_{name}']/total if total else None
        return result

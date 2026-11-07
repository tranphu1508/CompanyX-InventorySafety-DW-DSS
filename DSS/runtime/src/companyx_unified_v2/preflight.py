"""Bounded-memory relational checks on local staging CSV; no production DB writes."""
from pathlib import Path
import csv,json,sqlite3,uuid,math
from .legacy import GPT,read,save

PRIMARY_KEYS={
    'RunEntity':['PlanningRunKey','EntityCode'],
    'Fact_SimulationEvent':['PlanningRunKey','EventSequence'],
    'Fact_SimulationDaily':['PlanningRunKey','DateKey','ProductKey','LocationKey'],
    'Fact_SimulationOrder':['PlanningRunKey','CustomerOrderCode'],
    'Fact_OptimizationSolve':['PlanningRunKey','SolveSequence'],
    'Fact_StochasticDraw':['PlanningRunKey','DrawSequence'],
    'Fact_PolicySimulation':['PlanningRunKey','ProductKey'],
    'Bridge_RunEntityRelation':['PlanningRunKey','ParentEntityCode','ChildEntityCode','RelationCode'],
    'Fact_RunSummary':['PlanningRunKey']}

def validate_solve_rows(values):
    seen=set();sequences=set()
    for r in values:
        seq=int(r['SolveSequence']);key=(r['DecisionAt'],int(r['AttemptNo']),r['ObjectiveStage'])
        if seq<=0 or int(r['AttemptNo'])<=0 or seq in sequences or key in seen:raise ValueError('Duplicate/invalid solve attempt')
        sequences.add(seq);seen.add(key)
        if r['ActionSource'] not in ('SOLVER_INCUMBENT','WARM_START','FALLBACK','NONE'):raise ValueError('Invalid V6 ActionSource')
        if r['ActionSource']=='SOLVER_INCUMBENT' and (not r['HasFeasibleSolution'] or r['SolverStatus'] not in ('OPTIMAL','NEAR_OPTIMAL','FEASIBLE_TIME_LIMIT')):
            raise ValueError('Action references an unaccepted solver result')
        seconds=float(r['SolverSeconds'])
        if not math.isfinite(seconds) or seconds<0 or r['InformationCutoffAt']>r['DecisionAt']:raise ValueError('Invalid solve time/cutoff')
        if r['ActionSource']=='SOLVER_INCUMBENT' and not r.get('DecisionOutputReference'):raise ValueError('Missing decision artifact')

def check(staging,contract,scope=None):
    staging=Path(staging);cache=GPT/'tmp/unified-preflight';cache.mkdir(parents=True,exist_ok=True)
    database=cache/(uuid.uuid4().hex+'.sqlite');con=sqlite3.connect(database);counts={}
    try:
        con.execute('PRAGMA temp_store=FILE')
        for table,cols in contract.items():
            fields=[c['name'] for c in cols]
            definitions=[]
            for c in cols:
                typ='REAL' if c['sql_type'].startswith('decimal') else 'INTEGER' if c['sql_type'] in ('int','bigint','bit') else 'TEXT'
                definitions.append('"'+c['name']+'" '+typ+('' if c['nullable'] else ' NOT NULL'))
            definitions.append('PRIMARY KEY ('+','.join(PRIMARY_KEYS[table])+')')
            con.execute('CREATE TABLE '+table+' ('+','.join(definitions)+')')
            with (staging/(table+'.csv')).open(encoding='utf-8-sig',newline='') as f:
                reader=csv.DictReader(f)
                if reader.fieldnames!=fields:raise ValueError('Column contract mismatch: '+table)
                count=0
                for row in reader:
                    con.execute('INSERT INTO '+table+' VALUES ('+','.join('?' for _ in fields)+')',[None if row[k]=='' else row[k] for k in fields]);count+=1
            counts[table]=count
        con.execute('CREATE INDEX event_entity ON Fact_SimulationEvent(PlanningRunKey,EntityCode)')
        con.execute('CREATE INDEX event_product_day ON Fact_SimulationEvent(PlanningRunKey,ProductKey,DateKey)')
        con.execute('CREATE INDEX relation_child ON Bridge_RunEntityRelation(PlanningRunKey,ChildEntityCode,RelationCode)')
        checks=[]
        def zero(label,sql):
            n=con.execute(sql).fetchone()[0]
            if n:raise ValueError(f'{label}: {n} invalid rows/groups')
            checks.append(label)
        zero('Positive event quantity','SELECT COUNT(*) FROM Fact_SimulationEvent WHERE Quantity<=0')
        from .integration_contract import EVENT_ENTITY_TYPES,RELATION_TYPES
        con.execute('CREATE TEMP TABLE event_types(code TEXT PRIMARY KEY,entity TEXT)')
        con.executemany('INSERT INTO event_types VALUES (?,?)',EVENT_ENTITY_TYPES.items())
        zero('V6 event catalog and entity type','''SELECT COUNT(*) FROM Fact_SimulationEvent e
            LEFT JOIN event_types t ON e.EventCode=t.code LEFT JOIN RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.EntityCode=r.EntityCode
            WHERE t.code IS NULL OR r.EntityType<>t.entity''')
        zero('V6 purchase supply references',"SELECT COUNT(*) FROM Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT') AND SupplyOptionKey IS NULL")
        con.execute('CREATE TEMP TABLE relation_types(code TEXT PRIMARY KEY,parent TEXT,child TEXT)')
        con.executemany('INSERT INTO relation_types VALUES (?,?,?)',[(k,*v) for k,v in RELATION_TYPES.items()])
        zero('Typed entity relations','''SELECT COUNT(*) FROM Bridge_RunEntityRelation b
            LEFT JOIN relation_types t ON b.RelationCode=t.code
            LEFT JOIN RunEntity p ON b.PlanningRunKey=p.PlanningRunKey AND b.ParentEntityCode=p.EntityCode
            LEFT JOIN RunEntity c ON b.PlanningRunKey=c.PlanningRunKey AND b.ChildEntityCode=c.EntityCode
            WHERE t.code IS NULL OR p.EntityCode IS NULL OR c.EntityCode IS NULL OR p.EntityType<>t.parent OR c.EntityType<>t.child
               OR p.EntityCode=c.EntityCode OR b.AllocatedQty<0 OR (b.AllocatedQty IS NULL)<>(b.AllocatedProductKey IS NULL)''')
        zero('Receipt lot relationship and gross inspection','''SELECT COUNT(*) FROM RunEntity r LEFT JOIN
            (SELECT PlanningRunKey,EntityCode,SUM(Quantity) qty FROM Fact_SimulationEvent
             WHERE EventCode IN ('BUY_RECEIVE_GOOD','BUY_REJECT') GROUP BY PlanningRunKey,EntityCode) e
            ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='RECEIPT_LOT' AND (ABS(r.OriginalQty-COALESCE(e.qty,0))>0.00001 OR
            (SELECT COUNT(*) FROM Bridge_RunEntityRelation b WHERE b.PlanningRunKey=r.PlanningRunKey AND b.ChildEntityCode=r.EntityCode AND b.RelationCode='HAS_RECEIPT')<>1)''')
        zero('Receipt event parent relationship','''SELECT COUNT(*) FROM Fact_SimulationEvent e
            WHERE e.EventCode IN ('BUY_RECEIVE_GOOD','BUY_REJECT') AND NOT EXISTS
            (SELECT 1 FROM Bridge_RunEntityRelation b WHERE b.PlanningRunKey=e.PlanningRunKey AND b.ChildEntityCode=e.EntityCode
            AND b.ParentEntityCode=e.RelatedEntityCode AND b.RelationCode='HAS_RECEIPT')''')
        zero('Event entity reference','''SELECT COUNT(*) FROM Fact_SimulationEvent e LEFT JOIN RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.EntityCode=r.EntityCode WHERE r.EntityCode IS NULL''')
        zero('Related entity reference','''SELECT COUNT(*) FROM Fact_SimulationEvent e LEFT JOIN RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.RelatedEntityCode=r.EntityCode WHERE e.RelatedEntityCode IS NOT NULL AND r.EntityCode IS NULL''')
        zero('Decision solve reference','''SELECT COUNT(*) FROM Fact_SimulationEvent e LEFT JOIN Fact_OptimizationSolve s
            ON e.PlanningRunKey=s.PlanningRunKey AND e.DecisionSolveSequence=s.SolveSequence WHERE e.DecisionSolveSequence IS NOT NULL AND s.SolveSequence IS NULL''')
        zero('Execution lineage','''SELECT COUNT(*) FROM Fact_SimulationEvent e LEFT JOIN RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.ProductionExecutionCode=r.EntityCode
            WHERE e.EventCode IN ('PRODUCTION_START','BOM_ISSUE','PRODUCTION_GOOD')
              AND (r.EntityCode IS NULL OR r.EntityType<>'OPERATION_EXECUTION')''')
        zero('Execution job relationship','''SELECT COUNT(*) FROM Fact_SimulationEvent e WHERE e.EventCode IN ('PRODUCTION_START','BOM_ISSUE','PRODUCTION_GOOD')
            AND NOT EXISTS (SELECT 1 FROM Bridge_RunEntityRelation b WHERE b.PlanningRunKey=e.PlanningRunKey
            AND b.ParentEntityCode=e.EntityCode AND b.ChildEntityCode=e.ProductionExecutionCode AND b.RelationCode='HAS_OPERATION')''')
        zero('Atomic order action','''SELECT COUNT(*) FROM Fact_SimulationEvent WHERE EventCode IN
            ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE') AND OrderActionCode IS NULL''')
        zero('Order line header reference','''SELECT COUNT(*) FROM RunEntity r LEFT JOIN Fact_SimulationOrder o
            ON r.PlanningRunKey=o.PlanningRunKey AND r.CustomerOrderCode=o.CustomerOrderCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' AND o.CustomerOrderCode IS NULL''')
        zero('Header expected line count','''SELECT COUNT(*) FROM (SELECT o.PlanningRunKey,o.CustomerOrderCode,o.ExpectedLineCount,
            COUNT(r.EntityCode) actual FROM Fact_SimulationOrder o LEFT JOIN RunEntity r
            ON o.PlanningRunKey=r.PlanningRunKey AND o.CustomerOrderCode=r.CustomerOrderCode AND r.EntityType='CUSTOMER_ORDER_LINE'
            GROUP BY o.PlanningRunKey,o.CustomerOrderCode HAVING actual<>o.ExpectedLineCount)''')
        con.execute('''CREATE TEMP VIEW settled AS SELECT r.PlanningRunKey,r.EntityCode,r.CustomerOrderCode,r.OriginalQty,
            COALESCE(SUM(CASE WHEN e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE') THEN e.Quantity ELSE 0 END),0) shipped,
            COALESCE(SUM(CASE WHEN e.EventCode='LOST_SALE' THEN e.Quantity ELSE 0 END),0) lost,
            COUNT(DISTINCT CASE WHEN e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE') THEN e.OrderActionCode END) actions
            FROM RunEntity r LEFT JOIN Fact_SimulationEvent e ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' GROUP BY r.PlanningRunKey,r.EntityCode''')
        zero('Order conservation','SELECT COUNT(*) FROM settled WHERE shipped<0 OR lost<0 OR shipped+lost>OriginalQty+0.00001')
        zero('Whole order settlement','''SELECT COUNT(*) FROM settled s JOIN Fact_SimulationOrder o
            ON s.PlanningRunKey=o.PlanningRunKey AND s.CustomerOrderCode=o.CustomerOrderCode
            WHERE (o.OrderStatus='FULFILLED' AND (ABS(s.shipped-s.OriginalQty)>0.00001 OR s.lost<>0 OR s.actions<>1))
               OR (o.OrderStatus='LOST' AND (ABS(s.lost-s.OriginalQty)>0.00001 OR s.shipped<>0 OR s.actions<>1))
               OR (o.OrderStatus='OPEN' AND (s.shipped<>0 OR s.lost<>0))''')
        zero('Full-order shared action','''SELECT COUNT(*) FROM (SELECT r.PlanningRunKey,r.CustomerOrderCode
            FROM RunEntity r JOIN Fact_SimulationEvent e ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' AND e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE')
            GROUP BY r.PlanningRunKey,r.CustomerOrderCode HAVING COUNT(DISTINCT e.OrderActionCode)<>1)''')
        zero('Nonnegative daily stock','''SELECT COUNT(*) FROM Fact_SimulationDaily WHERE OnHandQty<0 OR ProductionWIPQty<0
            OR QueuedProductionQty<0 OR PurchaseInTransitQty<0 OR OpenPurchaseQty<0 OR CustomerBacklogQty<0 OR LostQty<0''')
        zero('No invented dispatch/transit','SELECT COUNT(*) FROM Fact_SimulationDaily WHERE PurchaseInTransitQty<>0 OR OwnedInTransitValue<>0')
        zero('Pending purchase state conservation','''WITH movements AS (
            SELECT PlanningRunKey,ProductKey,DateKey,SUM(CASE WHEN EventCode='BUY_ORDER' THEN Quantity ELSE -Quantity END) delta
            FROM Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')
            GROUP BY PlanningRunKey,ProductKey,DateKey), balances AS (
            SELECT d.OpenPurchaseQty,SUM(COALESCE(e.delta,0)) OVER
            (PARTITION BY d.PlanningRunKey,d.ProductKey ORDER BY d.DateKey ROWS UNBOUNDED PRECEDING) expected
            FROM Fact_SimulationDaily d LEFT JOIN movements e ON e.PlanningRunKey=d.PlanningRunKey
            AND e.ProductKey=d.ProductKey AND e.DateKey=d.DateKey)
            SELECT COUNT(*) FROM balances WHERE ABS(OpenPurchaseQty-expected)>0.00001''')
        zero('Daily/event customer quantities','''SELECT COUNT(*) FROM Fact_SimulationDaily d LEFT JOIN
            (SELECT PlanningRunKey,DateKey,ProductKey,
             SUM(CASE WHEN EventCode='SHIP_ON_TIME' THEN Quantity ELSE 0 END) ont,
             SUM(CASE WHEN EventCode='SHIP_LATE' THEN Quantity ELSE 0 END) late,
             SUM(CASE WHEN EventCode='LOST_SALE' THEN Quantity ELSE 0 END) lost
             FROM Fact_SimulationEvent GROUP BY PlanningRunKey,DateKey,ProductKey) e
            ON d.PlanningRunKey=e.PlanningRunKey AND d.DateKey=e.DateKey AND d.ProductKey=e.ProductKey
            WHERE ABS(d.OnTimeDeliveredQty-COALESCE(e.ont,0))>0.00001 OR ABS(d.LateDeliveredQty-COALESCE(e.late,0))>0.00001
               OR ABS(d.LostQty-COALESCE(e.lost,0))>0.00001''')
        zero('Summary inventory valuation','''SELECT COUNT(*) FROM Fact_RunSummary s JOIN
            (SELECT PlanningRunKey,AVG(total) average_value FROM (SELECT PlanningRunKey,DateKey,SUM(OnHandValue+WIPValue) total
             FROM Fact_SimulationDaily GROUP BY PlanningRunKey,DateKey) GROUP BY PlanningRunKey) d
            ON s.PlanningRunKey=d.PlanningRunKey WHERE ABS(s.AvgInventoryValue-d.average_value)>0.0001''')
        zero('Product demand conservation','''SELECT COUNT(*) FROM Fact_PolicySimulation WHERE
            ABS(OpeningBacklogQty+TotalDemandQty-FilledQty-LostQty-EndingBacklogQty)>0.00001''')
        zero('Product calendar and valuation','''SELECT COUNT(*) FROM Fact_PolicySimulation p LEFT JOIN
            (SELECT PlanningRunKey,ProductKey,COUNT(*) n,AVG(OnHandQty) oh,AVG(ProductionWIPQty) wip,
              AVG(OnHandValue+WIPValue) val,SUM(CustomerBacklogQty) late FROM Fact_SimulationDaily GROUP BY PlanningRunKey,ProductKey) d
            ON p.PlanningRunKey=d.PlanningRunKey AND p.ProductKey=d.ProductKey WHERE d.n IS NULL OR p.SimulatedDays<>d.n
            OR ABS(p.AvgOnHandQty-d.oh)>0.00001 OR ABS(p.AvgWIPQty-d.wip)>0.00001 OR ABS(p.AvgInventoryValue-d.val)>0.0001
            OR ABS(p.LateUnitDays-d.late)>0.00001 OR p.AvgInTransitQty<>0 OR p.AvgInTransitValue<>0''')
        zero('Product summary coverage','''SELECT COUNT(*) FROM (SELECT DISTINCT PlanningRunKey,ProductKey FROM Fact_SimulationDaily) d
            LEFT JOIN Fact_PolicySimulation p ON p.PlanningRunKey=d.PlanningRunKey AND p.ProductKey=d.ProductKey WHERE p.ProductKey IS NULL''')
        solve_rows=[dict(zip([c['name'] for c in contract['Fact_OptimizationSolve']],r)) for r in con.execute('SELECT * FROM Fact_OptimizationSolve')]
        validate_solve_rows(solve_rows)
        if scope:
            from datetime import date
            n=(date.fromisoformat(scope['End'])-date.fromisoformat(scope['Start'])).days+1
            zero('Full calendar days',f'SELECT COUNT(*) FROM Fact_PolicySimulation WHERE SimulatedDays<>{n}')
            rate=float(scope['HoldingCostRatePerYear'])
            zero('Annual holding cost',f'SELECT COUNT(*) FROM Fact_PolicySimulation WHERE ABS(HoldingCost-AvgInventoryValue*{n}*{rate}/365.0)>0.0001')
            if scope['Policy']=='ROP':
                zero('ROP has no fabricated solves','SELECT COUNT(*) FROM Fact_OptimizationSolve')
                zero('ROP solver seconds NULL','SELECT COUNT(*) FROM Fact_RunSummary WHERE SolverSeconds IS NOT NULL')
            con.execute('CREATE TEMP TABLE service_products(p INTEGER PRIMARY KEY)')
            con.executemany('INSERT INTO service_products VALUES (?)',[(p,) for p in scope['ServiceProductKeys']])
            zero('Same-cohort summary totals','''SELECT COUNT(*) FROM Fact_RunSummary s JOIN
                (SELECT PlanningRunKey,SUM(TotalDemandQty) due,SUM(OnTimeDeliveredQty) ont,SUM(LostQty) lost,SUM(LateUnitDays) late
                 FROM Fact_PolicySimulation WHERE ProductKey IN (SELECT p FROM service_products) GROUP BY PlanningRunKey) p
                ON s.PlanningRunKey=p.PlanningRunKey WHERE ABS(s.CustomerDueQty-p.due)>0.00001 OR ABS(s.OnTimeDeliveredQty-p.ont)>0.00001
                OR ABS(s.LostQty-p.lost)>0.00001 OR ABS(s.LateUnitDays-p.late)>0.00001''')
        zero('Stochastic draw uniqueness','''SELECT COUNT(*) FROM (SELECT PlanningRunKey,StreamCode,EventIdentity,DrawIndex
            FROM Fact_StochasticDraw GROUP BY PlanningRunKey,StreamCode,EventIdentity,DrawIndex HAVING COUNT(*)>1)''')
        result=dict(status='PASSED',rows=counts,checks=len(checks),check_names=checks,scope='Local relational and event reconciliation; external DW surrogate FK resolution is still required',production_database_written=False)
        save(staging/'preflight.json',result);return result
    except (ValueError,sqlite3.Error) as exc:
        save(staging/'preflight.json',dict(status='FAILED',error=str(exc),production_database_written=False))
        raise ValueError('Relational preflight failed: '+str(exc)) from exc
    finally:
        con.close();database.unlink(missing_ok=True)

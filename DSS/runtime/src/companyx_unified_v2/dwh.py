"""Strict local staging adapter. It never invents surrogate keys or writes a DB."""
from pathlib import Path
from datetime import datetime
from decimal import Decimal,ROUND_HALF_UP
import argparse,csv,json,math,re
from .legacy import read,save
from .run import sha,stamp
from .integration_contract import EVENT_ENTITY_TYPES,validate_profile

def rows(path):
    if path.exists():
        with path.open(encoding='utf-8') as f:
            for line in f:
                if line.strip():yield json.loads(line)

def sql_value(col,value):
    """Reject overflow/type errors before declaring a CSV ready for staging."""
    if value is None:
        if not col['nullable']:raise ValueError('Missing '+col['name'])
        return None
    typ=col['sql_type']
    if typ in ('int','bigint'):
        bits=32 if typ=='int' else 64
        if type(value) is not int or not -(2**(bits-1))<=value<2**(bits-1):raise ValueError('Integer overflow/type: '+col['name'])
    elif typ=='bit':
        if value not in (True,False,0,1):raise ValueError('Invalid bit: '+col['name'])
        value=int(value)
    elif typ.startswith('decimal'):
        precision,scale=map(int,re.findall(r'\d+',typ))
        d=Decimal(str(value))
        if not d.is_finite():raise ValueError('Nonfinite decimal: '+col['name'])
        d=d.quantize(Decimal(1).scaleb(-scale),rounding=ROUND_HALF_UP)
        if abs(d)>=Decimal(10)**(precision-scale):raise ValueError('Decimal overflow: '+col['name'])
        value=format(d,'f')
    elif typ.startswith('nvarchar'):
        n=int(re.search(r'\d+',typ)[0])
        if not isinstance(value,str) or len(value.encode('utf-16-le'))//2>n:raise ValueError('Text length/type: '+col['name'])
    elif typ=='datetime2':datetime.fromisoformat(str(value).replace('Z','+00:00'))
    return value

def validate_artifact(folder):
    folder=Path(folder);complete=read(folder/'completion.json');manifest=read(folder/'table_manifest.json')
    if complete['status']!='COMPLETE' or sha(folder/'table_manifest.json')!=complete['table_manifest_sha256']:raise ValueError('Incomplete/changed run')
    run=read(folder/'run.json')
    if run.get('schema')!='companyx.unified.run.v2':raise ValueError('Use the matching legacy adapter for old runs; V6 semantic export requires a new v0.1.3 run')
    if complete['RunCode']!=run['RunCode'] or manifest['RunCode']!=run['RunCode']:raise ValueError('Run identity mismatch')
    if sha(folder/'metrics.json')!=complete['metrics_sha256']:raise ValueError('Metrics hash mismatch')
    from .legacy import digest
    if digest(read(folder/'input.json'))!=run['input_sha256']:raise ValueError('Input hash mismatch')
    if digest(read(folder/'execution_spec.json'))!=run['execution_spec_sha256']:raise ValueError('Spec hash mismatch')
    from .inputs import prepare
    snapshot=read(folder/'input.json');spec=read(folder/'execution_spec.json')
    validate_profile(read(folder/'execution_profile.json'),snapshot,spec,prepare(snapshot,spec))
    if run.get('valuation_sha256'):
        from .valuation import validate as validate_valuation
        snapshot=read(folder/'input.json');basis=read(folder/'valuation_basis.json')
        if validate_valuation(snapshot)!=run['valuation_sha256'] or basis!=snapshot['metadata']['valuation']:
            raise ValueError('Frozen valuation artifact mismatch')
    required={'RunEntity.jsonl','Fact_SimulationDaily.jsonl','Fact_SimulationOrder.jsonl','RunSummary.jsonl','ProductScope.jsonl',
        'Fact_OptimizationSolve.jsonl','Fact_PolicySimulation.jsonl','Bridge_RunEntityRelation.jsonl','ExternalSupplyDraw.jsonl'}
    if not required<=manifest['tables'].keys():raise ValueError('Missing required output tables')
    for name,entry in manifest['tables'].items():
        if Path(name).name!=name or not name.endswith('.jsonl'):raise ValueError('Invalid manifest path')
        if sha(folder/'tables'/name)!=entry['sha256']:raise ValueError('Table hash mismatch: '+name)
        count=0
        for row in rows(folder/'tables'/name):
            if row.get('RunCode')!=run['RunCode']:raise ValueError('Cross-run row: '+name)
            count+=1
        if count!=entry['rows']:raise ValueError('Row count mismatch: '+name)
    if run.get('valuation_sha256'):
        expected=[dict(RunCode=run['RunCode'],**r,ValuationHash=run['valuation_sha256']) for r in basis['rows']]
        if list(rows(folder/'tables/ValuationBasis.jsonl'))!=expected:raise ValueError('Valuation table differs from frozen price basis')
    return run,manifest

def stage(folder,keymap,output):
    folder=Path(folder).resolve();output=Path(output).resolve();run,manifest=validate_artifact(folder)
    contract=read(Path(__file__).with_name('contract_v6_2.json'))['tables']
    if keymap.get('RunCode')!=run['RunCode']:raise ValueError('RunCode mapping mismatch')
    for k in ('PlanningRunKey','LoadBatchID','ScenarioVersionKey'):
        if type(keymap.get(k)) is not int or keymap[k]<=0:raise ValueError('Missing explicit '+k)
    if keymap['PlanningRunKey']>2147483647:raise ValueError('SQL V6.2 PlanningRunKey is INT')
    pkeys=list(keymap.get('ProductKeys',{}).values())
    if len(set(pkeys))!=len(pkeys):raise ValueError('ProductID mapping must be one-to-one')
    if output.exists() and any(output.iterdir()):raise ValueError('Use a fresh staging directory')
    output.mkdir(parents=True,exist_ok=True);errors=[];files={};counts={};loaded=run['created_at']
    def key(mapping,value):
        k=keymap.get(mapping,{}).get(str(value))
        if k is None:raise ValueError(f'Missing {mapping}[{value}]')
        if mapping!='EventCodes' and (type(k) is not int or k<=0):raise ValueError('Invalid surrogate key in '+mapping)
        return k
    def transform(table,r,index):
        x=dict(r);x.update(PlanningRunKey=keymap['PlanningRunKey'],LoadBatchID=keymap['LoadBatchID'],LoadedAt=loaded)
        if 'ProductID' in r:x['ProductKey']=key('ProductKeys',r['ProductID'])
        if table=='Fact_SimulationDaily':x.update(DateKey=int(r['Date'].replace('-','')),LocationKey=-1)
        if table=='RunEntity':x['ScenarioVersionKey']=keymap['ScenarioVersionKey']
        if table=='Fact_SimulationEvent':
            x.update(DateKey=int(r['EventAt'][:10].replace('-','')),FromLocationKey=-1,ToLocationKey=-1,
                     EventCode=key('EventCodes',r['EventCode']))
            if x['EventCode']!=r['EventCode'] or x['EventCode'] not in EVENT_ENTITY_TYPES:raise ValueError('Event mapping must preserve canonical V6 meaning')
            if r.get('VendorID') is not None:x['SupplyOptionKey']=key('SupplyOptionKeys',f"{r['ProductID']}:{r['VendorID']}")
        if table=='Fact_StochasticDraw':
            x.update(DrawSequence=index,DistributionKey=key('DistributionKeys',r['StreamCode']),
                EventIdentity=r['DrawKey'],DrawIndex=0,RawSampleValue=r['UniformValue'],KnownAt=r['DecisionAt'],
                DrawKind='SUPPLY_DELAY_DAYS' if r['StreamCode']=='lead' else 'REJECT_QTY',
                TrialQty=None if r['StreamCode']=='lead' else r['TrialQty'])
        if table=='Bridge_RunEntityRelation' and r.get('AllocatedProductID') is not None:
            x['AllocatedProductKey']=key('ProductKeys',r['AllocatedProductID'])
        return x
    try:
        for table,cols in contract.items():
            if table=='Fact_RunSummary':continue
            fields=[c['name'] for c in cols];path=output/f'{table}.csv'
            with path.open('w',encoding='utf-8-sig',newline='') as f:
                writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader();count=0
                for i,r in enumerate(rows(folder/'tables'/f'{table}.jsonl'),1):
                    x=transform(table,r,i)
                    for col in cols:
                        if not col['nullable'] and x.get(col['name']) is None:raise ValueError(f"{table} row {i}: missing {col['name']}")
                    writer.writerow({c['name']:sql_value(c,x.get(c['name'])) for c in cols});count+=1
            files[path.name]=sha(path);counts[table]=count
        m=read(folder/'metrics.json')
        summary=dict(PlanningRunKey=keymap['PlanningRunKey'],EvaluationScope='Service quantities: manufactured V1 due-date cohort. Whole-order count: all siblings. AvgInventoryValue: all finite stock plus WIP over every calendar day.',
            CustomerDueQty=m['due_units_manufactured'],OnTimeDeliveredQty=m['on_time_units_manufactured'],OnTimeUnitRate=m['on_time_unit_rate_manufactured'],
            LostQty=m['lost_units_manufactured'],EndingBacklogQty=m['backlog_units_manufactured'],LateUnitDays=m['late_unit_days_manufactured'],
            AvgInventoryValue=m['mean_InventoryWIPValueAll'],AvgOwnedInTransitValue=0,WallClockSeconds=m['wall_seconds'],
            SolverSeconds=sum(x['SolverSeconds'] for x in rows(folder/'tables/Fact_OptimizationSolve.jsonl')) if run['policy']=='QUETSCHLICH_ADAPT' else None,
            ValidationStatus='PASSED',ValidationNote='Physical conservation and whole-order atomicity passed; surrogate keys supplied by caller, FK verification required during database transaction',
            OpeningBacklogQty=0,LateDeliveredQty=m['shipped_units_manufactured']-m['on_time_units_manufactured'],FilledQty=m['shipped_units_manufactured'],
            DueOrderCount=m['due_orders'],OnTimeFullOrderCount=m['orders_full_on_time'],LostOrderCount=m['lost_orders'],OnTimeFullOrderRate=m['full_order_on_time_rate'])
        cols=contract['Fact_RunSummary'];fields=[x['name'] for x in cols]
        for c in cols:
            if not c['nullable'] and summary.get(c['name']) is None:raise ValueError('Summary requires '+c['name'])
        with (output/'Fact_RunSummary.csv').open('w',encoding='utf-8-sig',newline='') as f:
            w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerow({c['name']:sql_value(c,summary.get(c['name'])) for c in cols})
        files['Fact_RunSummary.csv']=sha(output/'Fact_RunSummary.csv');counts['Fact_RunSummary']=1
        execution_profile=read(folder/'execution_profile.json');save(output/'execution_profile.json',execution_profile)
        scope=dict(ServiceProductKeys=[key('ProductKeys',p) for p in execution_profile['ServiceProductIDs']],
            FiniteStockProductKeys=[key('ProductKeys',p) for p in execution_profile['FiniteStockProductIDs']],
            Policy=run['policy'],Start=run['start'],End=run['end'],HoldingCostRatePerYear=execution_profile['HoldingCostRatePerYear'])
        save(output/'validation_scope.json',scope)
        from .preflight import check
        check(output,contract,scope)
        # Explicit SQL columns/types, preserving the existing production schema.
        sql=['-- Load CSV into these TEMP tables on one connection; then insert with FK checks in a transaction.',
             '-- Register Scenario/Policy/ExperimentCase/Replication/PlanningRun before importing results.',
             'SET XACT_ABORT ON;']
        order=['Fact_SimulationOrder','RunEntity','Bridge_RunEntityRelation','Fact_OptimizationSolve','Fact_SimulationDaily',
            'Fact_SimulationEvent','Fact_StochasticDraw','Fact_PolicySimulation','Fact_RunSummary']
        for table in order:
            sql.append('CREATE TABLE #'+table+' (\n'+',\n'.join('  ['+c['name']+'] '+c['sql_type']+(' NULL' if c['nullable'] else ' NOT NULL') for c in contract[table])+'\n);')
        sql+=['-- Import generated CSVs into #tables here, keeping empty fields as SQL NULL.','BEGIN TRANSACTION;',
              f"IF EXISTS (SELECT 1 FROM dss.Fact_RunSummary WHERE PlanningRunKey={keymap['PlanningRunKey']}) THROW 51000, 'Run already published; verify its manifest instead of re-inserting', 1;"]
        for table in order:
            names=','.join('['+c['name']+']' for c in contract[table]);sql.append(f'INSERT dss.{table} ({names}) SELECT {names} FROM #{table};')
        sql+=['-- Run the project DQ checks before setting Dim_PlanningRun to SUCCEEDED.','COMMIT;']
        (output/'load_template.sql').write_text('\n'.join(sql),encoding='utf-8')
        status='READY_FOR_STAGING'
    except (ValueError,KeyError,ArithmeticError,TypeError) as exc:errors.append(str(exc));status='BLOCKED'
    if run.get('valuation_sha256'):
        save(output/'valuation_basis.json',read(folder/'valuation_basis.json'))
        from .valuation import dwh_configuration
        save(output/'valuation_config_natural_keys.json',dwh_configuration(read(folder/'input.json')))
    result=dict(status=status,RunCode=run['RunCode'],PlanningRunKey=keymap['PlanningRunKey'],files=files,rows=counts,errors=errors,
                valuation_sha256=run.get('valuation_sha256'),
                source_table_manifest_sha256=sha(folder/'table_manifest.json'),database_written=False)
    if run.get('valuation_sha256'):
        result['valuation_artifacts']={name:sha(output/name) for name in ('valuation_basis.json','valuation_config_natural_keys.json')}
    result['semantic_artifacts']={name:sha(output/name) for name in ('execution_profile.json','validation_scope.json') if (output/name).exists()}
    save(output/'load_manifest.json',result)
    return result

def stage_audit(folder,keymap,output):
    """Export terminal failed/interrupted solver audit, never result facts or KPIs."""
    from .legacy import digest
    from .preflight import validate_solve_rows
    folder=Path(folder);output=Path(output);run=read(folder/'run.json');audit=read(folder/'failure_audit_manifest.json')
    if (folder/'completion.json').exists() or audit['status'] not in ('FAILED','INTERRUPTED'):raise ValueError('Expected terminal failed audit')
    if audit['RunCode']!=run['RunCode'] or read(folder/'status.json')['status']!=audit['status']:raise ValueError('Audit identity/status mismatch')
    for name,field in [('input.json','input_sha256'),('execution_spec.json','execution_spec_sha256')]:
        if digest(read(folder/name))!=run[field] or audit[field]!=run[field]:raise ValueError('Changed failed-run input/spec')
    table=folder/'tables/Fact_OptimizationSolve.jsonl'
    if sha(table)!=audit['solve_table_sha256']:raise ValueError('Failed solve audit hash mismatch')
    values=list(rows(table))
    if len(values)!=audit['solve_rows'] or any(r['RunCode']!=run['RunCode'] for r in values):raise ValueError('Failed audit row identity mismatch')
    validate_solve_rows(values)
    if keymap.get('RunCode')!=run['RunCode']:raise ValueError('RunCode mapping mismatch')
    for key in ('PlanningRunKey','LoadBatchID'):
        if type(keymap.get(key)) is not int or keymap[key]<=0:raise ValueError('Missing explicit '+key)
    if output.exists() and any(output.iterdir()):raise ValueError('Use a fresh audit staging directory')
    output.mkdir(parents=True,exist_ok=True);cols=read(Path(__file__).with_name('contract_v6_2.json'))['tables']['Fact_OptimizationSolve']
    path=output/'Fact_OptimizationSolve.csv'
    with path.open('w',encoding='utf-8-sig',newline='') as f:
        writer=csv.DictWriter(f,fieldnames=[c['name'] for c in cols]);writer.writeheader()
        for row in values:
            x=dict(row,PlanningRunKey=keymap['PlanningRunKey'],LoadBatchID=keymap['LoadBatchID'],LoadedAt=stamp())
            writer.writerow({c['name']:sql_value(c,x.get(c['name'])) for c in cols})
    result=dict(status='READY_FOR_AUDIT_STAGING',RunCode=run['RunCode'],PlanningRunKey=keymap['PlanningRunKey'],
        FinalRunStatus='CANCELLED' if audit['status']=='INTERRUPTED' else 'FAILED',
        files={path.name:sha(path)},rows={'Fact_OptimizationSolve':len(values)},result_publication_allowed=False,database_written=False)
    save(output/'load_manifest.json',result);return result

def main():
    p=argparse.ArgumentParser();p.add_argument('--run',required=True);p.add_argument('--keymap',required=True);p.add_argument('--output',required=True)
    p.add_argument('--audit-only',action='store_true')
    a=p.parse_args();r=(stage_audit if a.audit_only else stage)(a.run,read(a.keymap),a.output);print(json.dumps(r,ensure_ascii=False))
    if r['status']=='BLOCKED':raise SystemExit(1)
if __name__=='__main__':main()

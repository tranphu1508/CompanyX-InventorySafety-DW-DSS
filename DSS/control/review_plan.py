"""A typed, display-only view of a verified plan; original solver files stay intact."""
from pathlib import Path
import json,hashlib
from common import read,save

def export_review_plan(artifact, destination):
    artifact=Path(artifact);destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    source=artifact/'inquiry_decision_plan.jsonl';manifest=read(artifact/'inquiry_decision_plan_manifest.json')
    sha=hashlib.sha256(source.read_bytes()).hexdigest()
    if sha!=manifest['sha256']:raise ValueError('Original plan hash mismatch')
    snapshot=read(artifact/'input.json')
    units={p['ProductID']:p['StockUnit'] for p in snapshot['products']}
    lines={}
    for line in snapshot['sales_order_lines']:lines.setdefault(line['SalesOrderID'],[]).append(line)
    target=destination/'plan_at_X.jsonl';count=0
    with source.open(encoding='utf-8') as src,target.open('w',encoding='utf-8') as dest:
        for raw in src:
            row=json.loads(raw);first=row.pop('IsImplementedFirstPeriod',row['PeriodOffset']==0)
            code=row['ActionCode'];whole=code.startswith('WHOLE_ORDER_');state=code.startswith('PROJECTED_')
            row['IsFirstPeriod']=first
            row['ValueKind']='WHOLE_ORDER_BINARY_DECISION' if whole else 'PREDICTED_STATE' if state else 'PLANNED_MATERIAL_QUANTITY'
            row['IsFirstPeriodPlanAction']=first and not state
            row['IsObservedExecution']=False
            if whole:
                row['OrderDecisionFlag']=row.pop('Quantity');row['Unit']='order'
                row['OrderLines']=[dict(ProductID=l['ProductID'],OrderQty=l['OrderQty'],StockUnit=units[l['ProductID']]) for l in lines[row['SalesOrderID']]]
            else:row['Unit']=units.get(row.get('ProductID'))
            dest.write(json.dumps(row,ensure_ascii=False,allow_nan=False)+'\n');count+=1
    receipt={'schema':'companyx.inquiry.review_plan.v1','source_sha256':sha,'source_manifest':str(artifact/'inquiry_decision_plan_manifest.json'),
             'path':str(target),'rows':count,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),
             'meaning':'Accepted optimization plan at X. Binary whole-order decisions are not product quantities. Inventory/backlog are predictions. Real execution remains in DES event facts.'}
    save(destination/'plan_manifest.json',receipt);return receipt

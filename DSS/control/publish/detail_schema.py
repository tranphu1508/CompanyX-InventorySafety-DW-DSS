"""Additive, owned relational storage for simulation plans and execution details."""
from __future__ import annotations
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
CONTRACT=json.loads((HERE/'detail_contract.json').read_text(encoding='utf-8'))
TABLES=dict(CONTRACT['tables'])
TABLES['PlanVersion']={
 'SchemaVersion':'str','DecisionVersionID':'str','DecisionAt':'date','DayIndex':'int','SolveSequence':'int','HorizonEndAt':'date',
 'DecisionReference':'str','DecisionSHA256':'str','StateReference':'str','StateSHA256':'str','ModelReference':'str','ModelSHA256':'str',
 'SolutionReference':'str','SolutionSHA256':'str','StateAt':'str','ModelBoundAtDecision':'bool'}
TABLES['PlanAction']={
 'DecisionVersionID':'str','RowNumber':'int','DecisionAt':'date','PlanAt':'date','PeriodOffset':'int','SolveSequence':'int',
 'ActionCode':'str','ValueKind':'str','ProductID':'int?','ParentProductID':'int?','SalesOrderID':'int?',
 'SalesOrderDetailID':'int?','Quantity':'decimal?','OrderDecisionFlag':'int?','QueueAge':'int?','StockUnit':'str?',
 'IsFirstPeriod':'bool','IsTentativeFuture':'bool','PlannedCompletionAt':'date?','ModelVariableIndex':'int?',
 'ParentActionRowNumber':'int?','IsObservedExecution':'bool'}

OWNER_SQL="""
SET XACT_ABORT ON;
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties
 WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107')
 THROW 51000,'Requires owned CompanyX warehouse',1;
IF SCHEMA_ID('cxdetail') IS NULL BEGIN
 EXEC('CREATE SCHEMA cxdetail AUTHORIZATION dbo');
 EXEC sys.sp_addextendedproperty @name='CompanyXDetailOwner',@value='companyx.execution-detail.v1',@level0type='SCHEMA',@level0name='cxdetail';
END;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=3 AND major_id=SCHEMA_ID('cxdetail')
 AND name='CompanyXDetailOwner' AND CONVERT(nvarchar(100),value)='companyx.execution-detail.v1') THROW 51000,'Unowned detail schema',1;
IF OBJECT_ID('cxdetail.RunDetail','U') IS NULL CREATE TABLE cxdetail.RunDetail(
 PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
 ContractVersion varchar(80) NOT NULL,ManifestHash char(64) NOT NULL,ManifestJSON nvarchar(max) NOT NULL CHECK(ISJSON(ManifestJSON)=1),
 ArtifactFolder nvarchar(2000) NOT NULL,IsPlanApplicable bit NOT NULL,PublishedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
"""

NATURAL_KEYS={
 'OrderLineDay':['Date','SalesOrderDetailID'],'OrderDay':['Date','SalesOrderID'],
 'ProductionJobDay':['Date','JobCode'],'ProductionExecution':['ExecutionCode'],'MaterialTrace':['EventSequence'],
 'AdvisoryAllocation':['DecisionVersionID','AllocationNo'],'PlanSupplyBalance':['DecisionVersionID','SupplyCode'],
 'PlanVersion':['DecisionVersionID'],'PlanAction':['DecisionVersionID','RowNumber'],
 'PlanOrderMaterial':['DecisionVersionID','MaterialRowNo']}

def sqltype(name,kind):
 base=kind.rstrip('?')
 if base=='str':
  length=64 if name.endswith(('SHA256','VersionID')) else 512 if name.endswith('Reference') else 180 if name in ('SupplyCode','JobCode','ExecutionCode') else 120
  return f'nvarchar({length})'
 return {'int':'bigint','date':'date','decimal':'decimal(28,8)','bool':'bit'}[base]

def schema_statements():
 yield OWNER_SQL
 for table,fields in TABLES.items():
  cols=['DetailRowID bigint IDENTITY NOT NULL PRIMARY KEY','PlanningRunKey int NOT NULL REFERENCES dss.Dim_PlanningRun(PlanningRunKey)']
  cols.extend(f'[{n}] {sqltype(n,t)} '+('NULL' if t.endswith('?') else 'NOT NULL') for n,t in fields.items())
  uq=','.join('[%s]'%x for x in ['PlanningRunKey',*NATURAL_KEYS[table]])
  cols.append(f'CONSTRAINT [UQ_Detail_{table}] UNIQUE({uq})')
  yield f"IF OBJECT_ID('cxdetail.{table}','U') IS NULL CREATE TABLE cxdetail.[{table}]("+','.join(cols)+');'
  # Empty detail tables use native SQL Server page compression from their first load.
  yield f"IF NOT EXISTS(SELECT TOP(1) 1 FROM cxdetail.[{table}]) AND EXISTS(SELECT 1 FROM sys.partitions WHERE object_id=OBJECT_ID('cxdetail.{table}') AND data_compression<>2) ALTER INDEX ALL ON cxdetail.[{table}] REBUILD WITH(DATA_COMPRESSION=PAGE,MAXDOP=2);"
 yield "GRANT SELECT ON SCHEMA::cxdetail TO [CompanyXMOLAPReader];"

def key(source,column):return f"CONVERT(nvarchar(240),CASE WHEN {source}.[{column}] IS NULL THEN N'0' ELSE CONCAT({source}.PlanningRunKey,N':',{source}.[{column}]) END)"
def pkey(source):return f"CONVERT(nvarchar(240),CONCAT({source}.PlanningRunKey,N':',{source}.DecisionVersionID))"
def supplykey(source):return f"CONVERT(nvarchar(300),CONCAT({source}.PlanningRunKey,N':',{source}.DecisionVersionID,N':',{source}.SupplyCode))"
def datekey(source,column):return f"COALESCE(CONVERT(int,CONVERT(char(8),{source}.[{column}],112)),0)"

def common_product(source,product='ProductID'):
 return f"LEFT JOIN cxolap.DimProduct p ON p.ProductID={source}.[{product}] AND p.ProductID>0 LEFT JOIN cxolap.DimRun r ON r.PlanningRunKey={source}.PlanningRunKey LEFT JOIN dss.Scenario_Product sp ON sp.ScenarioVersionKey=r.ScenarioVersionKey AND sp.ProductKey=p.ProductKey"

def view_definitions():
 v={}
 v['PublishedRun']="SELECT d.* FROM cxdetail.RunDetail d JOIN cxactive.ActiveRunScope a ON a.PlanningRunKey=d.PlanningRunKey"
 for table in TABLES:
  v['Source'+table]=f"SELECT f.* FROM cxdetail.[{table}] f JOIN cxdetail.PublishedRun pr ON pr.PlanningRunKey=f.PlanningRunKey"
 v['DimSalesOrder']=f"SELECT {key('f','SalesOrderID')} SalesOrderKey,CONVERT(nvarchar(240),CONCAT(N'SO ',f.SalesOrderID,N' | Run ',f.PlanningRunKey)) SalesOrderName,CONVERT(nvarchar(60),f.SalesOrderID) SalesOrderID FROM cxdetail.SourceOrderDay f GROUP BY f.PlanningRunKey,f.SalesOrderID UNION ALL SELECT N'0',N'Không áp dụng',N'Không áp dụng'"
 v['DimSalesOrderLine']=f"SELECT {key('f','SalesOrderDetailID')} SalesOrderLineKey,CONVERT(nvarchar(240),CONCAT(N'SO ',f.SalesOrderID,N' / Line ',f.SalesOrderDetailID,N' | Run ',f.PlanningRunKey)) LineName,CONVERT(nvarchar(60),f.SalesOrderDetailID) SourceLineID FROM cxdetail.SourceOrderLineDay f GROUP BY f.PlanningRunKey,f.SalesOrderID,f.SalesOrderDetailID UNION ALL SELECT N'0',N'Không áp dụng',N'Không áp dụng'"
 v['DimProductionJob']=f"SELECT {key('f','JobCode')} JobKey,CONVERT(nvarchar(240),CONCAT(f.JobCode,N' | Run ',f.PlanningRunKey)) JobName,f.JobCode FROM cxdetail.SourceProductionJobDay f GROUP BY f.PlanningRunKey,f.JobCode UNION ALL SELECT N'0',N'Không áp dụng',N'Không áp dụng'"
 v['DimProductionExecution']=f"SELECT {key('f','ExecutionCode')} ExecutionKey,CONVERT(nvarchar(240),CONCAT(f.ExecutionCode,N' | Run ',f.PlanningRunKey)) ExecutionName,f.ExecutionCode FROM cxdetail.SourceProductionExecution f UNION ALL SELECT N'0',N'Không áp dụng',N'Không áp dụng'"
 v['DimPlanVersion']=f"SELECT {pkey('f')} PlanVersionKey,CONVERT(nvarchar(240),CONCAT(CONVERT(char(10),f.DecisionAt,120),N' | Run ',f.PlanningRunKey,N' | Solve ',f.SolveSequence)) PlanVersionName,f.DecisionSHA256 DecisionHash,CONVERT(nvarchar(80),N'ACCEPTED_ADVISORY') PlanStatus,{datekey('f','DecisionAt')} DecisionDateKey,CONVERT(int,ROW_NUMBER() OVER(PARTITION BY f.PlanningRunKey ORDER BY f.DecisionAt,f.DecisionVersionID)) PlanVersionOrdinal,f.PlanningRunKey,f.DecisionVersionID FROM cxdetail.SourcePlanVersion f"
 catalog={
  'PRODUCTION_REQUEST':'PLANNED_MATERIAL_QUANTITY','PRODUCTION_START':'PLANNED_MATERIAL_QUANTITY','PURCHASE_ORDER':'PLANNED_MATERIAL_QUANTITY',
  'ORDER_LINE_SHIPMENT':'PLANNED_ORDER_LINE_QUANTITY','ORDER_LINE_LOSS':'PLANNED_ORDER_LINE_QUANTITY','ORDER_LINE_UNSERVED':'PLANNED_ORDER_LINE_QUANTITY',
  'FORECAST_SHIPMENT':'PLANNED_MATERIAL_QUANTITY','PLANNED_BOM_ISSUE':'PLANNED_MATERIAL_QUANTITY',
  'PLANNED_PRODUCTION_RECEIPT':'PLANNED_MATERIAL_QUANTITY','PLANNED_PURCHASE_RECEIPT':'PLANNED_MATERIAL_QUANTITY',
  'PROJECTED_ON_HAND':'PREDICTED_STATE','PROJECTED_ACTUAL_BACKLOG':'PREDICTED_STATE','PROJECTED_FORECAST_SHORTAGE':'PREDICTED_STATE',
  'WHOLE_ORDER_SHIPMENT':'WHOLE_ORDER_BINARY_DECISION','WHOLE_ORDER_LOSS':'WHOLE_ORDER_BINARY_DECISION','WHOLE_ORDER_UNSERVED':'WHOLE_ORDER_BINARY_DECISION'}
 literals=','.join("(N'%s',N'%s')"%(k,val) for k,val in catalog.items())
 v['DimPlanAction']="SELECT CONVERT(nvarchar(120),c.ActionCode) ActionCode,CONVERT(nvarchar(120),c.ActionCode) ActionName,CONVERT(nvarchar(120),COALESCE(o.ValueKind,c.ValueKind)) ValueKind FROM (VALUES "+literals+") c(ActionCode,ValueKind) LEFT JOIN (SELECT ActionCode,MIN(ValueKind) ValueKind FROM cxdetail.SourcePlanAction GROUP BY ActionCode) o ON o.ActionCode=c.ActionCode"
 v['DimPlanPeriod']="SELECT DISTINCT CONVERT(int,PeriodOffset) PeriodOffset,CONVERT(nvarchar(40),CONCAT(N't+',PeriodOffset)) PeriodName,IsFirstPeriod,IsTentativeFuture FROM cxdetail.SourcePlanAction"
 v['DimTraceMethod']="SELECT DISTINCT TraceMethod MethodCode,TraceMethod MethodName FROM cxdetail.SourceMaterialTrace UNION SELECT DISTINCT Method,Method FROM cxdetail.SourceAdvisoryAllocation UNION SELECT DISTINCT Method,Method FROM cxdetail.SourcePlanOrderMaterial"
 v['DimOrderLineStatus']="SELECT DISTINCT OrderStatus StatusCode,OrderStatus StatusName FROM cxdetail.SourceOrderLineDay UNION SELECT DISTINCT OrderStatus,OrderStatus FROM cxdetail.SourceOrderDay"
 v['DimAllocationSupply']=f"SELECT {supplykey('f')} SupplyKey,CONVERT(nvarchar(500),CONCAT(f.SupplyCode,N' | ',CONVERT(char(10),f.DecisionAt,120),N' | Run ',f.PlanningRunKey)) SupplyName,f.SupplyCode,f.SupplyKind,{datekey('f','AvailableAt')} AvailableDateKey FROM cxdetail.SourcePlanSupplyBalance f"
 v['DimAllocationConsumer']="SELECT CONVERT(nvarchar(120),v.Code) ConsumerCode,CONVERT(nvarchar(120),v.Code) ConsumerName FROM (VALUES (N'SALES_ORDER_LINE'),(N'PLANNED_BOM'),(N'FORECAST')) v(Code)"
 v['DimMaterialLevel']="SELECT DISTINCT CONVERT(nvarchar(40),CONCAT(MaterialDepth,':',CONVERT(int,IsLeafComponent))) MaterialLevelKey,CONVERT(nvarchar(80),CONCAT('Depth ',MaterialDepth,' | ',CASE WHEN IsLeafComponent=1 THEN 'leaf' ELSE 'intermediate' END)) MaterialLevelName,CONVERT(int,MaterialDepth) MaterialDepth,IsLeafComponent FROM cxdetail.SourcePlanOrderMaterial"
 productcols='COALESCE(p.ProductKey,-1) ProductKey,COALESCE(sp.StockUnitMeasureKey,0) StockUnitMeasureKey'
 v['FactOrderDaily']=f"SELECT f.*, {key('f','SalesOrderID')} SalesOrderKey,{datekey('f','Date')} DateKey,{datekey('f','KnownAt')} KnownDateKey,{datekey('f','DueAt')} DueDateKey FROM cxdetail.SourceOrderDay f"
 v['FactOrderLineDaily']=f"SELECT f.*,{productcols},{key('f','SalesOrderID')} SalesOrderKey,{key('f','SalesOrderDetailID')} SalesOrderLineKey,{datekey('f','Date')} DateKey,{datekey('f','KnownAt')} KnownDateKey,{datekey('f','DueAt')} DueDateKey FROM cxdetail.SourceOrderLineDay f {common_product('f')}"
 v['FactJobDaily']=f"SELECT f.*,{productcols},{key('f','JobCode')} JobKey,{datekey('f','Date')} DateKey,{datekey('f','CreatedAt')} CreatedDateKey FROM cxdetail.SourceProductionJobDay f {common_product('f')}"
 v['FactProductionExecution']=f"SELECT f.*,{productcols},{key('f','JobCode')} JobKey,{key('f','ExecutionCode')} ExecutionKey,{datekey('f','StartAt')} StartDateKey,{datekey('f','CompletedAt')} CompletionDateKey,CONVERT(bigint,1) ExecutionCount FROM cxdetail.SourceProductionExecution f {common_product('f')}"
 v['FactMaterialTrace']=f"SELECT f.*,{productcols},COALESCE(pp.ProductKey,-1) ParentProductKey,{key('f','JobCode')} JobKey,{key('f','ExecutionCode')} ExecutionKey,{datekey('f','EventAt')} DateKey,CONVERT(bigint,1) IssueCount FROM cxdetail.SourceMaterialTrace f {common_product('f','ComponentProductID')} LEFT JOIN cxolap.DimProduct pp ON pp.ProductID=f.ParentProductID AND pp.ProductID>0"
 planjoin='JOIN cxdetail.DimPlanVersion pv ON pv.PlanningRunKey=f.PlanningRunKey AND pv.DecisionVersionID=f.DecisionVersionID'
 v['FactRollingPlan']=f"SELECT f.*,{productcols},COALESCE(pp.ProductKey,-1) ParentProductKey,pv.PlanVersionKey,pv.PlanVersionOrdinal,{key('f','SalesOrderID')} SalesOrderKey,{key('f','SalesOrderDetailID')} SalesOrderLineKey,{datekey('f','DecisionAt')} DecisionDateKey,{datekey('f','PlanAt')} PlannedDateKey FROM cxdetail.SourcePlanAction f {planjoin} {common_product('f')} LEFT JOIN cxolap.DimProduct pp ON pp.ProductID=f.ParentProductID AND pp.ProductID>0 WHERE f.Quantity IS NOT NULL"
 v['FactRollingOrderPlan']=f"SELECT f.*,pv.PlanVersionKey,pv.PlanVersionOrdinal,{key('f','SalesOrderID')} SalesOrderKey,{datekey('f','DecisionAt')} DecisionDateKey,{datekey('f','PlanAt')} PlannedDateKey FROM cxdetail.SourcePlanAction f {planjoin} WHERE f.OrderDecisionFlag IS NOT NULL"
 v['FactPlannedAllocation']=f"SELECT f.*,{productcols},COALESCE(pp.ProductKey,-1) ParentProductKey,pv.PlanVersionKey,pv.PlanVersionOrdinal,{key('f','SalesOrderID')} SalesOrderKey,{key('f','SalesOrderDetailID')} SalesOrderLineKey,{supplykey('f')} SupplyKey,{datekey('f','DecisionAt')} DecisionDateKey,{datekey('f','PlanAt')} PlannedDateKey,{datekey('f','SupplyAvailableAt')} SupplyDateKey,CONVERT(bigint,1) AllocationCount FROM cxdetail.SourceAdvisoryAllocation f {planjoin} {common_product('f')} LEFT JOIN cxolap.DimProduct pp ON pp.ProductID=f.ParentProductID AND pp.ProductID>0"
 v['FactPlanSupplyBalance']=f"SELECT f.*,{productcols},pv.PlanVersionKey,pv.PlanVersionOrdinal,{supplykey('f')} SupplyKey,{datekey('f','DecisionAt')} DecisionDateKey,{datekey('f','AvailableAt')} SupplyDateKey FROM cxdetail.SourcePlanSupplyBalance f {planjoin} {common_product('f')}"
 v['FactPlanOrderMaterial']=f"SELECT f.*,{productcols},COALESCE(pp.ProductKey,-1) ParentProductKey,COALESCE(rp.ProductKey,-1) RootProductKey,pv.PlanVersionKey,pv.PlanVersionOrdinal,{key('f','SalesOrderID')} SalesOrderKey,{key('f','SalesOrderDetailID')} SalesOrderLineKey,{datekey('f','DecisionAt')} DecisionDateKey,{datekey('f','PlanAt')} PlannedDateKey,CONVERT(nvarchar(40),CONCAT(f.MaterialDepth,':',CONVERT(int,f.IsLeafComponent))) MaterialLevelKey FROM cxdetail.SourcePlanOrderMaterial f {planjoin} {common_product('f','ComponentProductID')} LEFT JOIN cxolap.DimProduct pp ON pp.ProductID=f.ParentProductID AND pp.ProductID>0 LEFT JOIN cxolap.DimProduct rp ON rp.ProductID=f.RootProductID AND rp.ProductID>0"
 return {n:'CREATE OR ALTER VIEW cxdetail.['+n+'] AS\n'+sql+';' for n,sql in v.items()}

def ensure_schema(conn):
 for sql in schema_statements():conn.execute(sql)
 for sql in view_definitions().values():conn.execute(sql)

if __name__=='__main__':
 import argparse,sys
 sys.path.insert(0,str(HERE.parent))
 from publish.publisher import CONNECTION
 parser=argparse.ArgumentParser();parser.add_argument('--apply',action='store_true');parser.add_argument('--output',type=Path);args=parser.parse_args()
 sql='\nGO\n'.join([*schema_statements(),*view_definitions().values()])
 if args.output:args.output.write_text(sql,encoding='utf-8')
 if args.apply:
  import pyodbc
  with pyodbc.connect(CONNECTION,autocommit=False,timeout=15) as conn:ensure_schema(conn);conn.commit()
  print('Detail schema and views installed')

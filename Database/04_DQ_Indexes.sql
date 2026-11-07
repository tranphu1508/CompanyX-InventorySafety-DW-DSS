IF DB_NAME() IN (N'InventorySafety',N'CompanyX',N'master',N'model',N'msdb',N'tempdb') THROW 51700,'Protected database',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE name=N'CompanyXSSISDeployment' AND CONVERT(nvarchar(100),value)=N'SSIS_20261029') THROW 51701,'Target is not this package deployment',1;
-- Additive access paths only. No table/view semantics or simulation code changes.
SET ANSI_NULLS ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON;
SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON; SET NUMERIC_ROUNDABORT OFF;
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dss.RunEntity') AND name=N'IX_DSS_DQ_CustomerLine')
CREATE NONCLUSTERED INDEX IX_DSS_DQ_CustomerLine
ON dss.RunEntity(PlanningRunKey,EntityCode)
INCLUDE(ProductKey,DueAt,IsOpeningEntity,OriginalQty,OpeningRemainingQty,CreatedAt,CustomerOrderCode,ScenarioVersionKey,InitialDemandLineCode,SourceRecordReference)
WHERE EntityType=N'CUSTOMER_ORDER_LINE'
WITH (MAXDOP=2);
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID(N'dss.Fact_SimulationEvent') AND name=N'IX_DSS_DQ_DeliveryEvent')
CREATE NONCLUSTERED INDEX IX_DSS_DQ_DeliveryEvent
ON dss.Fact_SimulationEvent(PlanningRunKey,EntityCode,EventAt,EventSequence)
INCLUDE(EventCode,Quantity)
WHERE EventCode IN (N'SHIP_ON_TIME',N'SHIP_LATE',N'LOST_SALE')
WITH (MAXDOP=2);

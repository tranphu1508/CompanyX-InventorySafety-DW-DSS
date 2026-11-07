DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context);
 SELECT D.SalesOrderDetailID,R.LineTotal OldTotal,
   CONVERT(numeric(38,6),ISNULL((D.UnitPrice*(1.0-D.UnitPriceDiscount))*D.OrderQty,0)) NewTotal
 INTO #Totals FROM etl_effective.SalesOrderDetail D JOIN etl_raw.SalesOrderDetail R ON R.SalesOrderDetailID=D.SalesOrderDetailID
 WHERE EXISTS(SELECT 1 FROM etl_v2.SalesEvidence E WHERE E.BatchID=@B AND E.SalesOrderDetailID=D.SalesOrderDetailID AND E.Resolution='CORRECTED');
 INSERT etl.Audit_DataCorrection(SourceSystem,SourceTable,SourceRecordKey,ColumnName,OriginalValue,CorrectedValue,SourceDataType,RuleID,RuleVersion,EvidenceTable,EvidenceRecordKey,LoadBatchID,CorrectedAt)
 SELECT 'CompanyX','Sales.SalesOrderDetail',CONVERT(nvarchar(30),T.SalesOrderDetailID),'LineTotal',CONVERT(nvarchar(100),T.OldTotal),CONVERT(nvarchar(100),T.NewTotal),'numeric(38,6)',
  'SAL-12','SAL-BACKFILL-v2','etl_v2.SalesEvidence',CONCAT(@B,':',T.SalesOrderDetailID),@B,SYSUTCDATETIME()
 FROM #Totals T WHERE T.OldTotal IS NULL OR T.OldTotal<>T.NewTotal;
 IF EXISTS(SELECT 1 FROM #Totals T JOIN etl_effective.SalesOrderDetail D ON D.SalesOrderDetailID=T.SalesOrderDetailID WHERE D.LineTotal<>T.NewTotal) THROW 51830,'SSIS LineTotal differs from approved SQL rule',1;
IF (SELECT COUNT_BIG(*) FROM etl_effective.SalesOrderDetail)<>(SELECT COUNT_BIG(*) FROM etl_raw.SalesOrderDetail) THROW 51831,'V02 row loss',1;
IF EXISTS(SELECT 1 FROM etl_effective.SalesOrderDetail D JOIN etl_raw.SalesOrderDetail R ON R.SalesOrderDetailID=D.SalesOrderDetailID JOIN ssis_flow.V02Lookup V ON V.SalesOrderDetailID=D.SalesOrderDetailID WHERE EXISTS(SELECT D.OrderQty,D.UnitPrice EXCEPT SELECT COALESCE(V.FixedQty,R.OrderQty),COALESCE(V.FixedPrice,R.UnitPrice))) THROW 51832,'V02 values differ',1;
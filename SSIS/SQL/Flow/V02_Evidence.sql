DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context); DELETE etl_effective.SalesOrderDetail; DELETE ssis_flow.V02Lookup;
 -- Legacy transactions have a per-order ordinal; recent trigger events use the
 -- real detail ID. Accept ordinal only for an unambiguous order/product pair.
 SELECT D.*,ROW_NUMBER() OVER(PARTITION BY SalesOrderID ORDER BY SalesOrderDetailID) LineOrdinal,
  COUNT(*) OVER(PARTITION BY SalesOrderID,ProductID) ProductLineCount
 INTO #Sales FROM etl_raw.SalesOrderDetail D;
 SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,UnitPrice,LineOrdinal,ProductLineCount
 INTO #Bad FROM #Sales WHERE OrderQty IS NULL OR OrderQty<=0 OR UnitPrice IS NULL OR UnitPrice<=0;

 SELECT 'TransactionHistory' SourceTable,TransactionID,ReferenceOrderID,ReferenceOrderLineID,ProductID,
        TransactionDate,Quantity,ActualCost
 INTO #History FROM etl_raw.TransactionHistory WHERE TransactionType='S'
 UNION ALL
 SELECT 'TransactionHistoryArchive',TransactionID,ReferenceOrderID,ReferenceOrderLineID,ProductID,
        TransactionDate,Quantity,ActualCost
 FROM etl_raw.TransactionHistoryArchive WHERE TransactionType='S';

 SELECT B.SalesOrderDetailID,H.* INTO #Evidence
 FROM #Bad B JOIN #History H ON H.ReferenceOrderID=B.SalesOrderID AND H.ProductID=B.ProductID
 WHERE (H.ReferenceOrderLineID=B.SalesOrderDetailID OR (B.ProductLineCount=1 AND H.ReferenceOrderLineID=B.LineOrdinal))
 ;
 -- Multiple historical events are snapshots, never additive transactions here.
 -- Disagreement between positive candidates is unresolved, not guessed.
 INSERT etl_v2.SalesEvidence
 SELECT @B,B.SalesOrderDetailID,F.FieldName,F.OriginalValue,
   CASE WHEN X.DistinctValues=1 THEN X.Value END,X.CandidateCount,X.DistinctValues,
   CASE WHEN X.DistinctValues=1 THEN 'CORRECTED' ELSE 'UNRESOLVED' END,
   (SELECT E.SourceTable,E.TransactionID,E.ReferenceOrderID,E.ReferenceOrderLineID,E.ProductID,
      E.TransactionDate,E.Quantity,E.ActualCost FROM #Evidence E WHERE E.SalesOrderDetailID=B.SalesOrderDetailID
      AND ((F.FieldName='OrderQty' AND E.Quantity>0) OR (F.FieldName='UnitPrice' AND E.ActualCost>0))
      ORDER BY E.TransactionDate,E.TransactionID,E.SourceTable FOR JSON PATH)
 FROM #Bad B CROSS APPLY(VALUES('OrderQty',CONVERT(decimal(28,8),B.OrderQty)),('UnitPrice',CONVERT(decimal(28,8),B.UnitPrice))) F(FieldName,OriginalValue)
 CROSS APPLY(SELECT COUNT(*) CandidateCount,
   CASE WHEN F.FieldName='OrderQty' THEN COUNT(DISTINCT E.Quantity) ELSE COUNT(DISTINCT E.ActualCost) END DistinctValues,
   CONVERT(decimal(28,8),CASE WHEN F.FieldName='OrderQty' THEN MIN(E.Quantity) ELSE MIN(E.ActualCost) END) Value
   FROM #Evidence E WHERE E.SalesOrderDetailID=B.SalesOrderDetailID
    AND ((F.FieldName='OrderQty' AND E.Quantity>0) OR (F.FieldName='UnitPrice' AND E.ActualCost>0))) X
 WHERE F.OriginalValue IS NULL OR F.OriginalValue<=0;
 INSERT etl.Audit_DataCorrection(SourceSystem,SourceTable,SourceRecordKey,ColumnName,OriginalValue,CorrectedValue,SourceDataType,RuleID,RuleVersion,EvidenceTable,EvidenceRecordKey,LoadBatchID,CorrectedAt)
 SELECT 'CompanyX','Sales.SalesOrderDetail',CONVERT(nvarchar(30),SalesOrderDetailID),FieldName,
   CONVERT(nvarchar(100),OriginalValue),CONVERT(nvarchar(100),EffectiveValue),'decimal(28,8)',
   IIF(FieldName='OrderQty','SAL-10','SAL-11'),'SAL-BACKFILL-v2','etl_v2.SalesEvidence',
   CONCAT(@B,':',SalesOrderDetailID,':',FieldName),@B,SYSUTCDATETIME()
 FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution='CORRECTED';

INSERT ssis_flow.V02Lookup SELECT D.SalesOrderDetailID,CONVERT(smallint,Q.EffectiveValue),CONVERT(money,P.EffectiveValue),CONVERT(bit,CASE WHEN Q.SalesOrderDetailID IS NOT NULL OR P.SalesOrderDetailID IS NOT NULL THEN 1 ELSE 0 END) FROM etl_raw.SalesOrderDetail D LEFT JOIN etl_v2.SalesEvidence Q ON Q.BatchID=@B AND Q.FieldName='OrderQty' AND Q.Resolution='CORRECTED' AND Q.SalesOrderDetailID=D.SalesOrderDetailID LEFT JOIN etl_v2.SalesEvidence P ON P.BatchID=@B AND P.FieldName='UnitPrice' AND P.Resolution='CORRECTED' AND P.SalesOrderDetailID=D.SalesOrderDetailID;
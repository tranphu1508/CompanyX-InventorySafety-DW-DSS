DECLARE @B bigint,@Previous bigint,@Next bigint,@Changes bigint,@Targets bigint,@Summary nvarchar(max); SELECT @B=BatchId,@Previous=PreviousVersion,@Next=NextVersion FROM ssis_flow.Context; SELECT @Changes=COUNT_BIG(*) FROM etl_v2.SourceChange WHERE BatchID=@B;
  SELECT @Targets=COUNT_BIG(*) FROM etl_v2.TargetChange WHERE BatchID=@B;
  SET @Summary=(SELECT @Previous PreviousVersion,@Next CapturedVersion,@Changes SourceChanges,@Targets TargetChanges,(SELECT COUNT(*) FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution='UNRESOLVED') UnresolvedCorrections FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
  UPDATE etl_v2.State SET LastVersion=@Next,LastBatchID=@B WHERE Id=1;
  UPDATE etl_v2.BatchState SET CapturedVersion=@Next,SourceChangeCount=@Changes,TargetChangeCount=@Targets,Status='SUCCEEDED' WHERE BatchID=@B;
  UPDATE etl.ETL_LoadBatch SET Status='SUCCEEDED',ValidationStatus=IIF(EXISTS(SELECT 1 FROM etl_v2.SalesEvidence WHERE BatchID=@B AND Resolution='UNRESOLVED'),'PASSED_WITH_WARNINGS','PASSED'),LoadCompletedAt=SYSUTCDATETIME(),ValidationSummary=@Summary WHERE LoadBatchID=@B;
  COMMIT;
  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
  EXEC sys.sp_releaseapplock @Resource=N'InventorySafety_FullLoad',@LockOwner='Session';
  EXEC sys.sp_releaseapplock @Resource=N'DSS_RESULT',@LockOwner='Session';


DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context),@Previous bigint=(SELECT PreviousVersion FROM ssis_flow.Context),@Next bigint=(SELECT NextVersion FROM ssis_flow.Context);
IF @Previous IS NULL BEGIN
INSERT etl_raw.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT S.[UnitMeasureCode],S.[Name],S.[ModifiedDate],@B FROM ssis_flow.Delta_UnitMeasure S;
INSERT stg.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT [UnitMeasureCode],[Name],[ModifiedDate],@B FROM etl_raw.[UnitMeasure];
INSERT etl_v2.SourceChange SELECT @B,N'Production.UnitMeasure','I',@Next,(SELECT R.[UnitMeasureCode] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[UnitMeasure] R;
END ELSE BEGIN
SELECT [UnitMeasureCode],CONVERT(char(1),FlowOperation) SYS_CHANGE_OPERATION,FlowVersion SYS_CHANGE_VERSION INTO #CT_UnitMeasure FROM ssis_flow.Delta_UnitMeasure;
INSERT etl_v2.SourceChange SELECT @B,N'Production.UnitMeasure',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[UnitMeasureCode] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_UnitMeasure C LEFT JOIN etl_raw.[UnitMeasure] R ON R.[UnitMeasureCode]=C.[UnitMeasureCode];
DELETE R FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION='D';
UPDATE R SET R.[Name]=S.[Name],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] JOIN ssis_flow.Delta_UnitMeasure S ON S.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>'D';
INSERT etl_raw.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT S.[UnitMeasureCode],S.[Name],S.[ModifiedDate],@B FROM #CT_UnitMeasure C JOIN ssis_flow.Delta_UnitMeasure S ON S.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>'D' AND NOT EXISTS(SELECT 1 FROM etl_raw.[UnitMeasure] R WHERE R.[UnitMeasureCode]=S.[UnitMeasureCode]);
INSERT stg.[UnitMeasure]([UnitMeasureCode],[Name],[ModifiedDate],LoadBatchID) SELECT R.[UnitMeasureCode],R.[Name],R.[ModifiedDate],@B FROM etl_raw.[UnitMeasure] R JOIN #CT_UnitMeasure C ON R.[UnitMeasureCode]=C.[UnitMeasureCode] WHERE C.SYS_CHANGE_OPERATION<>'D';
END;
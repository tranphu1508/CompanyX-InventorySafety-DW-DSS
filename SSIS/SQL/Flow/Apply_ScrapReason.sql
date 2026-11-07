DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context),@Previous bigint=(SELECT PreviousVersion FROM ssis_flow.Context),@Next bigint=(SELECT NextVersion FROM ssis_flow.Context);
IF @Previous IS NULL BEGIN
INSERT etl_raw.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT S.[ScrapReasonID],S.[Name],S.[ModifiedDate],@B FROM ssis_flow.Delta_ScrapReason S;
INSERT stg.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT [ScrapReasonID],[Name],[ModifiedDate],@B FROM etl_raw.[ScrapReason];
INSERT etl_v2.SourceChange SELECT @B,N'Production.ScrapReason','I',@Next,(SELECT R.[ScrapReasonID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[ScrapReason] R;
END ELSE BEGIN
SELECT [ScrapReasonID],CONVERT(char(1),FlowOperation) SYS_CHANGE_OPERATION,FlowVersion SYS_CHANGE_VERSION INTO #CT_ScrapReason FROM ssis_flow.Delta_ScrapReason;
INSERT etl_v2.SourceChange SELECT @B,N'Production.ScrapReason',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[ScrapReasonID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_ScrapReason C LEFT JOIN etl_raw.[ScrapReason] R ON R.[ScrapReasonID]=C.[ScrapReasonID];
DELETE R FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION='D';
UPDATE R SET R.[Name]=S.[Name],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] JOIN ssis_flow.Delta_ScrapReason S ON S.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>'D';
INSERT etl_raw.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT S.[ScrapReasonID],S.[Name],S.[ModifiedDate],@B FROM #CT_ScrapReason C JOIN ssis_flow.Delta_ScrapReason S ON S.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>'D' AND NOT EXISTS(SELECT 1 FROM etl_raw.[ScrapReason] R WHERE R.[ScrapReasonID]=S.[ScrapReasonID]);
INSERT stg.[ScrapReason]([ScrapReasonID],[Name],[ModifiedDate],LoadBatchID) SELECT R.[ScrapReasonID],R.[Name],R.[ModifiedDate],@B FROM etl_raw.[ScrapReason] R JOIN #CT_ScrapReason C ON R.[ScrapReasonID]=C.[ScrapReasonID] WHERE C.SYS_CHANGE_OPERATION<>'D';
END;
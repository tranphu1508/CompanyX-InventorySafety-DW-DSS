DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context),@Previous bigint=(SELECT PreviousVersion FROM ssis_flow.Context),@Next bigint=(SELECT NextVersion FROM ssis_flow.Context);
IF @Previous IS NULL BEGIN
INSERT etl_raw.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT S.[LocationID],S.[Name],S.[CostRate],S.[Availability],S.[ModifiedDate],@B FROM ssis_flow.Delta_Location S;
INSERT stg.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT [LocationID],[Name],[CostRate],[Availability],[ModifiedDate],@B FROM etl_raw.[Location];
INSERT etl_v2.SourceChange SELECT @B,N'Production.Location','I',@Next,(SELECT R.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),NULL FROM etl_raw.[Location] R;
END ELSE BEGIN
SELECT [LocationID],CONVERT(char(1),FlowOperation) SYS_CHANGE_OPERATION,FlowVersion SYS_CHANGE_VERSION INTO #CT_Location FROM ssis_flow.Delta_Location;
INSERT etl_v2.SourceChange SELECT @B,N'Production.Location',C.SYS_CHANGE_OPERATION,C.SYS_CHANGE_VERSION,(SELECT C.[LocationID] FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),(SELECT R.* FOR JSON PATH,WITHOUT_ARRAY_WRAPPER,INCLUDE_NULL_VALUES) FROM #CT_Location C LEFT JOIN etl_raw.[Location] R ON R.[LocationID]=C.[LocationID];
DELETE R FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION='D';
UPDATE R SET R.[Name]=S.[Name],R.[CostRate]=S.[CostRate],R.[Availability]=S.[Availability],R.[ModifiedDate]=S.[ModifiedDate],R.LoadBatchID=@B FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] JOIN ssis_flow.Delta_Location S ON S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>'D';
INSERT etl_raw.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT S.[LocationID],S.[Name],S.[CostRate],S.[Availability],S.[ModifiedDate],@B FROM #CT_Location C JOIN ssis_flow.Delta_Location S ON S.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>'D' AND NOT EXISTS(SELECT 1 FROM etl_raw.[Location] R WHERE R.[LocationID]=S.[LocationID]);
INSERT stg.[Location]([LocationID],[Name],[CostRate],[Availability],[ModifiedDate],LoadBatchID) SELECT R.[LocationID],R.[Name],R.[CostRate],R.[Availability],R.[ModifiedDate],@B FROM etl_raw.[Location] R JOIN #CT_Location C ON R.[LocationID]=C.[LocationID] WHERE C.SYS_CHANGE_OPERATION<>'D';
END;
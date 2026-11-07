DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context);


IF EXISTS(SELECT [ScrapReasonID],[ScrapReasonName] FROM etl_calc.[Dim_ScrapReason] EXCEPT SELECT [ScrapReasonID],[ScrapReasonName] FROM dw.Dim_ScrapReason) OR EXISTS(SELECT [ScrapReasonID],[ScrapReasonName] FROM dw.Dim_ScrapReason EXCEPT SELECT [ScrapReasonID],[ScrapReasonName] FROM etl_calc.[Dim_ScrapReason]) THROW 51940,N'Projected target mismatch: dw.Dim_ScrapReason',1;
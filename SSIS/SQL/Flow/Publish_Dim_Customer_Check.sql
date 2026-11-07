DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context);


IF EXISTS(SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM etl_calc.[Dim_Customer] EXCEPT SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM dw.Dim_Customer) OR EXISTS(SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM dw.Dim_Customer EXCEPT SELECT [CustomerID],[PersonID],[StoreID],[CustomerType] FROM etl_calc.[Dim_Customer]) THROW 51940,N'Projected target mismatch: dw.Dim_Customer',1;
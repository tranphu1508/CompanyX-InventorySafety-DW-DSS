DECLARE @B bigint=(SELECT BatchId FROM ssis_flow.Context);


IF EXISTS(SELECT [UnitMeasureCode],[UnitMeasureName] FROM etl_calc.[Dim_UnitMeasure] EXCEPT SELECT [UnitMeasureCode],[UnitMeasureName] FROM dw.Dim_UnitMeasure) OR EXISTS(SELECT [UnitMeasureCode],[UnitMeasureName] FROM dw.Dim_UnitMeasure EXCEPT SELECT [UnitMeasureCode],[UnitMeasureName] FROM etl_calc.[Dim_UnitMeasure]) THROW 51940,N'Projected target mismatch: dw.Dim_UnitMeasure',1;
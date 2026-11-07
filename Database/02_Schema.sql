CREATE SCHEMA [dss] AUTHORIZATION dbo;
GO
CREATE SCHEMA [dss_legacy_20261025] AUTHORIZATION dbo;
GO
CREATE SCHEMA [dw] AUTHORIZATION dbo;
GO
CREATE SCHEMA [etl] AUTHORIZATION dbo;
GO
CREATE SCHEMA [stg] AUTHORIZATION dbo;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE   FUNCTION [etl].[DateKey](@d datetime2) RETURNS int AS
BEGIN RETURN CASE WHEN @d IS NULL THEN 0 ELSE CONVERT(int,CONVERT(char(8),@d,112)) END END;

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_WorkOrder](
	[WorkOrderKey] [bigint] IDENTITY(1,1) NOT NULL,
	[WorkOrderID] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[ScrapReasonKey] [int] NOT NULL,
	[StartDateKey] [int] NOT NULL,
	[DueDateKey] [int] NOT NULL,
	[EndDateKey] [int] NOT NULL,
	[ActualStartDateKey] [int] NOT NULL,
	[ActualEndDateKey] [int] NOT NULL,
	[OrderQty] [int] NULL,
	[StockedQty] [int] NULL,
	[ScrappedQty] [int] NULL,
	[PlannedLeadTimeDays] [int] NULL,
	[RecordedLeadTimeDays] [int] NULL,
	[ActualLeadTimeDays] [int] NULL,
	[LateDays] [int] NULL,
	[OperationCount] [int] NULL,
	[TotalActualResourceHrs] [decimal](19, 4) NULL,
	[TotalPlannedCost] [decimal](19, 4) NULL,
	[TotalActualCost] [decimal](19, 4) NULL,
	[StartAt] [datetime2](7) NULL,
	[DueAt] [datetime2](7) NULL,
	[EndAt] [datetime2](7) NULL,
	[ActualStartAt] [datetime2](7) NULL,
	[ActualEndAt] [datetime2](7) NULL,
	[IsComplete] [bit] NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_WorkOrder] PRIMARY KEY CLUSTERED 
(
	[WorkOrderKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   VIEW dss.v_WorkOrderProductionTime AS
SELECT W.WorkOrderKey,W.WorkOrderID,W.ProductKey,W.OrderQty,
       W.RecordedLeadTimeDays,W.ActualLeadTimeDays,
       E.ProductionTimeSource,E.EffectiveStartAt,E.EffectiveEndAt,
       DATEDIFF(day,E.EffectiveStartAt,E.EffectiveEndAt) AS ProductionLeadTimeDays,
       CONVERT(bit,CASE WHEN E.EffectiveEndAt IS NOT NULL THEN 1 ELSE 0 END) AS IsDurationUsable,
       W.LoadBatchID
FROM dw.Fact_WorkOrder W
CROSS APPLY (SELECT CASE WHEN W.OperationCount>0 AND W.ActualStartAt IS NOT NULL
 AND W.ActualEndAt>=W.ActualStartAt THEN 1 ELSE 0 END AS RoutingValid,
 CASE WHEN W.StartAt IS NOT NULL AND W.EndAt>=W.StartAt THEN 1 ELSE 0 END AS WorkOrderValid) V
CROSS APPLY (SELECT
 CONVERT(varchar(20),CASE WHEN V.RoutingValid=1 THEN 'ROUTING' WHEN V.WorkOrderValid=1 THEN 'WORK_ORDER' ELSE 'UNAVAILABLE' END) AS ProductionTimeSource,
 CASE WHEN V.RoutingValid=1 THEN W.ActualStartAt WHEN V.WorkOrderValid=1 THEN W.StartAt END AS EffectiveStartAt,
 CASE WHEN V.RoutingValid=1 THEN W.ActualEndAt WHEN V.WorkOrderValid=1 THEN W.EndAt END AS EffectiveEndAt) E;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[ExperimentCase](
	[ExperimentCaseKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ExperimentVersionKey] [bigint] NOT NULL,
	[CaseCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CaseName] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[IsBaseline] [bit] NOT NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[PolicyConfigVersionKey] [bigint] NOT NULL,
	[InputSnapshotKey] [bigint] NOT NULL,
	[DataCutoffDateKey] [int] NOT NULL,
	[SimulationStartDateKey] [int] NOT NULL,
	[SimulationEndDateKey] [int] NOT NULL,
	[DemandInputMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DemandRuleVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RuleSetVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CaseNote] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DemandSourceKind] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SourceForecastRunKey] [int] NULL,
 CONSTRAINT [PK_V6_dss_ExperimentCase] PRIMARY KEY CLUSTERED 
(
	[ExperimentCaseKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[ExperimentReplication](
	[ExperimentReplicationKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ExperimentVersionKey] [bigint] NOT NULL,
	[ReplicationNo] [int] NOT NULL,
	[BaseSeed] [bigint] NOT NULL,
	[RandomStreamVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_ExperimentReplication] PRIMARY KEY CLUSTERED 
(
	[ExperimentReplicationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_PlanningRun](
	[PlanningRunKey] [int] IDENTITY(1,1) NOT NULL,
	[RunCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RunPurpose] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ScenarioVersionKey] [bigint] NULL,
	[ReplicationNo] [int] NULL,
	[RandomSeed] [bigint] NULL,
	[RandomStreamVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DataCutoffDateKey] [int] NULL,
	[DemandRuleVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RuleSetVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RunStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RunAt] [datetime2](7) NOT NULL,
	[CompletedAt] [datetime2](7) NULL,
	[RunNote] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[DemandBucket] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HistoryWindowPeriods] [int] NULL,
	[ForecastModel] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ForecastHorizonPeriods] [int] NULL,
	[SigmaMethod] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[PromoKnowledgeLeadDays] [int] NULL,
	[InputSnapshotKey] [bigint] NULL,
	[ExperimentCaseKey] [bigint] NULL,
	[ExperimentReplicationKey] [bigint] NULL,
	[AttemptNo] [int] NOT NULL,
	[MetricDefinitionVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SourceForecastRunKey] [int] NULL,
	[ExperimentVersionKey] [bigint] NULL,
	[RunRequestId] [uniqueidentifier] NOT NULL,
	[ExecutionSpecHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ExecutionSpecVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ExecutionSpecReference] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_Dim_PlanningRun] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   VIEW dss.v_PlanningRunContext
AS
SELECT
    r.[PlanningRunKey],
    r.[RunCode],
    r.[RunPurpose],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[ScenarioVersionKey] WHEN r.RunPurpose = N'RECOMMENDATION' THEN r.[ScenarioVersionKey] ELSE CAST(NULL AS bigint) END AS [ScenarioVersionKey],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[PolicyConfigVersionKey] ELSE CAST(NULL AS bigint) END AS [PolicyConfigVersionKey],
    c.[DemandSourceKind],
    COALESCE(r.[ReplicationNo], rep.[ReplicationNo]) AS [ReplicationNo],
    COALESCE(r.[RandomSeed], rep.[BaseSeed]) AS [RandomSeed],
    COALESCE(r.[RandomStreamVersion], rep.[RandomStreamVersion]) AS [RandomStreamVersion],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[DataCutoffDateKey] WHEN r.RunPurpose IN (N'FORECAST', N'RECOMMENDATION') THEN r.[DataCutoffDateKey] ELSE CAST(NULL AS int) END AS [DataCutoffDateKey],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[SimulationStartDateKey] ELSE CAST(NULL AS int) END AS [SimulationStartDateKey],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[SimulationEndDateKey] ELSE CAST(NULL AS int) END AS [SimulationEndDateKey],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[DemandInputMode] ELSE CAST(NULL AS nvarchar(30)) END AS [DemandInputMode],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[DemandRuleVersion] WHEN r.RunPurpose IN (N'FORECAST', N'RECOMMENDATION') THEN r.[DemandRuleVersion] ELSE CAST(NULL AS nvarchar(100)) END AS [DemandRuleVersion],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[RuleSetVersion] WHEN r.RunPurpose IN (N'FORECAST', N'RECOMMENDATION') THEN r.[RuleSetVersion] ELSE CAST(NULL AS nvarchar(200)) END AS [RuleSetVersion],
    r.[RunStatus],
    r.[RunAt],
    r.[CompletedAt],
    r.[RunNote],
    r.[LoadBatchID],
    r.[DemandBucket],
    r.[HistoryWindowPeriods],
    r.[ForecastModel],
    r.[ForecastHorizonPeriods],
    r.[SigmaMethod],
    r.[PromoKnowledgeLeadDays],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[InputSnapshotKey] WHEN r.RunPurpose IN (N'FORECAST', N'RECOMMENDATION') THEN r.[InputSnapshotKey] ELSE CAST(NULL AS bigint) END AS [InputSnapshotKey],
    r.[ExperimentCaseKey],
    r.[ExperimentReplicationKey],
    r.[AttemptNo],
    r.[MetricDefinitionVersion],
    CASE WHEN r.RunPurpose = N'SIMULATION' THEN c.[SourceForecastRunKey] WHEN r.RunPurpose = N'RECOMMENDATION' THEN r.[SourceForecastRunKey] ELSE CAST(NULL AS bigint) END AS [SourceForecastRunKey],
    r.[ExperimentVersionKey],
    r.[RunRequestId],
    r.[ExecutionSpecHash],
    r.[ExecutionSpecVersion],
    r.[ExecutionSpecReference]
FROM dss.Dim_PlanningRun AS r
LEFT JOIN dss.ExperimentCase AS c
  ON r.RunPurpose = N'SIMULATION'
 AND c.ExperimentVersionKey = r.ExperimentVersionKey
 AND c.ExperimentCaseKey = r.ExperimentCaseKey
LEFT JOIN dss.ExperimentReplication rep ON rep.ExperimentReplicationKey=r.ExperimentReplicationKey;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_RunSummary](
	[PlanningRunKey] [int] NOT NULL,
	[EvaluationScope] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CustomerDueQty] [decimal](28, 8) NOT NULL,
	[OnTimeDeliveredQty] [decimal](28, 8) NOT NULL,
	[OnTimeUnitRate] [decimal](19, 8) NULL,
	[LostQty] [decimal](28, 8) NOT NULL,
	[EndingBacklogQty] [decimal](28, 8) NOT NULL,
	[LateUnitDays] [decimal](28, 8) NOT NULL,
	[AvgInventoryValue] [decimal](28, 8) NOT NULL,
	[AvgOwnedInTransitValue] [decimal](28, 8) NOT NULL,
	[WallClockSeconds] [decimal](19, 4) NOT NULL,
	[SolverSeconds] [decimal](19, 4) NULL,
	[ValidationStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ValidationNote] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OpeningBacklogQty] [decimal](28, 8) NOT NULL,
	[LateDeliveredQty] [decimal](28, 8) NOT NULL,
	[FilledQty] [decimal](28, 8) NOT NULL,
	[DueOrderCount] [bigint] NOT NULL,
	[OnTimeFullOrderCount] [bigint] NOT NULL,
	[LostOrderCount] [bigint] NOT NULL,
	[OnTimeFullOrderRate] [decimal](19, 8) NULL,
 CONSTRAINT [PK_V6_dss_Fact_RunSummary] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_InitialCustomerOrder](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[DemandLineCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductKey] [int] NOT NULL,
	[DemandLocationKey] [int] NOT NULL,
	[OrderOffsetDays] [int] NOT NULL,
	[DueOffsetDays] [int] NOT NULL,
	[OriginalOrderQty] [decimal](28, 8) NOT NULL,
	[DeliveredBeforeStartQty] [decimal](28, 8) NOT NULL,
	[ClosedBeforeStartQty] [decimal](28, 8) NOT NULL,
	[OutstandingQty] [decimal](28, 8) NOT NULL,
	[SourceRecordReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CustomerOrderCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_InitialCustomerOrder] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[DemandLineCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[RunEntity](
	[PlanningRunKey] [int] NOT NULL,
	[EntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EntityType] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductKey] [int] NOT NULL,
	[OriginalQty] [decimal](28, 8) NOT NULL,
	[OpeningRemainingQty] [decimal](28, 8) NOT NULL,
	[CreatedAt] [datetime2](7) NOT NULL,
	[DueAt] [datetime2](7) NULL,
	[PromisedAvailableAt] [datetime2](7) NULL,
	[IsOpeningEntity] [bit] NOT NULL,
	[SourceRecordReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[InitialEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[InitialDemandLineCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CustomerOrderCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_RunEntity] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[EntityCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_SimulationOrder](
	[PlanningRunKey] [int] NOT NULL,
	[CustomerOrderCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SourceSalesOrderID] [int] NULL,
	[SourceRecordReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[KnownAt] [datetime2](7) NOT NULL,
	[DueAt] [datetime2](7) NOT NULL,
	[ExpectedLineCount] [int] NOT NULL,
	[OrderStatus] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CompletedAt] [datetime2](7) NULL,
	[CancelledAt] [datetime2](7) NULL,
	[CancellationReason] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_V6_dss_Fact_SimulationOrder] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[CustomerOrderCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Date](
	[DateKey] [int] NOT NULL,
	[CalendarDate] [date] NULL,
	[CalendarYear] [int] NULL,
	[CalendarQuarter] [int] NULL,
	[CalendarMonth] [int] NULL,
	[DayOfMonth] [int] NULL,
	[DayOfWeek] [int] NULL,
	[IsWeekend] [bit] NULL,
	[ISOWeek] [int] NULL,
	[ISOYear] [int] NULL,
	[WeekStartDate] [date] NULL,
	[MonthStartDate] [date] NULL,
 CONSTRAINT [PK_dw_Dim_Date] PRIMARY KEY CLUSTERED 
(
	[DateKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_SimulationEvent](
	[PlanningRunKey] [int] NOT NULL,
	[EventSequence] [bigint] NOT NULL,
	[EventAt] [datetime2](7) NOT NULL,
	[DateKey] [int] NOT NULL,
	[EventCode] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RelatedEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SourceRecordReference] [nvarchar](300) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductKey] [int] NOT NULL,
	[FromLocationKey] [int] NOT NULL,
	[ToLocationKey] [int] NOT NULL,
	[Quantity] [decimal](28, 8) NOT NULL,
	[SupplyOptionKey] [bigint] NULL,
	[RouteStepKey] [bigint] NULL,
	[KnownAt] [datetime2](7) NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[ReasonCode] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductionExecutionCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OrderActionCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DecisionSolveSequence] [bigint] NULL,
 CONSTRAINT [PK_V6_dss_Fact_SimulationEvent] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[EventSequence] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   VIEW dss.v_SimulationOrderLine
AS
WITH B AS (
 SELECT e.PlanningRunKey,e.EntityCode,c.InputSnapshotKey,e.SourceRecordReference,
 e.ProductKey,CONVERT(date,e.DueAt) DueDate,ds.CalendarDate StartDate,de.CalendarDate EndDate,
 e.IsOpeningEntity,e.OriginalQty,e.OpeningRemainingQty,
 CONVERT(decimal(28,8),CASE WHEN e.IsOpeningEntity=1 THEN e.OpeningRemainingQty ELSE e.OriginalQty END) Q0,
 CONVERT(date,e.CreatedAt) CreatedDate,e.CustomerOrderCode,
 CASE WHEN e.IsOpeningEntity=1 THEN i.ClosedBeforeStartQty ELSE CONVERT(decimal(28,8),0) END ClosedBeforeStartQty
 FROM dss.RunEntity e
 JOIN dss.v_PlanningRunContext c ON c.PlanningRunKey=e.PlanningRunKey
 JOIN dss.Fact_RunSummary s ON s.PlanningRunKey=e.PlanningRunKey AND s.ValidationStatus=N'PASSED'
 JOIN dss.Fact_SimulationOrder o ON o.PlanningRunKey=e.PlanningRunKey AND o.CustomerOrderCode=e.CustomerOrderCode
 JOIN dw.Dim_Date ds ON ds.DateKey=c.SimulationStartDateKey
 JOIN dw.Dim_Date de ON de.DateKey=c.SimulationEndDateKey
 LEFT JOIN dss.Scenario_InitialCustomerOrder i ON i.ScenarioVersionKey=e.ScenarioVersionKey AND i.DemandLineCode=e.InitialDemandLineCode
 WHERE c.RunPurpose=N'SIMULATION' AND c.RunStatus=N'SUCCEEDED' AND e.EntityType=N'CUSTOMER_ORDER_LINE'
 AND CONVERT(date,e.CreatedAt)<=de.CalendarDate
), Periods AS (
 SELECT B.*,v.LateStart,
 CASE WHEN v.LateStart<=EndDate THEN DATEDIFF(day,v.LateStart,EndDate)+1 ELSE 0 END LateDayCount
 FROM B CROSS APPLY(SELECT MAX(d) LateStart FROM (VALUES(StartDate),(DueDate),(CreatedDate)) x(d)) v
), E AS (
 SELECT b.PlanningRunKey,b.EntityCode,f.EventSequence,f.EventAt,CONVERT(date,f.EventAt) EventDate,
 f.EventCode,f.Quantity,b.Q0,b.LateStart,b.EndDate,
 SUM(CASE WHEN f.EventCode IN(N'SHIP_ON_TIME',N'SHIP_LATE') THEN f.Quantity ELSE CONVERT(decimal(28,8),0) END)
 OVER(PARTITION BY b.PlanningRunKey,b.EntityCode ORDER BY f.EventAt,f.EventSequence ROWS UNBOUNDED PRECEDING) RunningFilled
 FROM Periods b JOIN dss.Fact_SimulationEvent f ON f.PlanningRunKey=b.PlanningRunKey AND f.EntityCode=b.EntityCode
 WHERE CONVERT(date,f.EventAt) BETWEEN b.StartDate AND b.EndDate
 AND ((f.EventCode=N'SHIP_ON_TIME' AND CONVERT(date,f.EventAt)<=b.DueDate)
 OR (f.EventCode=N'SHIP_LATE' AND CONVERT(date,f.EventAt)>b.DueDate)
 OR f.EventCode=N'LOST_SALE')
), A AS (
 SELECT PlanningRunKey,EntityCode,
 SUM(CASE WHEN EventCode=N'SHIP_ON_TIME' THEN Quantity ELSE 0 END) OnTimeQty,
 SUM(CASE WHEN EventCode=N'SHIP_LATE' THEN Quantity ELSE 0 END) LateQty,
 SUM(CASE WHEN EventCode=N'LOST_SALE' THEN Quantity ELSE 0 END) LostQty,
 MAX(CASE WHEN EventCode IN(N'SHIP_ON_TIME',N'SHIP_LATE') THEN EventDate END) LastDeliveryDate,
 MIN(CASE WHEN EventCode IN(N'SHIP_ON_TIME',N'SHIP_LATE') AND RunningFilled>=Q0 THEN EventDate END) FullDeliveryDate,
 SUM(Quantity*CONVERT(decimal(10,0),CASE WHEN LateStart>EndDate THEN 0 ELSE DATEDIFF(day,CASE WHEN EventDate>LateStart THEN EventDate ELSE LateStart END,EndDate)+1 END)) RemovedUnitDays
 FROM E GROUP BY PlanningRunKey,EntityCode
), Q AS (
 SELECT b.*,
 CONVERT(decimal(28,8),COALESCE(a.OnTimeQty,0)) OnTimeQty,
 CONVERT(decimal(28,8),COALESCE(a.LateQty,0)) LateQty,
 CONVERT(decimal(28,8),COALESCE(a.LostQty,0)) LostQty,
 a.LastDeliveryDate,
 CASE WHEN COALESCE(a.LostQty,0)=0 AND b.ClosedBeforeStartQty=0 THEN a.FullDeliveryDate END CompletionDate,
 CONVERT(decimal(28,8),b.Q0*b.LateDayCount-COALESCE(a.RemovedUnitDays,0)) LateUnitDays
 FROM Periods b LEFT JOIN A a ON a.PlanningRunKey=b.PlanningRunKey AND a.EntityCode=b.EntityCode
)
SELECT PlanningRunKey,EntityCode,InputSnapshotKey,SourceRecordReference,ProductKey,
 CONVERT(int,CONVERT(char(8),DueDate,112)) DueDateKey,
 CONVERT(int,CONVERT(char(8),StartDate,112)) EvaluationStartDateKey,
 CONVERT(int,CONVERT(char(8),EndDate,112)) EvaluationEndDateKey,
 IsOpeningEntity,OriginalQty OriginalOrderQty,OpeningRemainingQty,Q0 ObligationQty,
 OnTimeQty,LateQty,CONVERT(decimal(28,8),OnTimeQty+LateQty) FilledQty,LostQty,
 CONVERT(decimal(28,8),Q0-OnTimeQty-LateQty-LostQty) UnfilledQtyAtEnd,
 CONVERT(decimal(28,8),CASE WHEN DueDate<=EndDate THEN Q0-OnTimeQty-LateQty-LostQty ELSE 0 END) OverdueUnfilledQtyAtEnd,
 LateUnitDays,
 CONVERT(int,CONVERT(char(8),LastDeliveryDate,112)) LastDeliveryDateKey,
 CONVERT(int,CONVERT(char(8),CompletionDate,112)) CompletionDateKey,
 CASE WHEN CompletionDate IS NULL THEN NULL WHEN CompletionDate<=DueDate THEN 0 ELSE DATEDIFF(day,DueDate,CompletionDate) END CompletionLateDays,
 CONVERT(nvarchar(30),CASE WHEN DueDate<StartDate THEN N'OPENING_OVERDUE' WHEN DueDate>EndDate THEN N'FUTURE_DUE' ELSE N'DUE_IN_RUN' END) EvaluationCohort,
 CONVERT(bit,CASE WHEN DueDate BETWEEN StartDate AND EndDate THEN 1 ELSE 0 END) IsDueInEvaluationPeriod,
 CONVERT(decimal(28,8),CASE WHEN DueDate BETWEEN StartDate AND EndDate THEN Q0 ELSE 0 END) OTUDemandQty,
 CONVERT(decimal(28,8),CASE WHEN DueDate BETWEEN StartDate AND EndDate THEN OnTimeQty ELSE 0 END) OTUOnTimeQty,
 CustomerOrderCode
FROM Q;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_ExperimentVersion](
	[ExperimentVersionKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ExperimentCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[VersionNo] [int] NOT NULL,
	[ExperimentName] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ResearchQuestion] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ChangedFactors] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ControlledFactors] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RandomizationMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RandomizationRuleVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[MetricDefinitionVersion] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PlannedReplicationCount] [int] NOT NULL,
	[LifecycleStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ConfigHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[PublishedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_V6_dss_Dim_ExperimentVersion] PRIMARY KEY CLUSTERED 
(
	[ExperimentVersionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   VIEW dss.v_ExperimentCaseExecution AS
SELECT c.*,e.ExperimentCode,
 CASE WHEN c.RuleSetVersion='companyx.dw.sql63.v2' THEN 'PORTABLE_V2' ELSE 'LEGACY_READ_ONLY' END ExecutionCompatibility
FROM dss.ExperimentCase c JOIN dss.Dim_ExperimentVersion e ON c.ExperimentVersionKey=e.ExperimentVersionKey
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[ArtifactObject](
	[ArtifactHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ArtifactKind] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Encoding] [varchar](32) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PayloadBase64] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CreatedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_ArtifactObject] PRIMARY KEY CLUSTERED 
(
	[ArtifactHash] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Bridge_RunEntityRelation](
	[PlanningRunKey] [int] NOT NULL,
	[ParentEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ChildEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RelationCode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[AllocatedQty] [decimal](28, 8) NULL,
	[AllocatedProductKey] [int] NULL,
 CONSTRAINT [PK_V6_dss_Bridge_RunEntityRelation] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ParentEntityCode] ASC,
	[ChildEntityCode] ASC,
	[RelationCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_EventType](
	[EventCode] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EventName] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EntityType] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[QuantityMeaning] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RequiredReferences] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Dim_EventType] PRIMARY KEY CLUSTERED 
(
	[EventCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_InputSnapshot](
	[InputSnapshotKey] [bigint] IDENTITY(1,1) NOT NULL,
	[SnapshotCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SnapshotReference] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InputHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SnapshotAsOfAt] [datetime2](7) NULL,
	[SnapshotScope] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SourceLoadBatchID] [bigint] NULL,
	[CreatedAt] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_V6_dss_Dim_InputSnapshot] PRIMARY KEY CLUSTERED 
(
	[InputSnapshotKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_PolicyConfigVersion](
	[PolicyConfigVersionKey] [bigint] IDENTITY(1,1) NOT NULL,
	[PolicyConfigCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[VersionNo] [int] NOT NULL,
	[PolicyTypeKey] [bigint] NOT NULL,
	[ConfigOrigin] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LifecycleStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ConfigHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_Dim_PolicyConfigVersion] PRIMARY KEY CLUSTERED 
(
	[PolicyConfigVersionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_PolicyType](
	[PolicyTypeKey] [bigint] IDENTITY(1,1) NOT NULL,
	[PolicyCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PolicyName] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DecisionScope] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Description] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[IsActive] [bit] NOT NULL,
 CONSTRAINT [PK_V6_dss_Dim_PolicyType] PRIMARY KEY CLUSTERED 
(
	[PolicyTypeKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_ScenarioVersion](
	[ScenarioVersionKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ScenarioCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[VersionNo] [int] NOT NULL,
	[ScenarioName] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ShortageHandlingMode] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[TimeBasis] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InitialStateMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InitialStateRule] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InventoryValuationRule] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[HoldingCostRatePerYear] [decimal](28, 8) NOT NULL,
	[AssumptionNote] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LifecycleStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ConfigHash] [char](64) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CreatedAt] [datetime2](7) NOT NULL,
	[PublishedAt] [datetime2](7) NULL,
	[InitialStateBindingMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ResolvedInputSnapshotKey] [bigint] NULL,
	[InitialStateAsOfDateKey] [int] NULL,
	[InitialStateDataCutoffDateKey] [int] NULL,
	[CustomerShipmentMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LostSalesScope] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_Dim_ScenarioVersion] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Dim_ServiceLevel](
	[ServiceLevelKey] [int] NOT NULL,
	[ServiceLevelPct] [decimal](6, 4) NULL,
	[ZValue] [decimal](9, 6) NULL,
 CONSTRAINT [PK_dss_Dim_ServiceLevel] PRIMARY KEY CLUSTERED 
(
	[ServiceLevelKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_DemandDaily](
	[DateKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[DemandRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[IndependentQty] [decimal](19, 4) NULL,
	[PromoIndependentQty] [decimal](19, 4) NULL,
	[DependentQty] [decimal](19, 4) NULL,
	[TotalDemandQty] [decimal](19, 4) NULL,
	[EligibleSalesLineCount] [int] NULL,
	[ExcludedSalesLineCount] [int] NULL,
	[ParentWorkOrderCount] [int] NULL,
	[IsInSellWindow] [bit] NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dss_Fact_DemandDaily] PRIMARY KEY CLUSTERED 
(
	[DateKey] ASC,
	[ProductKey] ASC,
	[DemandRuleVersion] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_DemandForecast](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[TargetPeriodStartDateKey] [int] NOT NULL,
	[DemandType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[HorizonPeriods] [int] NULL,
	[ForecastQty] [decimal](19, 4) NULL,
	[ForecastLowerQty] [decimal](19, 4) NULL,
	[ForecastUpperQty] [decimal](19, 4) NULL,
	[PredictionIntervalPct] [decimal](6, 4) NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_V6_dss_Fact_DemandForecast] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC,
	[TargetPeriodStartDateKey] ASC,
	[DemandType] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_OptimizationSolve](
	[PlanningRunKey] [int] NOT NULL,
	[SolveSequence] [bigint] NOT NULL,
	[DecisionAt] [datetime2](7) NOT NULL,
	[AttemptNo] [int] NOT NULL,
	[ObjectiveStage] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InformationCutoffAt] [datetime2](7) NOT NULL,
	[HorizonEndAt] [datetime2](7) NOT NULL,
	[PlanningForecastRunKey] [int] NULL,
	[ForecastInputReference] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[StateInputReference] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DecisionOutputReference] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SolverStatus] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[HasFeasibleSolution] [bit] NOT NULL,
	[ActionSource] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ObjectiveValue] [decimal](28, 8) NULL,
	[BestBound] [decimal](28, 8) NULL,
	[RelativeGap] [decimal](19, 8) NULL,
	[SolverSeconds] [decimal](19, 4) NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_V6_dss_Fact_OptimizationSolve] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[SolveSequence] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_PolicySimulation](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[SimulatedDays] [int] NOT NULL,
	[InitialOnHandQty] [decimal](28, 8) NOT NULL,
	[OpeningBacklogQty] [decimal](28, 8) NOT NULL,
	[TotalDemandQty] [decimal](28, 8) NOT NULL,
	[OnTimeDeliveredQty] [decimal](28, 8) NOT NULL,
	[LateDeliveredQty] [decimal](28, 8) NOT NULL,
	[FilledQty] [decimal](28, 8) NOT NULL,
	[LostQty] [decimal](28, 8) NOT NULL,
	[EndingBacklogQty] [decimal](28, 8) NOT NULL,
	[LateUnitDays] [decimal](28, 8) NOT NULL,
	[OnTimeUnitRate] [decimal](19, 8) NULL,
	[FillRate] [decimal](19, 8) NULL,
	[AvgOnHandQty] [decimal](28, 8) NOT NULL,
	[AvgWIPQty] [decimal](28, 8) NOT NULL,
	[AvgInTransitQty] [decimal](28, 8) NOT NULL,
	[AvgInventoryValue] [decimal](28, 8) NOT NULL,
	[AvgInTransitValue] [decimal](28, 8) NOT NULL,
	[HoldingCost] [decimal](28, 8) NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
 CONSTRAINT [PK_V6_dss_Fact_PolicySimulation] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_SafetyStockRecommendation](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[ServiceLevelKey] [int] NOT NULL,
	[VendorKey] [int] NOT NULL,
	[SupplyType] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[AvgDemandPerDay] [decimal](19, 6) NULL,
	[DemandSigmaPerDay] [decimal](19, 6) NULL,
	[SigmaSource] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DemandObservationCount] [int] NULL,
	[AvgLeadTimeDays] [decimal](9, 2) NULL,
	[LeadTimeSigmaDays] [decimal](9, 2) NULL,
	[LeadTimeSource] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LeadTimeObservationCount] [int] NULL,
	[RecommendedSafetyStock] [decimal](19, 4) NULL,
	[RecommendedReorderPoint] [decimal](19, 4) NULL,
	[PolicySafetyStockLevel] [int] NULL,
	[PolicyReorderPoint] [int] NULL,
	[OnHandQty] [int] NULL,
	[OnOrderQty] [int] NULL,
	[InventoryPosition] [int] NULL,
	[SafetyStockGap] [decimal](19, 4) NULL,
	[IsBelowReorderPoint] [bit] NULL,
	[UnitCostAtRun] [decimal](19, 4) NULL,
	[SafetyStockValue] [decimal](28, 6) NULL,
	[AnnualHoldingCost] [decimal](28, 6) NULL,
	[CalcStatus] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CalcNote] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
	[SupplyOptionKey] [bigint] NULL,
 CONSTRAINT [PK_V6_dss_Fact_SafetyStockRecommendation] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC,
	[ServiceLevelKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_SimulationDaily](
	[PlanningRunKey] [int] NOT NULL,
	[DateKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[LocationKey] [int] NOT NULL,
	[OnHandQty] [decimal](28, 8) NOT NULL,
	[ProductionWIPQty] [decimal](28, 8) NOT NULL,
	[QueuedProductionQty] [decimal](28, 8) NOT NULL,
	[PurchaseInTransitQty] [decimal](28, 8) NOT NULL,
	[CustomerBacklogQty] [decimal](28, 8) NOT NULL,
	[CustomerDueQty] [decimal](28, 8) NOT NULL,
	[OnTimeDeliveredQty] [decimal](28, 8) NOT NULL,
	[LateDeliveredQty] [decimal](28, 8) NOT NULL,
	[LostQty] [decimal](28, 8) NOT NULL,
	[BOMConsumedQty] [decimal](28, 8) NOT NULL,
	[PurchaseAcceptedQty] [decimal](28, 8) NOT NULL,
	[PurchaseRejectedQty] [decimal](28, 8) NOT NULL,
	[ProductionGoodQty] [decimal](28, 8) NOT NULL,
	[OnHandValue] [decimal](28, 8) NOT NULL,
	[WIPValue] [decimal](28, 8) NOT NULL,
	[OwnedInTransitValue] [decimal](28, 8) NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[OpenPurchaseQty] [decimal](28, 8) NOT NULL,
 CONSTRAINT [PK_V6_dss_Fact_SimulationDaily] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[DateKey] ASC,
	[ProductKey] ASC,
	[LocationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Fact_StochasticDraw](
	[PlanningRunKey] [int] NOT NULL,
	[DrawSequence] [bigint] NOT NULL,
	[DistributionKey] [bigint] NOT NULL,
	[StreamCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EventIdentity] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DrawIndex] [int] NOT NULL,
	[RawSampleValue] [decimal](28, 8) NOT NULL,
	[AppliedValue] [decimal](28, 8) NOT NULL,
	[KnownAt] [datetime2](7) NOT NULL,
	[DrawKind] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[TrialQty] [decimal](28, 8) NULL,
 CONSTRAINT [PK_V6_dss_Fact_StochasticDraw] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[DrawSequence] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[PolicyParameterDefinition](
	[PolicyTypeKey] [bigint] NOT NULL,
	[ParameterCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ValueType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[UnitCode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[IsRequired] [bit] NOT NULL,
	[MinValue] [decimal](28, 8) NULL,
	[MaxValue] [decimal](28, 8) NULL,
	[AllowedTextValues] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Description] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_PolicyParameterDefinition] PRIMARY KEY CLUSTERED 
(
	[PolicyTypeKey] ASC,
	[ParameterCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[PolicyParameterValue](
	[PolicyConfigVersionKey] [bigint] NOT NULL,
	[PolicyTypeKey] [bigint] NOT NULL,
	[ParameterCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[NumericValue] [decimal](28, 8) NULL,
	[TextValue] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[BooleanValue] [bit] NULL,
 CONSTRAINT [PK_V6_dss_PolicyParameterValue] PRIMARY KEY CLUSTERED 
(
	[PolicyConfigVersionKey] ASC,
	[ParameterCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[PolicyProductConfig](
	[PolicyConfigVersionKey] [bigint] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[ReorderPointUsed] [decimal](28, 8) NOT NULL,
	[TargetLevelUsed] [decimal](28, 8) NOT NULL,
	[ParameterRuleVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NOT NULL,
 CONSTRAINT [PK_V6_dss_PolicyProductConfig] PRIMARY KEY CLUSTERED 
(
	[PolicyConfigVersionKey] ASC,
	[ProductKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_CustomerOrder](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[DemandLineCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductKey] [int] NOT NULL,
	[OrderOffsetDays] [int] NOT NULL,
	[DueOffsetDays] [int] NOT NULL,
	[Quantity] [decimal](28, 8) NOT NULL,
	[ForecastReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CustomerOrderCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_CustomerOrder] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[DemandLineCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_Distribution](
	[DistributionKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[DistributionCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InputKind] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DistributionType] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[TimeOrRatioUnit] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ParametersJson] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LowerBound] [decimal](28, 8) NOT NULL,
	[UpperBound] [decimal](28, 8) NULL,
	[RoundingRule] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DependenceGroupCode] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_Distribution] PRIMARY KEY CLUSTERED 
(
	[DistributionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_InitialEntity](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[InitialEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[EntityType] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductKey] [int] NOT NULL,
	[OriginalQty] [decimal](28, 8) NOT NULL,
	[RemainingQty] [decimal](28, 8) NOT NULL,
	[CreatedOffsetDays] [int] NOT NULL,
	[ParentInitialEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SourceRecordReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_Scenario_InitialEntity] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[InitialEntityCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_InitialPosition](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[PositionCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductKey] [int] NOT NULL,
	[StateCode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[FromLocationKey] [int] NOT NULL,
	[ToLocationKey] [int] NOT NULL,
	[Quantity] [decimal](28, 8) NOT NULL,
	[AvailableOffsetDays] [int] NULL,
	[RouteStepKey] [bigint] NULL,
	[InitialEntityCode] [nvarchar](150) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SupplyOptionKey] [bigint] NULL,
	[RemainingProcessHours] [decimal](28, 8) NULL,
	[SetupCompletedFlag] [bit] NULL,
	[ExpectedAvailableOffsetDays] [int] NULL,
	[SourceRecordReference] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_V6_dss_Scenario_InitialPosition] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[PositionCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_Product](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[StockUnitMeasureKey] [int] NOT NULL,
	[DemandLocationKey] [int] NOT NULL,
	[IsIndependentDemandItem] [bit] NOT NULL,
	[IsActiveInScenario] [bit] NOT NULL,
	[SellEndHandling] [nvarchar](60) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[StandardCostUsed] [decimal](28, 8) NOT NULL,
	[CostBasisNote] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_Product] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[ProductKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_Production](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[ProductionMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LeadTimeDistributionKey] [bigint] NULL,
	[LeadTimeSemantics] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RouteKey] [bigint] NULL,
	[MaterialIssueLocationKey] [int] NOT NULL,
	[FinishedReceiptLocationKey] [int] NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_Production] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[ProductKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_Route](
	[RouteKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[RouteCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RouteDescription] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_Route] PRIMARY KEY CLUSTERED 
(
	[RouteKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_RouteStep](
	[RouteStepKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[RouteKey] [bigint] NOT NULL,
	[StepNo] [int] NOT NULL,
	[LocationKey] [int] NOT NULL,
	[SetupTimeHours] [decimal](28, 8) NOT NULL,
	[ProcessTimeHoursPerStockUnit] [decimal](28, 8) NOT NULL,
	[ProcessTimeFactorDistributionKey] [bigint] NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_RouteStep] PRIMARY KEY CLUSTERED 
(
	[RouteStepKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_Supply](
	[SupplyOptionKey] [bigint] IDENTITY(1,1) NOT NULL,
	[ScenarioVersionKey] [bigint] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[VendorKey] [int] NOT NULL,
	[ReceiptLocationKey] [int] NOT NULL,
	[PurchaseUnitMeasureKey] [int] NOT NULL,
	[DelayDistributionKey] [bigint] NOT NULL,
	[RejectRateDistributionKey] [bigint] NOT NULL,
	[SupplyLimitMode] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[MinOrderQty] [decimal](28, 8) NOT NULL,
	[MaxOrderQty] [decimal](28, 8) NULL,
	[UnitPurchaseCost] [decimal](28, 8) NOT NULL,
	[InspectionRule] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[InTransitOwnershipRule] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[BaseLeadTimeDays] [int] NOT NULL,
	[RejectSamplingRule] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_Supply] PRIMARY KEY CLUSTERED 
(
	[SupplyOptionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_SupplyCalendar](
	[SupplyOptionKey] [bigint] NOT NULL,
	[DateKey] [int] NOT NULL,
	[MaxDispatchQty] [decimal](28, 8) NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_SupplyCalendar] PRIMARY KEY CLUSTERED 
(
	[SupplyOptionKey] ASC,
	[DateKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss].[Scenario_UnitConversion](
	[ScenarioVersionKey] [bigint] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[FromUnitMeasureKey] [int] NOT NULL,
	[ToUnitMeasureKey] [int] NOT NULL,
	[ConversionFactor] [decimal](28, 8) NOT NULL,
 CONSTRAINT [PK_V6_dss_Scenario_UnitConversion] PRIMARY KEY CLUSTERED 
(
	[ScenarioVersionKey] ASC,
	[ProductKey] ASC,
	[FromUnitMeasureKey] ASC,
	[ToUnitMeasureKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss_legacy_20261025].[Dim_PlanningRun](
	[PlanningRunKey] [int] IDENTITY(1,1) NOT NULL,
	[RunCode] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[RunAt] [datetime2](7) NULL,
	[DataCutoffDateKey] [int] NOT NULL,
	[DemandBucket] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HistoryWindowPeriods] [int] NULL,
	[ForecastModel] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ForecastHorizonPeriods] [int] NULL,
	[SigmaMethod] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[BuyLeadTimeCV] [decimal](9, 6) NULL,
	[PromoKnowledgeLeadDays] [int] NULL,
	[HoldingCostRatePerYear] [decimal](9, 6) NULL,
	[SimulationStartDateKey] [int] NOT NULL,
	[SimulationEndDateKey] [int] NOT NULL,
	[InitialInventoryRule] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OrderQtyRule] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OrderingCostPerOrder] [decimal](19, 4) NULL,
	[DemandRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RuleSetVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RunStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RunNote] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
 CONSTRAINT [PK_dss_Dim_PlanningRun] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss_legacy_20261025].[Fact_DemandForecast](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[TargetPeriodStartDateKey] [int] NOT NULL,
	[DemandType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[HorizonPeriods] [int] NULL,
	[ForecastQty] [decimal](19, 4) NULL,
	[ForecastLowerQty] [decimal](19, 4) NULL,
	[ForecastUpperQty] [decimal](19, 4) NULL,
	[PredictionIntervalPct] [decimal](6, 4) NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dss_Fact_DemandForecast] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC,
	[TargetPeriodStartDateKey] ASC,
	[DemandType] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss_legacy_20261025].[Fact_PolicySimulation](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[PolicyType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ServiceLevelKey] [int] NOT NULL,
	[SafetyStockUsed] [decimal](19, 4) NULL,
	[ReorderPointUsed] [decimal](19, 4) NULL,
	[OrderQtyUsed] [decimal](19, 4) NULL,
	[InitialOnHandQty] [decimal](19, 4) NULL,
	[SimulatedDays] [int] NULL,
	[TotalDemandQty] [decimal](19, 4) NULL,
	[FilledQty] [decimal](19, 4) NULL,
	[LostQty] [decimal](19, 4) NULL,
	[FillRate] [decimal](9, 6) NULL,
	[StockoutDays] [int] NULL,
	[ReplenishmentCycles] [int] NULL,
	[StockoutCycles] [int] NULL,
	[CycleServiceLevel] [decimal](9, 6) NULL,
	[OrdersPlaced] [int] NULL,
	[AvgOnHandQty] [decimal](19, 4) NULL,
	[AvgInventoryValue] [decimal](28, 6) NULL,
	[HoldingCost] [decimal](28, 6) NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dss_Fact_PolicySimulation] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC,
	[PolicyType] ASC,
	[ServiceLevelKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation](
	[PlanningRunKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[ServiceLevelKey] [int] NOT NULL,
	[VendorKey] [int] NOT NULL,
	[SupplyType] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[AvgDemandPerDay] [decimal](19, 6) NULL,
	[DemandSigmaPerDay] [decimal](19, 6) NULL,
	[SigmaSource] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DemandObservationCount] [int] NULL,
	[AvgLeadTimeDays] [decimal](9, 2) NULL,
	[LeadTimeSigmaDays] [decimal](9, 2) NULL,
	[LeadTimeSource] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LeadTimeObservationCount] [int] NULL,
	[ScrapRate] [decimal](9, 6) NULL,
	[RecommendedSafetyStock] [decimal](19, 4) NULL,
	[RecommendedReorderPoint] [decimal](19, 4) NULL,
	[PolicySafetyStockLevel] [int] NULL,
	[PolicyReorderPoint] [int] NULL,
	[OnHandQty] [int] NULL,
	[OnOrderQty] [int] NULL,
	[InventoryPosition] [int] NULL,
	[SafetyStockGap] [decimal](19, 4) NULL,
	[IsBelowReorderPoint] [bit] NULL,
	[UnitCostAtRun] [decimal](19, 4) NULL,
	[SafetyStockValue] [decimal](28, 6) NULL,
	[AnnualHoldingCost] [decimal](28, 6) NULL,
	[CalcStatus] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CalcNote] [nvarchar](500) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dss_Fact_SafetyStockRecommendation] PRIMARY KEY CLUSTERED 
(
	[PlanningRunKey] ASC,
	[ProductKey] ASC,
	[ServiceLevelKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Bridge_BillOfMaterials](
	[BOMKey] [int] IDENTITY(1,1) NOT NULL,
	[BillOfMaterialsID] [int] NOT NULL,
	[AssemblyProductKey] [int] NOT NULL,
	[ComponentProductKey] [int] NOT NULL,
	[UnitMeasureKey] [int] NOT NULL,
	[BOMLevel] [int] NULL,
	[PerAssemblyQty] [decimal](8, 2) NULL,
	[StartDate] [date] NULL,
	[EndDate] [date] NULL,
	[IsStructureValid] [bit] NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Bridge_BillOfMaterials] PRIMARY KEY CLUSTERED 
(
	[BOMKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Bridge_ProductPromotion](
	[ProductKey] [int] NOT NULL,
	[PromotionKey] [int] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Bridge_ProductPromotion] PRIMARY KEY CLUSTERED 
(
	[ProductKey] ASC,
	[PromotionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Channel](
	[ChannelKey] [int] NOT NULL,
	[OnlineOrderFlag] [bit] NULL,
	[ChannelName] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
 CONSTRAINT [PK_dw_Dim_Channel] PRIMARY KEY CLUSTERED 
(
	[ChannelKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Customer](
	[CustomerKey] [int] IDENTITY(1,1) NOT NULL,
	[CustomerID] [int] NULL,
	[PersonID] [int] NULL,
	[StoreID] [int] NULL,
	[CustomerType] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_Customer] PRIMARY KEY CLUSTERED 
(
	[CustomerKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Location](
	[LocationKey] [int] IDENTITY(1,1) NOT NULL,
	[LocationID] [int] NULL,
	[LocationName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CostRate] [decimal](10, 4) NULL,
	[Availability] [decimal](8, 2) NULL,
	[LocationType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[HasProductionConflict] [bit] NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_Location] PRIMARY KEY CLUSTERED 
(
	[LocationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Product](
	[ProductKey] [int] IDENTITY(1,1) NOT NULL,
	[ProductID] [int] NULL,
	[ProductNumber] [nvarchar](25) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductSubcategoryID] [int] NULL,
	[SubcategoryName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductCategoryID] [int] NULL,
	[CategoryName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductModelID] [int] NULL,
	[MakeFlag] [bit] NULL,
	[FinishedGoodsFlag] [bit] NULL,
	[SupplyType] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductRole] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[IsBOMAssembly] [bit] NULL,
	[IsBOMComponent] [bit] NULL,
	[Color] [nvarchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Size] [nvarchar](5) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SizeUnitName] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Weight] [decimal](8, 2) NULL,
	[WeightUnitName] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductLine] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductLineName] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Class] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ClassName] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Style] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[StyleName] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DaysToManufacture] [int] NULL,
	[SafetyStockLevel] [int] NULL,
	[ReorderPoint] [int] NULL,
	[StandardCost] [decimal](19, 4) NULL,
	[ListPrice] [decimal](19, 4) NULL,
	[SellStartDate] [date] NULL,
	[SellEndDate] [date] NULL,
	[DiscontinuedDate] [date] NULL,
	[DQStatus] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_Product] PRIMARY KEY CLUSTERED 
(
	[ProductKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Promotion](
	[PromotionKey] [int] IDENTITY(1,1) NOT NULL,
	[SpecialOfferID] [int] NULL,
	[Description] [nvarchar](255) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OfferType] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OfferCategory] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DiscountPct] [decimal](9, 6) NULL,
	[StartDate] [datetime2](7) NULL,
	[EndDate] [datetime2](7) NULL,
	[MinQty] [int] NULL,
	[MaxQty] [int] NULL,
	[IsNoDiscount] [bit] NULL,
	[IsScheduleValid] [bit] NULL,
	[IsDiscountValid] [bit] NULL,
	[IsQtyRangeValid] [bit] NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_Promotion] PRIMARY KEY CLUSTERED 
(
	[PromotionKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_PurchaseStatus](
	[PurchaseStatusKey] [int] NOT NULL,
	[StatusCode] [int] NULL,
	[StatusName] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[IsDocumented] [bit] NULL,
 CONSTRAINT [PK_dw_Dim_PurchaseStatus] PRIMARY KEY CLUSTERED 
(
	[PurchaseStatusKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_SalesStatus](
	[SalesStatusKey] [int] NOT NULL,
	[StatusCode] [int] NULL,
	[StatusName] [nvarchar](40) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[IsDocumented] [bit] NULL,
	[IsDemandEligible] [bit] NULL,
 CONSTRAINT [PK_dw_Dim_SalesStatus] PRIMARY KEY CLUSTERED 
(
	[SalesStatusKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_ScrapReason](
	[ScrapReasonKey] [int] IDENTITY(1,1) NOT NULL,
	[ScrapReasonID] [int] NULL,
	[ScrapReasonName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_ScrapReason] PRIMARY KEY CLUSTERED 
(
	[ScrapReasonKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_UnitMeasure](
	[UnitMeasureKey] [int] IDENTITY(1,1) NOT NULL,
	[UnitMeasureCode] [nvarchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[UnitMeasureName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_UnitMeasure] PRIMARY KEY CLUSTERED 
(
	[UnitMeasureKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Dim_Vendor](
	[VendorKey] [int] IDENTITY(1,1) NOT NULL,
	[VendorID] [int] NULL,
	[AccountNumber] [nvarchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[VendorName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CreditRating] [int] NULL,
	[CreditRatingName] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[PreferredVendorStatus] [bit] NULL,
	[ActiveFlag] [bit] NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Dim_Vendor] PRIMARY KEY CLUSTERED 
(
	[VendorKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_InventoryOnHand](
	[ProductKey] [int] NOT NULL,
	[LocationKey] [int] NOT NULL,
	[AsOfDateKey] [int] NOT NULL,
	[Shelf] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Bin] [int] NULL,
	[QuantityOnHand] [int] NULL,
	[UnitCostAsOf] [decimal](19, 4) NULL,
	[InventoryValue] [decimal](28, 6) NULL,
	[IsNegativeQty] [bit] NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_InventoryOnHand] PRIMARY KEY CLUSTERED 
(
	[ProductKey] ASC,
	[LocationKey] ASC,
	[AsOfDateKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_ProductVendorTerms](
	[ProductKey] [int] NOT NULL,
	[VendorKey] [int] NOT NULL,
	[AsOfDateKey] [int] NOT NULL,
	[UnitMeasureKey] [int] NOT NULL,
	[AverageLeadTime] [int] NULL,
	[StandardPrice] [decimal](19, 4) NULL,
	[LastReceiptCost] [decimal](19, 4) NULL,
	[LastReceiptDateKey] [int] NOT NULL,
	[MinOrderQty] [int] NULL,
	[MaxOrderQty] [int] NULL,
	[OnOrderQty] [int] NULL,
	[IsOrderQtyRangeValid] [bit] NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_ProductVendorTerms] PRIMARY KEY CLUSTERED 
(
	[ProductKey] ASC,
	[VendorKey] ASC,
	[AsOfDateKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_PurchaseOrderLine](
	[PurchaseOrderLineKey] [bigint] IDENTITY(1,1) NOT NULL,
	[PurchaseOrderID] [int] NOT NULL,
	[PurchaseOrderDetailID] [int] NOT NULL,
	[OrderDateKey] [int] NOT NULL,
	[ExpectedShipDateKey] [int] NOT NULL,
	[ExpectedReceiptDateKey] [int] NOT NULL,
	[VendorKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[PurchaseStatusKey] [int] NOT NULL,
	[OrderQty] [int] NULL,
	[ReceivedQty] [decimal](19, 4) NULL,
	[RejectedQty] [decimal](19, 4) NULL,
	[StockedQty] [decimal](19, 4) NULL,
	[UnitPrice] [decimal](19, 4) NULL,
	[LineTotal] [decimal](28, 6) NULL,
	[OrderAt] [datetime2](7) NULL,
	[ExpectedShipAt] [datetime2](7) NULL,
	[ExpectedReceiptAt] [datetime2](7) NULL,
	[IsVendorProductDeclared] [bit] NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_PurchaseOrderLine] PRIMARY KEY CLUSTERED 
(
	[PurchaseOrderLineKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_SalesOrderLine](
	[SalesOrderLineKey] [bigint] IDENTITY(1,1) NOT NULL,
	[SalesOrderID] [int] NOT NULL,
	[SalesOrderDetailID] [int] NOT NULL,
	[OrderDateKey] [int] NOT NULL,
	[DueDateKey] [int] NOT NULL,
	[ShipDateKey] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[PromotionKey] [int] NOT NULL,
	[SalesStatusKey] [int] NOT NULL,
	[CustomerKey] [int] NOT NULL,
	[ChannelKey] [int] NOT NULL,
	[OrderQty] [int] NULL,
	[UnitPrice] [decimal](19, 4) NULL,
	[UnitPriceDiscount] [decimal](9, 6) NULL,
	[LineTotal] [decimal](28, 6) NULL,
	[OrderAt] [datetime2](7) NULL,
	[DueAt] [datetime2](7) NULL,
	[ShippedAt] [datetime2](7) NULL,
	[IsDemandEligible] [bit] NOT NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_SalesOrderLine] PRIMARY KEY CLUSTERED 
(
	[SalesOrderLineKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Fact_WorkOrderOperation](
	[WorkOrderOperationKey] [bigint] IDENTITY(1,1) NOT NULL,
	[WorkOrderID] [int] NOT NULL,
	[OperationSequence] [int] NOT NULL,
	[ProductKey] [int] NOT NULL,
	[LocationKey] [int] NOT NULL,
	[ScheduledStartDateKey] [int] NOT NULL,
	[ScheduledEndDateKey] [int] NOT NULL,
	[ActualStartDateKey] [int] NOT NULL,
	[ActualEndDateKey] [int] NOT NULL,
	[ScheduledDurationDays] [int] NULL,
	[ActualDurationDays] [int] NULL,
	[ActualResourceHrs] [decimal](19, 4) NULL,
	[PlannedCost] [decimal](19, 4) NULL,
	[ActualCost] [decimal](19, 4) NULL,
	[IsLastOperation] [bit] NULL,
	[DQReasonCode] [nvarchar](200) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[DQRuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Fact_WorkOrderOperation] PRIMARY KEY CLUSTERED 
(
	[WorkOrderOperationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dw].[Ref_ProductPriceHistory](
	[ProductKey] [int] NOT NULL,
	[PriceType] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[StartDate] [date] NOT NULL,
	[EndDate] [date] NULL,
	[Amount] [decimal](19, 4) NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[LoadedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_dw_Ref_ProductPriceHistory] PRIMARY KEY CLUSTERED 
(
	[ProductKey] ASC,
	[PriceType] ASC,
	[StartDate] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [etl].[Audit_DataCorrection](
	[CorrectionID] [bigint] IDENTITY(1,1) NOT NULL,
	[SourceSystem] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SourceTable] [nvarchar](128) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SourceRecordKey] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ColumnName] [nvarchar](128) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OriginalValue] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CorrectedValue] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SourceDataType] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RuleID] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RuleVersion] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[EvidenceTable] [nvarchar](128) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[EvidenceRecordKey] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[LoadBatchID] [bigint] NOT NULL,
	[CorrectedAt] [datetime2](7) NULL,
 CONSTRAINT [PK_etl_Audit_DataCorrection] PRIMARY KEY CLUSTERED 
(
	[CorrectionID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [etl].[ETL_LoadBatch](
	[LoadBatchID] [bigint] IDENTITY(1,1) NOT NULL,
	[SourceSystem] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PipelineName] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ExtractionMode] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LoadMode] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ExtractStartedAt] [datetime2](7) NULL,
	[ExtractCompletedAt] [datetime2](7) NULL,
	[LoadStartedAt] [datetime2](7) NULL,
	[LoadCompletedAt] [datetime2](7) NULL,
	[RuleSetVersion] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Status] [nvarchar](20) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ValidationStatus] [nvarchar](30) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[SourceSnapshotReference] [nvarchar](2000) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ValidationSummary] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ErrorMessage] [nvarchar](max) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[RetryOfLoadBatchID] [bigint] NULL,
 CONSTRAINT [PK_etl_ETL_LoadBatch] PRIMARY KEY CLUSTERED 
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [etl].[SchemaMigrationHistory](
	[MigrationCode] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PriorSchema] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[LegacyMetadataReference] [nvarchar](100) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[BackupNote] [nvarchar](1000) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[AppliedAt] [datetime2](0) NOT NULL,
 CONSTRAINT [PK_SchemaMigrationHistory] PRIMARY KEY CLUSTERED 
(
	[MigrationCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, IGNORE_DUP_KEY = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[BillOfMaterials](
	[BillOfMaterialsID] [int] NOT NULL,
	[ProductAssemblyID] [int] NULL,
	[ComponentID] [int] NOT NULL,
	[StartDate] [datetime] NOT NULL,
	[EndDate] [datetime] NULL,
	[UnitMeasureCode] [nchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[BOMLevel] [smallint] NOT NULL,
	[PerAssemblyQty] [decimal](8, 2) NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[Customer](
	[CustomerID] [int] NOT NULL,
	[PersonID] [int] NULL,
	[StoreID] [int] NULL,
	[TerritoryID] [int] NULL,
	[AccountNumber] [varchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[Location](
	[LocationID] [smallint] NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CostRate] [smallmoney] NOT NULL,
	[Availability] [decimal](8, 2) NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[Product](
	[ProductID] [int] NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ProductNumber] [nvarchar](25) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[MakeFlag] [bit] NOT NULL,
	[FinishedGoodsFlag] [bit] NOT NULL,
	[Color] [nvarchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SafetyStockLevel] [smallint] NOT NULL,
	[ReorderPoint] [smallint] NOT NULL,
	[StandardCost] [money] NOT NULL,
	[ListPrice] [money] NOT NULL,
	[Size] [nvarchar](5) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[SizeUnitMeasureCode] [nchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[WeightUnitMeasureCode] [nchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Weight] [decimal](8, 2) NULL,
	[DaysToManufacture] [int] NOT NULL,
	[ProductLine] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Class] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[Style] [nchar](2) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ProductSubcategoryID] [int] NULL,
	[ProductModelID] [int] NULL,
	[SellStartDate] [datetime] NOT NULL,
	[SellEndDate] [datetime] NULL,
	[DiscontinuedDate] [datetime] NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductCategory](
	[ProductCategoryID] [int] NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductCostHistory](
	[ProductID] [int] NOT NULL,
	[StartDate] [datetime] NOT NULL,
	[EndDate] [datetime] NULL,
	[StandardCost] [money] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductInventory](
	[ProductID] [int] NOT NULL,
	[LocationID] [smallint] NOT NULL,
	[Shelf] [nvarchar](10) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Bin] [tinyint] NOT NULL,
	[Quantity] [smallint] NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductListPriceHistory](
	[ProductID] [int] NOT NULL,
	[StartDate] [datetime] NOT NULL,
	[EndDate] [datetime] NULL,
	[ListPrice] [money] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductSubcategory](
	[ProductSubcategoryID] [int] NOT NULL,
	[ProductCategoryID] [int] NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ProductVendor](
	[ProductID] [int] NOT NULL,
	[BusinessEntityID] [int] NOT NULL,
	[AverageLeadTime] [int] NOT NULL,
	[StandardPrice] [money] NOT NULL,
	[LastReceiptCost] [money] NULL,
	[LastReceiptDate] [datetime] NULL,
	[MinOrderQty] [int] NOT NULL,
	[MaxOrderQty] [int] NOT NULL,
	[OnOrderQty] [int] NULL,
	[UnitMeasureCode] [nchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[PurchaseOrderDetail](
	[PurchaseOrderID] [int] NOT NULL,
	[PurchaseOrderDetailID] [int] NOT NULL,
	[DueDate] [datetime] NOT NULL,
	[OrderQty] [smallint] NOT NULL,
	[ProductID] [int] NOT NULL,
	[UnitPrice] [money] NOT NULL,
	[LineTotal] [money] NOT NULL,
	[ReceivedQty] [decimal](8, 2) NOT NULL,
	[RejectedQty] [decimal](8, 2) NOT NULL,
	[StockedQty] [decimal](9, 2) NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[PurchaseOrderHeader](
	[PurchaseOrderID] [int] NOT NULL,
	[RevisionNumber] [tinyint] NOT NULL,
	[Status] [tinyint] NOT NULL,
	[EmployeeID] [int] NOT NULL,
	[VendorID] [int] NOT NULL,
	[ShipMethodID] [int] NOT NULL,
	[OrderDate] [datetime] NOT NULL,
	[ShipDate] [datetime] NULL,
	[SubTotal] [money] NOT NULL,
	[TaxAmt] [money] NOT NULL,
	[Freight] [money] NOT NULL,
	[TotalDue] [money] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[SalesOrderDetail](
	[SalesOrderID] [int] NOT NULL,
	[SalesOrderDetailID] [int] NOT NULL,
	[CarrierTrackingNumber] [nvarchar](25) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[OrderQty] [smallint] NULL,
	[ProductID] [int] NOT NULL,
	[SpecialOfferID] [int] NOT NULL,
	[UnitPrice] [money] NULL,
	[UnitPriceDiscount] [money] NOT NULL,
	[LineTotal] [numeric](38, 6) NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[SalesOrderHeader](
	[SalesOrderID] [int] NOT NULL,
	[RevisionNumber] [tinyint] NOT NULL,
	[OrderDate] [datetime] NOT NULL,
	[DueDate] [datetime] NOT NULL,
	[ShipDate] [datetime] NULL,
	[Status] [tinyint] NOT NULL,
	[OnlineOrderFlag] [bit] NOT NULL,
	[SalesOrderNumber] [nvarchar](25) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[PurchaseOrderNumber] [nvarchar](25) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[AccountNumber] [nvarchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CustomerID] [int] NOT NULL,
	[SalesPersonID] [int] NULL,
	[TerritoryID] [int] NULL,
	[BillToAddressID] [int] NOT NULL,
	[ShipToAddressID] [int] NOT NULL,
	[ShipMethodID] [int] NOT NULL,
	[CreditCardID] [int] NULL,
	[CreditCardApprovalCode] [varchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[CurrencyRateID] [int] NULL,
	[SubTotal] [money] NOT NULL,
	[TaxAmt] [money] NOT NULL,
	[Freight] [money] NOT NULL,
	[TotalDue] [money] NOT NULL,
	[Comment] [nvarchar](128) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[ScrapReason](
	[ScrapReasonID] [smallint] NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[SpecialOffer](
	[SpecialOfferID] [int] NOT NULL,
	[Description] [nvarchar](255) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[DiscountPct] [smallmoney] NOT NULL,
	[Type] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Category] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[StartDate] [datetime] NOT NULL,
	[EndDate] [datetime] NOT NULL,
	[MinQty] [int] NOT NULL,
	[MaxQty] [int] NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[SpecialOfferProduct](
	[SpecialOfferID] [int] NOT NULL,
	[ProductID] [int] NOT NULL,
	[rowguid] [uniqueidentifier] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[TransactionHistory](
	[TransactionID] [int] NOT NULL,
	[ProductID] [int] NOT NULL,
	[ReferenceOrderID] [int] NOT NULL,
	[ReferenceOrderLineID] [int] NOT NULL,
	[TransactionDate] [datetime] NOT NULL,
	[TransactionType] [nchar](1) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Quantity] [int] NULL,
	[ActualCost] [money] NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[TransactionHistoryArchive](
	[TransactionID] [int] NOT NULL,
	[ProductID] [int] NOT NULL,
	[ReferenceOrderID] [int] NOT NULL,
	[ReferenceOrderLineID] [int] NOT NULL,
	[TransactionDate] [datetime] NOT NULL,
	[TransactionType] [nchar](1) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Quantity] [int] NOT NULL,
	[ActualCost] [money] NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[UnitMeasure](
	[UnitMeasureCode] [nchar](3) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[Vendor](
	[BusinessEntityID] [int] NOT NULL,
	[AccountNumber] [nvarchar](15) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[Name] [nvarchar](50) COLLATE SQL_Latin1_General_CP1_CI_AS NOT NULL,
	[CreditRating] [tinyint] NOT NULL,
	[PreferredVendorStatus] [bit] NOT NULL,
	[ActiveFlag] [bit] NOT NULL,
	[PurchasingWebServiceURL] [nvarchar](1024) COLLATE SQL_Latin1_General_CP1_CI_AS NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[WorkOrder](
	[WorkOrderID] [int] NOT NULL,
	[ProductID] [int] NOT NULL,
	[OrderQty] [int] NOT NULL,
	[StockedQty] [int] NOT NULL,
	[ScrappedQty] [smallint] NOT NULL,
	[StartDate] [datetime] NOT NULL,
	[EndDate] [datetime] NULL,
	[DueDate] [datetime] NOT NULL,
	[ScrapReasonID] [smallint] NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [stg].[WorkOrderRouting](
	[WorkOrderID] [int] NOT NULL,
	[ProductID] [int] NOT NULL,
	[OperationSequence] [smallint] NOT NULL,
	[LocationID] [smallint] NOT NULL,
	[ScheduledStartDate] [datetime] NOT NULL,
	[ScheduledEndDate] [datetime] NOT NULL,
	[ActualStartDate] [datetime] NULL,
	[ActualEndDate] [datetime] NULL,
	[ActualResourceHrs] [decimal](9, 4) NULL,
	[PlannedCost] [money] NOT NULL,
	[ActualCost] [money] NULL,
	[ModifiedDate] [datetime] NOT NULL,
	[LoadBatchID] [bigint] NOT NULL
) ON [PRIMARY]

GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_ExperimentVersion_0] ON [dss].[Dim_ExperimentVersion]
(
	[ExperimentCode] ASC,
	[VersionNo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_InputSnapshot_0] ON [dss].[Dim_InputSnapshot]
(
	[SnapshotCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE NONCLUSTERED INDEX [IX_V6_Run_ExecutionSpecHash] ON [dss].[Dim_PlanningRun]
(
	[ExecutionSpecHash] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_PlanningRun_0] ON [dss].[Dim_PlanningRun]
(
	[RunCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_PlanningRun_1] ON [dss].[Dim_PlanningRun]
(
	[RunRequestId] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_Run_CaseReplicationAttempt] ON [dss].[Dim_PlanningRun]
(
	[ExperimentCaseKey] ASC,
	[ExperimentReplicationKey] ASC,
	[AttemptNo] ASC
)
WHERE ([RunPurpose]=N'SIMULATION')
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_PolicyConfigVersion_0] ON [dss].[Dim_PolicyConfigVersion]
(
	[PolicyConfigCode] ASC,
	[VersionNo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_PolicyType_0] ON [dss].[Dim_PolicyType]
(
	[PolicyCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Dim_ScenarioVersion_0] ON [dss].[Dim_ScenarioVersion]
(
	[ScenarioCode] ASC,
	[VersionNo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_ExperimentCase_0] ON [dss].[ExperimentCase]
(
	[ExperimentVersionKey] ASC,
	[CaseCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_ExperimentCase_1] ON [dss].[ExperimentCase]
(
	[ExperimentVersionKey] ASC,
	[ExperimentCaseKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_ExperimentReplication_0] ON [dss].[ExperimentReplication]
(
	[ExperimentVersionKey] ASC,
	[ReplicationNo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_ExperimentReplication_1] ON [dss].[ExperimentReplication]
(
	[ExperimentVersionKey] ASC,
	[ExperimentReplicationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Fact_OptimizationSolve_0] ON [dss].[Fact_OptimizationSolve]
(
	[PlanningRunKey] ASC,
	[DecisionAt] ASC,
	[AttemptNo] ASC,
	[ObjectiveStage] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Fact_StochasticDraw_0] ON [dss].[Fact_StochasticDraw]
(
	[PlanningRunKey] ASC,
	[StreamCode] ASC,
	[EventIdentity] ASC,
	[DrawIndex] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Scenario_Distribution_0] ON [dss].[Scenario_Distribution]
(
	[ScenarioVersionKey] ASC,
	[DistributionCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Scenario_Route_0] ON [dss].[Scenario_Route]
(
	[ScenarioVersionKey] ASC,
	[RouteCode] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Scenario_RouteStep_0] ON [dss].[Scenario_RouteStep]
(
	[RouteKey] ASC,
	[StepNo] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_V6_dss_Scenario_Supply_0] ON [dss].[Scenario_Supply]
(
	[ScenarioVersionKey] ASC,
	[ProductKey] ASC,
	[VendorKey] ASC,
	[ReceiptLocationKey] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Bridge_BillOfMaterials_Source] ON [dw].[Bridge_BillOfMaterials]
(
	[BillOfMaterialsID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Channel_OnlineOrderFlag] ON [dw].[Dim_Channel]
(
	[OnlineOrderFlag] ASC
)
WHERE ([OnlineOrderFlag] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Customer_CustomerID] ON [dw].[Dim_Customer]
(
	[CustomerID] ASC
)
WHERE ([CustomerID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Location_LocationID] ON [dw].[Dim_Location]
(
	[LocationID] ASC
)
WHERE ([LocationID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Product_ProductID] ON [dw].[Dim_Product]
(
	[ProductID] ASC
)
WHERE ([ProductID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Promotion_SpecialOfferID] ON [dw].[Dim_Promotion]
(
	[SpecialOfferID] ASC
)
WHERE ([SpecialOfferID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_PurchaseStatus_StatusCode] ON [dw].[Dim_PurchaseStatus]
(
	[StatusCode] ASC
)
WHERE ([StatusCode] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_SalesStatus_StatusCode] ON [dw].[Dim_SalesStatus]
(
	[StatusCode] ASC
)
WHERE ([StatusCode] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_ScrapReason_ScrapReasonID] ON [dw].[Dim_ScrapReason]
(
	[ScrapReasonID] ASC
)
WHERE ([ScrapReasonID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_UnitMeasure_UnitMeasureCode] ON [dw].[Dim_UnitMeasure]
(
	[UnitMeasureCode] ASC
)
WHERE ([UnitMeasureCode] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Dim_Vendor_VendorID] ON [dw].[Dim_Vendor]
(
	[VendorID] ASC
)
WHERE ([VendorID] IS NOT NULL)
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Fact_PurchaseOrderLine_Source] ON [dw].[Fact_PurchaseOrderLine]
(
	[PurchaseOrderID] ASC,
	[PurchaseOrderDetailID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Fact_SalesOrderLine_Source] ON [dw].[Fact_SalesOrderLine]
(
	[SalesOrderID] ASC,
	[SalesOrderDetailID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Fact_WorkOrder_Source] ON [dw].[Fact_WorkOrder]
(
	[WorkOrderID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_dw_Fact_WorkOrderOperation_Source] ON [dw].[Fact_WorkOrderOperation]
(
	[WorkOrderID] ASC,
	[ProductKey] ASC,
	[OperationSequence] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
SET ANSI_PADDING ON

GO
CREATE UNIQUE NONCLUSTERED INDEX [UX_ETL_LoadBatch_OneRunningPipeline] ON [etl].[ETL_LoadBatch]
(
	[PipelineName] ASC
)
WHERE ([Status]='RUNNING')
WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_BillOfMaterials_Batch] ON [stg].[BillOfMaterials]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_Customer_Batch] ON [stg].[Customer]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_Location_Batch] ON [stg].[Location]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_Product_Batch] ON [stg].[Product]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductCategory_Batch] ON [stg].[ProductCategory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductCostHistory_Batch] ON [stg].[ProductCostHistory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductInventory_Batch] ON [stg].[ProductInventory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductListPriceHistory_Batch] ON [stg].[ProductListPriceHistory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductSubcategory_Batch] ON [stg].[ProductSubcategory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ProductVendor_Batch] ON [stg].[ProductVendor]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_PurchaseOrderDetail_Batch] ON [stg].[PurchaseOrderDetail]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_PurchaseOrderHeader_Batch] ON [stg].[PurchaseOrderHeader]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_SalesOrderDetail_Batch] ON [stg].[SalesOrderDetail]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_SalesOrderHeader_Batch] ON [stg].[SalesOrderHeader]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_ScrapReason_Batch] ON [stg].[ScrapReason]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_SpecialOffer_Batch] ON [stg].[SpecialOffer]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_SpecialOfferProduct_Batch] ON [stg].[SpecialOfferProduct]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_TransactionHistory_Batch] ON [stg].[TransactionHistory]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_TransactionHistoryArchive_Batch] ON [stg].[TransactionHistoryArchive]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_UnitMeasure_Batch] ON [stg].[UnitMeasure]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_Vendor_Batch] ON [stg].[Vendor]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_WorkOrder_Batch] ON [stg].[WorkOrder]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
CREATE NONCLUSTERED INDEX [IX_WorkOrderRouting_Batch] ON [stg].[WorkOrderRouting]
(
	[LoadBatchID] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON, OPTIMIZE_FOR_SEQUENTIAL_KEY = OFF) ON [PRIMARY]
GO
ALTER TABLE [dss].[ArtifactObject] ADD  CONSTRAINT [DF_ArtifactCreated]  DEFAULT (sysutcdatetime()) FOR [CreatedAt]
GO
ALTER TABLE [etl].[SchemaMigrationHistory] ADD  CONSTRAINT [DF_SchemaMigrationApplied]  DEFAULT (sysutcdatetime()) FOR [AppliedAt]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [FK_V6_132] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [FK_V6_132]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [FK_V6_133] FOREIGN KEY([AllocatedProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [FK_V6_133]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [FK_V6_134] FOREIGN KEY([PlanningRunKey], [ParentEntityCode])
REFERENCES [dss].[RunEntity] ([PlanningRunKey], [EntityCode])
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [FK_V6_134]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [FK_V6_135] FOREIGN KEY([PlanningRunKey], [ChildEntityCode])
REFERENCES [dss].[RunEntity] ([PlanningRunKey], [EntityCode])
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [FK_V6_135]
GO
ALTER TABLE [dss].[Dim_InputSnapshot]  WITH CHECK ADD  CONSTRAINT [FK_V6_118] FOREIGN KEY([SourceLoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Dim_InputSnapshot] CHECK CONSTRAINT [FK_V6_118]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_045] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_045]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_046] FOREIGN KEY([DataCutoffDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_046]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_047] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_047]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_144] FOREIGN KEY([InputSnapshotKey])
REFERENCES [dss].[Dim_InputSnapshot] ([InputSnapshotKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_144]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_145] FOREIGN KEY([SourceForecastRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_145]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_153] FOREIGN KEY([ExperimentVersionKey])
REFERENCES [dss].[Dim_ExperimentVersion] ([ExperimentVersionKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_153]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_154] FOREIGN KEY([ExperimentVersionKey], [ExperimentCaseKey])
REFERENCES [dss].[ExperimentCase] ([ExperimentVersionKey], [ExperimentCaseKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_154]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_V6_155] FOREIGN KEY([ExperimentVersionKey], [ExperimentReplicationKey])
REFERENCES [dss].[ExperimentReplication] ([ExperimentVersionKey], [ExperimentReplicationKey])
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [FK_V6_155]
GO
ALTER TABLE [dss].[Dim_PolicyConfigVersion]  WITH CHECK ADD  CONSTRAINT [FK_V6_063] FOREIGN KEY([PolicyTypeKey])
REFERENCES [dss].[Dim_PolicyType] ([PolicyTypeKey])
GO
ALTER TABLE [dss].[Dim_PolicyConfigVersion] CHECK CONSTRAINT [FK_V6_063]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [FK_V6_149] FOREIGN KEY([ResolvedInputSnapshotKey])
REFERENCES [dss].[Dim_InputSnapshot] ([InputSnapshotKey])
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [FK_V6_149]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [FK_V6_150] FOREIGN KEY([InitialStateAsOfDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [FK_V6_150]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [FK_V6_151] FOREIGN KEY([InitialStateDataCutoffDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [FK_V6_151]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_119] FOREIGN KEY([ExperimentVersionKey])
REFERENCES [dss].[Dim_ExperimentVersion] ([ExperimentVersionKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_119]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_120] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_120]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_121] FOREIGN KEY([PolicyConfigVersionKey])
REFERENCES [dss].[Dim_PolicyConfigVersion] ([PolicyConfigVersionKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_121]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_122] FOREIGN KEY([InputSnapshotKey])
REFERENCES [dss].[Dim_InputSnapshot] ([InputSnapshotKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_122]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_123] FOREIGN KEY([DataCutoffDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_123]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_124] FOREIGN KEY([SimulationStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_124]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_125] FOREIGN KEY([SimulationEndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_125]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [FK_V6_152] FOREIGN KEY([SourceForecastRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [FK_V6_152]
GO
ALTER TABLE [dss].[ExperimentReplication]  WITH CHECK ADD  CONSTRAINT [FK_V6_126] FOREIGN KEY([ExperimentVersionKey])
REFERENCES [dss].[Dim_ExperimentVersion] ([ExperimentVersionKey])
GO
ALTER TABLE [dss].[ExperimentReplication] CHECK CONSTRAINT [FK_V6_126]
GO
ALTER TABLE [dss].[Fact_DemandDaily]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_DemandDaily_DateKey] FOREIGN KEY([DateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Fact_DemandDaily] CHECK CONSTRAINT [FK_dss_Fact_DemandDaily_DateKey]
GO
ALTER TABLE [dss].[Fact_DemandDaily]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_DemandDaily_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_DemandDaily] CHECK CONSTRAINT [FK_dss_Fact_DemandDaily_ProductKey]
GO
ALTER TABLE [dss].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_V6_048] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_DemandForecast] CHECK CONSTRAINT [FK_V6_048]
GO
ALTER TABLE [dss].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_V6_049] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_DemandForecast] CHECK CONSTRAINT [FK_V6_049]
GO
ALTER TABLE [dss].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_V6_050] FOREIGN KEY([TargetPeriodStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Fact_DemandForecast] CHECK CONSTRAINT [FK_V6_050]
GO
ALTER TABLE [dss].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_V6_051] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_DemandForecast] CHECK CONSTRAINT [FK_V6_051]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [FK_V6_158] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [FK_V6_158]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [FK_V6_162] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [FK_V6_162]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [FK_V6_164] FOREIGN KEY([PlanningForecastRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [FK_V6_164]
GO
ALTER TABLE [dss].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_V6_058] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_V6_058]
GO
ALTER TABLE [dss].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_V6_059] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_V6_059]
GO
ALTER TABLE [dss].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_V6_060] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_V6_060]
GO
ALTER TABLE [dss].[Fact_RunSummary]  WITH CHECK ADD  CONSTRAINT [FK_V6_116] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_RunSummary] CHECK CONSTRAINT [FK_V6_116]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_052] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_052]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_053] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_053]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_054] FOREIGN KEY([ServiceLevelKey])
REFERENCES [dss].[Dim_ServiceLevel] ([ServiceLevelKey])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_054]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_055] FOREIGN KEY([VendorKey])
REFERENCES [dw].[Dim_Vendor] ([VendorKey])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_055]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_056] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_056]
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_V6_057] FOREIGN KEY([SupplyOptionKey])
REFERENCES [dss].[Scenario_Supply] ([SupplyOptionKey])
GO
ALTER TABLE [dss].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_V6_057]
GO
ALTER TABLE [dss].[Fact_SimulationDaily]  WITH CHECK ADD  CONSTRAINT [FK_V6_101] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_SimulationDaily] CHECK CONSTRAINT [FK_V6_101]
GO
ALTER TABLE [dss].[Fact_SimulationDaily]  WITH CHECK ADD  CONSTRAINT [FK_V6_102] FOREIGN KEY([DateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Fact_SimulationDaily] CHECK CONSTRAINT [FK_V6_102]
GO
ALTER TABLE [dss].[Fact_SimulationDaily]  WITH CHECK ADD  CONSTRAINT [FK_V6_103] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_SimulationDaily] CHECK CONSTRAINT [FK_V6_103]
GO
ALTER TABLE [dss].[Fact_SimulationDaily]  WITH CHECK ADD  CONSTRAINT [FK_V6_104] FOREIGN KEY([LocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Fact_SimulationDaily] CHECK CONSTRAINT [FK_V6_104]
GO
ALTER TABLE [dss].[Fact_SimulationDaily]  WITH CHECK ADD  CONSTRAINT [FK_V6_105] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_SimulationDaily] CHECK CONSTRAINT [FK_V6_105]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_106] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_106]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_107] FOREIGN KEY([DateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_107]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_108] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_108]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_109] FOREIGN KEY([FromLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_109]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_110] FOREIGN KEY([ToLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_110]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_111] FOREIGN KEY([SupplyOptionKey])
REFERENCES [dss].[Scenario_Supply] ([SupplyOptionKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_111]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_112] FOREIGN KEY([RouteStepKey])
REFERENCES [dss].[Scenario_RouteStep] ([RouteStepKey])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_112]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_113] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_113]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_146] FOREIGN KEY([EventCode])
REFERENCES [dss].[Dim_EventType] ([EventCode])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_146]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_147] FOREIGN KEY([PlanningRunKey], [EntityCode])
REFERENCES [dss].[RunEntity] ([PlanningRunKey], [EntityCode])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_147]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_148] FOREIGN KEY([PlanningRunKey], [RelatedEntityCode])
REFERENCES [dss].[RunEntity] ([PlanningRunKey], [EntityCode])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_148]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [FK_V6_165] FOREIGN KEY([PlanningRunKey], [DecisionSolveSequence])
REFERENCES [dss].[Fact_OptimizationSolve] ([PlanningRunKey], [SolveSequence])
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [FK_V6_165]
GO
ALTER TABLE [dss].[Fact_SimulationOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_157] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[Fact_SimulationOrder] CHECK CONSTRAINT [FK_V6_157]
GO
ALTER TABLE [dss].[Fact_SimulationOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_161] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_SimulationOrder] CHECK CONSTRAINT [FK_V6_161]
GO
ALTER TABLE [dss].[Fact_StochasticDraw]  WITH CHECK ADD  CONSTRAINT [FK_V6_114] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[Fact_StochasticDraw] CHECK CONSTRAINT [FK_V6_114]
GO
ALTER TABLE [dss].[Fact_StochasticDraw]  WITH CHECK ADD  CONSTRAINT [FK_V6_115] FOREIGN KEY([DistributionKey])
REFERENCES [dss].[Scenario_Distribution] ([DistributionKey])
GO
ALTER TABLE [dss].[Fact_StochasticDraw] CHECK CONSTRAINT [FK_V6_115]
GO
ALTER TABLE [dss].[PolicyParameterDefinition]  WITH CHECK ADD  CONSTRAINT [FK_V6_062] FOREIGN KEY([PolicyTypeKey])
REFERENCES [dss].[Dim_PolicyType] ([PolicyTypeKey])
GO
ALTER TABLE [dss].[PolicyParameterDefinition] CHECK CONSTRAINT [FK_V6_062]
GO
ALTER TABLE [dss].[PolicyParameterValue]  WITH CHECK ADD  CONSTRAINT [FK_V6_064] FOREIGN KEY([PolicyConfigVersionKey])
REFERENCES [dss].[Dim_PolicyConfigVersion] ([PolicyConfigVersionKey])
GO
ALTER TABLE [dss].[PolicyParameterValue] CHECK CONSTRAINT [FK_V6_064]
GO
ALTER TABLE [dss].[PolicyParameterValue]  WITH CHECK ADD  CONSTRAINT [FK_V6_117] FOREIGN KEY([PolicyTypeKey], [ParameterCode])
REFERENCES [dss].[PolicyParameterDefinition] ([PolicyTypeKey], [ParameterCode])
GO
ALTER TABLE [dss].[PolicyParameterValue] CHECK CONSTRAINT [FK_V6_117]
GO
ALTER TABLE [dss].[PolicyProductConfig]  WITH CHECK ADD  CONSTRAINT [FK_V6_156] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [dss].[PolicyProductConfig] CHECK CONSTRAINT [FK_V6_156]
GO
ALTER TABLE [dss].[PolicyProductConfig]  WITH CHECK ADD  CONSTRAINT [FK_V6_159] FOREIGN KEY([PolicyConfigVersionKey])
REFERENCES [dss].[Dim_PolicyConfigVersion] ([PolicyConfigVersionKey])
GO
ALTER TABLE [dss].[PolicyProductConfig] CHECK CONSTRAINT [FK_V6_159]
GO
ALTER TABLE [dss].[PolicyProductConfig]  WITH CHECK ADD  CONSTRAINT [FK_V6_160] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[PolicyProductConfig] CHECK CONSTRAINT [FK_V6_160]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_130] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_130]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_131] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_131]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_141] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_141]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_142] FOREIGN KEY([ScenarioVersionKey], [InitialEntityCode])
REFERENCES [dss].[Scenario_InitialEntity] ([ScenarioVersionKey], [InitialEntityCode])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_142]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_143] FOREIGN KEY([ScenarioVersionKey], [InitialDemandLineCode])
REFERENCES [dss].[Scenario_InitialCustomerOrder] ([ScenarioVersionKey], [DemandLineCode])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_143]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_163] FOREIGN KEY([PlanningRunKey], [CustomerOrderCode])
REFERENCES [dss].[Fact_SimulationOrder] ([PlanningRunKey], [CustomerOrderCode])
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [FK_V6_163]
GO
ALTER TABLE [dss].[Scenario_CustomerOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_094] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_CustomerOrder] CHECK CONSTRAINT [FK_V6_094]
GO
ALTER TABLE [dss].[Scenario_CustomerOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_095] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_CustomerOrder] CHECK CONSTRAINT [FK_V6_095]
GO
ALTER TABLE [dss].[Scenario_Distribution]  WITH CHECK ADD  CONSTRAINT [FK_V6_065] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_Distribution] CHECK CONSTRAINT [FK_V6_065]
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_127] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder] CHECK CONSTRAINT [FK_V6_127]
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_128] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder] CHECK CONSTRAINT [FK_V6_128]
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder]  WITH CHECK ADD  CONSTRAINT [FK_V6_129] FOREIGN KEY([DemandLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder] CHECK CONSTRAINT [FK_V6_129]
GO
ALTER TABLE [dss].[Scenario_InitialEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_137] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_InitialEntity] CHECK CONSTRAINT [FK_V6_137]
GO
ALTER TABLE [dss].[Scenario_InitialEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_138] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_InitialEntity] CHECK CONSTRAINT [FK_V6_138]
GO
ALTER TABLE [dss].[Scenario_InitialEntity]  WITH CHECK ADD  CONSTRAINT [FK_V6_139] FOREIGN KEY([ScenarioVersionKey], [ParentInitialEntityCode])
REFERENCES [dss].[Scenario_InitialEntity] ([ScenarioVersionKey], [InitialEntityCode])
GO
ALTER TABLE [dss].[Scenario_InitialEntity] CHECK CONSTRAINT [FK_V6_139]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_096] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_096]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_097] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_097]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_098] FOREIGN KEY([FromLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_098]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_099] FOREIGN KEY([ToLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_099]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_100] FOREIGN KEY([RouteStepKey])
REFERENCES [dss].[Scenario_RouteStep] ([RouteStepKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_100]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_136] FOREIGN KEY([SupplyOptionKey])
REFERENCES [dss].[Scenario_Supply] ([SupplyOptionKey])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_136]
GO
ALTER TABLE [dss].[Scenario_InitialPosition]  WITH CHECK ADD  CONSTRAINT [FK_V6_140] FOREIGN KEY([ScenarioVersionKey], [InitialEntityCode])
REFERENCES [dss].[Scenario_InitialEntity] ([ScenarioVersionKey], [InitialEntityCode])
GO
ALTER TABLE [dss].[Scenario_InitialPosition] CHECK CONSTRAINT [FK_V6_140]
GO
ALTER TABLE [dss].[Scenario_Product]  WITH CHECK ADD  CONSTRAINT [FK_V6_066] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_Product] CHECK CONSTRAINT [FK_V6_066]
GO
ALTER TABLE [dss].[Scenario_Product]  WITH CHECK ADD  CONSTRAINT [FK_V6_067] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_Product] CHECK CONSTRAINT [FK_V6_067]
GO
ALTER TABLE [dss].[Scenario_Product]  WITH CHECK ADD  CONSTRAINT [FK_V6_068] FOREIGN KEY([StockUnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dss].[Scenario_Product] CHECK CONSTRAINT [FK_V6_068]
GO
ALTER TABLE [dss].[Scenario_Product]  WITH CHECK ADD  CONSTRAINT [FK_V6_069] FOREIGN KEY([DemandLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_Product] CHECK CONSTRAINT [FK_V6_069]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_088] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_088]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_089] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_089]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_090] FOREIGN KEY([LeadTimeDistributionKey])
REFERENCES [dss].[Scenario_Distribution] ([DistributionKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_090]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_091] FOREIGN KEY([RouteKey])
REFERENCES [dss].[Scenario_Route] ([RouteKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_091]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_092] FOREIGN KEY([MaterialIssueLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_092]
GO
ALTER TABLE [dss].[Scenario_Production]  WITH CHECK ADD  CONSTRAINT [FK_V6_093] FOREIGN KEY([FinishedReceiptLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_Production] CHECK CONSTRAINT [FK_V6_093]
GO
ALTER TABLE [dss].[Scenario_Route]  WITH CHECK ADD  CONSTRAINT [FK_V6_083] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_Route] CHECK CONSTRAINT [FK_V6_083]
GO
ALTER TABLE [dss].[Scenario_RouteStep]  WITH CHECK ADD  CONSTRAINT [FK_V6_084] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_RouteStep] CHECK CONSTRAINT [FK_V6_084]
GO
ALTER TABLE [dss].[Scenario_RouteStep]  WITH CHECK ADD  CONSTRAINT [FK_V6_085] FOREIGN KEY([RouteKey])
REFERENCES [dss].[Scenario_Route] ([RouteKey])
GO
ALTER TABLE [dss].[Scenario_RouteStep] CHECK CONSTRAINT [FK_V6_085]
GO
ALTER TABLE [dss].[Scenario_RouteStep]  WITH CHECK ADD  CONSTRAINT [FK_V6_086] FOREIGN KEY([LocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_RouteStep] CHECK CONSTRAINT [FK_V6_086]
GO
ALTER TABLE [dss].[Scenario_RouteStep]  WITH CHECK ADD  CONSTRAINT [FK_V6_087] FOREIGN KEY([ProcessTimeFactorDistributionKey])
REFERENCES [dss].[Scenario_Distribution] ([DistributionKey])
GO
ALTER TABLE [dss].[Scenario_RouteStep] CHECK CONSTRAINT [FK_V6_087]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_074] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_074]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_075] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_075]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_076] FOREIGN KEY([VendorKey])
REFERENCES [dw].[Dim_Vendor] ([VendorKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_076]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_077] FOREIGN KEY([ReceiptLocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_077]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_078] FOREIGN KEY([PurchaseUnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_078]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_079] FOREIGN KEY([DelayDistributionKey])
REFERENCES [dss].[Scenario_Distribution] ([DistributionKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_079]
GO
ALTER TABLE [dss].[Scenario_Supply]  WITH CHECK ADD  CONSTRAINT [FK_V6_080] FOREIGN KEY([RejectRateDistributionKey])
REFERENCES [dss].[Scenario_Distribution] ([DistributionKey])
GO
ALTER TABLE [dss].[Scenario_Supply] CHECK CONSTRAINT [FK_V6_080]
GO
ALTER TABLE [dss].[Scenario_SupplyCalendar]  WITH CHECK ADD  CONSTRAINT [FK_V6_081] FOREIGN KEY([SupplyOptionKey])
REFERENCES [dss].[Scenario_Supply] ([SupplyOptionKey])
GO
ALTER TABLE [dss].[Scenario_SupplyCalendar] CHECK CONSTRAINT [FK_V6_081]
GO
ALTER TABLE [dss].[Scenario_SupplyCalendar]  WITH CHECK ADD  CONSTRAINT [FK_V6_082] FOREIGN KEY([DateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss].[Scenario_SupplyCalendar] CHECK CONSTRAINT [FK_V6_082]
GO
ALTER TABLE [dss].[Scenario_UnitConversion]  WITH CHECK ADD  CONSTRAINT [FK_V6_070] FOREIGN KEY([ScenarioVersionKey])
REFERENCES [dss].[Dim_ScenarioVersion] ([ScenarioVersionKey])
GO
ALTER TABLE [dss].[Scenario_UnitConversion] CHECK CONSTRAINT [FK_V6_070]
GO
ALTER TABLE [dss].[Scenario_UnitConversion]  WITH CHECK ADD  CONSTRAINT [FK_V6_071] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss].[Scenario_UnitConversion] CHECK CONSTRAINT [FK_V6_071]
GO
ALTER TABLE [dss].[Scenario_UnitConversion]  WITH CHECK ADD  CONSTRAINT [FK_V6_072] FOREIGN KEY([FromUnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dss].[Scenario_UnitConversion] CHECK CONSTRAINT [FK_V6_072]
GO
ALTER TABLE [dss].[Scenario_UnitConversion]  WITH CHECK ADD  CONSTRAINT [FK_V6_073] FOREIGN KEY([ToUnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dss].[Scenario_UnitConversion] CHECK CONSTRAINT [FK_V6_073]
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_dss_Dim_PlanningRun_DataCutoffDateKey] FOREIGN KEY([DataCutoffDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun] CHECK CONSTRAINT [FK_dss_Dim_PlanningRun_DataCutoffDateKey]
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_dss_Dim_PlanningRun_SimulationEndDateKey] FOREIGN KEY([SimulationEndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun] CHECK CONSTRAINT [FK_dss_Dim_PlanningRun_SimulationEndDateKey]
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [FK_dss_Dim_PlanningRun_SimulationStartDateKey] FOREIGN KEY([SimulationStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss_legacy_20261025].[Dim_PlanningRun] CHECK CONSTRAINT [FK_dss_Dim_PlanningRun_SimulationStartDateKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_DemandForecast_PlanningRunKey] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss_legacy_20261025].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast] CHECK CONSTRAINT [FK_dss_Fact_DemandForecast_PlanningRunKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_DemandForecast_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast] CHECK CONSTRAINT [FK_dss_Fact_DemandForecast_ProductKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_DemandForecast_TargetPeriodStartDateKey] FOREIGN KEY([TargetPeriodStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_DemandForecast] CHECK CONSTRAINT [FK_dss_Fact_DemandForecast_TargetPeriodStartDateKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_PolicySimulation_PlanningRunKey] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss_legacy_20261025].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_dss_Fact_PolicySimulation_PlanningRunKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_PolicySimulation_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_dss_Fact_PolicySimulation_ProductKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_PolicySimulation_ServiceLevelKey] FOREIGN KEY([ServiceLevelKey])
REFERENCES [dss].[Dim_ServiceLevel] ([ServiceLevelKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_PolicySimulation] CHECK CONSTRAINT [FK_dss_Fact_PolicySimulation_ServiceLevelKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_PlanningRunKey] FOREIGN KEY([PlanningRunKey])
REFERENCES [dss_legacy_20261025].[Dim_PlanningRun] ([PlanningRunKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_PlanningRunKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_ProductKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_ServiceLevelKey] FOREIGN KEY([ServiceLevelKey])
REFERENCES [dss].[Dim_ServiceLevel] ([ServiceLevelKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_ServiceLevelKey]
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation]  WITH CHECK ADD  CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_VendorKey] FOREIGN KEY([VendorKey])
REFERENCES [dw].[Dim_Vendor] ([VendorKey])
GO
ALTER TABLE [dss_legacy_20261025].[Fact_SafetyStockRecommendation] CHECK CONSTRAINT [FK_dss_Fact_SafetyStockRecommendation_VendorKey]
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials]  WITH CHECK ADD  CONSTRAINT [FK_dw_Bridge_BillOfMaterials_AssemblyProductKey] FOREIGN KEY([AssemblyProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials] CHECK CONSTRAINT [FK_dw_Bridge_BillOfMaterials_AssemblyProductKey]
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials]  WITH CHECK ADD  CONSTRAINT [FK_dw_Bridge_BillOfMaterials_ComponentProductKey] FOREIGN KEY([ComponentProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials] CHECK CONSTRAINT [FK_dw_Bridge_BillOfMaterials_ComponentProductKey]
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials]  WITH CHECK ADD  CONSTRAINT [FK_dw_Bridge_BillOfMaterials_UnitMeasureKey] FOREIGN KEY([UnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dw].[Bridge_BillOfMaterials] CHECK CONSTRAINT [FK_dw_Bridge_BillOfMaterials_UnitMeasureKey]
GO
ALTER TABLE [dw].[Bridge_ProductPromotion]  WITH CHECK ADD  CONSTRAINT [FK_dw_Bridge_ProductPromotion_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Bridge_ProductPromotion] CHECK CONSTRAINT [FK_dw_Bridge_ProductPromotion_ProductKey]
GO
ALTER TABLE [dw].[Bridge_ProductPromotion]  WITH CHECK ADD  CONSTRAINT [FK_dw_Bridge_ProductPromotion_PromotionKey] FOREIGN KEY([PromotionKey])
REFERENCES [dw].[Dim_Promotion] ([PromotionKey])
GO
ALTER TABLE [dw].[Bridge_ProductPromotion] CHECK CONSTRAINT [FK_dw_Bridge_ProductPromotion_PromotionKey]
GO
ALTER TABLE [dw].[Fact_InventoryOnHand]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_InventoryOnHand_AsOfDateKey] FOREIGN KEY([AsOfDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_InventoryOnHand] CHECK CONSTRAINT [FK_dw_Fact_InventoryOnHand_AsOfDateKey]
GO
ALTER TABLE [dw].[Fact_InventoryOnHand]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_InventoryOnHand_LocationKey] FOREIGN KEY([LocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dw].[Fact_InventoryOnHand] CHECK CONSTRAINT [FK_dw_Fact_InventoryOnHand_LocationKey]
GO
ALTER TABLE [dw].[Fact_InventoryOnHand]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_InventoryOnHand_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_InventoryOnHand] CHECK CONSTRAINT [FK_dw_Fact_InventoryOnHand_ProductKey]
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_ProductVendorTerms_AsOfDateKey] FOREIGN KEY([AsOfDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms] CHECK CONSTRAINT [FK_dw_Fact_ProductVendorTerms_AsOfDateKey]
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_ProductVendorTerms_LastReceiptDateKey] FOREIGN KEY([LastReceiptDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms] CHECK CONSTRAINT [FK_dw_Fact_ProductVendorTerms_LastReceiptDateKey]
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_ProductVendorTerms_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms] CHECK CONSTRAINT [FK_dw_Fact_ProductVendorTerms_ProductKey]
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_ProductVendorTerms_UnitMeasureKey] FOREIGN KEY([UnitMeasureKey])
REFERENCES [dw].[Dim_UnitMeasure] ([UnitMeasureKey])
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms] CHECK CONSTRAINT [FK_dw_Fact_ProductVendorTerms_UnitMeasureKey]
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_ProductVendorTerms_VendorKey] FOREIGN KEY([VendorKey])
REFERENCES [dw].[Dim_Vendor] ([VendorKey])
GO
ALTER TABLE [dw].[Fact_ProductVendorTerms] CHECK CONSTRAINT [FK_dw_Fact_ProductVendorTerms_VendorKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ExpectedReceiptDateKey] FOREIGN KEY([ExpectedReceiptDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ExpectedReceiptDateKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ExpectedShipDateKey] FOREIGN KEY([ExpectedShipDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ExpectedShipDateKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_OrderDateKey] FOREIGN KEY([OrderDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_OrderDateKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_ProductKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_PurchaseStatusKey] FOREIGN KEY([PurchaseStatusKey])
REFERENCES [dw].[Dim_PurchaseStatus] ([PurchaseStatusKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_PurchaseStatusKey]
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_VendorKey] FOREIGN KEY([VendorKey])
REFERENCES [dw].[Dim_Vendor] ([VendorKey])
GO
ALTER TABLE [dw].[Fact_PurchaseOrderLine] CHECK CONSTRAINT [FK_dw_Fact_PurchaseOrderLine_VendorKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_ChannelKey] FOREIGN KEY([ChannelKey])
REFERENCES [dw].[Dim_Channel] ([ChannelKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_ChannelKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_CustomerKey] FOREIGN KEY([CustomerKey])
REFERENCES [dw].[Dim_Customer] ([CustomerKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_CustomerKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_DueDateKey] FOREIGN KEY([DueDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_DueDateKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_OrderDateKey] FOREIGN KEY([OrderDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_OrderDateKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_ProductKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_PromotionKey] FOREIGN KEY([PromotionKey])
REFERENCES [dw].[Dim_Promotion] ([PromotionKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_PromotionKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_SalesStatusKey] FOREIGN KEY([SalesStatusKey])
REFERENCES [dw].[Dim_SalesStatus] ([SalesStatusKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_SalesStatusKey]
GO
ALTER TABLE [dw].[Fact_SalesOrderLine]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_SalesOrderLine_ShipDateKey] FOREIGN KEY([ShipDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_SalesOrderLine] CHECK CONSTRAINT [FK_dw_Fact_SalesOrderLine_ShipDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_ActualEndDateKey] FOREIGN KEY([ActualEndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_ActualEndDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_ActualStartDateKey] FOREIGN KEY([ActualStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_ActualStartDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_DueDateKey] FOREIGN KEY([DueDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_DueDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_EndDateKey] FOREIGN KEY([EndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_EndDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_ProductKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_ScrapReasonKey] FOREIGN KEY([ScrapReasonKey])
REFERENCES [dw].[Dim_ScrapReason] ([ScrapReasonKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_ScrapReasonKey]
GO
ALTER TABLE [dw].[Fact_WorkOrder]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrder_StartDateKey] FOREIGN KEY([StartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrder] CHECK CONSTRAINT [FK_dw_Fact_WorkOrder_StartDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ActualEndDateKey] FOREIGN KEY([ActualEndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ActualEndDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ActualStartDateKey] FOREIGN KEY([ActualStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ActualStartDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_LocationKey] FOREIGN KEY([LocationKey])
REFERENCES [dw].[Dim_Location] ([LocationKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_LocationKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ProductKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ScheduledEndDateKey] FOREIGN KEY([ScheduledEndDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ScheduledEndDateKey]
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation]  WITH CHECK ADD  CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ScheduledStartDateKey] FOREIGN KEY([ScheduledStartDateKey])
REFERENCES [dw].[Dim_Date] ([DateKey])
GO
ALTER TABLE [dw].[Fact_WorkOrderOperation] CHECK CONSTRAINT [FK_dw_Fact_WorkOrderOperation_ScheduledStartDateKey]
GO
ALTER TABLE [dw].[Ref_ProductPriceHistory]  WITH CHECK ADD  CONSTRAINT [FK_dw_Ref_ProductPriceHistory_ProductKey] FOREIGN KEY([ProductKey])
REFERENCES [dw].[Dim_Product] ([ProductKey])
GO
ALTER TABLE [dw].[Ref_ProductPriceHistory] CHECK CONSTRAINT [FK_dw_Ref_ProductPriceHistory_ProductKey]
GO
ALTER TABLE [etl].[Audit_DataCorrection]  WITH CHECK ADD  CONSTRAINT [FK_etl_Audit_DataCorrection_LoadBatchID] FOREIGN KEY([LoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [etl].[Audit_DataCorrection] CHECK CONSTRAINT [FK_etl_Audit_DataCorrection_LoadBatchID]
GO
ALTER TABLE [etl].[ETL_LoadBatch]  WITH CHECK ADD  CONSTRAINT [FK_etl_ETL_LoadBatch_RetryOfLoadBatchID] FOREIGN KEY([RetryOfLoadBatchID])
REFERENCES [etl].[ETL_LoadBatch] ([LoadBatchID])
GO
ALTER TABLE [etl].[ETL_LoadBatch] CHECK CONSTRAINT [FK_etl_ETL_LoadBatch_RetryOfLoadBatchID]
GO
ALTER TABLE [dss].[ArtifactObject]  WITH CHECK ADD  CONSTRAINT [CK_ArtifactEncoding] CHECK  (([Encoding]='GZIP_JSON_UTF8_BASE64'))
GO
ALTER TABLE [dss].[ArtifactObject] CHECK CONSTRAINT [CK_ArtifactEncoding]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [CK_V6_Bridge_RunEntityRelation_AllocatedPair] CHECK  (([AllocatedQty] IS NULL AND [AllocatedProductKey] IS NULL OR [AllocatedQty] IS NOT NULL AND [AllocatedProductKey] IS NOT NULL AND [AllocatedQty]>=(0)))
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [CK_V6_Bridge_RunEntityRelation_AllocatedPair]
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation]  WITH CHECK ADD  CONSTRAINT [CK_V6_Bridge_RunEntityRelation_NoSelf] CHECK  (([ParentEntityCode]<>[ChildEntityCode]))
GO
ALTER TABLE [dss].[Bridge_RunEntityRelation] CHECK CONSTRAINT [CK_V6_Bridge_RunEntityRelation_NoSelf]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [CK_PlanningRun_ConfigSource_v41] CHECK  (([RunPurpose]=N'SIMULATION' AND [ExperimentVersionKey] IS NOT NULL AND [ExperimentCaseKey] IS NOT NULL AND [ExperimentReplicationKey] IS NOT NULL AND [ScenarioVersionKey] IS NULL AND [InputSnapshotKey] IS NULL AND [DataCutoffDateKey] IS NULL AND [DemandRuleVersion] IS NULL AND [RuleSetVersion] IS NULL AND [SourceForecastRunKey] IS NULL OR [RunPurpose]=N'FORECAST' AND [ExperimentVersionKey] IS NULL AND [ExperimentCaseKey] IS NULL AND [ExperimentReplicationKey] IS NULL AND [InputSnapshotKey] IS NOT NULL AND [DataCutoffDateKey] IS NOT NULL AND [DemandRuleVersion] IS NOT NULL AND [RuleSetVersion] IS NOT NULL AND [ScenarioVersionKey] IS NULL AND [SourceForecastRunKey] IS NULL OR [RunPurpose]=N'RECOMMENDATION' AND [ExperimentVersionKey] IS NULL AND [ExperimentCaseKey] IS NULL AND [ExperimentReplicationKey] IS NULL AND [InputSnapshotKey] IS NOT NULL AND [DataCutoffDateKey] IS NOT NULL AND [DemandRuleVersion] IS NOT NULL AND [RuleSetVersion] IS NOT NULL AND [ScenarioVersionKey] IS NOT NULL))
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [CK_PlanningRun_ConfigSource_v41]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_PlanningRun_Attempt] CHECK  (([AttemptNo]>=(1)))
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [CK_V6_Dim_PlanningRun_Attempt]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_PlanningRun_Manifest] CHECK  (([RunPurpose]<>'SIMULATION' OR [ExecutionSpecHash] IS NOT NULL AND [ExecutionSpecVersion] IS NOT NULL AND [ExecutionSpecReference] IS NOT NULL))
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [CK_V6_Dim_PlanningRun_Manifest]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_PlanningRun_RunPurpose] CHECK  (([RunPurpose]='RECOMMENDATION' OR [RunPurpose]='FORECAST' OR [RunPurpose]='SIMULATION'))
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [CK_V6_Dim_PlanningRun_RunPurpose]
GO
ALTER TABLE [dss].[Dim_PlanningRun]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_PlanningRun_RunStatus] CHECK  (([RunStatus]='CANCELLED' OR [RunStatus]='FAILED' OR [RunStatus]='SUCCEEDED' OR [RunStatus]='RUNNING' OR [RunStatus]='CREATED'))
GO
ALTER TABLE [dss].[Dim_PlanningRun] CHECK CONSTRAINT [CK_V6_Dim_PlanningRun_RunStatus]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_ScenarioVersion_Binding] CHECK  (([InitialStateBindingMode]='RELATIVE_TEMPLATE' AND [ResolvedInputSnapshotKey] IS NULL AND [InitialStateAsOfDateKey] IS NULL AND [InitialStateDataCutoffDateKey] IS NULL OR [InitialStateBindingMode]='SNAPSHOT_BOUND' AND [ResolvedInputSnapshotKey] IS NOT NULL AND [InitialStateAsOfDateKey] IS NOT NULL AND [InitialStateDataCutoffDateKey] IS NOT NULL AND [InitialStateDataCutoffDateKey]<=[InitialStateAsOfDateKey]))
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [CK_V6_Dim_ScenarioVersion_Binding]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_ScenarioVersion_Fulfillment] CHECK  (([ShortageHandlingMode]='BACKORDER' AND ([CustomerShipmentMode]='COMPLETE_ORDER' OR [CustomerShipmentMode]='PARTIAL_LINE') AND [LostSalesScope] IS NULL OR [ShortageHandlingMode]='LOST_SALES' AND [CustomerShipmentMode]='COMPLETE_ORDER' AND [LostSalesScope] IS NOT NULL AND [LostSalesScope]='WHOLE_SALES_ORDER'))
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [CK_V6_Dim_ScenarioVersion_Fulfillment]
GO
ALTER TABLE [dss].[Dim_ScenarioVersion]  WITH CHECK ADD  CONSTRAINT [CK_V6_Dim_ScenarioVersion_HoldingRate] CHECK  (([HoldingCostRatePerYear]>=(0)))
GO
ALTER TABLE [dss].[Dim_ScenarioVersion] CHECK CONSTRAINT [CK_V6_Dim_ScenarioVersion_HoldingRate]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [CK_V6_ExperimentCase_Dates] CHECK  (([DataCutoffDateKey]<=[SimulationStartDateKey] AND [SimulationStartDateKey]<=[SimulationEndDateKey]))
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [CK_V6_ExperimentCase_Dates]
GO
ALTER TABLE [dss].[ExperimentCase]  WITH CHECK ADD  CONSTRAINT [CK_V6_ExperimentCase_DemandSource] CHECK  (([DemandSourceKind]='HISTORICAL_REPLAY' AND [DemandInputMode]='HISTORICAL_ORDER_REPLAY' AND [SourceForecastRunKey] IS NULL OR [DemandSourceKind]='SCENARIO_ORDERS' AND [DemandInputMode]='FORECAST_SCENARIO' AND [SourceForecastRunKey] IS NULL OR [DemandSourceKind]='FORECAST_RUN' AND [DemandInputMode]='FORECAST_SCENARIO' AND [SourceForecastRunKey] IS NOT NULL))
GO
ALTER TABLE [dss].[ExperimentCase] CHECK CONSTRAINT [CK_V6_ExperimentCase_DemandSource]
GO
ALTER TABLE [dss].[ExperimentReplication]  WITH CHECK ADD  CONSTRAINT [CK_V6_ExperimentReplication_Number] CHECK  (([ReplicationNo]>=(1)))
GO
ALTER TABLE [dss].[ExperimentReplication] CHECK CONSTRAINT [CK_V6_ExperimentReplication_Number]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_OptimizationSolve_Feasible] CHECK  (([HasFeasibleSolution]=(1) AND [ObjectiveValue] IS NOT NULL OR [HasFeasibleSolution]=(0) AND [ObjectiveValue] IS NULL))
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [CK_V6_Fact_OptimizationSolve_Feasible]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_OptimizationSolve_Gap] CHECK  (([RelativeGap] IS NULL OR [RelativeGap]>=(0)))
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [CK_V6_Fact_OptimizationSolve_Gap]
GO
ALTER TABLE [dss].[Fact_OptimizationSolve]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_OptimizationSolve_Timing] CHECK  (([InformationCutoffAt]<=[DecisionAt] AND [HorizonEndAt]>=[DecisionAt] AND [SolverSeconds]>=(0) AND [AttemptNo]>=(1)))
GO
ALTER TABLE [dss].[Fact_OptimizationSolve] CHECK CONSTRAINT [CK_V6_Fact_OptimizationSolve_Timing]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationEvent_EventDate] CHECK  (([DateKey]=CONVERT([int],CONVERT([char](8),[EventAt],(112)))))
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [CK_V6_Fact_SimulationEvent_EventDate]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationEvent_OrderAction] CHECK  ((NOT ([EventCode]='LOST_SALE' OR [EventCode]='SHIP_LATE' OR [EventCode]='SHIP_ON_TIME') OR [OrderActionCode] IS NOT NULL))
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [CK_V6_Fact_SimulationEvent_OrderAction]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationEvent_ProductionExecution] CHECK  ((NOT ([EventCode]='PRODUCTION_GOOD' OR [EventCode]='BOM_ISSUE' OR [EventCode]='PRODUCTION_START') OR [ProductionExecutionCode] IS NOT NULL))
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [CK_V6_Fact_SimulationEvent_ProductionExecution]
GO
ALTER TABLE [dss].[Fact_SimulationEvent]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationEvent_Quantity] CHECK  (([Quantity]>(0)))
GO
ALTER TABLE [dss].[Fact_SimulationEvent] CHECK CONSTRAINT [CK_V6_Fact_SimulationEvent_Quantity]
GO
ALTER TABLE [dss].[Fact_SimulationOrder]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationOrder_LineCount] CHECK  (([ExpectedLineCount]>(0)))
GO
ALTER TABLE [dss].[Fact_SimulationOrder] CHECK CONSTRAINT [CK_V6_Fact_SimulationOrder_LineCount]
GO
ALTER TABLE [dss].[Fact_SimulationOrder]  WITH CHECK ADD  CONSTRAINT [CK_V6_Fact_SimulationOrder_Status] CHECK  (([OrderStatus]='LOST' OR [OrderStatus]='FULFILLED' OR [OrderStatus]='PARTIALLY_SHIPPED' OR [OrderStatus]='OPEN'))
GO
ALTER TABLE [dss].[Fact_SimulationOrder] CHECK CONSTRAINT [CK_V6_Fact_SimulationOrder_Status]
GO
ALTER TABLE [dss].[PolicyParameterValue]  WITH CHECK ADD  CONSTRAINT [CK_V6_PolicyParameterValue_OneValue] CHECK  ((((case when [NumericValue] IS NULL then (0) else (1) end+case when [TextValue] IS NULL then (0) else (1) end)+case when [BooleanValue] IS NULL then (0) else (1) end)=(1)))
GO
ALTER TABLE [dss].[PolicyParameterValue] CHECK CONSTRAINT [CK_V6_PolicyParameterValue_OneValue]
GO
ALTER TABLE [dss].[PolicyProductConfig]  WITH CHECK ADD  CONSTRAINT [CK_V6_PolicyProductConfig_Thresholds] CHECK  (([ReorderPointUsed]>=(0) AND [TargetLevelUsed]>=[ReorderPointUsed]))
GO
ALTER TABLE [dss].[PolicyProductConfig] CHECK CONSTRAINT [CK_V6_PolicyProductConfig_Thresholds]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [CK_V6_RunEntity_Customer] CHECK  (([EntityType]='CUSTOMER_ORDER_LINE' AND [DueAt] IS NOT NULL AND [CustomerOrderCode] IS NOT NULL OR [EntityType]<>'CUSTOMER_ORDER_LINE' AND [CustomerOrderCode] IS NULL))
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [CK_V6_RunEntity_Customer]
GO
ALTER TABLE [dss].[RunEntity]  WITH CHECK ADD  CONSTRAINT [CK_V6_RunEntity_Quantity] CHECK  (([OriginalQty]>=(0) AND [OpeningRemainingQty]>=(0) AND [OpeningRemainingQty]<=[OriginalQty]))
GO
ALTER TABLE [dss].[RunEntity] CHECK CONSTRAINT [CK_V6_RunEntity_Quantity]
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder]  WITH CHECK ADD  CONSTRAINT [CK_V6_Scenario_InitialCustomerOrder_Balance] CHECK  (([OriginalOrderQty]=(([DeliveredBeforeStartQty]+[ClosedBeforeStartQty])+[OutstandingQty]) AND [DeliveredBeforeStartQty]>=(0) AND [ClosedBeforeStartQty]>=(0) AND [OutstandingQty]>(0)))
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder] CHECK CONSTRAINT [CK_V6_Scenario_InitialCustomerOrder_Balance]
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder]  WITH CHECK ADD  CONSTRAINT [CK_V6_Scenario_InitialCustomerOrder_CreatedBeforeRun] CHECK  (([OrderOffsetDays]<(0)))
GO
ALTER TABLE [dss].[Scenario_InitialCustomerOrder] CHECK CONSTRAINT [CK_V6_Scenario_InitialCustomerOrder_CreatedBeforeRun]
GO
ALTER TABLE [dss].[Scenario_InitialEntity]  WITH CHECK ADD  CONSTRAINT [CK_V6_Scenario_InitialEntity_Balance] CHECK  (([OriginalQty]>=[RemainingQty] AND [RemainingQty]>=(0) AND [CreatedOffsetDays]<(0)))
GO
ALTER TABLE [dss].[Scenario_InitialEntity] CHECK CONSTRAINT [CK_V6_Scenario_InitialEntity_Balance]
GO
ALTER TABLE [dss].[Scenario_InitialEntity]  WITH CHECK ADD  CONSTRAINT [CK_V6_Scenario_InitialEntity_Parent] CHECK  (([ParentInitialEntityCode] IS NULL OR [ParentInitialEntityCode]<>[InitialEntityCode]))
GO
ALTER TABLE [dss].[Scenario_InitialEntity] CHECK CONSTRAINT [CK_V6_Scenario_InitialEntity_Parent]
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE etl.uspBeginBatch
 @B bigint OUTPUT,
 @PipelineName nvarchar(100)=N'DWH_FULL',
 @SourceSystem nvarchar(100)=NULL,
 @RuleSetVersion nvarchar(100)=NULL,
 @SourceSnapshotReference nvarchar(max)=NULL,
 @SourceBackupName nvarchar(max)=NULL,
 @SourceBackupSha256 varchar(max)=NULL
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NULLIF(LTRIM(RTRIM(@PipelineName)),N'') IS NULL THROW 51110,'PipelineName is required.',1;
 SET @PipelineName=UPPER(LTRIM(RTRIM(@PipelineName)));
 SET @SourceSnapshotReference=NULLIF(LTRIM(RTRIM(@SourceSnapshotReference)),N'');
 SET @SourceBackupName=NULLIF(LTRIM(RTRIM(@SourceBackupName)),N'');
 SET @SourceBackupSha256=NULLIF(LTRIM(RTRIM(@SourceBackupSha256)),'');
 IF @SourceBackupName IS NOT NULL OR @SourceBackupSha256 IS NOT NULL
 BEGIN
  IF @SourceSnapshotReference IS NOT NULL THROW 51220,'Supply a reference or backup name/hash, not both.',1;
  IF @SourceBackupName IS NULL OR @SourceBackupSha256 IS NULL OR LEN(@SourceBackupSha256)<>64
    OR @SourceBackupSha256 COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9A-Fa-f]%'
   THROW 51221,'Backup reference needs a real name and a 64-hex SHA-256.',1;
  SET @SourceSnapshotReference=@SourceBackupName+N'#sha256='+LOWER(@SourceBackupSha256);
 END;
 IF DATALENGTH(@SourceSnapshotReference)>4000 THROW 51222,'SourceSnapshotReference exceeds 2000 characters.',1;
 IF @SourceSystem IS NULL SET @SourceSystem=CASE WHEN @PipelineName IN (N'DSS_CONFIG',N'DSS_RESULT') THEN N'CompanyX DSS' ELSE N'CompanyX SQL Server' END;
 IF @RuleSetVersion IS NULL SET @RuleSetVersion=CASE WHEN @PipelineName=N'DWH_FULL' THEN N'S2T-v1;DQ-v1;ETL-FIX-1-2-4-5-6' ELSE N'S2T-V6.1;DSS-contract-pending' END;
 BEGIN TRY
  BEGIN TRAN;
  DECLARE @lock int,@resource nvarchar(255)=N'InventorySafety_Batch:'+@PipelineName;
  EXEC @lock=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
  IF @lock<0 THROW 51111,'Another batch for this pipeline is initializing.',1;
  IF EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WITH(UPDLOCK,HOLDLOCK) WHERE PipelineName=@PipelineName AND Status='RUNNING') THROW 51112,'This pipeline already has a RUNNING batch.',1;
  DECLARE @Latest bigint,@Retry bigint;
  SELECT TOP(1) @Latest=LoadBatchID,@Retry=CASE WHEN Status='FAILED' THEN LoadBatchID END
  FROM etl.ETL_LoadBatch WHERE PipelineName=@PipelineName ORDER BY LoadBatchID DESC;
  INSERT etl.ETL_LoadBatch(SourceSystem,PipelineName,ExtractionMode,LoadMode,ExtractStartedAt,RuleSetVersion,Status,ValidationStatus,RetryOfLoadBatchID,SourceSnapshotReference)
  SELECT @SourceSystem,@PipelineName,N'FULL',CASE WHEN EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE PipelineName=@PipelineName AND Status='SUCCEEDED') THEN 'FULL_RELOAD' ELSE 'INITIAL_FULL' END,SYSUTCDATETIME(),@RuleSetVersion,'RUNNING','NOT_RUN',@Retry,@SourceSnapshotReference;
  SET @B=SCOPE_IDENTITY();
  COMMIT;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
 SELECT @B AS LoadBatchID;
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE etl.uspFailBatch
 @B bigint,@Message nvarchar(max),@ValidationSummary nvarchar(max)=NULL
AS
BEGIN
 SET NOCOUNT ON;
 -- The caller must roll back the failed load before this independent write.
 UPDATE etl.ETL_LoadBatch SET Status='FAILED',ValidationStatus='FAILED',
  LoadCompletedAt=SYSUTCDATETIME(),ErrorMessage=@Message,
  ValidationSummary=COALESCE(@ValidationSummary,ValidationSummary)
 WHERE LoadBatchID=@B AND Status='RUNNING';
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadBridges] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #BillOfMaterials FROM stg.BillOfMaterials WHERE LoadBatchID=@B;
SELECT * INTO #ProductCostHistory FROM stg.ProductCostHistory WHERE LoadBatchID=@B;
SELECT * INTO #ProductListPriceHistory FROM stg.ProductListPriceHistory WHERE LoadBatchID=@B;
SELECT * INTO #SpecialOfferProduct FROM stg.SpecialOfferProduct WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DELETE FROM dw.Bridge_ProductPromotion; DELETE FROM dw.Bridge_BillOfMaterials; DELETE FROM dw.Ref_ProductPriceHistory;
INSERT dw.Bridge_ProductPromotion ([ProductKey],[PromotionKey],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(O.PromotionKey,0),
 @B,
 SYSUTCDATETIME()
FROM #SpecialOfferProduct B LEFT JOIN dw.Dim_Product P ON P.ProductID=B.ProductID LEFT JOIN dw.Dim_Promotion O ON O.SpecialOfferID=B.SpecialOfferID;
INSERT dw.Bridge_BillOfMaterials ([BillOfMaterialsID],[AssemblyProductKey],[ComponentProductKey],[UnitMeasureKey],[BOMLevel],[PerAssemblyQty],[StartDate],[EndDate],[IsStructureValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT B.BillOfMaterialsID,
 CASE WHEN B.ProductAssemblyID IS NULL THEN -1 ELSE COALESCE(A.ProductKey,0) END,
 COALESCE(C.ProductKey,0),
 COALESCE(U.UnitMeasureKey,0),
 B.BOMLevel,
 B.PerAssemblyQty,
 B.StartDate,
 B.EndDate,
 CASE WHEN (B.ComponentID=B.ProductAssemblyID) OR (B.ProductAssemblyID IS NULL AND (B.BOMLevel<>0 OR B.PerAssemblyQty<>1)) OR (B.ProductAssemblyID IS NOT NULL AND B.BOMLevel<1) THEN 0 ELSE 1 END,
 NULLIF(CONCAT_WS(',',CASE WHEN B.ComponentID=B.ProductAssemblyID THEN 'BOM-01' END,CASE WHEN B.ProductAssemblyID IS NULL AND (B.BOMLevel<>0 OR B.PerAssemblyQty<>1) THEN 'BOM-02' END,CASE WHEN B.ProductAssemblyID IS NOT NULL AND B.BOMLevel<1 THEN 'BOM-03' END,CASE WHEN B.EndDate<=B.StartDate THEN 'BOM-04' END),''),
 'DQ-v1',
 @B,
 SYSUTCDATETIME()
FROM #BillOfMaterials B LEFT JOIN dw.Dim_Product A ON A.ProductID=B.ProductAssemblyID LEFT JOIN dw.Dim_Product C ON C.ProductID=B.ComponentID LEFT JOIN dw.Dim_UnitMeasure U ON U.UnitMeasureCode=RTRIM(B.UnitMeasureCode);
INSERT dw.Ref_ProductPriceHistory ([ProductKey],[PriceType],[StartDate],[EndDate],[Amount],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 'STANDARD_COST',
 H.StartDate,
 H.EndDate,
 H.StandardCost,
 @B,
 SYSUTCDATETIME()
FROM #ProductCostHistory H LEFT JOIN dw.Dim_Product P ON P.ProductID=H.ProductID;
INSERT dw.Ref_ProductPriceHistory ([ProductKey],[PriceType],[StartDate],[EndDate],[Amount],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 'LIST_PRICE',
 H.StartDate,
 H.EndDate,
 H.ListPrice,
 @B,
 SYSUTCDATETIME()
FROM #ProductListPriceHistory H LEFT JOIN dw.Dim_Product P ON P.ProductID=H.ProductID;

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE etl.uspLoadDemandDaily
 @B bigint, @DemandRuleVersion nvarchar(50)=N'DEM-v1'
AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF @DemandRuleVersion IS NULL OR @DemandRuleVersion<>N'DEM-v1'
  THROW 51210,'Unsupported demand rule. Implement a new rule before assigning a new version.',1;
 IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING' AND PipelineName='DWH_FULL')
  THROW 51211,'A RUNNING DWH_FULL batch is required for historical demand.',1;
 DECLARE @AsOf date=(SELECT MAX(d) FROM (
  SELECT MAX(OrderDate) d FROM stg.SalesOrderHeader WHERE LoadBatchID=@B
  UNION ALL SELECT MAX(OrderDate) FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B
  UNION ALL SELECT MAX(StartDate) FROM stg.WorkOrder WHERE LoadBatchID=@B) D);
 IF @AsOf IS NULL THROW 51212,'Cannot determine the existing G03 historical cutoff.',1;
 BEGIN TRY
  BEGIN TRAN;
  IF EXISTS(SELECT 1 FROM dw.Fact_SalesOrderLine WHERE LoadBatchID<>@B)
   OR EXISTS(SELECT 1 FROM dw.Fact_WorkOrder WHERE LoadBatchID<>@B)
   OR EXISTS(SELECT 1 FROM dw.Bridge_BillOfMaterials WHERE LoadBatchID<>@B)
   THROW 51213,'Refresh the historical facts/BOM in the same batch before loading demand.',1;

  SELECT ProductKey,SellStartDate,
    CASE WHEN SellEndDate IS NULL OR SellEndDate<SellStartDate OR SellEndDate>@AsOf THEN @AsOf ELSE SellEndDate END AS SellWindowEnd
  INTO #Products FROM dw.Dim_Product
  WHERE ProductKey>0 AND COALESCE(DQStatus,N'')<>N'EXCLUDED';
  CREATE UNIQUE CLUSTERED INDEX IX_P ON #Products(ProductKey);
  -- A zero-filled history must not silently skip calendar days.
  IF EXISTS(SELECT 1 FROM #Products P WHERE P.SellStartDate<=P.SellWindowEnd AND
   (SELECT COUNT_BIG(*) FROM dw.Dim_Date D WHERE D.DateKey>0 AND D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd)
   <>DATEDIFF_BIG(day,P.SellStartDate,P.SellWindowEnd)+1)
   THROW 51214,'Dim_Date does not cover the complete product history window.',1;
  IF EXISTS(SELECT 1 FROM dw.Fact_SalesOrderLine S JOIN #Products P ON P.ProductKey=S.ProductKey
    LEFT JOIN dw.Dim_Date D ON D.DateKey=S.OrderDateKey
    WHERE D.CalendarDate IS NULL OR D.CalendarDate>@AsOf)
   THROW 51215,'Sales dates cannot be placed in the historical demand window.',1;
  IF EXISTS(SELECT 1 FROM dw.Fact_SalesOrderLine S JOIN #Products P ON P.ProductKey=S.ProductKey
    WHERE S.IsDemandEligible=1 AND (S.OrderQty IS NULL OR S.OrderQty<=0))
   THROW 51216,'Eligible sales quantity violates the existing DQ contract.',1;

  -- Aggregate sales and BOM separately to avoid fanout multiplication.
  SELECT S.OrderDateKey AS DateKey,S.ProductKey,
   SUM(CASE WHEN S.IsDemandEligible=1 THEN CONVERT(decimal(19,4),S.OrderQty) ELSE CONVERT(decimal(19,4),0) END) AS IndependentQty,
   SUM(CASE WHEN S.IsDemandEligible=1 AND M.IsNoDiscount=0 THEN CONVERT(decimal(19,4),S.OrderQty) ELSE CONVERT(decimal(19,4),0) END) AS PromoIndependentQty,
   COUNT(CASE WHEN S.IsDemandEligible=1 THEN 1 END) AS EligibleSalesLineCount,
   COUNT(CASE WHEN COALESCE(S.IsDemandEligible,0)=0 THEN 1 END) AS ExcludedSalesLineCount
  INTO #Sales FROM dw.Fact_SalesOrderLine S
  JOIN #Products P ON P.ProductKey=S.ProductKey
  LEFT JOIN dw.Dim_Promotion M ON M.PromotionKey=S.PromotionKey
  GROUP BY S.OrderDateKey,S.ProductKey;
  CREATE UNIQUE CLUSTERED INDEX IX_S ON #Sales(DateKey,ProductKey);

  SELECT W.StartDateKey AS DateKey,B.ComponentProductKey AS ProductKey,W.WorkOrderID,
   CONVERT(decimal(19,4),W.OrderQty)*CONVERT(decimal(8,2),B.PerAssemblyQty) AS Qty
  INTO #Requirements
  FROM dw.Fact_WorkOrder W JOIN #Products A ON A.ProductKey=W.ProductKey
  JOIN dw.Bridge_BillOfMaterials B ON B.AssemblyProductKey=W.ProductKey
  JOIN #Products C ON C.ProductKey=B.ComponentProductKey
  WHERE B.IsStructureValid=1 AND B.StartDate<=W.StartAt
    AND (B.EndDate IS NULL OR B.EndDate>W.StartAt);
  IF EXISTS(SELECT 1 FROM #Requirements R LEFT JOIN dw.Dim_Date D ON D.DateKey=R.DateKey
    WHERE R.Qty IS NULL OR R.Qty<0 OR D.CalendarDate IS NULL OR D.CalendarDate>@AsOf)
   THROW 51217,'Historical BOM demand has invalid quantity or date; no silent zero substitution.',1;
  SELECT DateKey,ProductKey,SUM(Qty) AS DependentQty,COUNT(DISTINCT WorkOrderID) AS ParentWorkOrderCount
  INTO #Dependent FROM #Requirements GROUP BY DateKey,ProductKey;
  CREATE UNIQUE CLUSTERED INDEX IX_D ON #Dependent(DateKey,ProductKey);

  SELECT D.DateKey,P.ProductKey INTO #Grid
  FROM #Products P JOIN dw.Dim_Date D ON D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd
  WHERE D.DateKey>0 AND D.CalendarDate<=@AsOf
  UNION SELECT DateKey,ProductKey FROM #Sales
  UNION SELECT DateKey,ProductKey FROM #Dependent;
  CREATE UNIQUE CLUSTERED INDEX IX_G ON #Grid(DateKey,ProductKey);
  DELETE dss.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion;
  INSERT dss.Fact_DemandDaily(DateKey,ProductKey,DemandRuleVersion,IndependentQty,PromoIndependentQty,
    DependentQty,TotalDemandQty,EligibleSalesLineCount,ExcludedSalesLineCount,ParentWorkOrderCount,IsInSellWindow,LoadBatchID,LoadedAt)
  SELECT G.DateKey,G.ProductKey,@DemandRuleVersion,COALESCE(S.IndependentQty,0),COALESCE(S.PromoIndependentQty,0),
    COALESCE(R.DependentQty,0),COALESCE(S.IndependentQty,0)+COALESCE(R.DependentQty,0),
    COALESCE(S.EligibleSalesLineCount,0),COALESCE(S.ExcludedSalesLineCount,0),COALESCE(R.ParentWorkOrderCount,0),
    CONVERT(bit,CASE WHEN D.CalendarDate BETWEEN P.SellStartDate AND P.SellWindowEnd THEN 1 ELSE 0 END),@B,SYSUTCDATETIME()
  FROM #Grid G JOIN #Products P ON P.ProductKey=G.ProductKey JOIN dw.Dim_Date D ON D.DateKey=G.DateKey
  LEFT JOIN #Sales S ON S.DateKey=G.DateKey AND S.ProductKey=G.ProductKey
  LEFT JOIN #Dependent R ON R.DateKey=G.DateKey AND R.ProductKey=G.ProductKey;
  IF (SELECT COUNT_BIG(*) FROM #Grid)<>(SELECT COUNT_BIG(*) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion)
    OR COALESCE((SELECT SUM(IndependentQty) FROM #Sales),0)<>COALESCE((SELECT SUM(IndependentQty) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion),0)
    OR COALESCE((SELECT SUM(DependentQty) FROM #Dependent),0)<>COALESCE((SELECT SUM(DependentQty) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=@DemandRuleVersion),0)
   THROW 51218,'Daily demand reconciliation failed.',1;
  COMMIT;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  THROW;
 END CATCH;
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadDimensions] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #UnitMeasure FROM stg.UnitMeasure WHERE LoadBatchID=@B;
SELECT * INTO #Location FROM stg.Location WHERE LoadBatchID=@B;
SELECT * INTO #Product FROM stg.Product WHERE LoadBatchID=@B;
SELECT * INTO #ScrapReason FROM stg.ScrapReason WHERE LoadBatchID=@B;
SELECT * INTO #BillOfMaterials FROM stg.BillOfMaterials WHERE LoadBatchID=@B;
SELECT * INTO #ProductCostHistory FROM stg.ProductCostHistory WHERE LoadBatchID=@B;
SELECT * INTO #ProductListPriceHistory FROM stg.ProductListPriceHistory WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrderRouting FROM stg.WorkOrderRouting WHERE LoadBatchID=@B;
SELECT * INTO #TransactionHistoryArchive FROM stg.TransactionHistoryArchive WHERE LoadBatchID=@B;
SELECT * INTO #Vendor FROM stg.Vendor WHERE LoadBatchID=@B;
SELECT * INTO #ProductVendor FROM stg.ProductVendor WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderHeader FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B;
SELECT * INTO #SpecialOffer FROM stg.SpecialOffer WHERE LoadBatchID=@B;
SELECT * INTO #Customer FROM stg.Customer WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderHeader FROM stg.SalesOrderHeader WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
EXEC etl.uspSeedSystemMembers @B;
SET IDENTITY_INSERT dw.Dim_UnitMeasure ON;
INSERT dw.Dim_UnitMeasure ([UnitMeasureKey],[UnitMeasureName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_UnitMeasure WHERE [UnitMeasureKey]=0);
SET IDENTITY_INSERT dw.Dim_UnitMeasure OFF;
SET IDENTITY_INSERT dw.Dim_Location ON;
INSERT dw.Dim_Location ([LocationKey],[LocationName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Location WHERE [LocationKey]=0);
SET IDENTITY_INSERT dw.Dim_Location OFF;
SET IDENTITY_INSERT dw.Dim_Vendor ON;
INSERT dw.Dim_Vendor ([VendorKey],[VendorName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Vendor WHERE [VendorKey]=0);
SET IDENTITY_INSERT dw.Dim_Vendor OFF;
SET IDENTITY_INSERT dw.Dim_Promotion ON;
INSERT dw.Dim_Promotion ([PromotionKey],[Description],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Promotion WHERE [PromotionKey]=0);
SET IDENTITY_INSERT dw.Dim_Promotion OFF;
SET IDENTITY_INSERT dw.Dim_Customer ON;
INSERT dw.Dim_Customer ([CustomerKey],[CustomerType],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Customer WHERE [CustomerKey]=0);
SET IDENTITY_INSERT dw.Dim_Customer OFF;
SET IDENTITY_INSERT dw.Dim_ScrapReason ON;
INSERT dw.Dim_ScrapReason ([ScrapReasonKey],[ScrapReasonName],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Không phế phẩm',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_ScrapReason WHERE [ScrapReasonKey]=0);
SET IDENTITY_INSERT dw.Dim_ScrapReason OFF;
SET IDENTITY_INSERT dw.Dim_Vendor ON;
INSERT dw.Dim_Vendor ([VendorKey],[VendorName],[ActiveFlag],[LoadBatchID],[LoadedAt])
SELECT -1,
 N'Không áp dụng (tự sản xuất)',
 0,
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Vendor WHERE [VendorKey]=-1);
SET IDENTITY_INSERT dw.Dim_Vendor OFF;
SET IDENTITY_INSERT dw.Dim_Product ON;
INSERT dw.Dim_Product ([ProductKey],[ProductName],[DQStatus],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT 0,
 N'Unknown',
 'EXCLUDED',
 'DQ-v1',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Product WHERE [ProductKey]=0);
INSERT dw.Dim_Product ([ProductKey],[ProductName],[DQStatus],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT -1,
 N'Không áp dụng',
 'EXCLUDED',
 'DQ-v1',
 @B,
 SYSUTCDATETIME()

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Product WHERE [ProductKey]=-1);
SET IDENTITY_INSERT dw.Dim_Product OFF;
INSERT dw.Dim_Date ([DateKey])
SELECT 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Date WHERE [DateKey]=0);
INSERT dw.Dim_Date ([DateKey])
SELECT -1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Date WHERE [DateKey]=-1);
INSERT dw.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 0,
 NULL,
 N'Unknown'

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Channel WHERE ChannelKey=0);
INSERT dw.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 1,
 1,
 N'Online'

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Channel WHERE ChannelKey=1);
INSERT dw.Dim_Channel ([ChannelKey],[OnlineOrderFlag],[ChannelName])
SELECT 2,
 0,
 N'Salesperson'

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Channel WHERE ChannelKey=2);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 0,
 NULL,
 N'Unknown',
 0,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=0);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 1,
 0,
 N'Chưa có tài liệu (mã 0)',
 0,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=1);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 2,
 1,
 N'In process',
 1,
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=2);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 3,
 2,
 N'Approved',
 1,
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=3);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 4,
 3,
 N'Backordered',
 1,
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=4);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 5,
 4,
 N'Rejected',
 1,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=5);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 6,
 5,
 N'Shipped',
 1,
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=6);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 7,
 6,
 N'Cancelled',
 1,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=7);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 8,
 7,
 N'Chưa có tài liệu (mã 7)',
 0,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=8);
INSERT dw.Dim_SalesStatus ([SalesStatusKey],[StatusCode],[StatusName],[IsDocumented],[IsDemandEligible])
SELECT 9,
 8,
 N'Chưa có tài liệu (mã 8)',
 0,
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_SalesStatus WHERE SalesStatusKey=9);
INSERT dw.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 0,
 NULL,
 N'Unknown',
 0

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus WHERE PurchaseStatusKey=0);
INSERT dw.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 1,
 1,
 N'Pending',
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus WHERE PurchaseStatusKey=1);
INSERT dw.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 2,
 2,
 N'Approved',
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus WHERE PurchaseStatusKey=2);
INSERT dw.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 3,
 3,
 N'Rejected',
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus WHERE PurchaseStatusKey=3);
INSERT dw.Dim_PurchaseStatus ([PurchaseStatusKey],[StatusCode],[StatusName],[IsDocumented])
SELECT 4,
 4,
 N'Complete',
 1

WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_PurchaseStatus WHERE PurchaseStatusKey=4);

DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
DECLARE @Min date=(SELECT MIN(d) FROM (SELECT MIN(SellStartDate) d FROM #Product UNION ALL SELECT MIN(StartDate) FROM #BillOfMaterials UNION ALL SELECT MIN(OrderDate) FROM #SalesOrderHeader UNION ALL SELECT MIN(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MIN(StartDate) FROM #WorkOrder UNION ALL SELECT MIN(StartDate) FROM #ProductCostHistory UNION ALL SELECT MIN(StartDate) FROM #ProductListPriceHistory UNION ALL SELECT MIN(LastReceiptDate) FROM #ProductVendor UNION ALL SELECT MIN(TransactionDate) FROM #TransactionHistoryArchive) X);
IF @AsOf IS NULL OR @Min IS NULL THROW 51000,'Missing date coverage in source.',1;
;WITH Dates AS (SELECT @Min d UNION ALL SELECT DATEADD(day,1,d) FROM Dates WHERE d<DATEFROMPARTS(YEAR(@AsOf)+1,12,31))
INSERT dw.Dim_Date(DateKey,CalendarDate,CalendarYear,CalendarQuarter,CalendarMonth,DayOfMonth,DayOfWeek,IsWeekend,ISOWeek,ISOYear,WeekStartDate,MonthStartDate)
SELECT etl.DateKey(d),d,YEAR(d),DATEPART(quarter,d),MONTH(d),DAY(d),DATEDIFF(day,'19000101',d)%7+1,IIF(DATEDIFF(day,'19000101',d)%7>=5,1,0),DATEPART(iso_week,d),YEAR(DATEADD(day,26-DATEPART(iso_week,d),d)),DATEADD(day,-(DATEDIFF(day,'19000101',d)%7),d),DATEFROMPARTS(YEAR(d),MONTH(d),1)
FROM Dates WHERE NOT EXISTS(SELECT 1 FROM dw.Dim_Date D WHERE D.DateKey=etl.DateKey(d)) OPTION(MAXRECURSION 0);
IF EXISTS(SELECT 1 FROM #SalesOrderHeader WHERE Status NOT BETWEEN 0 AND 8) THROW 51000,'Undocumented sales status outside 0..8.',1;
MERGE dw.Dim_UnitMeasure WITH(HOLDLOCK) AS D USING (SELECT RTRIM(UnitMeasureCode) AS [UnitMeasureCode],
 Name AS [UnitMeasureName],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #UnitMeasure) AS S ON D.[UnitMeasureCode]=S.[UnitMeasureCode]
WHEN MATCHED THEN UPDATE SET D.[UnitMeasureName]=S.[UnitMeasureName],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([UnitMeasureCode],[UnitMeasureName],[LoadBatchID],[LoadedAt]) VALUES (S.[UnitMeasureCode],S.[UnitMeasureName],S.[LoadBatchID],S.[LoadedAt]);
MERGE dw.Dim_Location WITH(HOLDLOCK) AS D USING (SELECT L.LocationID AS [LocationID],
 L.Name AS [LocationName],
 L.CostRate AS [CostRate],
 L.Availability AS [Availability],
 IIF(L.Availability=0,'STORAGE','PRODUCTION') AS [LocationType],
 IIF(L.Availability=0 AND EXISTS(SELECT 1 FROM #WorkOrderRouting R WHERE R.LocationID=L.LocationID),1,0) AS [HasProductionConflict],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Location L) AS S ON D.[LocationID]=S.[LocationID]
WHEN MATCHED THEN UPDATE SET D.[LocationName]=S.[LocationName],D.[CostRate]=S.[CostRate],D.[Availability]=S.[Availability],D.[LocationType]=S.[LocationType],D.[HasProductionConflict]=S.[HasProductionConflict],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([LocationID],[LocationName],[CostRate],[Availability],[LocationType],[HasProductionConflict],[LoadBatchID],[LoadedAt]) VALUES (S.[LocationID],S.[LocationName],S.[CostRate],S.[Availability],S.[LocationType],S.[HasProductionConflict],S.[LoadBatchID],S.[LoadedAt]);
MERGE dw.Dim_Vendor WITH(HOLDLOCK) AS D USING (SELECT BusinessEntityID AS [VendorID],
 AccountNumber AS [AccountNumber],
 Name AS [VendorName],
 CreditRating AS [CreditRating],
 CASE CreditRating WHEN 1 THEN N'Xuất sắc' WHEN 2 THEN N'Tốt' WHEN 3 THEN N'Trên trung bình' WHEN 4 THEN N'Trung bình' WHEN 5 THEN N'Dưới trung bình' ELSE N'Không xác định' END AS [CreditRatingName],
 PreferredVendorStatus AS [PreferredVendorStatus],
 ActiveFlag AS [ActiveFlag],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Vendor) AS S ON D.[VendorID]=S.[VendorID]
WHEN MATCHED THEN UPDATE SET D.[AccountNumber]=S.[AccountNumber],D.[VendorName]=S.[VendorName],D.[CreditRating]=S.[CreditRating],D.[CreditRatingName]=S.[CreditRatingName],D.[PreferredVendorStatus]=S.[PreferredVendorStatus],D.[ActiveFlag]=S.[ActiveFlag],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([VendorID],[AccountNumber],[VendorName],[CreditRating],[CreditRatingName],[PreferredVendorStatus],[ActiveFlag],[LoadBatchID],[LoadedAt]) VALUES (S.[VendorID],S.[AccountNumber],S.[VendorName],S.[CreditRating],S.[CreditRatingName],S.[PreferredVendorStatus],S.[ActiveFlag],S.[LoadBatchID],S.[LoadedAt]);
MERGE dw.Dim_Promotion WITH(HOLDLOCK) AS D USING (SELECT SpecialOfferID AS [SpecialOfferID],
 Description AS [Description],
 Type AS [OfferType],
 Category AS [OfferCategory],
 DiscountPct AS [DiscountPct],
 StartDate AS [StartDate],
 EndDate AS [EndDate],
 MinQty AS [MinQty],
 MaxQty AS [MaxQty],
 IIF(DiscountPct=0,1,0) AS [IsNoDiscount],
 IIF(StartDate IS NOT NULL AND EndDate IS NOT NULL AND StartDate<=EndDate,1,0) AS [IsScheduleValid],
 IIF(DiscountPct BETWEEN 0 AND 1,1,0) AS [IsDiscountValid],
 IIF(MaxQty IS NULL OR (MaxQty>=0 AND MaxQty>=MinQty),1,0) AS [IsQtyRangeValid],
 NULLIF(CONCAT_WS(',',CASE WHEN StartDate IS NULL OR EndDate IS NULL OR EndDate<StartDate THEN 'PRM-01' END,CASE WHEN DiscountPct NOT BETWEEN 0 AND 1 THEN 'PRM-02' END,CASE WHEN MaxQty<0 OR MaxQty<MinQty THEN 'PRM-03' END),'') AS [DQReasonCode],
 'DQ-v1' AS [DQRuleVersion],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #SpecialOffer) AS S ON D.[SpecialOfferID]=S.[SpecialOfferID]
WHEN MATCHED THEN UPDATE SET D.[Description]=S.[Description],D.[OfferType]=S.[OfferType],D.[OfferCategory]=S.[OfferCategory],D.[DiscountPct]=S.[DiscountPct],D.[StartDate]=S.[StartDate],D.[EndDate]=S.[EndDate],D.[MinQty]=S.[MinQty],D.[MaxQty]=S.[MaxQty],D.[IsNoDiscount]=S.[IsNoDiscount],D.[IsScheduleValid]=S.[IsScheduleValid],D.[IsDiscountValid]=S.[IsDiscountValid],D.[IsQtyRangeValid]=S.[IsQtyRangeValid],D.[DQReasonCode]=S.[DQReasonCode],D.[DQRuleVersion]=S.[DQRuleVersion],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([SpecialOfferID],[Description],[OfferType],[OfferCategory],[DiscountPct],[StartDate],[EndDate],[MinQty],[MaxQty],[IsNoDiscount],[IsScheduleValid],[IsDiscountValid],[IsQtyRangeValid],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) VALUES (S.[SpecialOfferID],S.[Description],S.[OfferType],S.[OfferCategory],S.[DiscountPct],S.[StartDate],S.[EndDate],S.[MinQty],S.[MaxQty],S.[IsNoDiscount],S.[IsScheduleValid],S.[IsDiscountValid],S.[IsQtyRangeValid],S.[DQReasonCode],S.[DQRuleVersion],S.[LoadBatchID],S.[LoadedAt]);
MERGE dw.Dim_Customer WITH(HOLDLOCK) AS D USING (SELECT CustomerID AS [CustomerID],
 PersonID AS [PersonID],
 StoreID AS [StoreID],
 CASE WHEN StoreID IS NOT NULL THEN 'Store' WHEN PersonID IS NOT NULL THEN 'Individual' ELSE 'Unknown' END AS [CustomerType],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Customer) AS S ON D.[CustomerID]=S.[CustomerID]
WHEN MATCHED THEN UPDATE SET D.[PersonID]=S.[PersonID],D.[StoreID]=S.[StoreID],D.[CustomerType]=S.[CustomerType],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([CustomerID],[PersonID],[StoreID],[CustomerType],[LoadBatchID],[LoadedAt]) VALUES (S.[CustomerID],S.[PersonID],S.[StoreID],S.[CustomerType],S.[LoadBatchID],S.[LoadedAt]);
MERGE dw.Dim_ScrapReason WITH(HOLDLOCK) AS D USING (SELECT ScrapReasonID AS [ScrapReasonID],
 Name AS [ScrapReasonName],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #ScrapReason) AS S ON D.[ScrapReasonID]=S.[ScrapReasonID]
WHEN MATCHED THEN UPDATE SET D.[ScrapReasonName]=S.[ScrapReasonName],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([ScrapReasonID],[ScrapReasonName],[LoadBatchID],[LoadedAt]) VALUES (S.[ScrapReasonID],S.[ScrapReasonName],S.[LoadBatchID],S.[LoadedAt]);

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadDWH] @B bigint AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND PipelineName=N'DWH_FULL' AND Status=N'RUNNING') THROW 51113,'A RUNNING DWH_FULL batch is required.',1;
 DECLARE @ValidationSummary nvarchar(max)=NULL,@ValidationResult int;
 BEGIN TRY
 BEGIN TRAN;
 UPDATE etl.ETL_LoadBatch SET ExtractCompletedAt=SYSUTCDATETIME(),LoadStartedAt=SYSUTCDATETIME() WHERE LoadBatchID=@B AND Status='RUNNING';
 EXEC etl.uspLoadDimensions @B;
 EXEC etl.uspLoadProduct @B;
 EXEC etl.uspLoadBridges @B;
 EXEC etl.uspLoadSales @B;
 EXEC etl.uspLoadPurchases @B;
 EXEC etl.uspLoadVendorTerms @B;
 EXEC etl.uspLoadOperations @B;
 EXEC etl.uspLoadInventory @B;
 EXEC etl.uspLoadWorkOrders @B;
 EXEC etl.uspLoadDemandDaily @B;
 EXEC @ValidationResult=etl.uspValidateAndFinish @B,@ValidationSummary OUTPUT,@ThrowOnFailure=0;
 IF @ValidationResult<>0 THROW 51000,'Mandatory reconciliation failed. See validation result.',1;
 COMMIT;
 END TRY BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK;
 DECLARE @Error nvarchar(max)=CONCAT(ERROR_PROCEDURE(),':',ERROR_LINE(),': ',ERROR_MESSAGE());
 EXEC etl.uspFailBatch @B,@Error,@ValidationSummary;
 THROW;
 END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadInventory] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #ProductInventory FROM stg.ProductInventory WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderHeader FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderHeader FROM stg.SalesOrderHeader WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
IF EXISTS(SELECT 1 FROM dw.Ref_ProductPriceHistory A JOIN dw.Ref_ProductPriceHistory B ON A.ProductKey=B.ProductKey AND A.PriceType=B.PriceType AND A.StartDate<B.StartDate AND COALESCE(A.EndDate,'99991231')>=B.StartDate) THROW 51000,'Overlapping price history requires review.',1;
DELETE FROM dw.Fact_InventoryOnHand;
INSERT dw.Fact_InventoryOnHand ([ProductKey],[LocationKey],[AsOfDateKey],[Shelf],[Bin],[QuantityOnHand],[UnitCostAsOf],[InventoryValue],[IsNegativeQty],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(L.LocationKey,0),
 etl.DateKey(@AsOf),
 I.Shelf,
 I.Bin,
 I.Quantity,
 COALESCE(C.Amount,P.StandardCost),
 CAST(I.Quantity AS decimal(19,4))*COALESCE(C.Amount,P.StandardCost),
 IIF(I.Quantity<0,1,0),
 @B,
 SYSUTCDATETIME()
FROM #ProductInventory I LEFT JOIN dw.Dim_Product P ON P.ProductID=I.ProductID LEFT JOIN dw.Dim_Location L ON L.LocationID=I.LocationID LEFT JOIN dw.Ref_ProductPriceHistory C ON C.ProductKey=P.ProductKey AND C.PriceType='STANDARD_COST' AND C.StartDate<=@AsOf AND (C.EndDate IS NULL OR C.EndDate>=@AsOf);

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadOperations] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrderRouting FROM stg.WorkOrderRouting WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DELETE FROM dw.Fact_WorkOrderOperation;
INSERT dw.Fact_WorkOrderOperation ([WorkOrderID],[OperationSequence],[ProductKey],[LocationKey],[ScheduledStartDateKey],[ScheduledEndDateKey],[ActualStartDateKey],[ActualEndDateKey],[ScheduledDurationDays],[ActualDurationDays],[ActualResourceHrs],[PlannedCost],[ActualCost],[IsLastOperation],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT R.WorkOrderID,
 R.OperationSequence,
 COALESCE(P.ProductKey,0),
 COALESCE(L.LocationKey,0),
 etl.DateKey(R.ScheduledStartDate),
 etl.DateKey(R.ScheduledEndDate),
 IIF(R.ActualStartDate IS NULL,-1,etl.DateKey(R.ActualStartDate)),
 IIF(R.ActualEndDate IS NULL,-1,etl.DateKey(R.ActualEndDate)),
 DATEDIFF(day,R.ScheduledStartDate,R.ScheduledEndDate),
 DATEDIFF(day,R.ActualStartDate,R.ActualEndDate),
 R.ActualResourceHrs,
 R.PlannedCost,
 R.ActualCost,
 IIF(R.OperationSequence=MAX(R.OperationSequence) OVER(PARTITION BY R.WorkOrderID),1,0),
 NULLIF(CONCAT_WS(',',CASE WHEN L.Availability=0 THEN 'OPR-01' END,CASE WHEN R.ActualEndDate<R.ActualStartDate THEN 'OPR-02' END,CASE WHEN R.ProductID<>W.ProductID THEN 'OPR-03' END),''),
 'DQ-v1',
 @B,
 SYSUTCDATETIME()
FROM #WorkOrderRouting R LEFT JOIN #WorkOrder W ON W.WorkOrderID=R.WorkOrderID LEFT JOIN dw.Dim_Product P ON P.ProductID=R.ProductID LEFT JOIN dw.Dim_Location L ON L.LocationID=R.LocationID;

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadProduct] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #UnitMeasure FROM stg.UnitMeasure WHERE LoadBatchID=@B;
SELECT * INTO #Product FROM stg.Product WHERE LoadBatchID=@B;
SELECT * INTO #ProductSubcategory FROM stg.ProductSubcategory WHERE LoadBatchID=@B;
SELECT * INTO #ProductCategory FROM stg.ProductCategory WHERE LoadBatchID=@B;
SELECT * INTO #BillOfMaterials FROM stg.BillOfMaterials WHERE LoadBatchID=@B;
SELECT * INTO #ProductInventory FROM stg.ProductInventory WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderDetail FROM stg.PurchaseOrderDetail WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderDetail FROM stg.SalesOrderDetail WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
MERGE dw.Dim_Product WITH(HOLDLOCK) AS D USING (SELECT P.ProductID AS [ProductID],
 P.ProductNumber AS [ProductNumber],
 P.Name AS [ProductName],
 P.ProductSubcategoryID AS [ProductSubcategoryID],
 S.Name AS [SubcategoryName],
 S.ProductCategoryID AS [ProductCategoryID],
 C.Name AS [CategoryName],
 P.ProductModelID AS [ProductModelID],
 P.MakeFlag AS [MakeFlag],
 P.FinishedGoodsFlag AS [FinishedGoodsFlag],
 IIF(P.MakeFlag=1,'MAKE','BUY') AS [SupplyType],
 CASE WHEN P.FinishedGoodsFlag=1 THEN 'FINISHED_GOOD' WHEN EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ProductAssemblyID=P.ProductID) AND EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN 'SUBASSEMBLY' WHEN EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN 'RAW_MATERIAL' WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) THEN 'ISOLATED' ELSE 'UNCLASSIFIED' END AS [ProductRole],
 IIF(EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ProductAssemblyID=P.ProductID),1,0) AS [IsBOMAssembly],
 IIF(EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL),1,0) AS [IsBOMComponent],
 P.Color AS [Color],
 P.Size AS [Size],
 US.Name AS [SizeUnitName],
 P.Weight AS [Weight],
 UW.Name AS [WeightUnitName],
 RTRIM(UPPER(P.ProductLine)) AS [ProductLine],
 CASE WHEN P.ProductLine IS NULL THEN NULL WHEN RTRIM(UPPER(P.ProductLine))='R' THEN N'Road' WHEN RTRIM(UPPER(P.ProductLine))='M' THEN N'Mountain' WHEN RTRIM(UPPER(P.ProductLine))='T' THEN N'Touring' WHEN RTRIM(UPPER(P.ProductLine))='S' THEN N'Standard' ELSE N'Không xác định' END AS [ProductLineName],
 RTRIM(UPPER(P.Class)) AS [Class],
 CASE WHEN P.Class IS NULL THEN NULL WHEN RTRIM(UPPER(P.Class))='H' THEN N'Cao cấp' WHEN RTRIM(UPPER(P.Class))='M' THEN N'Trung bình' WHEN RTRIM(UPPER(P.Class))='L' THEN N'Thấp' ELSE N'Không xác định' END AS [ClassName],
 RTRIM(UPPER(P.Style)) AS [Style],
 CASE WHEN P.Style IS NULL THEN NULL WHEN RTRIM(UPPER(P.Style))='W' THEN N'Nữ' WHEN RTRIM(UPPER(P.Style))='M' THEN N'Nam' WHEN RTRIM(UPPER(P.Style))='U' THEN N'Chung' ELSE N'Không xác định' END AS [StyleName],
 P.DaysToManufacture AS [DaysToManufacture],
 P.SafetyStockLevel AS [SafetyStockLevel],
 P.ReorderPoint AS [ReorderPoint],
 P.StandardCost AS [StandardCost],
 P.ListPrice AS [ListPrice],
 P.SellStartDate AS [SellStartDate],
 P.SellEndDate AS [SellEndDate],
 P.DiscontinuedDate AS [DiscontinuedDate],
 CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN 'EXCLUDED' WHEN NULLIF(CONCAT_WS(',',CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN 'PRD-01' END,CASE WHEN P.MakeFlag=0 AND NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN 'PRD-02' END,CASE WHEN P.SafetyStockLevel<=0 THEN 'PRD-03' END,CASE WHEN P.ReorderPoint<=0 THEN 'PRD-04' END,CASE WHEN P.SellEndDate<P.SellStartDate THEN 'PRD-05' END),'') IS NOT NULL THEN 'WARNING' ELSE 'OK' END AS [DQStatus],
 NULLIF(CONCAT_WS(',',CASE WHEN NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #PurchaseOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #WorkOrder X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #ProductInventory X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID OR X.ProductAssemblyID=P.ProductID) THEN 'PRD-01' END,CASE WHEN P.MakeFlag=0 AND NOT EXISTS(SELECT 1 FROM #SalesOrderDetail X WHERE X.ProductID=P.ProductID) AND NOT EXISTS(SELECT 1 FROM #BillOfMaterials X WHERE X.ComponentID=P.ProductID AND X.ProductAssemblyID IS NOT NULL) THEN 'PRD-02' END,CASE WHEN P.SafetyStockLevel<=0 THEN 'PRD-03' END,CASE WHEN P.ReorderPoint<=0 THEN 'PRD-04' END,CASE WHEN P.SellEndDate<P.SellStartDate THEN 'PRD-05' END),'') AS [DQReasonCode],
 'DQ-v1' AS [DQRuleVersion],
 @B AS [LoadBatchID],
 SYSUTCDATETIME() AS [LoadedAt]
FROM #Product P LEFT JOIN #ProductSubcategory S ON S.ProductSubcategoryID=P.ProductSubcategoryID LEFT JOIN #ProductCategory C ON C.ProductCategoryID=S.ProductCategoryID LEFT JOIN #UnitMeasure US ON US.UnitMeasureCode=P.SizeUnitMeasureCode LEFT JOIN #UnitMeasure UW ON UW.UnitMeasureCode=P.WeightUnitMeasureCode) AS S ON D.[ProductID]=S.[ProductID]
WHEN MATCHED THEN UPDATE SET D.[ProductNumber]=S.[ProductNumber],D.[ProductName]=S.[ProductName],D.[ProductSubcategoryID]=S.[ProductSubcategoryID],D.[SubcategoryName]=S.[SubcategoryName],D.[ProductCategoryID]=S.[ProductCategoryID],D.[CategoryName]=S.[CategoryName],D.[ProductModelID]=S.[ProductModelID],D.[MakeFlag]=S.[MakeFlag],D.[FinishedGoodsFlag]=S.[FinishedGoodsFlag],D.[SupplyType]=S.[SupplyType],D.[ProductRole]=S.[ProductRole],D.[IsBOMAssembly]=S.[IsBOMAssembly],D.[IsBOMComponent]=S.[IsBOMComponent],D.[Color]=S.[Color],D.[Size]=S.[Size],D.[SizeUnitName]=S.[SizeUnitName],D.[Weight]=S.[Weight],D.[WeightUnitName]=S.[WeightUnitName],D.[ProductLine]=S.[ProductLine],D.[ProductLineName]=S.[ProductLineName],D.[Class]=S.[Class],D.[ClassName]=S.[ClassName],D.[Style]=S.[Style],D.[StyleName]=S.[StyleName],D.[DaysToManufacture]=S.[DaysToManufacture],D.[SafetyStockLevel]=S.[SafetyStockLevel],D.[ReorderPoint]=S.[ReorderPoint],D.[StandardCost]=S.[StandardCost],D.[ListPrice]=S.[ListPrice],D.[SellStartDate]=S.[SellStartDate],D.[SellEndDate]=S.[SellEndDate],D.[DiscontinuedDate]=S.[DiscontinuedDate],D.[DQStatus]=S.[DQStatus],D.[DQReasonCode]=S.[DQReasonCode],D.[DQRuleVersion]=S.[DQRuleVersion],D.[LoadBatchID]=S.[LoadBatchID],D.[LoadedAt]=S.[LoadedAt]
WHEN NOT MATCHED THEN INSERT ([ProductID],[ProductNumber],[ProductName],[ProductSubcategoryID],[SubcategoryName],[ProductCategoryID],[CategoryName],[ProductModelID],[MakeFlag],[FinishedGoodsFlag],[SupplyType],[ProductRole],[IsBOMAssembly],[IsBOMComponent],[Color],[Size],[SizeUnitName],[Weight],[WeightUnitName],[ProductLine],[ProductLineName],[Class],[ClassName],[Style],[StyleName],[DaysToManufacture],[SafetyStockLevel],[ReorderPoint],[StandardCost],[ListPrice],[SellStartDate],[SellEndDate],[DiscontinuedDate],[DQStatus],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt]) VALUES (S.[ProductID],S.[ProductNumber],S.[ProductName],S.[ProductSubcategoryID],S.[SubcategoryName],S.[ProductCategoryID],S.[CategoryName],S.[ProductModelID],S.[MakeFlag],S.[FinishedGoodsFlag],S.[SupplyType],S.[ProductRole],S.[IsBOMAssembly],S.[IsBOMComponent],S.[Color],S.[Size],S.[SizeUnitName],S.[Weight],S.[WeightUnitName],S.[ProductLine],S.[ProductLineName],S.[Class],S.[ClassName],S.[Style],S.[StyleName],S.[DaysToManufacture],S.[SafetyStockLevel],S.[ReorderPoint],S.[StandardCost],S.[ListPrice],S.[SellStartDate],S.[SellEndDate],S.[DiscontinuedDate],S.[DQStatus],S.[DQReasonCode],S.[DQRuleVersion],S.[LoadBatchID],S.[LoadedAt]);

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadPurchases] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #ProductVendor FROM stg.ProductVendor WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderHeader FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderDetail FROM stg.PurchaseOrderDetail WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DELETE FROM dw.Fact_PurchaseOrderLine;
INSERT dw.Fact_PurchaseOrderLine ([PurchaseOrderID],[PurchaseOrderDetailID],[OrderDateKey],[ExpectedShipDateKey],[ExpectedReceiptDateKey],[VendorKey],[ProductKey],[PurchaseStatusKey],[OrderQty],[ReceivedQty],[RejectedQty],[StockedQty],[UnitPrice],[LineTotal],[OrderAt],[ExpectedShipAt],[ExpectedReceiptAt],[IsVendorProductDeclared],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT D.PurchaseOrderID,
 D.PurchaseOrderDetailID,
 etl.DateKey(H.OrderDate),
 IIF(H.ShipDate IS NULL,-1,etl.DateKey(H.ShipDate)),
 etl.DateKey(D.DueDate),
 COALESCE(V.VendorKey,0),
 COALESCE(P.ProductKey,0),
 COALESCE(S.PurchaseStatusKey,0),
 D.OrderQty,
 D.ReceivedQty,
 D.RejectedQty,
 D.StockedQty,
 D.UnitPrice,
 CAST(D.OrderQty AS decimal(19,4))*CAST(D.UnitPrice AS decimal(19,4)),
 H.OrderDate,
 H.ShipDate,
 D.DueDate,
 IIF(PV.ProductID IS NULL,0,1),
 NULLIF(CONCAT_WS(',',CASE WHEN PV.ProductID IS NULL THEN 'PUR-01' END,CASE WHEN D.RejectedQty>D.ReceivedQty THEN 'PUR-02' END,CASE WHEN D.ReceivedQty>D.OrderQty THEN 'PUR-03' END,CASE WHEN D.DueDate<H.OrderDate THEN 'PUR-04' END),''),
 'DQ-v1',
 @B,
 SYSUTCDATETIME()
FROM #PurchaseOrderDetail D INNER JOIN #PurchaseOrderHeader H ON H.PurchaseOrderID=D.PurchaseOrderID LEFT JOIN #ProductVendor PV ON PV.ProductID=D.ProductID AND PV.BusinessEntityID=H.VendorID LEFT JOIN dw.Dim_Product P ON P.ProductID=D.ProductID LEFT JOIN dw.Dim_Vendor V ON V.VendorID=H.VendorID LEFT JOIN dw.Dim_PurchaseStatus S ON S.StatusCode=H.Status;

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadSales] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #SpecialOfferProduct FROM stg.SpecialOfferProduct WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderHeader FROM stg.SalesOrderHeader WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderDetail FROM stg.SalesOrderDetail WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DELETE FROM dw.Fact_SalesOrderLine;
INSERT dw.Fact_SalesOrderLine ([SalesOrderID],[SalesOrderDetailID],[OrderDateKey],[DueDateKey],[ShipDateKey],[ProductKey],[PromotionKey],[SalesStatusKey],[CustomerKey],[ChannelKey],[OrderQty],[UnitPrice],[UnitPriceDiscount],[LineTotal],[OrderAt],[DueAt],[ShippedAt],[IsDemandEligible],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT D.SalesOrderID,
 D.SalesOrderDetailID,
 etl.DateKey(H.OrderDate),
 etl.DateKey(H.DueDate),
 IIF(H.ShipDate IS NULL,-1,etl.DateKey(H.ShipDate)),
 COALESCE(P.ProductKey,0),
 COALESCE(O.PromotionKey,0),
 COALESCE(S.SalesStatusKey,0),
 COALESCE(C.CustomerKey,0),
 COALESCE(K.ChannelKey,0),
 D.OrderQty,
 D.UnitPrice,
 D.UnitPriceDiscount,
 D.LineTotal,
 H.OrderDate,
 H.DueDate,
 H.ShipDate,
 IIF(S.IsDemandEligible=1 AND D.OrderQty>0,1,0),
 NULLIF(CONCAT_WS(',',CASE WHEN D.OrderQty IS NULL THEN 'SAL-01' END,CASE WHEN D.OrderQty<=0 THEN 'SAL-02' END,CASE WHEN D.UnitPrice IS NULL THEN 'SAL-03' END,CASE WHEN D.UnitPrice<0 THEN 'SAL-04' END,CASE WHEN H.DueDate<H.OrderDate THEN 'SAL-05' END,CASE WHEN H.ShipDate<H.OrderDate THEN 'SAL-06' END,CASE WHEN S.IsDemandEligible=0 AND S.IsDocumented=1 THEN 'SAL-07' END,CASE WHEN COALESCE(S.IsDocumented,0)=0 THEN 'SAL-08' END,CASE WHEN NOT EXISTS(SELECT 1 FROM #SpecialOfferProduct X WHERE X.ProductID=D.ProductID AND X.SpecialOfferID=D.SpecialOfferID) THEN 'SAL-09' END),''),
 'DQ-v1',
 @B,
 SYSUTCDATETIME()
FROM #SalesOrderDetail D INNER JOIN #SalesOrderHeader H ON H.SalesOrderID=D.SalesOrderID LEFT JOIN dw.Dim_Product P ON P.ProductID=D.ProductID LEFT JOIN dw.Dim_Promotion O ON O.SpecialOfferID=D.SpecialOfferID LEFT JOIN dw.Dim_SalesStatus S ON S.StatusCode=H.Status LEFT JOIN dw.Dim_Customer C ON C.CustomerID=H.CustomerID LEFT JOIN dw.Dim_Channel K ON K.OnlineOrderFlag=H.OnlineOrderFlag;

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadVendorTerms] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #ProductVendor FROM stg.ProductVendor WHERE LoadBatchID=@B;
SELECT * INTO #PurchaseOrderHeader FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B;
SELECT * INTO #SalesOrderHeader FROM stg.SalesOrderHeader WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM #SalesOrderHeader UNION ALL SELECT MAX(OrderDate) FROM #PurchaseOrderHeader UNION ALL SELECT MAX(StartDate) FROM #WorkOrder) X);
DELETE FROM dw.Fact_ProductVendorTerms;
INSERT dw.Fact_ProductVendorTerms ([ProductKey],[VendorKey],[AsOfDateKey],[UnitMeasureKey],[AverageLeadTime],[StandardPrice],[LastReceiptCost],[LastReceiptDateKey],[MinOrderQty],[MaxOrderQty],[OnOrderQty],[IsOrderQtyRangeValid],[LoadBatchID],[LoadedAt])
SELECT COALESCE(P.ProductKey,0),
 COALESCE(V.VendorKey,0),
 etl.DateKey(@AsOf),
 COALESCE(U.UnitMeasureKey,0),
 PV.AverageLeadTime,
 PV.StandardPrice,
 PV.LastReceiptCost,
 IIF(PV.LastReceiptDate IS NULL,-1,etl.DateKey(PV.LastReceiptDate)),
 PV.MinOrderQty,
 PV.MaxOrderQty,
 PV.OnOrderQty,
 IIF(PV.MaxOrderQty>=PV.MinOrderQty,1,0),
 @B,
 SYSUTCDATETIME()
FROM #ProductVendor PV LEFT JOIN dw.Dim_Product P ON P.ProductID=PV.ProductID LEFT JOIN dw.Dim_Vendor V ON V.VendorID=PV.BusinessEntityID LEFT JOIN dw.Dim_UnitMeasure U ON U.UnitMeasureCode=RTRIM(PV.UnitMeasureCode);

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspLoadWorkOrders] @B bigint AS
BEGIN
SET NOCOUNT ON; SET XACT_ABORT ON;
IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING') THROW 51000,'Batch is not RUNNING.',1;
SELECT * INTO #WorkOrder FROM stg.WorkOrder WHERE LoadBatchID=@B;
SELECT * INTO #WorkOrderRouting FROM stg.WorkOrderRouting WHERE LoadBatchID=@B;
BEGIN TRY
BEGIN TRAN;
DELETE FROM dw.Fact_WorkOrder;
INSERT dw.Fact_WorkOrder ([WorkOrderID],[ProductKey],[ScrapReasonKey],[StartDateKey],[DueDateKey],[EndDateKey],[ActualStartDateKey],[ActualEndDateKey],[OrderQty],[StockedQty],[ScrappedQty],[PlannedLeadTimeDays],[RecordedLeadTimeDays],[ActualLeadTimeDays],[LateDays],[OperationCount],[TotalActualResourceHrs],[TotalPlannedCost],[TotalActualCost],[StartAt],[DueAt],[EndAt],[ActualStartAt],[ActualEndAt],[IsComplete],[DQReasonCode],[DQRuleVersion],[LoadBatchID],[LoadedAt])
SELECT W.WorkOrderID,
 COALESCE(P.ProductKey,0),
 COALESCE(S.ScrapReasonKey,0),
 etl.DateKey(W.StartDate),
 etl.DateKey(W.DueDate),
 IIF(W.EndDate IS NULL,-1,etl.DateKey(W.EndDate)),
 IIF(A.ActualStart IS NULL,-1,etl.DateKey(A.ActualStart)),
 IIF(L.ActualEndDate IS NULL,-1,etl.DateKey(L.ActualEndDate)),
 W.OrderQty,
 W.StockedQty,
 W.ScrappedQty,
 DATEDIFF(day,W.StartDate,W.DueDate),
 DATEDIFF(day,W.StartDate,W.EndDate),
 DATEDIFF(day,A.ActualStart,L.ActualEndDate),
 DATEDIFF(day,W.DueDate,L.ActualEndDate),
 COALESCE(A.OpCount,0),
 A.ResourceHrs,
 A.PlannedCost,
 A.ActualCost,
 W.StartDate,
 W.DueDate,
 W.EndDate,
 A.ActualStart,
 L.ActualEndDate,
 IIF(L.ActualEndDate IS NOT NULL,1,0),
 NULLIF(CONCAT_WS(',',CASE WHEN A.WorkOrderID IS NULL THEN 'WOR-01' END,CASE WHEN W.ScrappedQty>0 AND W.ScrapReasonID IS NULL THEN 'WOR-02' END,CASE WHEN W.ScrappedQty=0 AND W.ScrapReasonID IS NOT NULL THEN 'WOR-03' END,CASE WHEN W.EndDate<W.StartDate THEN 'WOR-04' END,CASE WHEN L.ActualEndDate<A.ActualStart THEN 'WOR-05' END),''),
 'DQ-v1',
 @B,
 SYSUTCDATETIME()
FROM #WorkOrder W LEFT JOIN (SELECT WorkOrderID,MIN(ActualStartDate) ActualStart,COUNT(*) OpCount,SUM(ActualResourceHrs) ResourceHrs,SUM(PlannedCost) PlannedCost,SUM(ActualCost) ActualCost FROM #WorkOrderRouting GROUP BY WorkOrderID) A ON A.WorkOrderID=W.WorkOrderID OUTER APPLY(SELECT TOP(1) ActualEndDate FROM #WorkOrderRouting R WHERE R.WorkOrderID=W.WorkOrderID ORDER BY OperationSequence DESC) L LEFT JOIN dw.Dim_Product P ON P.ProductID=W.ProductID LEFT JOIN dw.Dim_ScrapReason S ON S.ScrapReasonID=W.ScrapReasonID;

COMMIT;
END TRY BEGIN CATCH
IF @@TRANCOUNT>0 ROLLBACK; THROW; END CATCH
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE etl.uspSeedSystemMembers @B bigint AS
BEGIN
 SET NOCOUNT ON; SET XACT_ABORT ON;
 IF NOT EXISTS(SELECT 1 FROM etl.ETL_LoadBatch WHERE LoadBatchID=@B AND Status='RUNNING'
 AND PipelineName IN ('DWH_FULL','SYSTEM_SEED')) THROW 51200,'A RUNNING seed or DWH batch is required.',1;
 BEGIN TRY
  BEGIN TRAN;
  IF EXISTS(SELECT 1 FROM dw.Dim_Location WITH(UPDLOCK,HOLDLOCK) WHERE LocationKey=-1 AND LocationID IS NOT NULL)
   THROW 51201,'LocationKey -1 is already assigned to a physical source location.',1;
  IF NOT EXISTS(SELECT 1 FROM dw.Dim_Location WITH(UPDLOCK,HOLDLOCK) WHERE LocationKey=-1)
  BEGIN
   SET IDENTITY_INSERT dw.Dim_Location ON;
   INSERT dw.Dim_Location(LocationKey,LocationName,LocationType,HasProductionConflict,LoadBatchID,LoadedAt)
   VALUES(-1,N'Không áp dụng / toàn phạm vi',N'NOT_APPLICABLE',0,@B,SYSUTCDATETIME());
   SET IDENTITY_INSERT dw.Dim_Location OFF;
  END;
  COMMIT;
 END TRY BEGIN CATCH
  IF XACT_STATE()<>0 ROLLBACK;
  SET IDENTITY_INSERT dw.Dim_Location OFF;
  THROW;
 END CATCH;
END;
GO
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE   PROCEDURE [etl].[uspValidateAndFinish] @B bigint, @ValidationSummary nvarchar(max)=NULL OUTPUT, @ThrowOnFailure bit=1 AS
BEGIN
 SET @ValidationSummary=NULL;
 SET NOCOUNT ON; SET XACT_ABORT ON;
 DECLARE @Checks TABLE(CheckName nvarchar(160),Expected decimal(38,6),Actual decimal(38,6));
 INSERT @Checks SELECT 'STG_UnitMeasure' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[UnitMeasure]) Expected,(SELECT COUNT_BIG(*) FROM stg.[UnitMeasure] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_Location' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[Location]) Expected,(SELECT COUNT_BIG(*) FROM stg.[Location] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_Product' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[Product]) Expected,(SELECT COUNT_BIG(*) FROM stg.[Product] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductSubcategory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ProductSubcategory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductSubcategory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductCategory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ProductCategory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductCategory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ScrapReason' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ScrapReason]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ScrapReason] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_BillOfMaterials' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[BillOfMaterials]) Expected,(SELECT COUNT_BIG(*) FROM stg.[BillOfMaterials] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductCostHistory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ProductCostHistory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductCostHistory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductListPriceHistory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ProductListPriceHistory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductListPriceHistory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductInventory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[ProductInventory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductInventory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_WorkOrder' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[WorkOrder]) Expected,(SELECT COUNT_BIG(*) FROM stg.[WorkOrder] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_WorkOrderRouting' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[WorkOrderRouting]) Expected,(SELECT COUNT_BIG(*) FROM stg.[WorkOrderRouting] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_TransactionHistory' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[TransactionHistory]) Expected,(SELECT COUNT_BIG(*) FROM stg.[TransactionHistory] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_TransactionHistoryArchive' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Production].[TransactionHistoryArchive]) Expected,(SELECT COUNT_BIG(*) FROM stg.[TransactionHistoryArchive] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_Vendor' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Purchasing].[Vendor]) Expected,(SELECT COUNT_BIG(*) FROM stg.[Vendor] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_ProductVendor' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Purchasing].[ProductVendor]) Expected,(SELECT COUNT_BIG(*) FROM stg.[ProductVendor] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_PurchaseOrderHeader' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Purchasing].[PurchaseOrderHeader]) Expected,(SELECT COUNT_BIG(*) FROM stg.[PurchaseOrderHeader] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_PurchaseOrderDetail' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Purchasing].[PurchaseOrderDetail]) Expected,(SELECT COUNT_BIG(*) FROM stg.[PurchaseOrderDetail] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_SpecialOffer' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Sales].[SpecialOffer]) Expected,(SELECT COUNT_BIG(*) FROM stg.[SpecialOffer] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_SpecialOfferProduct' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Sales].[SpecialOfferProduct]) Expected,(SELECT COUNT_BIG(*) FROM stg.[SpecialOfferProduct] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_Customer' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Sales].[Customer]) Expected,(SELECT COUNT_BIG(*) FROM stg.[Customer] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_SalesOrderHeader' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Sales].[SalesOrderHeader]) Expected,(SELECT COUNT_BIG(*) FROM stg.[SalesOrderHeader] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'STG_SalesOrderDetail' CheckName,(SELECT COUNT_BIG(*) FROM CompanyX.[Sales].[SalesOrderDetail]) Expected,(SELECT COUNT_BIG(*) FROM stg.[SalesOrderDetail] WHERE LoadBatchID=@B) Actual
UNION ALL
SELECT 'DW_Dim_Product',(SELECT COUNT_BIG(*)+2 FROM stg.Product WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_Product)
UNION ALL
SELECT 'DW_Dim_UnitMeasure',(SELECT COUNT_BIG(*)+1 FROM stg.UnitMeasure WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_UnitMeasure)
UNION ALL
SELECT 'DW_Dim_Location',(SELECT COUNT_BIG(*)+2 FROM stg.Location WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_Location)
UNION ALL
SELECT 'DW_Dim_Vendor',(SELECT COUNT_BIG(*)+2 FROM stg.Vendor WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_Vendor)
UNION ALL
SELECT 'DW_Dim_Promotion',(SELECT COUNT_BIG(*)+1 FROM stg.SpecialOffer WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_Promotion)
UNION ALL
SELECT 'DW_Dim_Customer',(SELECT COUNT_BIG(*)+1 FROM stg.Customer WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_Customer)
UNION ALL
SELECT 'DW_Dim_ScrapReason',(SELECT COUNT_BIG(*)+1 FROM stg.ScrapReason WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Dim_ScrapReason)
UNION ALL
SELECT 'DW_Bridge_ProductPromotion',(SELECT COUNT_BIG(*)+0 FROM stg.SpecialOfferProduct WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Bridge_ProductPromotion)
UNION ALL
SELECT 'DW_Bridge_BillOfMaterials',(SELECT COUNT_BIG(*)+0 FROM stg.BillOfMaterials WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Bridge_BillOfMaterials)
UNION ALL
SELECT 'DW_Fact_SalesOrderLine',(SELECT COUNT_BIG(*)+0 FROM stg.SalesOrderDetail WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_SalesOrderLine)
UNION ALL
SELECT 'DW_Fact_PurchaseOrderLine',(SELECT COUNT_BIG(*)+0 FROM stg.PurchaseOrderDetail WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine)
UNION ALL
SELECT 'DW_Fact_ProductVendorTerms',(SELECT COUNT_BIG(*)+0 FROM stg.ProductVendor WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms)
UNION ALL
SELECT 'DW_Fact_WorkOrder',(SELECT COUNT_BIG(*)+0 FROM stg.WorkOrder WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_WorkOrder)
UNION ALL
SELECT 'DW_Fact_WorkOrderOperation',(SELECT COUNT_BIG(*)+0 FROM stg.WorkOrderRouting WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation)
UNION ALL
SELECT 'DW_Fact_InventoryOnHand',(SELECT COUNT_BIG(*)+0 FROM stg.ProductInventory WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Fact_InventoryOnHand)
UNION ALL
SELECT 'DW_PriceHistory',(SELECT COUNT_BIG(*) FROM stg.ProductCostHistory WHERE LoadBatchID=@B)+(SELECT COUNT_BIG(*) FROM stg.ProductListPriceHistory WHERE LoadBatchID=@B),(SELECT COUNT_BIG(*) FROM dw.Ref_ProductPriceHistory)
UNION ALL
SELECT 'SalesQty',(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM stg.SalesOrderDetail WHERE LoadBatchID=@B),(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM dw.Fact_SalesOrderLine)
UNION ALL
SELECT 'PurchaseQty',(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM stg.PurchaseOrderDetail WHERE LoadBatchID=@B),(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM dw.Fact_PurchaseOrderLine)
UNION ALL
SELECT 'InventoryQty',(SELECT COALESCE(SUM(CAST(Quantity AS decimal(28,6))),0) FROM stg.ProductInventory WHERE LoadBatchID=@B),(SELECT COALESCE(SUM(CAST(QuantityOnHand AS decimal(28,6))),0) FROM dw.Fact_InventoryOnHand)
UNION ALL
SELECT 'WorkQty',(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM stg.WorkOrder WHERE LoadBatchID=@B),(SELECT COALESCE(SUM(CAST(OrderQty AS decimal(28,6))),0) FROM dw.Fact_WorkOrder)
UNION ALL
SELECT 'ScrapQty',(SELECT COALESCE(SUM(CAST(ScrappedQty AS decimal(28,6))),0) FROM stg.WorkOrder WHERE LoadBatchID=@B),(SELECT COALESCE(SUM(CAST(ScrappedQty AS decimal(28,6))),0) FROM dw.Fact_WorkOrder)
UNION ALL
SELECT 'FK_dw.Bridge_ProductPromotion_ProductKey',0,COUNT_BIG(*) FROM dw.Bridge_ProductPromotion F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Bridge_ProductPromotion_PromotionKey',0,COUNT_BIG(*) FROM dw.Bridge_ProductPromotion F LEFT JOIN dw.Dim_Promotion D ON F.[PromotionKey]=D.[PromotionKey] WHERE F.[PromotionKey] IS NOT NULL AND D.[PromotionKey] IS NULL
UNION ALL
SELECT 'FK_dw.Bridge_BillOfMaterials_AssemblyProductKey',0,COUNT_BIG(*) FROM dw.Bridge_BillOfMaterials F LEFT JOIN dw.Dim_Product D ON F.[AssemblyProductKey]=D.[ProductKey] WHERE F.[AssemblyProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Bridge_BillOfMaterials_ComponentProductKey',0,COUNT_BIG(*) FROM dw.Bridge_BillOfMaterials F LEFT JOIN dw.Dim_Product D ON F.[ComponentProductKey]=D.[ProductKey] WHERE F.[ComponentProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Bridge_BillOfMaterials_UnitMeasureKey',0,COUNT_BIG(*) FROM dw.Bridge_BillOfMaterials F LEFT JOIN dw.Dim_UnitMeasure D ON F.[UnitMeasureKey]=D.[UnitMeasureKey] WHERE F.[UnitMeasureKey] IS NOT NULL AND D.[UnitMeasureKey] IS NULL
UNION ALL
SELECT 'FK_dw.Ref_ProductPriceHistory_ProductKey',0,COUNT_BIG(*) FROM dw.Ref_ProductPriceHistory F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_OrderDateKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Date D ON F.[OrderDateKey]=D.[DateKey] WHERE F.[OrderDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_DueDateKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Date D ON F.[DueDateKey]=D.[DateKey] WHERE F.[DueDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_ShipDateKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Date D ON F.[ShipDateKey]=D.[DateKey] WHERE F.[ShipDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_PromotionKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Promotion D ON F.[PromotionKey]=D.[PromotionKey] WHERE F.[PromotionKey] IS NOT NULL AND D.[PromotionKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_SalesStatusKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_SalesStatus D ON F.[SalesStatusKey]=D.[SalesStatusKey] WHERE F.[SalesStatusKey] IS NOT NULL AND D.[SalesStatusKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_CustomerKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Customer D ON F.[CustomerKey]=D.[CustomerKey] WHERE F.[CustomerKey] IS NOT NULL AND D.[CustomerKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_SalesOrderLine_ChannelKey',0,COUNT_BIG(*) FROM dw.Fact_SalesOrderLine F LEFT JOIN dw.Dim_Channel D ON F.[ChannelKey]=D.[ChannelKey] WHERE F.[ChannelKey] IS NOT NULL AND D.[ChannelKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_OrderDateKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_Date D ON F.[OrderDateKey]=D.[DateKey] WHERE F.[OrderDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_ExpectedShipDateKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_Date D ON F.[ExpectedShipDateKey]=D.[DateKey] WHERE F.[ExpectedShipDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_ExpectedReceiptDateKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_Date D ON F.[ExpectedReceiptDateKey]=D.[DateKey] WHERE F.[ExpectedReceiptDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_VendorKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_Vendor D ON F.[VendorKey]=D.[VendorKey] WHERE F.[VendorKey] IS NOT NULL AND D.[VendorKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_PurchaseOrderLine_PurchaseStatusKey',0,COUNT_BIG(*) FROM dw.Fact_PurchaseOrderLine F LEFT JOIN dw.Dim_PurchaseStatus D ON F.[PurchaseStatusKey]=D.[PurchaseStatusKey] WHERE F.[PurchaseStatusKey] IS NOT NULL AND D.[PurchaseStatusKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_ProductVendorTerms_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_ProductVendorTerms_VendorKey',0,COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms F LEFT JOIN dw.Dim_Vendor D ON F.[VendorKey]=D.[VendorKey] WHERE F.[VendorKey] IS NOT NULL AND D.[VendorKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_ProductVendorTerms_AsOfDateKey',0,COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms F LEFT JOIN dw.Dim_Date D ON F.[AsOfDateKey]=D.[DateKey] WHERE F.[AsOfDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_ProductVendorTerms_UnitMeasureKey',0,COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms F LEFT JOIN dw.Dim_UnitMeasure D ON F.[UnitMeasureKey]=D.[UnitMeasureKey] WHERE F.[UnitMeasureKey] IS NOT NULL AND D.[UnitMeasureKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_ProductVendorTerms_LastReceiptDateKey',0,COUNT_BIG(*) FROM dw.Fact_ProductVendorTerms F LEFT JOIN dw.Dim_Date D ON F.[LastReceiptDateKey]=D.[DateKey] WHERE F.[LastReceiptDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_LocationKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Location D ON F.[LocationKey]=D.[LocationKey] WHERE F.[LocationKey] IS NOT NULL AND D.[LocationKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_ScheduledStartDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Date D ON F.[ScheduledStartDateKey]=D.[DateKey] WHERE F.[ScheduledStartDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_ScheduledEndDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Date D ON F.[ScheduledEndDateKey]=D.[DateKey] WHERE F.[ScheduledEndDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_ActualStartDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Date D ON F.[ActualStartDateKey]=D.[DateKey] WHERE F.[ActualStartDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrderOperation_ActualEndDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrderOperation F LEFT JOIN dw.Dim_Date D ON F.[ActualEndDateKey]=D.[DateKey] WHERE F.[ActualEndDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_InventoryOnHand_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_InventoryOnHand F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_InventoryOnHand_LocationKey',0,COUNT_BIG(*) FROM dw.Fact_InventoryOnHand F LEFT JOIN dw.Dim_Location D ON F.[LocationKey]=D.[LocationKey] WHERE F.[LocationKey] IS NOT NULL AND D.[LocationKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_InventoryOnHand_AsOfDateKey',0,COUNT_BIG(*) FROM dw.Fact_InventoryOnHand F LEFT JOIN dw.Dim_Date D ON F.[AsOfDateKey]=D.[DateKey] WHERE F.[AsOfDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_ProductKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Product D ON F.[ProductKey]=D.[ProductKey] WHERE F.[ProductKey] IS NOT NULL AND D.[ProductKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_ScrapReasonKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_ScrapReason D ON F.[ScrapReasonKey]=D.[ScrapReasonKey] WHERE F.[ScrapReasonKey] IS NOT NULL AND D.[ScrapReasonKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_StartDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Date D ON F.[StartDateKey]=D.[DateKey] WHERE F.[StartDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_DueDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Date D ON F.[DueDateKey]=D.[DateKey] WHERE F.[DueDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_EndDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Date D ON F.[EndDateKey]=D.[DateKey] WHERE F.[EndDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_ActualStartDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Date D ON F.[ActualStartDateKey]=D.[DateKey] WHERE F.[ActualStartDateKey] IS NOT NULL AND D.[DateKey] IS NULL
UNION ALL
SELECT 'FK_dw.Fact_WorkOrder_ActualEndDateKey',0,COUNT_BIG(*) FROM dw.Fact_WorkOrder F LEFT JOIN dw.Dim_Date D ON F.[ActualEndDateKey]=D.[DateKey] WHERE F.[ActualEndDateKey] IS NOT NULL AND D.[DateKey] IS NULL;
 INSERT @Checks
 SELECT N'DEM-v1 independent quantity',
  COALESCE((SELECT SUM(CONVERT(decimal(19,4),S.OrderQty)) FROM dw.Fact_SalesOrderLine S JOIN dw.Dim_Product P ON P.ProductKey=S.ProductKey WHERE S.IsDemandEligible=1 AND P.ProductKey>0 AND COALESCE(P.DQStatus,N'')<>N'EXCLUDED'),0),
  COALESCE((SELECT SUM(IndependentQty) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=N'DEM-v1' AND LoadBatchID=@B),0)
 UNION ALL
 SELECT N'DEM-v1 dependent quantity',
  COALESCE((SELECT SUM(CONVERT(decimal(19,4),W.OrderQty)*CONVERT(decimal(8,2),B.PerAssemblyQty))
   FROM dw.Fact_WorkOrder W JOIN dw.Bridge_BillOfMaterials B ON B.AssemblyProductKey=W.ProductKey
   JOIN dw.Dim_Product A ON A.ProductKey=W.ProductKey JOIN dw.Dim_Product C ON C.ProductKey=B.ComponentProductKey
   WHERE A.ProductKey>0 AND C.ProductKey>0 AND COALESCE(A.DQStatus,N'')<>N'EXCLUDED' AND COALESCE(C.DQStatus,N'')<>N'EXCLUDED'
   AND B.IsStructureValid=1 AND B.StartDate<=W.StartAt AND (B.EndDate IS NULL OR B.EndDate>W.StartAt)),0),
  COALESCE((SELECT SUM(DependentQty) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=N'DEM-v1' AND LoadBatchID=@B),0)
 UNION ALL
 SELECT N'DEM-v1 stale batch rows',0,COUNT_BIG(*) FROM dss.Fact_DemandDaily WHERE DemandRuleVersion=N'DEM-v1' AND LoadBatchID<>@B
 UNION ALL
 SELECT N'DEM-v1 total equals components',0,COUNT_BIG(*) FROM dss.Fact_DemandDaily
 WHERE DemandRuleVersion=N'DEM-v1' AND (TotalDemandQty IS NULL OR IndependentQty IS NULL OR DependentQty IS NULL OR TotalDemandQty<>IndependentQty+DependentQty);

 DECLARE @Quality TABLE(TableName nvarchar(128),RuleID nvarchar(100),AffectedRows bigint);
 INSERT @Quality SELECT 'dw.Dim_Promotion' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Dim_Promotion CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Dim_Product' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Dim_Product CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Bridge_BillOfMaterials' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Bridge_BillOfMaterials CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Fact_SalesOrderLine CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Fact_PurchaseOrderLine' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Fact_PurchaseOrderLine CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Fact_WorkOrderOperation' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Fact_WorkOrderOperation CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value UNION ALL SELECT 'dw.Fact_WorkOrder' TableName,S.value RuleID,COUNT_BIG(*) AffectedRows FROM dw.Fact_WorkOrder CROSS APPLY STRING_SPLIT(DQReasonCode,',') S GROUP BY S.value;
 DECLARE @Unknown TABLE(TableName nvarchar(128),ColumnName nvarchar(128),TotalRows bigint,UnknownRows bigint);
 INSERT @Unknown SELECT 'dw.Bridge_ProductPromotion' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Bridge_ProductPromotion UNION ALL SELECT 'dw.Bridge_ProductPromotion' TableName,'PromotionKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([PromotionKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Bridge_ProductPromotion UNION ALL SELECT 'dw.Bridge_BillOfMaterials' TableName,'AssemblyProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([AssemblyProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Bridge_BillOfMaterials UNION ALL SELECT 'dw.Bridge_BillOfMaterials' TableName,'ComponentProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ComponentProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Bridge_BillOfMaterials UNION ALL SELECT 'dw.Bridge_BillOfMaterials' TableName,'UnitMeasureKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([UnitMeasureKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Bridge_BillOfMaterials UNION ALL SELECT 'dw.Ref_ProductPriceHistory' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Ref_ProductPriceHistory UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_SalesOrderLine UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,'PromotionKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([PromotionKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_SalesOrderLine UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,'SalesStatusKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([SalesStatusKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_SalesOrderLine UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,'CustomerKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([CustomerKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_SalesOrderLine UNION ALL SELECT 'dw.Fact_SalesOrderLine' TableName,'ChannelKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ChannelKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_SalesOrderLine UNION ALL SELECT 'dw.Fact_PurchaseOrderLine' TableName,'VendorKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([VendorKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_PurchaseOrderLine UNION ALL SELECT 'dw.Fact_PurchaseOrderLine' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_PurchaseOrderLine UNION ALL SELECT 'dw.Fact_PurchaseOrderLine' TableName,'PurchaseStatusKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([PurchaseStatusKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_PurchaseOrderLine UNION ALL SELECT 'dw.Fact_ProductVendorTerms' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_ProductVendorTerms UNION ALL SELECT 'dw.Fact_ProductVendorTerms' TableName,'VendorKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([VendorKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_ProductVendorTerms UNION ALL SELECT 'dw.Fact_ProductVendorTerms' TableName,'UnitMeasureKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([UnitMeasureKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_ProductVendorTerms UNION ALL SELECT 'dw.Fact_WorkOrderOperation' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_WorkOrderOperation UNION ALL SELECT 'dw.Fact_WorkOrderOperation' TableName,'LocationKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([LocationKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_WorkOrderOperation UNION ALL SELECT 'dw.Fact_InventoryOnHand' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_InventoryOnHand UNION ALL SELECT 'dw.Fact_InventoryOnHand' TableName,'LocationKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([LocationKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_InventoryOnHand UNION ALL SELECT 'dw.Fact_WorkOrder' TableName,'ProductKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(IIF([ProductKey]=0,1,0) AS bigint)),0) UnknownRows FROM dw.Fact_WorkOrder UNION ALL SELECT 'dw.Fact_WorkOrder' TableName,'ScrapReasonKey' ColumnName,COUNT_BIG(*) TotalRows,COALESCE(SUM(CAST(CASE WHEN W.ScrapReasonID IS NOT NULL AND F.ScrapReasonKey=0 THEN 1 ELSE 0 END AS bigint)),0) UnknownRows FROM dw.Fact_WorkOrder F JOIN stg.WorkOrder W ON W.WorkOrderID=F.WorkOrderID AND W.LoadBatchID=@B;
 DECLARE @AsOf date=(SELECT MAX(d) FROM (SELECT MAX(OrderDate) d FROM stg.SalesOrderHeader WHERE LoadBatchID=@B UNION ALL SELECT MAX(OrderDate) FROM stg.PurchaseOrderHeader WHERE LoadBatchID=@B UNION ALL SELECT MAX(StartDate) FROM stg.WorkOrder WHERE LoadBatchID=@B) X);
 DECLARE @Json nvarchar(max)=(SELECT @AsOf AsOfDate,'DWH plus historical daily demand; simulation not executed' Scope,N'G03_MAX_ACTIVITY_DATE_ASSUMED' AsOfRule,N'Assumed reporting date, not a verified inventory observation timestamp' AsOfMeaning,
 JSON_QUERY((SELECT * FROM @Checks FOR JSON PATH)) Checks,
 JSON_QUERY((SELECT * FROM @Quality FOR JSON PATH)) DataQuality,
 JSON_QUERY((SELECT * FROM @Unknown FOR JSON PATH)) UnknownKeys FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 SET @ValidationSummary=@Json;
 IF EXISTS(SELECT 1 FROM @Checks WHERE Expected<>Actual OR Actual IS NULL)
 BEGIN
   -- Return normally to copy the full OUTPUT value to the load coordinator.
   -- THROW here would not reliably copy OUTPUT parameters back to its caller.
   IF @ThrowOnFailure=0 RETURN 1;
   -- Preserve legacy standalone use; transactional callers use uspLoadDWH.
   EXEC etl.uspFailBatch @B,N'Mandatory reconciliation failed. See validation result.',@Json;
  SELECT * FROM @Checks WHERE Expected<>Actual OR Actual IS NULL;
  THROW 51000,'Mandatory reconciliation failed. See validation result.',1;
 END;
 UPDATE etl.ETL_LoadBatch SET ValidationSummary=@Json,ValidationStatus=CASE WHEN EXISTS(SELECT 1 FROM @Quality) OR EXISTS(SELECT 1 FROM @Unknown WHERE CONVERT(decimal(38,6),UnknownRows)>CONVERT(decimal(38,6),TotalRows)*0.01) THEN 'PASSED_WITH_WARNINGS' ELSE 'PASSED' END,Status='SUCCEEDED',LoadCompletedAt=SYSUTCDATETIME() WHERE LoadBatchID=@B;
 SELECT CheckName,Expected,Actual FROM @Checks;
 RETURN 0;
END;
GO
EXEC sys.sp_addextendedproperty @name=N'CompanyXDeploymentOwner',@value=N'inventorysafety-production-deployment-20261028';
GO
EXEC sys.sp_addextendedproperty @name=N'InventorySafetyPatch',@value=N'V6.3.1-20261028-peer-scenarios';
GO

EXEC sys.sp_addextendedproperty @name=N'CompanyXSSISDeployment',@value=N'SSIS_20261029';
GO

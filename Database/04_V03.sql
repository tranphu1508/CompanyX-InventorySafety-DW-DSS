IF DB_NAME() IN (N'InventorySafety',N'CompanyX',N'master',N'model',N'msdb',N'tempdb') THROW 51700,'Protected database',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE name=N'CompanyXSSISDeployment' AND CONVERT(nvarchar(100),value)=N'SSIS_20261029') THROW 51701,'Target is not this package deployment',1;
IF OBJECT_ID(N'dss.InputSnapshot_ProductionLeadTime', N'U') IS NULL
BEGIN
CREATE TABLE dss.InputSnapshot_ProductionLeadTime (
 [InputSnapshotKey] bigint NOT NULL,
 [ProductKey] int NOT NULL,
 [LpDays] int NOT NULL,
 [L90Days] int NOT NULL,
 [MedianLeadTimeDays] decimal(10,1) NOT NULL,
 [ObservationCount] int NOT NULL,
 [LastHistoryCompletionDate] date NOT NULL,
 [HistoryCutoffExclusive] date NOT NULL,
 [LeadTimeUnit] varchar(16) NOT NULL,
 [LeadTimeSource] varchar(32) NOT NULL,
 [SourceMeasure] nvarchar(256) NOT NULL,
 [ObservationFormula] nvarchar(256) NOT NULL,
 [SampleFilter] nvarchar(1000) NOT NULL,
 [MedianFormula] nvarchar(512) NOT NULL,
 [LpFormula] nvarchar(256) NOT NULL,
 [L90Formula] nvarchar(256) NOT NULL,
 [FallbackRule] nvarchar(256) NOT NULL,
 [SourceArtifactHash] char(64) NOT NULL,
 [SourceJsonPath] nvarchar(256) NOT NULL,
 [SourceParameterJson] nvarchar(max) NOT NULL,
 [SourceParameterHash] char(64) NOT NULL,
 [SourceWorkOrderHash] char(64) NOT NULL,
 [EstimatorCodeHash] char(64) NOT NULL,
 [EstimatorReference] nvarchar(512) NOT NULL,
 [MaterializationMode] varchar(32) NOT NULL,
 [MaterializedAt] datetime2(7) NOT NULL CONSTRAINT DF_V03_MaterializedAt DEFAULT SYSUTCDATETIME(),
 CONSTRAINT PK_V03_InputSnapshot_ProductionLeadTime PRIMARY KEY (InputSnapshotKey,ProductKey),
 CONSTRAINT FK_V03_Lead_InputSnapshot FOREIGN KEY (InputSnapshotKey) REFERENCES dss.Dim_InputSnapshot(InputSnapshotKey),
 CONSTRAINT FK_V03_Lead_Product FOREIGN KEY (ProductKey) REFERENCES dw.Dim_Product(ProductKey),
 CONSTRAINT FK_V03_Lead_Artifact FOREIGN KEY (SourceArtifactHash) REFERENCES dss.ArtifactObject(ArtifactHash),
 CONSTRAINT CK_V03_Positive CHECK (LpDays>0 AND L90Days>0 AND MedianLeadTimeDays>0 AND ObservationCount>0),
 CONSTRAINT CK_V03_Cutoff CHECK (LastHistoryCompletionDate<HistoryCutoffExclusive),
 CONSTRAINT CK_V03_CopyMode CHECK (MaterializationMode='COPY_FROZEN_VALUES' AND LeadTimeUnit='CALENDAR_DAY' AND LeadTimeSource='WORKORDER_RECORDED'),
 CONSTRAINT CK_V03_Json CHECK(ISJSON(SourceParameterJson)=1)
);
END;

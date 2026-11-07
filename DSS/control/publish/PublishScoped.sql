-- CompanyX: native SSIS Execute SQL publication. SQL Server 2022, local demo only.
-- Derived scoped publisher: only the owned copied warehouse; original core remains intact.
-- OLE DB parameters (ordinal): PackageRoot, OutputFolder, SourceDatabase.
SET NOCOUNT ON; SET XACT_ABORT ON; SET ANSI_NULLS ON; SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET QUOTED_IDENTIFIER ON;
SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
DECLARE @root nvarchar(4000)=?, @folder nvarchar(4000)=?, @source sysname=?;
SET @root=REPLACE(@root,'/','\'); SET @folder=REPLACE(@folder,'/','\');
IF RIGHT(@root,1)='\' SET @root=LEFT(@root,LEN(@root)-1);
IF RIGHT(@folder,1)='\' SET @folder=LEFT(@folder,LEN(@folder)-1);
IF DB_NAME()<>'CompanyX_DW_SIM_20261107' OR @source<>'CompanyX_Demo'
 OR DB_NAME() LIKE '%[^a-zA-Z0-9_]%' OR @source LIKE '%[^a-zA-Z0-9_]%'
 THROW 51000,'Only isolated demo databases are allowed',1;
IF @root NOT LIKE '[A-Za-z]:\%' OR @folder NOT LIKE '[A-Za-z]:\%'
 OR @root LIKE '%..%' OR @folder LIKE '%..%'
 THROW 51000,'Use absolute local paths without parent traversal',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXDemoOwner' AND CONVERT(nvarchar(100),value)='CompanyX_Demo_20261103')
 THROW 51000,'Unowned target database',1;
IF NOT EXISTS(SELECT 1 FROM sys.extended_properties WHERE class=0 AND name='CompanyXSplitOwner' AND CONVERT(nvarchar(100),value)='companyx-split-20261107') THROW 51000,'Missing MOLAP copy ownership marker',1;
IF NOT EXISTS(SELECT 1 FROM etl_v2.State WHERE SourceDatabase=@source)
 THROW 51000,'Wrong ETL source binding',1;
IF NOT EXISTS(SELECT 1 FROM sim_etl.LoadBatch WHERE PipelineName='DWH_INCREMENTAL_V2' AND Status='SUCCEEDED' AND ValidationStatus IN ('PASSED','PASSED_WITH_WARNINGS'))
 THROW 51000,'No validated ETL batch',1;
DECLARE @path nvarchar(4000),@raw varbinary(max),@json nvarchar(max),@sql nvarchar(max),@message nvarchar(2048),@lock int;
CREATE TABLE #file_exists(FileExists int,IsDirectory int,ParentExists int);
SET @path=@folder+'\RUNNING.lock'; INSERT #file_exists EXEC master.dbo.xp_fileexist @path;
SET @path=@folder+'\DW_PUBLISH.lock'; INSERT #file_exists EXEC master.dbo.xp_fileexist @path;
IF EXISTS(SELECT 1 FROM #file_exists WHERE FileExists=1) THROW 51000,'Simulation/publication lock exists; inspect it before retry',1;
CREATE TABLE #files(Name nvarchar(300) PRIMARY KEY,Path nvarchar(4000),Raw varbinary(max),Json nvarchar(max),Hash varchar(64));
EXEC(N'CREATE PROCEDURE #read_file @path nvarchar(4000),@raw varbinary(max) OUTPUT,@json nvarchar(max) OUTPUT AS
BEGIN
 SET NOCOUNT ON;
 SET @raw=0x; SET @json=CONVERT(nvarchar(max),0x);
 DECLARE @sql nvarchar(max)=N''SELECT @r=BulkColumn FROM OPENROWSET(BULK N''+NCHAR(39)+REPLACE(@path,NCHAR(39),NCHAR(39)+NCHAR(39))+NCHAR(39)+N'',SINGLE_BLOB) f'';
 EXEC sys.sp_executesql @sql,N''@r varbinary(max) OUTPUT'',@raw OUTPUT;
 SET @json=CONVERT(nvarchar(max),CONVERT(varchar(max),@raw) COLLATE Latin1_General_100_BIN2_UTF8);
END');
BEGIN TRY
 BEGIN TRANSACTION;
 EXEC @lock=sys.sp_getapplock @Resource='CompanyX_SSIS_NATIVE_IO',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
 IF @lock<0 THROW 51000,'Another native SSIS operation owns this database',1;
 EXEC @lock=sys.sp_getapplock @Resource='InventorySafety_FullLoad',@LockMode='Exclusive',@LockOwner='Transaction',@LockTimeout=0;
 IF @lock<0 THROW 51000,'ETL is active; retry after it completes',1;
 DECLARE @name nvarchar(300);
 DECLARE files CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'run.json|execution_spec.json|input.json|input_source.json|execution_profile.json|completion.json|table_manifest.json|simulation_export.json|metrics.json|simulation_selection.json|dw_source_proof.json|scope.json|run.json.canonical|execution_spec.json.canonical|input.json.canonical|input_source.json.canonical|execution_profile.json.canonical','|');
 OPEN files; FETCH NEXT FROM files INTO @name;
 WHILE @@FETCH_STATUS=0 BEGIN
  SET @path=@folder+'\'+@name; EXEC #read_file @path,@raw OUTPUT,@json OUTPUT;
  IF ISJSON(@json)<>1 THROW 51000,'Invalid JSON metadata',1;
  INSERT #files VALUES(@name,@path,@raw,@json,LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',@raw),2)));
  FETCH NEXT FROM files INTO @name;
 END; CLOSE files; DEALLOCATE files;
 DECLARE defs CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM STRING_SPLIT(N'SSIS/core_identity.json|SSIS/core_hashes.json|SSIS/schema_pin.json|SSIS/event_catalog.json|SSIS/relation_types.json|DSS/inputs/V03_FrozenLeadValues.json','|');
 OPEN defs; FETCH NEXT FROM defs INTO @name;
 WHILE @@FETCH_STATUS=0 BEGIN
  SET @path=@root+'\'+REPLACE(@name,'/','\'); EXEC #read_file @path,@raw OUTPUT,@json OUTPUT;
  INSERT #files VALUES(@name,@path,@raw,@json,LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',@raw),2)));
  FETCH NEXT FROM defs INTO @name;
 END; CLOSE defs; DEALLOCATE defs;
 DECLARE @expected varchar(64),@core nvarchar(max)=(SELECT Json FROM #files WHERE Name='SSIS/core_hashes.json');
 DECLARE corefiles CURSOR LOCAL FAST_FORWARD FOR SELECT [key],value FROM OPENJSON(@core);
 OPEN corefiles; FETCH NEXT FROM corefiles INTO @name,@expected;
 WHILE @@FETCH_STATUS=0 BEGIN
  IF @name LIKE '%..%' OR @name LIKE '%:%' THROW 51000,'Invalid core path',1;
  SET @path=@root+'\'+REPLACE(@name,'/','\'); EXEC #read_file @path,@raw OUTPUT,@json OUTPUT;
  IF LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',@raw),2))<>@expected BEGIN
   SET @message='Protected core changed: '+@name; THROW 51000,@message,1;
  END;
  INSERT #files VALUES('core/'+@name,@path,NULL,NULL,@expected);
  FETCH NEXT FROM corefiles INTO @name,@expected;
 END; CLOSE corefiles; DEALLOCATE corefiles;
 DECLARE @pin nvarchar(max)=(SELECT Json FROM #files WHERE Name='SSIS/schema_pin.json');
 IF EXISTS(SELECT TableName,ColumnName,TypeName,MaxLength,[Precision],Scale,IsNullable,IsIdentity
 FROM OPENJSON(@pin,'$.columns') WITH(TableName nvarchar(200),ColumnName sysname,TypeName sysname,MaxLength int,[Precision] int,Scale int,IsNullable bit,IsIdentity bit)
 EXCEPT SELECT s.name+'.'+t.name,c.name,ty.name,c.max_length,c.precision,c.scale,c.is_nullable,c.is_identity
 FROM sys.tables t JOIN sys.schemas s ON t.schema_id=s.schema_id JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id)
 THROW 51000,'Warehouse column contract changed',1;
 DECLARE @run nvarchar(max)=(SELECT Json FROM #files WHERE Name='run.json.canonical'),
 @spec nvarchar(max)=(SELECT Json FROM #files WHERE Name='execution_spec.json.canonical'),
 @snapshot nvarchar(max)=(SELECT Json FROM #files WHERE Name='input.json.canonical'),
 @original nvarchar(max)=(SELECT Json FROM #files WHERE Name='input_source.json.canonical'),
 @profile nvarchar(max)=(SELECT Json FROM #files WHERE Name='execution_profile.json.canonical'),
 @completion nvarchar(max)=(SELECT Json FROM #files WHERE Name='completion.json'),
 @manifest nvarchar(max)=(SELECT Json FROM #files WHERE Name='table_manifest.json'),
 @export nvarchar(max)=(SELECT Json FROM #files WHERE Name='simulation_export.json'),
 @metrics nvarchar(max)=(SELECT Json FROM #files WHERE Name='metrics.json'),
 @selection nvarchar(max)=(SELECT Json FROM #files WHERE Name='simulation_selection.json'),
 @scope nvarchar(max)=(SELECT Json FROM #files WHERE Name='scope.json');
 DECLARE @runCode uniqueidentifier=CONVERT(uniqueidentifier,JSON_VALUE(@run,'$.RunCode')),
 @days int=DATEDIFF(day,CONVERT(date,JSON_VALUE(@run,'$.start')),CONVERT(date,JSON_VALUE(@run,'$.end')))+1,
 @policy nvarchar(50)=JSON_VALUE(@spec,'$.policy'),@version nvarchar(50)='companyx.control.v1',
 @coreHash varchar(64)=JSON_VALUE((SELECT Json FROM #files WHERE Name='SSIS/core_identity.json'),'$.code_sha256'),
 @completionHash varchar(64)=(SELECT Hash FROM #files WHERE Name='completion.json');
 IF ISNULL(JSON_VALUE(@run,'$.schema'),'')<>'companyx.unified.run.v2' OR ISNULL(JSON_VALUE(@completion,'$.status'),'')<>'COMPLETE'
 OR ISNULL(JSON_VALUE(@export,'$.schema'),'')<>@version OR @runCode IS NULL OR @days<1
 OR ISNULL(JSON_VALUE(@run,'$.code_sha256'),'')<>@coreHash OR ISNULL(JSON_VALUE(@export,'$.core_sha256'),'')<>@coreHash
 OR ISNULL(JSON_VALUE(@completion,'$.RunCode'),'')<>CONVERT(nvarchar(36),@runCode)
 OR ISNULL(JSON_VALUE(@manifest,'$.RunCode'),'')<>CONVERT(nvarchar(36),@runCode)
 OR ISNULL(TRY_CONVERT(int,JSON_VALUE(@completion,'$.completed_days')),-1)<>@days
 THROW 51000,'Incomplete or incompatible simulation artifact',1;
 IF ISNULL(JSON_VALUE(@completion,'$.table_manifest_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='table_manifest.json')
 OR ISNULL(JSON_VALUE(@completion,'$.metrics_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='metrics.json')
 OR ISNULL(JSON_VALUE(@export,'$.completion_sha256'),'')<>@completionHash
 OR ISNULL(JSON_VALUE(@run,'$.input_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='input.json.canonical')
 OR ISNULL(JSON_VALUE(@run,'$.execution_spec_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='execution_spec.json.canonical')
 THROW 51000,'Metadata checksum mismatch',1;
 IF (SELECT COUNT(*) FROM OPENJSON(@export,'$.canonical_files'))<>5 OR EXISTS(
 SELECT 1 FROM OPENJSON(@export,'$.canonical_files') c LEFT JOIN #files f ON f.Name=c.[key] COLLATE DATABASE_DEFAULT+'.canonical'
 WHERE f.Name IS NULL OR f.Hash<>c.value) THROW 51000,'Canonical checksum mismatch',1;
 IF ISNULL(JSON_VALUE(@scope,'$.schema'),'')<>'companyx.control.scope.v1'
 OR ISNULL(JSON_VALUE(@scope,'$.initial_state_mode'),'')<>'NEW_EXPERIMENT'
 OR ISNULL(JSON_VALUE(@scope,'$.product_scope_mode'),'') NOT IN ('SELECTED_LINES','WHOLE_ORDERS')
 OR JSON_VALUE(@scope,'$.start')<>JSON_VALUE(@run,'$.start') OR JSON_VALUE(@scope,'$.end')<>JSON_VALUE(@run,'$.end')
 OR ISNULL(JSON_VALUE(@export,'$.scope_file_sha256'),'')<>(SELECT Hash FROM #files WHERE Name='scope.json')
 THROW 51000,'Scope contract mismatch',1;
 DECLARE @evaluation nvarchar(1000)=CONCAT('NEW_EXPERIMENT; ',JSON_VALUE(@scope,'$.evaluation_scope'),'; manufactured due-date service cohort; inventory includes selected roots and BOM dependencies; fixed historical assumptions; ',JSON_VALUE(@scope,'$.start'),'..',JSON_VALUE(@scope,'$.end'));
 -- Compare JSON trees, retaining array indexes, property names, types and long scalar values.
 CREATE TABLE #tree(Side int,Path nvarchar(max) COLLATE Latin1_General_100_BIN2,Value nvarchar(max) COLLATE Latin1_General_100_BIN2,Type int,Depth int);
 CREATE INDEX IX_tree_depth ON #tree(Depth,Type);
 CREATE TABLE #treeHash(Side int,Digest binary(32)); CREATE INDEX IX_treeHash ON #treeHash(Side,Digest);
 DECLARE canonical CURSOR LOCAL FAST_FORWARD FOR SELECT [key] FROM OPENJSON(@export,'$.canonical_files');
 OPEN canonical; FETCH NEXT FROM canonical INTO @name;
 WHILE @@FETCH_STATUS=0 BEGIN
  TRUNCATE TABLE #tree;
  INSERT #tree SELECT 0,N'$',Json,5,0 FROM #files WHERE Name=@name UNION ALL SELECT 1,N'$',Json,5,0 FROM #files WHERE Name=@name+'.canonical';
  DECLARE @depth int=0;
  WHILE EXISTS(SELECT 1 FROM #tree WHERE Depth=@depth AND Type IN(4,5)) BEGIN
   INSERT #tree SELECT t.Side,t.Path+N'/'+CONVERT(nvarchar(20),DATALENGTH(j.[key]))+N':'+j.[key],j.value,j.type,@depth+1 FROM #tree t CROSS APPLY OPENJSON(t.Value) j WHERE t.Depth=@depth AND t.Type IN(4,5);
   SET @depth+=1; IF @depth>100 THROW 51000,'Excessive JSON nesting',1;
  END;
  TRUNCATE TABLE #treeHash;
  INSERT #treeHash SELECT Side,HASHBYTES('SHA2_256',CONVERT(varbinary(max),CONCAT(CONVERT(nvarchar(max),DATALENGTH(Path)),N':',Path,N':',Type,N':',CASE WHEN Type IN(4,5) THEN NULL ELSE Value END))) FROM #tree;
  IF EXISTS(SELECT Digest FROM #treeHash GROUP BY Digest HAVING SUM(CASE WHEN Side=0 THEN CONVERT(bigint,1) ELSE CONVERT(bigint,-1) END)<>0)
   THROW 51000,'Canonical and readable JSON differ',1;
  FETCH NEXT FROM canonical INTO @name;
 END; CLOSE canonical; DEALLOCATE canonical;
 -- Recheck the same sales cohort and effective BOM as the original native adapter.
 SELECT * INTO #sales FROM OPENJSON(@original,'$.sales_order_lines') WITH(SalesOrderDetailID int,SalesOrderID int,ProductID int,OrderQty decimal(28,8),OrderDate date,DueDate date);
 SELECT f.SalesOrderDetailID,f.SalesOrderID,p.ProductID,CONVERT(decimal(28,8),f.OrderQty) OrderQty,
 CONVERT(date,CONVERT(char(8),f.OrderDateKey),112) OrderDate,CONVERT(date,CONVERT(char(8),f.DueDateKey),112) DueDate,f.IsDemandEligible
 INTO #actualSales FROM dw.Fact_SalesOrderLine f JOIN dw.Dim_Product p ON p.ProductKey=f.ProductKey
 WHERE (JSON_VALUE(@scope,'$.product_scope_mode')='WHOLE_ORDERS' AND f.SalesOrderID IN(SELECT SalesOrderID FROM #sales)) OR (JSON_VALUE(@scope,'$.product_scope_mode')='SELECTED_LINES' AND f.SalesOrderDetailID IN(SELECT SalesOrderDetailID FROM #sales));
 IF EXISTS(SELECT * FROM #sales EXCEPT SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,OrderDate,DueDate FROM #actualSales)
 OR EXISTS(SELECT SalesOrderDetailID,SalesOrderID,ProductID,OrderQty,OrderDate,DueDate FROM #actualSales EXCEPT SELECT * FROM #sales)
 OR (SELECT COUNT(*) FROM #sales)<>(SELECT COUNT(*) FROM #actualSales)
 OR EXISTS(SELECT 1 FROM #actualSales WHERE IsDemandEligible<>1) THROW 51000,'DW sales snapshot drift',1;
 SELECT * INTO #bom FROM OPENJSON(@original,'$.bom') WITH(ProductAssemblyID int,ComponentID int,PerAssemblyQty decimal(28,8),UnitMeasureCode nvarchar(10));
 SELECT a.ProductID ProductAssemblyID,c.ProductID ComponentID,CONVERT(decimal(28,8),b.PerAssemblyQty) PerAssemblyQty,RTRIM(u.UnitMeasureCode) UnitMeasureCode,b.IsStructureValid INTO #actualBom
 FROM dw.Bridge_BillOfMaterials b JOIN dw.Dim_Product a ON a.ProductKey=b.AssemblyProductKey JOIN dw.Dim_Product c ON c.ProductKey=b.ComponentProductKey JOIN dw.Dim_UnitMeasure u ON u.UnitMeasureKey=b.UnitMeasureKey
 WHERE a.ProductID IN(SELECT ProductID FROM OPENJSON(@original,'$.products') WITH(ProductID int,IsManufactured bit) WHERE IsManufactured=1)
 AND b.StartDate<=CONVERT(date,JSON_VALUE(@scope,'$.original_base_start')) AND (b.EndDate IS NULL OR b.EndDate>=CONVERT(date,JSON_VALUE(@scope,'$.original_base_start')));
 IF EXISTS(SELECT * FROM #bom EXCEPT SELECT ProductAssemblyID,ComponentID,PerAssemblyQty,UnitMeasureCode FROM #actualBom)
 OR EXISTS(SELECT ProductAssemblyID,ComponentID,PerAssemblyQty,UnitMeasureCode FROM #actualBom EXCEPT SELECT * FROM #bom)
 OR (SELECT COUNT(*) FROM #bom)<>(SELECT COUNT(*) FROM #actualBom)
 OR EXISTS(SELECT 1 FROM #actualBom WHERE IsStructureValid<>1) THROW 51000,'DW BOM snapshot drift',1;
 CREATE TABLE #payload(TableName sysname,RowNumber bigint,Payload nvarchar(max),PRIMARY KEY(TableName,RowNumber));
 DECLARE @rows bigint,@table sysname;
 DECLARE results CURSOR LOCAL FAST_FORWARD FOR SELECT [key],JSON_VALUE(value,'$.sha256'),CONVERT(bigint,JSON_VALUE(value,'$.rows')) FROM OPENJSON(@manifest,'$.tables');
 OPEN results; FETCH NEXT FROM results INTO @name,@expected,@rows;
 WHILE @@FETCH_STATUS=0 BEGIN
  IF @name NOT LIKE '%.jsonl' OR @name LIKE '%[/:\]%' OR @name LIKE '%..%' THROW 51000,'Unsafe manifest path',1;
  SET @path=@folder+'\tables\'+@name; EXEC #read_file @path,@raw OUTPUT,@json OUTPUT;
  IF LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',@raw),2))<>@expected BEGIN SET @message='Result checksum mismatch: '+@name; THROW 51000,@message,1; END;
  INSERT #files VALUES('tables/'+@name,@path,NULL,NULL,@expected);
  SET @table=LEFT(@name,LEN(@name)-6);
  INSERT #payload SELECT @table,ROW_NUMBER() OVER(ORDER BY ordinal),value FROM STRING_SPLIT(@json,CHAR(10),1) WHERE LEN(TRIM(REPLACE(value,CHAR(13),'')))>0;
  IF @@ROWCOUNT<>@rows THROW 51000,'Result row count mismatch',1;
  FETCH NEXT FROM results INTO @name,@expected,@rows;
 END; CLOSE results; DEALLOCATE results;
 IF EXISTS(SELECT 1 FROM #payload WHERE ISJSON(Payload)<>1) THROW 51000,'Malformed JSONL row',1;
 IF EXISTS(SELECT 1 FROM #payload WHERE ISNULL(TRY_CONVERT(uniqueidentifier,JSON_VALUE(Payload,'$.RunCode')),'00000000-0000-0000-0000-000000000000')<>@runCode) THROW 51000,'Cross-run result row',1;
 SELECT DISTINCT ProductID INTO #demandProducts FROM OPENJSON(@snapshot,'$.sales_order_lines') WITH(ProductID int);
 CREATE UNIQUE INDEX IX_demandProducts ON #demandProducts(ProductID);
 DECLARE @runKey int,@batchKey bigint,@scenarioKey bigint,@inputKey bigint,@experiment bigint,@replication bigint,@pt bigint,@pk bigint,@caseKey bigint,
 @delay bigint,@quality bigint,@existing bit=0,@code nvarchar(100)='CONTROL_'+REPLACE(CONVERT(nvarchar(36),@runCode),'-',''),
 @now datetime2=SYSUTCDATETIME(),@inputRef nvarchar(100)='db:sha256:'+(SELECT Hash FROM #files WHERE Name='input_source.json.canonical'),
 @specRef nvarchar(100)='db:sha256:'+(SELECT Hash FROM #files WHERE Name='execution_spec.json.canonical'),
 @stream nvarchar(100)='COMPANYX-SHA256-20261026-v1',@metricVersion nvarchar(100)='V6-G35-G36-G37;unified-0.1.3';
 SELECT @runKey=PlanningRunKey,@batchKey=LoadBatchID,@caseKey=ExperimentCaseKey FROM dss.Dim_PlanningRun WHERE RunCode=@runCode;

 CREATE TABLE #oldFacts(TableName sysname PRIMARY KEY,RowsBefore bigint,ChecksumBefore int);
 INSERT #oldFacts SELECT 'Fact_SimulationOrder',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationOrder WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'RunEntity',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.RunEntity WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Bridge_RunEntityRelation',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Bridge_RunEntityRelation WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_OptimizationSolve',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_OptimizationSolve WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_SimulationDaily',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationDaily WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_SimulationEvent',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationEvent WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_StochasticDraw',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_StochasticDraw WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_PolicySimulation',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_PolicySimulation WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 INSERT #oldFacts SELECT 'Fact_RunSummary',COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_RunSummary WHERE PlanningRunKey<>ISNULL(@runKey,-2147483648);
 IF @runKey IS NOT NULL BEGIN
  SET @existing=1;
  IF NOT EXISTS(SELECT 1 FROM dss.Dim_PlanningRun WHERE PlanningRunKey=@runKey AND RunStatus='SUCCEEDED') THROW 51000,'Existing nonterminal run requires review',1;
  IF NOT EXISTS(SELECT 1 FROM sim_etl.LoadBatch WHERE LoadBatchID=@batchKey AND PipelineName='DSS_RESULT' AND Status='SUCCEEDED' AND JSON_VALUE(ValidationSummary,'$.completion_sha256')=@completionHash) THROW 51000,'Existing publication proof mismatch',1;
  SELECT @scenarioKey=ScenarioVersionKey FROM dss.ExperimentCase WHERE ExperimentCaseKey=@caseKey;
 END ELSE BEGIN

INSERT sim_etl.LoadBatch(SourceSystem,PipelineName,ExtractionMode,LoadMode,RuleSetVersion,Status,ValidationStatus,LoadStartedAt,SourceSnapshotReference) VALUES('CompanyX SSIS native IO','DSS_RESULT','FULL','APPEND',@version,'RUNNING','PENDING',@now,'unified-run:'+CONVERT(nvarchar(36),@runCode)); SET @batchKey=SCOPE_IDENTITY();

DECLARE @catalog nvarchar(max)=(SELECT Json FROM #files WHERE Name='SSIS/event_catalog.json');

IF EXISTS (SELECT 1 FROM OPENJSON(@catalog) WITH(EventCode nvarchar(40),EntityType nvarchar(30)) c JOIN dss.Dim_EventType e ON c.EventCode=e.EventCode WHERE c.EntityType<>e.EntityType) THROW 51000,N'Event catalog conflict',1;

INSERT dss.Dim_EventType (EventCode,EventName,EntityType,QuantityMeaning,RequiredReferences) SELECT j.EventCode,j.EventName,j.EntityType,j.QuantityMeaning,j.RequiredReferences FROM OPENJSON(@catalog) WITH(EventCode nvarchar(1000),EventName nvarchar(1000),EntityType nvarchar(1000),QuantityMeaning nvarchar(1000),RequiredReferences nvarchar(1000)) j WHERE NOT EXISTS(SELECT 1 FROM dss.Dim_EventType e WHERE e.EventCode=j.EventCode);

DECLARE @hash varchar(64),@kind nvarchar(50),@compressed varbinary(max),@base64 varchar(max);
 DECLARE artifacts CURSOR LOCAL FAST_FORWARD FOR SELECT Raw,Hash,CASE WHEN Name IN('input_source.json.canonical','input.json.canonical') THEN 'INPUT_SNAPSHOT' ELSE 'EXECUTION_MANIFEST' END FROM #files WHERE Name LIKE '%.canonical';
 OPEN artifacts; FETCH NEXT FROM artifacts INTO @raw,@hash,@kind;
 WHILE @@FETCH_STATUS=0 BEGIN
  IF NOT EXISTS(SELECT 1 FROM dss.ArtifactObject WHERE ArtifactHash=@hash) BEGIN
   SET @compressed=COMPRESS(@raw); SET @base64=CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@compressed"))','varchar(max)');
   INSERT dss.ArtifactObject(ArtifactHash,ArtifactKind,Encoding,PayloadBase64) VALUES(@hash,@kind,'GZIP_JSON_UTF8_BASE64',@base64);
  END ELSE BEGIN
   SELECT @base64=PayloadBase64 FROM dss.ArtifactObject WHERE ArtifactHash=@hash;
   SET @compressed=CAST(N'' AS xml).value('xs:base64Binary(sql:variable("@base64"))','varbinary(max)');
   IF LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',DECOMPRESS(@compressed)),2))<>@hash THROW 51000,'Corrupt DW artifact',1;
  END;
  FETCH NEXT FROM artifacts INTO @raw,@hash,@kind;
 END; CLOSE artifacts; DEALLOCATE artifacts;

INSERT dss.Dim_InputSnapshot ([SnapshotCode],[SnapshotReference],[InputHash],[SnapshotAsOfAt],[SourceLoadBatchID],[SnapshotScope],[CreatedAt]) VALUES (@code+'_INPUT',@inputRef,SUBSTRING(@inputRef,11,64),JSON_VALUE(@snapshot,'$.start'),JSON_VALUE((SELECT Json FROM #files WHERE Name='dw_source_proof.json'),'$.etl_batch'),@evaluation,@now); SET @inputKey=SCOPE_IDENTITY();

INSERT dss.Dim_ExperimentVersion ([ExperimentCode],[VersionNo],[ExperimentName],[ResearchQuestion],[ChangedFactors],[ControlledFactors],[RandomizationMode],[RandomizationRuleVersion],[MetricDefinitionVersion],[PlannedReplicationCount],[LifecycleStatus],[ConfigHash],[PublishedAt]) VALUES (@code,1,JSON_VALUE(@run,'$.CaseName'),N'Reproduce CompanyX policy using unchanged numerical core',N'Policy, scenario, solver and production lead time mode','input='+JSON_VALUE(@run,'$.input_sha256')+';core='+JSON_VALUE(@run,'$.code_sha256'),'PAIRED_STREAMS',@stream,@metricVersion,1,'PUBLISHED',JSON_VALUE(@run,'$.execution_spec_sha256'),@now); SET @experiment=SCOPE_IDENTITY();

INSERT dss.ExperimentReplication ([ExperimentVersionKey],[ReplicationNo],[BaseSeed],[RandomStreamVersion]) VALUES (@experiment,CONVERT(int,JSON_VALUE(@spec,'$.replication'))+1,20261026,@stream); SET @replication=SCOPE_IDENTITY();

SELECT @pt=PolicyTypeKey FROM dss.Dim_PolicyType WHERE PolicyCode=@policy; IF @pt IS NULL BEGIN

INSERT dss.Dim_PolicyType ([PolicyCode],[PolicyName],[DecisionScope],[Description],[IsActive]) VALUES (@policy,CASE WHEN @policy='ROP' THEN 'ROP' ELSE 'Quetschlich Adapt' END,'NETWORK','Unchanged CompanyX core',1); SET @pt=SCOPE_IDENTITY();

END ELSE IF NOT EXISTS(SELECT 1 FROM dss.Dim_PolicyType WHERE PolicyTypeKey=@pt AND IsActive=1 AND DecisionScope='NETWORK') THROW 51000,'Unsupported policy type',1;

IF NOT EXISTS(SELECT 1 FROM dss.PolicyParameterDefinition WHERE PolicyTypeKey=@pt AND ParameterCode='UNIFIED_EXECUTION')

INSERT dss.PolicyParameterDefinition ([PolicyTypeKey],[ParameterCode],[ValueType],[UnitCode],[IsRequired],[Description]) VALUES (@pt,'UNIFIED_EXECUTION','TEXT','NONE',1,'Frozen numerical execution settings');

INSERT dss.Dim_PolicyConfigVersion ([PolicyConfigCode],[VersionNo],[PolicyTypeKey],[ConfigOrigin],[LifecycleStatus],[ConfigHash]) VALUES (@code+'_'+@policy,1,@pt,'USER_DEFINED','PUBLISHED',JSON_VALUE(@run,'$.execution_spec_sha256')); SET @pk=SCOPE_IDENTITY();

INSERT dss.PolicyParameterValue ([PolicyConfigVersionKey],[PolicyTypeKey],[ParameterCode],[TextValue]) VALUES (@pk,@pt,'UNIFIED_EXECUTION',(SELECT JSON_QUERY(@spec,'$.solver') solver,CONVERT(decimal(28,8),JSON_VALUE(@spec,'$.lost_unit_penalty')) lost_unit_penalty,CONVERT(decimal(28,8),JSON_VALUE(@spec,'$.late_unit_day_penalty')) late_unit_day_penalty,CONVERT(decimal(28,8),JSON_VALUE(@spec,'$.terminal_unserved_unit_penalty')) terminal_unserved_unit_penalty FOR JSON PATH,WITHOUT_ARRAY_WRAPPER));

INSERT dss.Dim_ScenarioVersion ([ScenarioCode],[VersionNo],[ScenarioName],[ShortageHandlingMode],[TimeBasis],[InitialStateMode],[InitialStateRule],[InitialStateBindingMode],[InventoryValuationRule],[HoldingCostRatePerYear],[AssumptionNote],[LifecycleStatus],[ConfigHash],[CreatedAt],[PublishedAt],[CustomerShipmentMode],[LostSalesScope]) VALUES (@code+'_S',1,JSON_VALUE(@run,'$.CaseName'),CASE WHEN JSON_VALUE(@spec,'$.allow_backorders')='true' THEN 'BACKORDER' ELSE 'LOST_SALES' END,'CALENDAR_DAY','EXPLICIT_POSITION',JSON_VALUE(@selection,'$.initial_state_rule'),'RELATIVE_TEMPLATE','FULL_STANDARD_COST_WIP',JSON_VALUE(@spec,'$.holding_cost_rate_per_year'),(SELECT @version adapter,@specRef execution_spec_reference,JSON_VALUE(@spec,'$.supply.mode') supply_mode,JSON_VALUE(@spec,'$.production_lead_time_mode') production_lead_time_mode,JSON_VALUE(@run,'$.input_sha256') input_sha256 FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),'PUBLISHED',JSON_VALUE(@run,'$.input_sha256'),@now,@now,'COMPLETE_ORDER',CASE WHEN JSON_VALUE(@spec,'$.allow_backorders')='true' THEN NULL ELSE 'WHOLE_SALES_ORDER' END); SET @scenarioKey=SCOPE_IDENTITY();

INSERT dss.Scenario_Distribution ([ScenarioVersionKey],[DistributionCode],[InputKind],[DistributionType],[TimeOrRatioUnit],[ParametersJson],[LowerBound],[UpperBound],[RoundingRule],[DependenceGroupCode]) VALUES (@scenarioKey,'SUPPLY_DELAY',N'SUPPLY_DELAY_DAYS',N'DISCRETE_EMPIRICAL',N'DAY',(SELECT JSON_QUERY('[0,1,2,3,4]') [values],JSON_QUERY(@spec,'$.supply.delay_probabilities') probabilities FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),0,4,N'CEIL_DAY','INDEPENDENT'); SET @delay=SCOPE_IDENTITY();

INSERT dss.Scenario_Distribution ([ScenarioVersionKey],[DistributionCode],[InputKind],[DistributionType],[TimeOrRatioUnit],[ParametersJson],[LowerBound],[UpperBound],[RoundingRule],[DependenceGroupCode]) VALUES (@scenarioKey,'SUPPLY_REJECT',N'SUPPLY_REJECT_RATE',N'CONSTANT',N'RATIO',(SELECT CONVERT(decimal(28,8),JSON_VALUE(@spec,'$.supply.reject_probability')) value FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),0,1,N'NONE','INDEPENDENT'); SET @quality=SCOPE_IDENTITY();

DECLARE @p nvarchar(max),@v nvarchar(max),@product int,@unit int,@purchase int,@vendor int,@lead decimal(28,8),@dk bigint;
 DECLARE products CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM OPENJSON(@snapshot,'$.products');
 OPEN products; FETCH NEXT FROM products INTO @p;
 WHILE @@FETCH_STATUS=0 BEGIN
  IF (SELECT COUNT(*) FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(@p,'$.ProductID') AND ProductKey>0)<>1 THROW 51000,'Missing/ambiguous product',1;
  IF (SELECT COUNT(*) FROM dw.Dim_UnitMeasure WHERE RTRIM(UnitMeasureCode)=JSON_VALUE(@p,'$.StockUnit') AND UnitMeasureKey>0)<>1 THROW 51000,'Missing/ambiguous unit',1;
  SELECT @product=ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(@p,'$.ProductID');
  SELECT @unit=UnitMeasureKey FROM dw.Dim_UnitMeasure WHERE RTRIM(UnitMeasureCode)=JSON_VALUE(@p,'$.StockUnit');

INSERT dss.Scenario_Product ([ScenarioVersionKey],[ProductKey],[StockUnitMeasureKey],[DemandLocationKey],[IsIndependentDemandItem],[IsActiveInScenario],[SellEndHandling],[StandardCostUsed],[CostBasisNote]) VALUES (@scenarioKey,@product,@unit,-1,CASE WHEN EXISTS(SELECT 1 FROM #demandProducts WHERE ProductID=JSON_VALUE(@p,'$.ProductID')) THEN 1 ELSE 0 END,1,'STOP_NEW_FORECAST_KEEP_ORDERS_AND_BOM',JSON_VALUE(@p,'$.UnitCost'),'Frozen valuation; see portable input artifact '+@inputRef);

INSERT dss.Scenario_InitialPosition ([ScenarioVersionKey],[PositionCode],[ProductKey],[StateCode],[FromLocationKey],[ToLocationKey],[Quantity],[AvailableOffsetDays]) VALUES (@scenarioKey,'ON_HAND_'+JSON_VALUE(@p,'$.ProductID'),@product,'ON_HAND',-1,-1,JSON_VALUE(@p,'$.InitialQty'),0);

IF @policy='ROP'

INSERT dss.PolicyProductConfig ([PolicyConfigVersionKey],[ProductKey],[ReorderPointUsed],[TargetLevelUsed],[ParameterRuleVersion],[LoadBatchID],[LoadedAt]) VALUES (@pk,@product,JSON_VALUE(@p,'$.ReorderPointQty'),JSON_VALUE(@p,'$.SafetyStockQty'),'UNIFIED_0.1.3_ROP_IP_LT_RP_FILL_SS',@batchKey,@now);

IF JSON_VALUE(@p,'$.IsManufactured')='true' BEGIN SET @lead=JSON_VALUE(@p,'$.ManufacturingParameters.lead_days');

INSERT dss.Scenario_Distribution ([ScenarioVersionKey],[DistributionCode],[InputKind],[DistributionType],[TimeOrRatioUnit],[ParametersJson],[LowerBound],[UpperBound],[RoundingRule],[DependenceGroupCode]) VALUES (@scenarioKey,'PRODUCTION_'+JSON_VALUE(@p,'$.ProductID'),N'PRODUCTION_TIME',N'CONSTANT',N'DAY',(SELECT @lead value FOR JSON PATH,WITHOUT_ARRAY_WRAPPER),@lead,@lead,N'CEIL_DAY','INDEPENDENT'); SET @dk=SCOPE_IDENTITY();

INSERT dss.Scenario_Production ([ScenarioVersionKey],[ProductKey],[ProductionMode],[LeadTimeDistributionKey],[LeadTimeSemantics],[MaterialIssueLocationKey],[FinishedReceiptLocationKey]) VALUES (@scenarioKey,@product,'AGGREGATE_LEAD_TIME',@dk,'REQUEST_INCLUSIVE',-1,-1);

END; FETCH NEXT FROM products INTO @p; END; CLOSE products; DEALLOCATE products;

DECLARE supplies CURSOR LOCAL FAST_FORWARD FOR SELECT value FROM OPENJSON(@snapshot,'$.supply_options');
 OPEN supplies; FETCH NEXT FROM supplies INTO @v;
 WHILE @@FETCH_STATUS=0 BEGIN
  SET @p=NULL; SELECT @p=value FROM OPENJSON(@snapshot,'$.products') WHERE JSON_VALUE(value,'$.ProductID')=JSON_VALUE(@v,'$.ProductID');
  IF @p IS NULL THROW 51000,'Supply product missing from snapshot',1;
  IF (SELECT COUNT(*) FROM dw.Dim_Vendor WHERE VendorID=JSON_VALUE(@v,'$.VendorID') AND VendorKey>0)<>1 THROW 51000,'Missing/ambiguous vendor',1;
  IF (SELECT COUNT(*) FROM dw.Dim_UnitMeasure WHERE RTRIM(UnitMeasureCode)=JSON_VALUE(@v,'$.PurchaseUnit') AND UnitMeasureKey>0)<>1 THROW 51000,'Missing/ambiguous purchase unit',1;
  SELECT @product=ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(@v,'$.ProductID');
  SELECT @unit=UnitMeasureKey FROM dw.Dim_UnitMeasure WHERE RTRIM(UnitMeasureCode)=JSON_VALUE(@p,'$.StockUnit');
  SELECT @purchase=UnitMeasureKey FROM dw.Dim_UnitMeasure WHERE RTRIM(UnitMeasureCode)=JSON_VALUE(@v,'$.PurchaseUnit');
  SELECT @vendor=VendorKey FROM dw.Dim_Vendor WHERE VendorID=JSON_VALUE(@v,'$.VendorID');
  IF NOT EXISTS(SELECT 1 FROM dss.Scenario_UnitConversion WHERE ScenarioVersionKey=@scenarioKey AND ProductKey=@product AND FromUnitMeasureKey=@purchase AND ToUnitMeasureKey=@unit)

INSERT dss.Scenario_UnitConversion ([ScenarioVersionKey],[ProductKey],[FromUnitMeasureKey],[ToUnitMeasureKey],[ConversionFactor]) VALUES (@scenarioKey,@product,@purchase,@unit,1);

INSERT dss.Scenario_Supply ([ScenarioVersionKey],[ProductKey],[VendorKey],[ReceiptLocationKey],[PurchaseUnitMeasureKey],[DelayDistributionKey],[RejectRateDistributionKey],[SupplyLimitMode],[MinOrderQty],[MaxOrderQty],[UnitPurchaseCost],[InspectionRule],[InTransitOwnershipRule],[BaseLeadTimeDays],[RejectSamplingRule]) VALUES (@scenarioKey,@product,@vendor,-1,@unit,@delay,@quality,'UNLIMITED',JSON_VALUE(@v,'$.min_order_qty'),JSON_VALUE(@v,'$.max_order_qty'),COALESCE(JSON_VALUE(@v,'$.standard_price_raw'),JSON_VALUE(@p,'$.UnitCost')),'REJECT_AT_RECEIPT','NOT_OWNED_IN_TRANSIT',JSON_VALUE(@v,'$.base_lead_days'),'BINOMIAL_UNIT');

FETCH NEXT FROM supplies INTO @v; END; CLOSE supplies; DEALLOCATE supplies;

INSERT dss.ExperimentCase ([ExperimentVersionKey],[CaseCode],[CaseName],[IsBaseline],[ScenarioVersionKey],[PolicyConfigVersionKey],[InputSnapshotKey],[DataCutoffDateKey],[SimulationStartDateKey],[SimulationEndDateKey],[DemandInputMode],[DemandRuleVersion],[RuleSetVersion],[DemandSourceKind],[CaseNote]) VALUES (@experiment,@code+'_CASE',JSON_VALUE(@run,'$.CaseName'),1,@scenarioKey,@pk,@inputKey,REPLACE(LEFT(JSON_VALUE(@snapshot,'$.start'),10),'-',''),REPLACE(LEFT(JSON_VALUE(@snapshot,'$.start'),10),'-',''),REPLACE(LEFT(JSON_VALUE(@snapshot,'$.end'),10),'-',''),'HISTORICAL_ORDER_REPLAY','V1_MANUFACTURED_ORDERS_ALL_SIBLINGS',@version,'HISTORICAL_REPLAY','Native SSIS IO; local simulation before atomic DW registration/publication'); SET @caseKey=SCOPE_IDENTITY();

INSERT dss.Dim_PlanningRun ([RunCode],[RunPurpose],[RunStatus],[RunAt],[LoadBatchID],[ExperimentVersionKey],[ExperimentCaseKey],[ExperimentReplicationKey],[AttemptNo],[ReplicationNo],[RandomSeed],[RandomStreamVersion],[MetricDefinitionVersion],[RunRequestId],[ExecutionSpecHash],[ExecutionSpecVersion],[ExecutionSpecReference],[RunNote]) VALUES (@runCode,'SIMULATION','RUNNING',JSON_VALUE(@run,'$.created_at'),@batchKey,@experiment,@caseKey,@replication,1,CONVERT(int,JSON_VALUE(@spec,'$.replication'))+1,20261026,@stream,@metricVersion,@runCode,JSON_VALUE(@run,'$.execution_spec_sha256'),@version,@specRef,'SSIS native adapter; source/result artifacts immutable; no automatic replay'); SET @runKey=SCOPE_IDENTITY();

DECLARE @v03 nvarchar(max)=(SELECT Json FROM #files WHERE Name='DSS/inputs/V03_FrozenLeadValues.json'); IF ISNULL(JSON_VALUE(@v03,'$.input_hash'),'')<>JSON_VALUE(@scope,'$.base_snapshot_content_sha256') THROW 51000,'V03 frozen snapshot mismatch',1;

SELECT p.ProductKey,j.[LpDays],j.[L90Days],j.[MedianLeadTimeDays],j.[ObservationCount],j.[LastHistoryCompletionDate],j.[HistoryCutoffExclusive],j.[LeadTimeUnit],j.[LeadTimeSource],j.[SourceMeasure],j.[ObservationFormula],j.[SampleFilter],j.[MedianFormula],j.[LpFormula],j.[L90Formula],j.[FallbackRule],j.[SourceArtifactHash],j.[SourceJsonPath],j.[SourceParameterJson],j.[SourceParameterHash],j.[SourceWorkOrderHash],j.[EstimatorCodeHash],j.[EstimatorReference],j.[MaterializationMode] INTO #leadValues FROM OPENJSON(@v03,'$.rows') WITH(ProductID int,[LpDays] int,[L90Days] int,[MedianLeadTimeDays] decimal(10,1),[ObservationCount] int,[LastHistoryCompletionDate] date,[HistoryCutoffExclusive] date,[LeadTimeUnit] varchar(16),[LeadTimeSource] varchar(32),[SourceMeasure] nvarchar(256),[ObservationFormula] nvarchar(256),[SampleFilter] nvarchar(1000),[MedianFormula] nvarchar(512),[LpFormula] nvarchar(256),[L90Formula] nvarchar(256),[FallbackRule] nvarchar(256),[SourceArtifactHash] char(64),[SourceJsonPath] nvarchar(256),[SourceParameterJson] nvarchar(max),[SourceParameterHash] char(64),[SourceWorkOrderHash] char(64),[EstimatorCodeHash] char(64),[EstimatorReference] nvarchar(512),[MaterializationMode] varchar(32)) j LEFT JOIN dw.Dim_Product p ON p.ProductID=j.ProductID AND p.ProductKey>0 WHERE j.ProductID IN(SELECT ProductID FROM OPENJSON(@original,'$.products') WITH(ProductID int,IsManufactured bit) WHERE IsManufactured=1);

IF EXISTS (SELECT 1 FROM #leadValues WHERE ProductKey IS NULL OR LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',CONVERT(varchar(max),SourceParameterJson COLLATE Latin1_General_100_BIN2_UTF8)),2))<>SourceParameterHash) THROW 51000,N'V03 parameter/key mismatch',1;

INSERT dss.InputSnapshot_ProductionLeadTime(InputSnapshotKey,ProductKey,[LpDays],[L90Days],[MedianLeadTimeDays],[ObservationCount],[LastHistoryCompletionDate],[HistoryCutoffExclusive],[LeadTimeUnit],[LeadTimeSource],[SourceMeasure],[ObservationFormula],[SampleFilter],[MedianFormula],[LpFormula],[L90Formula],[FallbackRule],[SourceArtifactHash],[SourceJsonPath],[SourceParameterJson],[SourceParameterHash],[SourceWorkOrderHash],[EstimatorCodeHash],[EstimatorReference],[MaterializationMode]) SELECT @inputKey,ProductKey,[LpDays],[L90Days],[MedianLeadTimeDays],[ObservationCount],[LastHistoryCompletionDate],[HistoryCutoffExclusive],[LeadTimeUnit],[LeadTimeSource],[SourceMeasure],[ObservationFormula],[SampleFilter],[MedianFormula],[LpFormula],[L90Formula],[FallbackRule],[SourceArtifactHash],[SourceJsonPath],[SourceParameterJson],[SourceParameterHash],[SourceWorkOrderHash],[EstimatorCodeHash],[EstimatorReference],[MaterializationMode] FROM #leadValues;

END; -- new-run registration

SELECT @delay=DistributionKey FROM dss.Scenario_Distribution WHERE ScenarioVersionKey=@scenarioKey AND DistributionCode='SUPPLY_DELAY'; SELECT @quality=DistributionKey FROM dss.Scenario_Distribution WHERE ScenarioVersionKey=@scenarioKey AND DistributionCode='SUPPLY_REJECT';

SELECT TOP(0) [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] INTO #Fact_SimulationOrder FROM dss.Fact_SimulationOrder;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_SimulationOrder.jsonl')) THROW 51000,N'Required table missing: Fact_SimulationOrder',1;

INSERT #Fact_SimulationOrder ([PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt]) SELECT @runKey,JSON_VALUE(r.Payload,'$.CustomerOrderCode'),JSON_VALUE(r.Payload,'$.SourceSalesOrderID'),JSON_VALUE(r.Payload,'$.SourceRecordReference'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.KnownAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.KnownAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.KnownAt')) END,CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.DueAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.DueAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.DueAt')) END,JSON_VALUE(r.Payload,'$.ExpectedLineCount'),JSON_VALUE(r.Payload,'$.OrderStatus'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.CompletedAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.CompletedAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.CompletedAt')) END,CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.CancelledAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.CancelledAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.CancelledAt')) END,JSON_VALUE(r.Payload,'$.CancellationReason'),@batchKey,CASE WHEN RIGHT(JSON_VALUE(@run,'$.created_at'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(@run,'$.created_at')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(@run,'$.created_at')) END FROM #payload r WHERE r.TableName='Fact_SimulationOrder';

SELECT TOP(0) [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] INTO #RunEntity FROM dss.RunEntity;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'RunEntity.jsonl')) THROW 51000,N'Required table missing: RunEntity',1;

INSERT #RunEntity ([PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode]) SELECT @runKey,JSON_VALUE(r.Payload,'$.EntityCode'),JSON_VALUE(r.Payload,'$.EntityType'),CASE WHEN EXISTS(SELECT 1 FROM OPENJSON(r.Payload) WHERE [key]='ProductID') THEN CASE WHEN COALESCE(JSON_VALUE(r.Payload,'$.ProductID'),'0')='0' THEN 0 ELSE (SELECT ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND ProductKey>0) END ELSE JSON_VALUE(r.Payload,'$.ProductKey') END,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OriginalQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OriginalQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OriginalQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpeningRemainingQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OpeningRemainingQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpeningRemainingQty')) END),8,1),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.CreatedAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.CreatedAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.CreatedAt')) END,CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.DueAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.DueAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.DueAt')) END,CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.PromisedAvailableAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.PromisedAvailableAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.PromisedAvailableAt')) END,CASE JSON_VALUE(r.Payload,'$.IsOpeningEntity') WHEN 'true' THEN '1' WHEN 'false' THEN '0' ELSE JSON_VALUE(r.Payload,'$.IsOpeningEntity') END,JSON_VALUE(r.Payload,'$.SourceRecordReference'),@scenarioKey,JSON_VALUE(r.Payload,'$.InitialEntityCode'),JSON_VALUE(r.Payload,'$.InitialDemandLineCode'),JSON_VALUE(r.Payload,'$.CustomerOrderCode') FROM #payload r WHERE r.TableName='RunEntity';

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='RunEntity' AND COALESCE(JSON_VALUE(Payload,'$.ProductID'),'0')<>'0' AND NOT EXISTS(SELECT 1 FROM dw.Dim_Product p WHERE p.ProductID=JSON_VALUE(Payload,'$.ProductID') AND p.ProductKey>0)) THROW 51000,N'Missing product: RunEntity',1;

SELECT TOP(0) [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] INTO #Bridge_RunEntityRelation FROM dss.Bridge_RunEntityRelation;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Bridge_RunEntityRelation.jsonl')) THROW 51000,N'Required table missing: Bridge_RunEntityRelation',1;

INSERT #Bridge_RunEntityRelation ([PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey]) SELECT @runKey,JSON_VALUE(r.Payload,'$.ParentEntityCode'),JSON_VALUE(r.Payload,'$.ChildEntityCode'),JSON_VALUE(r.Payload,'$.RelationCode'),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AllocatedQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AllocatedQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AllocatedQty')) END),8,1),(SELECT ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(r.Payload,'$.AllocatedProductID') AND ProductKey>0) FROM #payload r WHERE r.TableName='Bridge_RunEntityRelation';

SELECT TOP(0) [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] INTO #Fact_OptimizationSolve FROM dss.Fact_OptimizationSolve;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_OptimizationSolve.jsonl')) THROW 51000,N'Required table missing: Fact_OptimizationSolve',1;

INSERT #Fact_OptimizationSolve ([PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt]) SELECT @runKey,JSON_VALUE(r.Payload,'$.SolveSequence'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.DecisionAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.DecisionAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.DecisionAt')) END,JSON_VALUE(r.Payload,'$.AttemptNo'),JSON_VALUE(r.Payload,'$.ObjectiveStage'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.InformationCutoffAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.InformationCutoffAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.InformationCutoffAt')) END,CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.HorizonEndAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.HorizonEndAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.HorizonEndAt')) END,JSON_VALUE(r.Payload,'$.PlanningForecastRunKey'),JSON_VALUE(r.Payload,'$.ForecastInputReference'),JSON_VALUE(r.Payload,'$.StateInputReference'),JSON_VALUE(r.Payload,'$.DecisionOutputReference'),JSON_VALUE(r.Payload,'$.SolverStatus'),CASE JSON_VALUE(r.Payload,'$.HasFeasibleSolution') WHEN 'true' THEN '1' WHEN 'false' THEN '0' ELSE JSON_VALUE(r.Payload,'$.HasFeasibleSolution') END,JSON_VALUE(r.Payload,'$.ActionSource'),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ObjectiveValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.ObjectiveValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ObjectiveValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.BestBound')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.BestBound')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.BestBound')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.RelativeGap')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.RelativeGap')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.RelativeGap')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.SolverSeconds')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.SolverSeconds')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.SolverSeconds')) END),4,1),@batchKey,CASE WHEN RIGHT(JSON_VALUE(@run,'$.created_at'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(@run,'$.created_at')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(@run,'$.created_at')) END FROM #payload r WHERE r.TableName='Fact_OptimizationSolve';

SELECT TOP(0) [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] INTO #Fact_SimulationDaily FROM dss.Fact_SimulationDaily;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_SimulationDaily.jsonl')) THROW 51000,N'Required table missing: Fact_SimulationDaily',1;

INSERT #Fact_SimulationDaily ([PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty]) SELECT @runKey,REPLACE(LEFT(JSON_VALUE(r.Payload,'$.Date'),10),'-',''),CASE WHEN EXISTS(SELECT 1 FROM OPENJSON(r.Payload) WHERE [key]='ProductID') THEN CASE WHEN COALESCE(JSON_VALUE(r.Payload,'$.ProductID'),'0')='0' THEN 0 ELSE (SELECT ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND ProductKey>0) END ELSE JSON_VALUE(r.Payload,'$.ProductKey') END,-1,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnHandQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OnHandQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnHandQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ProductionWIPQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.ProductionWIPQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ProductionWIPQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.QueuedProductionQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.QueuedProductionQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.QueuedProductionQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseInTransitQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.PurchaseInTransitQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseInTransitQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.CustomerBacklogQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.CustomerBacklogQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.CustomerBacklogQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.CustomerDueQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.CustomerDueQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.CustomerDueQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateDeliveredQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.LateDeliveredQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateDeliveredQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LostQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.LostQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LostQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.BOMConsumedQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.BOMConsumedQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.BOMConsumedQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseAcceptedQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.PurchaseAcceptedQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseAcceptedQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseRejectedQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.PurchaseRejectedQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.PurchaseRejectedQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ProductionGoodQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.ProductionGoodQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.ProductionGoodQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnHandValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OnHandValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnHandValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.WIPValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.WIPValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.WIPValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OwnedInTransitValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OwnedInTransitValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OwnedInTransitValue')) END),8,1),@batchKey,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpenPurchaseQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OpenPurchaseQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpenPurchaseQty')) END),8,1) FROM #payload r WHERE r.TableName='Fact_SimulationDaily';

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='Fact_SimulationDaily' AND COALESCE(JSON_VALUE(Payload,'$.ProductID'),'0')<>'0' AND NOT EXISTS(SELECT 1 FROM dw.Dim_Product p WHERE p.ProductID=JSON_VALUE(Payload,'$.ProductID') AND p.ProductKey>0)) THROW 51000,N'Missing product: Fact_SimulationDaily',1;

SELECT TOP(0) [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] INTO #Fact_SimulationEvent FROM dss.Fact_SimulationEvent;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_SimulationEvent.jsonl')) THROW 51000,N'Required table missing: Fact_SimulationEvent',1;

INSERT #Fact_SimulationEvent ([PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence]) SELECT @runKey,JSON_VALUE(r.Payload,'$.EventSequence'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.EventAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.EventAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.EventAt')) END,REPLACE(LEFT(JSON_VALUE(r.Payload,'$.EventAt'),10),'-',''),JSON_VALUE(r.Payload,'$.EventCode'),JSON_VALUE(r.Payload,'$.EntityCode'),JSON_VALUE(r.Payload,'$.RelatedEntityCode'),JSON_VALUE(r.Payload,'$.SourceRecordReference'),CASE WHEN EXISTS(SELECT 1 FROM OPENJSON(r.Payload) WHERE [key]='ProductID') THEN CASE WHEN COALESCE(JSON_VALUE(r.Payload,'$.ProductID'),'0')='0' THEN 0 ELSE (SELECT ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND ProductKey>0) END ELSE JSON_VALUE(r.Payload,'$.ProductKey') END,-1,-1,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.Quantity')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.Quantity')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.Quantity')) END),8,1),(SELECT s.SupplyOptionKey FROM dss.Scenario_Supply s JOIN dw.Dim_Product p ON p.ProductKey=s.ProductKey JOIN dw.Dim_Vendor v ON v.VendorKey=s.VendorKey WHERE s.ScenarioVersionKey=@scenarioKey AND p.ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND v.VendorID=JSON_VALUE(r.Payload,'$.VendorID')),JSON_VALUE(r.Payload,'$.RouteStepKey'),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.KnownAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.KnownAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.KnownAt')) END,@batchKey,JSON_VALUE(r.Payload,'$.ReasonCode'),JSON_VALUE(r.Payload,'$.ProductionExecutionCode'),JSON_VALUE(r.Payload,'$.OrderActionCode'),JSON_VALUE(r.Payload,'$.DecisionSolveSequence') FROM #payload r WHERE r.TableName='Fact_SimulationEvent';

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='Fact_SimulationEvent' AND COALESCE(JSON_VALUE(Payload,'$.ProductID'),'0')<>'0' AND NOT EXISTS(SELECT 1 FROM dw.Dim_Product p WHERE p.ProductID=JSON_VALUE(Payload,'$.ProductID') AND p.ProductKey>0)) THROW 51000,N'Missing product: Fact_SimulationEvent',1;

SELECT TOP(0) [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] INTO #Fact_StochasticDraw FROM dss.Fact_StochasticDraw;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_StochasticDraw.jsonl')) THROW 51000,N'Required table missing: Fact_StochasticDraw',1;

INSERT #Fact_StochasticDraw ([PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty]) SELECT @runKey,r.RowNumber,CASE JSON_VALUE(r.Payload,'$.StreamCode') WHEN 'lead' THEN @delay WHEN 'quality' THEN @quality END,JSON_VALUE(r.Payload,'$.StreamCode'),JSON_VALUE(r.Payload,'$.DrawKey'),0,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.UniformValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.UniformValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.UniformValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AppliedValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AppliedValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AppliedValue')) END),8,1),CASE WHEN RIGHT(JSON_VALUE(r.Payload,'$.DecisionAt'),6) LIKE '[+-][0-9][0-9]:[0-9][0-9]' THEN CONVERT(datetime2,CONVERT(datetimeoffset,JSON_VALUE(r.Payload,'$.DecisionAt')) AT TIME ZONE CURRENT_TIMEZONE_ID()) ELSE CONVERT(datetime2,JSON_VALUE(r.Payload,'$.DecisionAt')) END,CASE WHEN JSON_VALUE(r.Payload,'$.StreamCode')='lead' THEN 'SUPPLY_DELAY_DAYS' ELSE 'REJECT_QTY' END,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),CASE WHEN JSON_VALUE(r.Payload,'$.StreamCode')='lead' THEN NULL ELSE JSON_VALUE(r.Payload,'$.TrialQty') END) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,CASE WHEN JSON_VALUE(r.Payload,'$.StreamCode')='lead' THEN NULL ELSE JSON_VALUE(r.Payload,'$.TrialQty') END),'0.############################','en-US') ELSE CONVERT(nvarchar(100),CASE WHEN JSON_VALUE(r.Payload,'$.StreamCode')='lead' THEN NULL ELSE JSON_VALUE(r.Payload,'$.TrialQty') END) END),8,1) FROM #payload r WHERE r.TableName='Fact_StochasticDraw';

SELECT TOP(0) [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] INTO #Fact_PolicySimulation FROM dss.Fact_PolicySimulation;

IF EXISTS (SELECT 1 WHERE NOT EXISTS(SELECT 1 FROM OPENJSON(@manifest,'$.tables') WHERE [key]=N'Fact_PolicySimulation.jsonl')) THROW 51000,N'Required table missing: Fact_PolicySimulation',1;

INSERT #Fact_PolicySimulation ([PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID]) SELECT @runKey,CASE WHEN EXISTS(SELECT 1 FROM OPENJSON(r.Payload) WHERE [key]='ProductID') THEN CASE WHEN COALESCE(JSON_VALUE(r.Payload,'$.ProductID'),'0')='0' THEN 0 ELSE (SELECT ProductKey FROM dw.Dim_Product WHERE ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND ProductKey>0) END ELSE JSON_VALUE(r.Payload,'$.ProductKey') END,JSON_VALUE(r.Payload,'$.SimulatedDays'),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.InitialOnHandQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.InitialOnHandQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.InitialOnHandQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpeningBacklogQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OpeningBacklogQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OpeningBacklogQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.TotalDemandQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.TotalDemandQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.TotalDemandQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeDeliveredQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateDeliveredQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.LateDeliveredQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateDeliveredQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.FilledQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.FilledQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.FilledQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LostQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.LostQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LostQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.EndingBacklogQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.EndingBacklogQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.EndingBacklogQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateUnitDays')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.LateUnitDays')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.LateUnitDays')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeUnitRate')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.OnTimeUnitRate')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.OnTimeUnitRate')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.FillRate')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.FillRate')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.FillRate')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgOnHandQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AvgOnHandQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgOnHandQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgWIPQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AvgWIPQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgWIPQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInTransitQty')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AvgInTransitQty')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInTransitQty')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInventoryValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AvgInventoryValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInventoryValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInTransitValue')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.AvgInTransitValue')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.AvgInTransitValue')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.HoldingCost')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(r.Payload,'$.HoldingCost')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(r.Payload,'$.HoldingCost')) END),8,1),@batchKey FROM #payload r WHERE r.TableName='Fact_PolicySimulation';

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='Fact_PolicySimulation' AND COALESCE(JSON_VALUE(Payload,'$.ProductID'),'0')<>'0' AND NOT EXISTS(SELECT 1 FROM dw.Dim_Product p WHERE p.ProductID=JSON_VALUE(Payload,'$.ProductID') AND p.ProductKey>0)) THROW 51000,N'Missing product: Fact_PolicySimulation',1;

SELECT TOP(0) [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] INTO #Fact_RunSummary FROM dss.Fact_RunSummary;

INSERT #Fact_RunSummary ([PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate]) SELECT @runKey,@evaluation,ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.due_units_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.due_units_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.due_units_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.on_time_units_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.on_time_units_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.on_time_units_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.on_time_unit_rate_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.on_time_unit_rate_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.on_time_unit_rate_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.lost_units_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.lost_units_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.lost_units_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.backlog_units_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.backlog_units_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.backlog_units_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.late_unit_days_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.late_unit_days_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.late_unit_days_manufactured')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.mean_InventoryWIPValueAll')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.mean_InventoryWIPValueAll')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.mean_InventoryWIPValueAll')) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),0) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,0),'0.############################','en-US') ELSE CONVERT(nvarchar(100),0) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.wall_seconds')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.wall_seconds')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.wall_seconds')) END),4,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),CASE WHEN @policy='ROP' THEN NULL ELSE (SELECT COALESCE(SUM(SolverSeconds),0) FROM #Fact_OptimizationSolve) END) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,CASE WHEN @policy='ROP' THEN NULL ELSE (SELECT COALESCE(SUM(SolverSeconds),0) FROM #Fact_OptimizationSolve) END),'0.############################','en-US') ELSE CONVERT(nvarchar(100),CASE WHEN @policy='ROP' THEN NULL ELSE (SELECT COALESCE(SUM(SolverSeconds),0) FROM #Fact_OptimizationSolve) END) END),4,1),'PASSED',N'Atomic native SSIS publication with relational/event/KPI reconciliation and SQL FK checks',ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),0) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,0),'0.############################','en-US') ELSE CONVERT(nvarchar(100),0) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.shipped_units_manufactured'))-CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.on_time_units_manufactured'))) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.shipped_units_manufactured'))-CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.on_time_units_manufactured'))),'0.############################','en-US') ELSE CONVERT(nvarchar(100),CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.shipped_units_manufactured'))-CONVERT(decimal(28,8),JSON_VALUE(@metrics,'$.on_time_units_manufactured'))) END),8,1),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.shipped_units_manufactured')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.shipped_units_manufactured')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.shipped_units_manufactured')) END),8,1),JSON_VALUE(@metrics,'$.due_orders'),JSON_VALUE(@metrics,'$.orders_full_on_time'),JSON_VALUE(@metrics,'$.lost_orders'),ROUND(CONVERT(decimal(38,18),CASE WHEN CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.full_order_on_time_rate')) LIKE '%[.eE]%' THEN FORMAT(CONVERT(float,JSON_VALUE(@metrics,'$.full_order_on_time_rate')),'0.############################','en-US') ELSE CONVERT(nvarchar(100),JSON_VALUE(@metrics,'$.full_order_on_time_rate')) END),8,1);

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='Bridge_RunEntityRelation' AND JSON_VALUE(Payload,'$.AllocatedProductID') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dw.Dim_Product p WHERE p.ProductID=JSON_VALUE(Payload,'$.AllocatedProductID') AND p.ProductKey>0)) THROW 51000,N'Missing allocated product',1;

IF EXISTS (SELECT 1 FROM #payload r WHERE TableName='Fact_SimulationEvent' AND JSON_VALUE(Payload,'$.VendorID') IS NOT NULL AND NOT EXISTS(SELECT 1 FROM dss.Scenario_Supply s JOIN dw.Dim_Product p ON p.ProductKey=s.ProductKey JOIN dw.Dim_Vendor v ON v.VendorKey=s.VendorKey WHERE s.ScenarioVersionKey=@scenarioKey AND p.ProductID=JSON_VALUE(r.Payload,'$.ProductID') AND v.VendorID=JSON_VALUE(r.Payload,'$.VendorID'))) THROW 51000,N'Missing event supply option',1;

CREATE UNIQUE INDEX IX_Fact_SimulationOrder ON #Fact_SimulationOrder ([PlanningRunKey],[CustomerOrderCode]);

CREATE UNIQUE INDEX IX_RunEntity ON #RunEntity ([PlanningRunKey],[EntityCode]);

CREATE UNIQUE INDEX IX_Bridge_RunEntityRelation ON #Bridge_RunEntityRelation ([PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode]);

CREATE UNIQUE INDEX IX_Fact_OptimizationSolve ON #Fact_OptimizationSolve ([PlanningRunKey],[SolveSequence]);

CREATE UNIQUE INDEX IX_Fact_SimulationDaily ON #Fact_SimulationDaily ([PlanningRunKey],[DateKey],[ProductKey],[LocationKey]);

CREATE UNIQUE INDEX IX_Fact_SimulationEvent ON #Fact_SimulationEvent ([PlanningRunKey],[EventSequence]);

CREATE UNIQUE INDEX IX_Fact_StochasticDraw ON #Fact_StochasticDraw ([PlanningRunKey],[DrawSequence]);

CREATE UNIQUE INDEX IX_Fact_PolicySimulation ON #Fact_PolicySimulation ([PlanningRunKey],[ProductKey]);

CREATE UNIQUE INDEX IX_Fact_RunSummary ON #Fact_RunSummary ([PlanningRunKey]);

CREATE TABLE #event_types(code nvarchar(100) PRIMARY KEY,entity nvarchar(100)); CREATE TABLE #relation_types(code nvarchar(100) PRIMARY KEY,parent nvarchar(100),child nvarchar(100)); CREATE TABLE #service_products(p int PRIMARY KEY);

INSERT #event_types SELECT EventCode,EntityType FROM OPENJSON((SELECT Json FROM #files WHERE Name='SSIS/event_catalog.json')) WITH(EventCode nvarchar(100),EntityType nvarchar(100)); INSERT #relation_types SELECT [key],JSON_VALUE(value,'$[0]'),JSON_VALUE(value,'$[1]') FROM OPENJSON((SELECT Json FROM #files WHERE Name='SSIS/relation_types.json')); INSERT #service_products SELECT p.ProductKey FROM OPENJSON(@profile,'$.ServiceProductIDs') j JOIN dw.Dim_Product p ON p.ProductID=j.value;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent WHERE Quantity<=0)<>0 THROW 51000,N'DQ: Positive event quantity',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e
            LEFT JOIN #event_types t ON e.EventCode=t.code LEFT JOIN #RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.EntityCode=r.EntityCode
            WHERE t.code IS NULL OR r.EntityType<>t.entity)<>0 THROW 51000,N'DQ: V6 event catalog and entity type',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT') AND SupplyOptionKey IS NULL)<>0 THROW 51000,N'DQ: V6 purchase supply references',1;

IF (SELECT COUNT(*) FROM #Bridge_RunEntityRelation b
            LEFT JOIN #relation_types t ON b.RelationCode=t.code
            LEFT JOIN #RunEntity p ON b.PlanningRunKey=p.PlanningRunKey AND b.ParentEntityCode=p.EntityCode
            LEFT JOIN #RunEntity c ON b.PlanningRunKey=c.PlanningRunKey AND b.ChildEntityCode=c.EntityCode
            WHERE t.code IS NULL OR p.EntityCode IS NULL OR c.EntityCode IS NULL OR p.EntityType<>t.parent OR c.EntityType<>t.child
               OR p.EntityCode=c.EntityCode OR b.AllocatedQty<0 OR ((b.AllocatedQty IS NULL AND b.AllocatedProductKey IS NOT NULL) OR (b.AllocatedQty IS NOT NULL AND b.AllocatedProductKey IS NULL)))<>0 THROW 51000,N'DQ: Typed entity relations',1;

IF (SELECT COUNT(*) FROM #RunEntity r LEFT JOIN
            (SELECT PlanningRunKey,EntityCode,SUM(Quantity) qty FROM #Fact_SimulationEvent
             WHERE EventCode IN ('BUY_RECEIVE_GOOD','BUY_REJECT') GROUP BY PlanningRunKey,EntityCode) e
            ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='RECEIPT_LOT' AND (ABS(r.OriginalQty-COALESCE(e.qty,0))>0.00001 OR
            (SELECT COUNT(*) FROM #Bridge_RunEntityRelation b WHERE b.PlanningRunKey=r.PlanningRunKey AND b.ChildEntityCode=r.EntityCode AND b.RelationCode='HAS_RECEIPT')<>1))<>0 THROW 51000,N'DQ: Receipt lot relationship and gross inspection',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e
            WHERE e.EventCode IN ('BUY_RECEIVE_GOOD','BUY_REJECT') AND NOT EXISTS
            (SELECT 1 FROM #Bridge_RunEntityRelation b WHERE b.PlanningRunKey=e.PlanningRunKey AND b.ChildEntityCode=e.EntityCode
            AND b.ParentEntityCode=e.RelatedEntityCode AND b.RelationCode='HAS_RECEIPT'))<>0 THROW 51000,N'DQ: Receipt event parent relationship',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e LEFT JOIN #RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.EntityCode=r.EntityCode WHERE r.EntityCode IS NULL)<>0 THROW 51000,N'DQ: Event entity reference',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e LEFT JOIN #RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.RelatedEntityCode=r.EntityCode WHERE e.RelatedEntityCode IS NOT NULL AND r.EntityCode IS NULL)<>0 THROW 51000,N'DQ: Related entity reference',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e LEFT JOIN #Fact_OptimizationSolve s
            ON e.PlanningRunKey=s.PlanningRunKey AND e.DecisionSolveSequence=s.SolveSequence WHERE e.DecisionSolveSequence IS NOT NULL AND s.SolveSequence IS NULL)<>0 THROW 51000,N'DQ: Decision solve reference',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e LEFT JOIN #RunEntity r
            ON e.PlanningRunKey=r.PlanningRunKey AND e.ProductionExecutionCode=r.EntityCode
            WHERE e.EventCode IN ('PRODUCTION_START','BOM_ISSUE','PRODUCTION_GOOD')
              AND (r.EntityCode IS NULL OR r.EntityType<>'OPERATION_EXECUTION'))<>0 THROW 51000,N'DQ: Execution lineage',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent e WHERE e.EventCode IN ('PRODUCTION_START','BOM_ISSUE','PRODUCTION_GOOD')
            AND NOT EXISTS (SELECT 1 FROM #Bridge_RunEntityRelation b WHERE b.PlanningRunKey=e.PlanningRunKey
            AND b.ParentEntityCode=e.EntityCode AND b.ChildEntityCode=e.ProductionExecutionCode AND b.RelationCode='HAS_OPERATION'))<>0 THROW 51000,N'DQ: Execution job relationship',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationEvent WHERE EventCode IN
            ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE') AND OrderActionCode IS NULL)<>0 THROW 51000,N'DQ: Atomic order action',1;

IF (SELECT COUNT(*) FROM #RunEntity r LEFT JOIN #Fact_SimulationOrder o
            ON r.PlanningRunKey=o.PlanningRunKey AND r.CustomerOrderCode=o.CustomerOrderCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' AND o.CustomerOrderCode IS NULL)<>0 THROW 51000,N'DQ: Order line header reference',1;

IF (SELECT COUNT(*) FROM (SELECT o.PlanningRunKey,o.CustomerOrderCode,o.ExpectedLineCount,
            COUNT(r.EntityCode) actual FROM #Fact_SimulationOrder o LEFT JOIN #RunEntity r
            ON o.PlanningRunKey=r.PlanningRunKey AND o.CustomerOrderCode=r.CustomerOrderCode AND r.EntityType='CUSTOMER_ORDER_LINE'
            GROUP BY o.PlanningRunKey,o.CustomerOrderCode,o.ExpectedLineCount HAVING COUNT(r.EntityCode)<>o.ExpectedLineCount) q)<>0 THROW 51000,N'DQ: Header expected line count',1;

SELECT r.PlanningRunKey,r.EntityCode,r.CustomerOrderCode,r.OriginalQty,
            COALESCE(SUM(CASE WHEN e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE') THEN e.Quantity ELSE 0 END),0) shipped,
            COALESCE(SUM(CASE WHEN e.EventCode='LOST_SALE' THEN e.Quantity ELSE 0 END),0) lost,
            COUNT(DISTINCT CASE WHEN e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE') THEN e.OrderActionCode END) actions
            INTO #settled FROM #RunEntity r LEFT JOIN #Fact_SimulationEvent e ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' GROUP BY r.PlanningRunKey,r.EntityCode,r.CustomerOrderCode,r.OriginalQty

IF (SELECT COUNT(*) FROM #settled WHERE shipped<0 OR lost<0 OR shipped+lost>OriginalQty+0.00001)<>0 THROW 51000,N'DQ: Order conservation',1;

IF (SELECT COUNT(*) FROM #settled s JOIN #Fact_SimulationOrder o
            ON s.PlanningRunKey=o.PlanningRunKey AND s.CustomerOrderCode=o.CustomerOrderCode
            WHERE (o.OrderStatus='FULFILLED' AND (ABS(s.shipped-s.OriginalQty)>0.00001 OR s.lost<>0 OR s.actions<>1))
               OR (o.OrderStatus='LOST' AND (ABS(s.lost-s.OriginalQty)>0.00001 OR s.shipped<>0 OR s.actions<>1))
               OR (o.OrderStatus='OPEN' AND (s.shipped<>0 OR s.lost<>0)))<>0 THROW 51000,N'DQ: Whole order settlement',1;

IF (SELECT COUNT(*) FROM (SELECT r.PlanningRunKey,r.CustomerOrderCode
            FROM #RunEntity r JOIN #Fact_SimulationEvent e ON r.PlanningRunKey=e.PlanningRunKey AND r.EntityCode=e.EntityCode
            WHERE r.EntityType='CUSTOMER_ORDER_LINE' AND e.EventCode IN ('SHIP_ON_TIME','SHIP_LATE','LOST_SALE')
            GROUP BY r.PlanningRunKey,r.CustomerOrderCode HAVING COUNT(DISTINCT e.OrderActionCode)<>1) q)<>0 THROW 51000,N'DQ: Full-order shared action',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationDaily WHERE OnHandQty<0 OR ProductionWIPQty<0
            OR QueuedProductionQty<0 OR PurchaseInTransitQty<0 OR OpenPurchaseQty<0 OR CustomerBacklogQty<0 OR LostQty<0)<>0 THROW 51000,N'DQ: Nonnegative daily stock',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationDaily WHERE PurchaseInTransitQty<>0 OR OwnedInTransitValue<>0)<>0 THROW 51000,N'DQ: No invented dispatch/transit',1;

DECLARE @checkCount bigint; WITH movements AS (
            SELECT PlanningRunKey,ProductKey,DateKey,SUM(CASE WHEN EventCode='BUY_ORDER' THEN Quantity ELSE -Quantity END) delta
            FROM #Fact_SimulationEvent WHERE EventCode IN ('BUY_ORDER','BUY_RECEIVE_GOOD','BUY_REJECT')
            GROUP BY PlanningRunKey,ProductKey,DateKey), balances AS (
            SELECT d.OpenPurchaseQty,SUM(COALESCE(e.delta,0)) OVER
            (PARTITION BY d.PlanningRunKey,d.ProductKey ORDER BY d.DateKey ROWS UNBOUNDED PRECEDING) expected
            FROM #Fact_SimulationDaily d LEFT JOIN movements e ON e.PlanningRunKey=d.PlanningRunKey
            AND e.ProductKey=d.ProductKey AND e.DateKey=d.DateKey)
            SELECT @checkCount=COUNT(*) FROM balances WHERE ABS(OpenPurchaseQty-expected)>0.00001; IF @checkCount<>0 THROW 51000,N'DQ: Pending purchase state conservation',1;

IF (SELECT COUNT(*) FROM #Fact_SimulationDaily d LEFT JOIN
            (SELECT PlanningRunKey,DateKey,ProductKey,
             SUM(CASE WHEN EventCode='SHIP_ON_TIME' THEN Quantity ELSE 0 END) ont,
             SUM(CASE WHEN EventCode='SHIP_LATE' THEN Quantity ELSE 0 END) late,
             SUM(CASE WHEN EventCode='LOST_SALE' THEN Quantity ELSE 0 END) lost
             FROM #Fact_SimulationEvent GROUP BY PlanningRunKey,DateKey,ProductKey) e
            ON d.PlanningRunKey=e.PlanningRunKey AND d.DateKey=e.DateKey AND d.ProductKey=e.ProductKey
            WHERE ABS(d.OnTimeDeliveredQty-COALESCE(e.ont,0))>0.00001 OR ABS(d.LateDeliveredQty-COALESCE(e.late,0))>0.00001
               OR ABS(d.LostQty-COALESCE(e.lost,0))>0.00001)<>0 THROW 51000,N'DQ: Daily/event customer quantities',1;

IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN
            (SELECT PlanningRunKey,AVG(total) average_value FROM (SELECT PlanningRunKey,DateKey,SUM(OnHandValue+WIPValue) total
             FROM #Fact_SimulationDaily GROUP BY PlanningRunKey,DateKey) totals GROUP BY PlanningRunKey) d
            ON s.PlanningRunKey=d.PlanningRunKey WHERE ABS(s.AvgInventoryValue-d.average_value)>0.0001)<>0 THROW 51000,N'DQ: Summary inventory valuation',1;

IF (SELECT COUNT(*) FROM #Fact_PolicySimulation WHERE
            ABS(OpeningBacklogQty+TotalDemandQty-FilledQty-LostQty-EndingBacklogQty)>0.00001)<>0 THROW 51000,N'DQ: Product demand conservation',1;

IF (SELECT COUNT(*) FROM #Fact_PolicySimulation p LEFT JOIN
            (SELECT PlanningRunKey,ProductKey,COUNT(*) n,AVG(OnHandQty) oh,AVG(ProductionWIPQty) wip,
              AVG(OnHandValue+WIPValue) val,SUM(CustomerBacklogQty) late FROM #Fact_SimulationDaily GROUP BY PlanningRunKey,ProductKey) d
            ON p.PlanningRunKey=d.PlanningRunKey AND p.ProductKey=d.ProductKey WHERE d.n IS NULL OR p.SimulatedDays<>d.n
            OR ABS(p.AvgOnHandQty-d.oh)>0.00001 OR ABS(p.AvgWIPQty-d.wip)>0.00001 OR ABS(p.AvgInventoryValue-d.val)>0.0001
            OR ABS(p.LateUnitDays-d.late)>0.00001 OR p.AvgInTransitQty<>0 OR p.AvgInTransitValue<>0)<>0 THROW 51000,N'DQ: Product calendar and valuation',1;

IF (SELECT COUNT(*) FROM (SELECT DISTINCT PlanningRunKey,ProductKey FROM #Fact_SimulationDaily) d
            LEFT JOIN #Fact_PolicySimulation p ON p.PlanningRunKey=d.PlanningRunKey AND p.ProductKey=d.ProductKey WHERE p.ProductKey IS NULL)<>0 THROW 51000,N'DQ: Product summary coverage',1;

IF (SELECT COUNT(*) FROM #Fact_RunSummary s JOIN
                (SELECT PlanningRunKey,SUM(TotalDemandQty) due,SUM(OnTimeDeliveredQty) ont,SUM(LostQty) lost,SUM(LateUnitDays) late
                 FROM #Fact_PolicySimulation WHERE ProductKey IN (SELECT p FROM #service_products) GROUP BY PlanningRunKey) p
                ON s.PlanningRunKey=p.PlanningRunKey WHERE ABS(s.CustomerDueQty-p.due)>0.00001 OR ABS(s.OnTimeDeliveredQty-p.ont)>0.00001
                OR ABS(s.LostQty-p.lost)>0.00001 OR ABS(s.LateUnitDays-p.late)>0.00001)<>0 THROW 51000,N'DQ: Same-cohort summary totals',1;

IF (SELECT COUNT(*) FROM (SELECT PlanningRunKey,StreamCode,EventIdentity,DrawIndex
            FROM #Fact_StochasticDraw GROUP BY PlanningRunKey,StreamCode,EventIdentity,DrawIndex HAVING COUNT(*)>1) q)<>0 THROW 51000,N'DQ: Stochastic draw uniqueness',1;

IF EXISTS (SELECT 1 FROM #Fact_PolicySimulation WHERE SimulatedDays<>@days) THROW 51000,N'Full calendar days',1;

IF EXISTS (SELECT 1 FROM #Fact_PolicySimulation WHERE ABS(HoldingCost-AvgInventoryValue*@days*CONVERT(decimal(28,8),JSON_VALUE(@spec,'$.holding_cost_rate_per_year'))/365.0)>0.0001) THROW 51000,N'Annual holding cost',1;

IF EXISTS (SELECT DecisionAt FROM #Fact_OptimizationSolve GROUP BY DecisionAt HAVING COUNT(*)>1) THROW 51000,N'Solve identity',1;

IF EXISTS (SELECT 1 FROM #Fact_OptimizationSolve WHERE ActionSource NOT IN ('SOLVER_INCUMBENT','WARM_START','FALLBACK','NONE') OR SolverSeconds<0 OR InformationCutoffAt>DecisionAt OR (ActionSource='SOLVER_INCUMBENT' AND (HasFeasibleSolution=0 OR SolverStatus NOT IN ('OPTIMAL','NEAR_OPTIMAL','FEASIBLE_TIME_LIMIT') OR DecisionOutputReference IS NULL))) THROW 51000,N'Solve semantics',1;

IF @policy='ROP' AND (EXISTS(SELECT 1 FROM #Fact_OptimizationSolve) OR EXISTS(SELECT 1 FROM #Fact_RunSummary WHERE SolverSeconds IS NOT NULL)) THROW 51000,'ROP solver semantics',1;

IF @existing=0 INSERT dss.Fact_SimulationOrder ([PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt]) SELECT [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] FROM #Fact_SimulationOrder;

IF EXISTS(SELECT [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] FROM dss.Fact_SimulationOrder WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] FROM #Fact_SimulationOrder) OR EXISTS(SELECT [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] FROM #Fact_SimulationOrder EXCEPT SELECT [PlanningRunKey],[CustomerOrderCode],[SourceSalesOrderID],[SourceRecordReference],[KnownAt],[DueAt],[ExpectedLineCount],[OrderStatus],[CompletedAt],[CancelledAt],[CancellationReason],[LoadBatchID],[LoadedAt] FROM dss.Fact_SimulationOrder WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_SimulationOrder',1;

IF @existing=0 INSERT dss.RunEntity ([PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode]) SELECT [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] FROM #RunEntity;

IF EXISTS(SELECT [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] FROM dss.RunEntity WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] FROM #RunEntity) OR EXISTS(SELECT [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] FROM #RunEntity EXCEPT SELECT [PlanningRunKey],[EntityCode],[EntityType],[ProductKey],[OriginalQty],[OpeningRemainingQty],[CreatedAt],[DueAt],[PromisedAvailableAt],[IsOpeningEntity],[SourceRecordReference],[ScenarioVersionKey],[InitialEntityCode],[InitialDemandLineCode],[CustomerOrderCode] FROM dss.RunEntity WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: RunEntity',1;

IF @existing=0 INSERT dss.Bridge_RunEntityRelation ([PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey]) SELECT [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] FROM #Bridge_RunEntityRelation;

IF EXISTS(SELECT [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] FROM dss.Bridge_RunEntityRelation WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] FROM #Bridge_RunEntityRelation) OR EXISTS(SELECT [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] FROM #Bridge_RunEntityRelation EXCEPT SELECT [PlanningRunKey],[ParentEntityCode],[ChildEntityCode],[RelationCode],[AllocatedQty],[AllocatedProductKey] FROM dss.Bridge_RunEntityRelation WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Bridge_RunEntityRelation',1;

IF @existing=0 INSERT dss.Fact_OptimizationSolve ([PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt]) SELECT [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] FROM #Fact_OptimizationSolve;

IF EXISTS(SELECT [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] FROM dss.Fact_OptimizationSolve WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] FROM #Fact_OptimizationSolve) OR EXISTS(SELECT [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] FROM #Fact_OptimizationSolve EXCEPT SELECT [PlanningRunKey],[SolveSequence],[DecisionAt],[AttemptNo],[ObjectiveStage],[InformationCutoffAt],[HorizonEndAt],[PlanningForecastRunKey],[ForecastInputReference],[StateInputReference],[DecisionOutputReference],[SolverStatus],[HasFeasibleSolution],[ActionSource],[ObjectiveValue],[BestBound],[RelativeGap],[SolverSeconds],[LoadBatchID],[LoadedAt] FROM dss.Fact_OptimizationSolve WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_OptimizationSolve',1;

IF @existing=0 INSERT dss.Fact_SimulationDaily ([PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty]) SELECT [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] FROM #Fact_SimulationDaily;

IF EXISTS(SELECT [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] FROM dss.Fact_SimulationDaily WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] FROM #Fact_SimulationDaily) OR EXISTS(SELECT [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] FROM #Fact_SimulationDaily EXCEPT SELECT [PlanningRunKey],[DateKey],[ProductKey],[LocationKey],[OnHandQty],[ProductionWIPQty],[QueuedProductionQty],[PurchaseInTransitQty],[CustomerBacklogQty],[CustomerDueQty],[OnTimeDeliveredQty],[LateDeliveredQty],[LostQty],[BOMConsumedQty],[PurchaseAcceptedQty],[PurchaseRejectedQty],[ProductionGoodQty],[OnHandValue],[WIPValue],[OwnedInTransitValue],[LoadBatchID],[OpenPurchaseQty] FROM dss.Fact_SimulationDaily WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_SimulationDaily',1;

IF @existing=0 INSERT dss.Fact_SimulationEvent ([PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence]) SELECT [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] FROM #Fact_SimulationEvent;

IF EXISTS(SELECT [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] FROM dss.Fact_SimulationEvent WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] FROM #Fact_SimulationEvent) OR EXISTS(SELECT [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] FROM #Fact_SimulationEvent EXCEPT SELECT [PlanningRunKey],[EventSequence],[EventAt],[DateKey],[EventCode],[EntityCode],[RelatedEntityCode],[SourceRecordReference],[ProductKey],[FromLocationKey],[ToLocationKey],[Quantity],[SupplyOptionKey],[RouteStepKey],[KnownAt],[LoadBatchID],[ReasonCode],[ProductionExecutionCode],[OrderActionCode],[DecisionSolveSequence] FROM dss.Fact_SimulationEvent WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_SimulationEvent',1;

IF @existing=0 INSERT dss.Fact_StochasticDraw ([PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty]) SELECT [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] FROM #Fact_StochasticDraw;

IF EXISTS(SELECT [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] FROM dss.Fact_StochasticDraw WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] FROM #Fact_StochasticDraw) OR EXISTS(SELECT [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] FROM #Fact_StochasticDraw EXCEPT SELECT [PlanningRunKey],[DrawSequence],[DistributionKey],[StreamCode],[EventIdentity],[DrawIndex],[RawSampleValue],[AppliedValue],[KnownAt],[DrawKind],[TrialQty] FROM dss.Fact_StochasticDraw WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_StochasticDraw',1;

IF @existing=0 INSERT dss.Fact_PolicySimulation ([PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID]) SELECT [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] FROM #Fact_PolicySimulation;

IF EXISTS(SELECT [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] FROM dss.Fact_PolicySimulation WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] FROM #Fact_PolicySimulation) OR EXISTS(SELECT [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] FROM #Fact_PolicySimulation EXCEPT SELECT [PlanningRunKey],[ProductKey],[SimulatedDays],[InitialOnHandQty],[OpeningBacklogQty],[TotalDemandQty],[OnTimeDeliveredQty],[LateDeliveredQty],[FilledQty],[LostQty],[EndingBacklogQty],[LateUnitDays],[OnTimeUnitRate],[FillRate],[AvgOnHandQty],[AvgWIPQty],[AvgInTransitQty],[AvgInventoryValue],[AvgInTransitValue],[HoldingCost],[LoadBatchID] FROM dss.Fact_PolicySimulation WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_PolicySimulation',1;

IF @existing=0 INSERT dss.Fact_RunSummary ([PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate]) SELECT [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] FROM #Fact_RunSummary;

IF EXISTS(SELECT [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] FROM dss.Fact_RunSummary WHERE PlanningRunKey=@runKey EXCEPT SELECT [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] FROM #Fact_RunSummary) OR EXISTS(SELECT [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] FROM #Fact_RunSummary EXCEPT SELECT [PlanningRunKey],[EvaluationScope],[CustomerDueQty],[OnTimeDeliveredQty],[OnTimeUnitRate],[LostQty],[EndingBacklogQty],[LateUnitDays],[AvgInventoryValue],[AvgOwnedInTransitValue],[WallClockSeconds],[SolverSeconds],[ValidationStatus],[ValidationNote],[OpeningBacklogQty],[LateDeliveredQty],[FilledQty],[DueOrderCount],[OnTimeFullOrderCount],[LostOrderCount],[OnTimeFullOrderRate] FROM dss.Fact_RunSummary WHERE PlanningRunKey=@runKey) THROW 51000,N'Published rows differ: Fact_RunSummary',1;

IF @existing=0 UPDATE dss.Dim_PlanningRun SET RunStatus='SUCCEEDED',CompletedAt=SYSUTCDATETIME() WHERE PlanningRunKey=@runKey;

IF (SELECT COUNT(*) n FROM dss.Fact_PolicySimulation p LEFT JOIN
        (SELECT PlanningRunKey,ProductKey,SUM(OTUDemandQty) demand,SUM(OTUOnTimeQty) ont,
          SUM(CASE WHEN EvaluationCohort<>'FUTURE_DUE' THEN FilledQty ELSE 0 END) filled,
          SUM(CASE WHEN EvaluationCohort<>'FUTURE_DUE' THEN LostQty ELSE 0 END) lost,
          SUM(OverdueUnfilledQtyAtEnd) backlog,SUM(LateUnitDays) late
         FROM dss.v_SimulationOrderLine WHERE PlanningRunKey=@runKey GROUP BY PlanningRunKey,ProductKey) v
        ON p.PlanningRunKey=v.PlanningRunKey AND p.ProductKey=v.ProductKey WHERE p.PlanningRunKey=@runKey AND
        (ABS(p.TotalDemandQty-COALESCE(v.demand,0))>0.00001 OR ABS(p.OnTimeDeliveredQty-COALESCE(v.ont,0))>0.00001 OR
         ABS(p.FilledQty-COALESCE(v.filled,0))>0.00001 OR ABS(p.LostQty-COALESCE(v.lost,0))>0.00001 OR
         ABS(p.EndingBacklogQty-COALESCE(v.backlog,0))>0.00001 OR ABS(p.LateUnitDays-COALESCE(v.late,0))>0.00001))<>0 THROW 51000,'SQL view KPI reconciliation failed',1;

-- Reread every source artifact before commit; a failed check rolls all inserts back.
 DECLARE unchanged CURSOR LOCAL FAST_FORWARD FOR SELECT Path,Hash FROM #files;
 OPEN unchanged; FETCH NEXT FROM unchanged INTO @path,@expected;
 WHILE @@FETCH_STATUS=0 BEGIN
  EXEC #read_file @path,@raw OUTPUT,@json OUTPUT;
  IF LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',@raw),2))<>@expected THROW 51000,'Artifact changed during publication',1;
  FETCH NEXT FROM unchanged INTO @path,@expected;
 END; CLOSE unchanged; DEALLOCATE unchanged;

 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationOrder WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_SimulationOrder') THROW 51000,'Existing run changed: Fact_SimulationOrder',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.RunEntity WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='RunEntity') THROW 51000,'Existing run changed: RunEntity',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Bridge_RunEntityRelation WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Bridge_RunEntityRelation') THROW 51000,'Existing run changed: Bridge_RunEntityRelation',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_OptimizationSolve WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_OptimizationSolve') THROW 51000,'Existing run changed: Fact_OptimizationSolve',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationDaily WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_SimulationDaily') THROW 51000,'Existing run changed: Fact_SimulationDaily',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_SimulationEvent WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_SimulationEvent') THROW 51000,'Existing run changed: Fact_SimulationEvent',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_StochasticDraw WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_StochasticDraw') THROW 51000,'Existing run changed: Fact_StochasticDraw',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_PolicySimulation WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_PolicySimulation') THROW 51000,'Existing run changed: Fact_PolicySimulation',1;
 IF EXISTS(SELECT COUNT_BIG(*),CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dss.Fact_RunSummary WHERE PlanningRunKey<>@runKey EXCEPT SELECT RowsBefore,ChecksumBefore FROM #oldFacts WHERE TableName='Fact_RunSummary') THROW 51000,'Existing run changed: Fact_RunSummary',1;

 IF OBJECT_ID('cxolap.ControlRunScope','U') IS NULL
 CREATE TABLE cxolap.ControlRunScope(
   PlanningRunKey int NOT NULL PRIMARY KEY REFERENCES dss.Dim_PlanningRun(PlanningRunKey),
   RunCode uniqueidentifier NOT NULL UNIQUE, RequestID nvarchar(100) NOT NULL UNIQUE,
   ScopeFileSHA256 char(64) NOT NULL, ScopeJSON nvarchar(max) NOT NULL CHECK(ISJSON(ScopeJSON)=1),
   ProductScopeMode varchar(30) NOT NULL, InitialStateMode varchar(30) NOT NULL,
   StartDate date NOT NULL, EndDate date NOT NULL, PublishedAt datetime2 NOT NULL);
 IF @existing=0 INSERT cxolap.ControlRunScope
 SELECT @runKey,@runCode,JSON_VALUE(@scope,'$.request_id'),(SELECT Hash FROM #files WHERE Name='scope.json'),@scope,
 JSON_VALUE(@scope,'$.product_scope_mode'),JSON_VALUE(@scope,'$.initial_state_mode'),JSON_VALUE(@scope,'$.start'),JSON_VALUE(@scope,'$.end'),SYSUTCDATETIME();
 IF NOT EXISTS(SELECT 1 FROM cxolap.ControlRunScope WHERE PlanningRunKey=@runKey AND RunCode=@runCode AND ScopeFileSHA256=(SELECT Hash FROM #files WHERE Name='scope.json'))
 THROW 51000,'Existing scoped publication provenance mismatch',1;
 DECLARE @proof nvarchar(max)=(SELECT @version [schema],'SSIS_CONTROL_NATIVE_SQL_V1' implementation,@completionHash completion_sha256,@runKey PlanningRunKey,'PASSED' relational_checks,'PASSED' sql_views,'EXACT_TYPED_BIDIRECTIONAL_COMPARE' database_verification FOR JSON PATH,WITHOUT_ARRAY_WRAPPER);
 IF @existing=0 UPDATE sim_etl.LoadBatch SET Status='SUCCEEDED',ValidationStatus='PASSED',LoadCompletedAt=SYSUTCDATETIME(),ValidationSummary=@proof WHERE LoadBatchID=@batchKey;
 COMMIT;
 SELECT CONVERT(nvarchar(4000),(SELECT CASE WHEN @existing=1 THEN 'ALREADY_LOADED' ELSE 'LOADED' END status,DB_NAME() [database],@runKey PlanningRunKey,@batchKey LoadBatchID,'SUCCEEDED' RunStatus,JSON_QUERY(@proof) proof FOR JSON PATH,WITHOUT_ARRAY_WRAPPER)) PublicationReceipt;
END TRY
BEGIN CATCH
 IF XACT_STATE()<>0 ROLLBACK;
 THROW;
END CATCH;

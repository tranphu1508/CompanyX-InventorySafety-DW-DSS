"""Preserve per-artifact bytes while comparing inquiry requests by typed JSON content."""
from .derive_inquiry_v2 import build_inquiry_v2

# Objects may reorder keys; array positions, scalar types, values and empty
# containers remain significant. Length-prefixed keys avoid path ambiguities.
SEMANTIC_TREE_SQL = r"""
 IF ISJSON(@storedInquiryRequest,OBJECT)<>1 OR ISJSON(@currentInquiryRequest,OBJECT)<>1
 THROW 51000,'Inquiry request must be a JSON object',1;
 ;WITH RequestRoots AS (
  SELECT CONVERT(tinyint,0) Side,@storedInquiryRequest NodeValue
  UNION ALL SELECT CONVERT(tinyint,1),@currentInquiryRequest
 ), RequestTree AS (
  SELECT Side,CONVERT(nvarchar(4000),N'$') COLLATE Latin1_General_100_BIN2 NodePath,CONVERT(int,5) NodeType,CONVERT(nvarchar(max),NodeValue) COLLATE Latin1_General_100_BIN2 NodeValue FROM RequestRoots
  UNION ALL
  SELECT t.Side,CONVERT(nvarchar(4000),t.NodePath+N'/'+CONVERT(nvarchar(10),DATALENGTH(j.[key])/2)+N':'+j.[key]) COLLATE Latin1_General_100_BIN2,CONVERT(int,j.[type]),CONVERT(nvarchar(max),j.[value]) COLLATE Latin1_General_100_BIN2
  FROM RequestTree t CROSS APPLY OPENJSON(CASE WHEN t.NodeType IN(4,5) THEN t.NodeValue ELSE N'{}' END) j
 )
 SELECT Side,NodePath COLLATE Latin1_General_100_BIN2 NodePath,NodeType,
  (CASE WHEN NodeType IN(4,5) THEN NULL ELSE NodeValue END) COLLATE Latin1_General_100_BIN2 NodeValue
 INTO #InquiryRequestNodes FROM RequestTree OPTION(MAXRECURSION 64);
 IF EXISTS(SELECT 1 FROM #InquiryRequestNodes WHERE DATALENGTH(NodePath)>=8000)
 THROW 51000,'Inquiry JSON property path exceeds validation limit',1;
 IF EXISTS(SELECT Side,NodePath FROM #InquiryRequestNodes GROUP BY Side,NodePath HAVING COUNT_BIG(*)>1)
 THROW 51000,'Duplicate inquiry JSON property path',1;
 IF EXISTS(SELECT CONVERT(varbinary(8000),NodePath),NodeType,CONVERT(varbinary(max),NodeValue) FROM #InquiryRequestNodes WHERE Side=0 EXCEPT SELECT CONVERT(varbinary(8000),NodePath),NodeType,CONVERT(varbinary(max),NodeValue) FROM #InquiryRequestNodes WHERE Side=1)
 OR EXISTS(SELECT CONVERT(varbinary(8000),NodePath),NodeType,CONVERT(varbinary(max),NodeValue) FROM #InquiryRequestNodes WHERE Side=1 EXCEPT SELECT CONVERT(varbinary(8000),NodePath),NodeType,CONVERT(varbinary(max),NodeValue) FROM #InquiryRequestNodes WHERE Side=0)
 THROW 51000,'Existing inquiry request semantic content differs',1;
 DROP TABLE #InquiryRequestNodes;
"""

def build_inquiry_v2_semantic(project):
    sql=build_inquiry_v2(project)
    def change(old,new):
        nonlocal sql
        if sql.count(old)!=1:raise ValueError('Semantic inquiry derivation point changed: '+old[:90])
        sql=sql.replace(old,new)
    change(" IF OBJECT_ID('cxcontrol.InquiryPurpose','U') IS NULL THROW 51000,'Install inquiry purpose schema first',1;",
           " IF OBJECT_ID('cxcontrol.CandidateRequestIdentity','U') IS NULL THROW 51000,'Install candidate request identity schema first',1;\n IF OBJECT_ID('cxcontrol.InquiryPurpose','U') IS NULL THROW 51000,'Install inquiry purpose schema first',1;")
    change(" IF NOT EXISTS(SELECT 1 FROM cxcontrol.Inquiry WHERE InquiryKey=@inquiryKey AND RequestHash=@requestHash AND BaseRunCode=CONVERT(uniqueidentifier,JSON_VALUE(@scope,'$.base_run_code')))\n THROW 51000,'Existing inquiry manifest differs',1;",
           """ IF NOT EXISTS(SELECT 1 FROM cxcontrol.Inquiry WHERE InquiryKey=@inquiryKey
 AND BaseRunCode=CONVERT(uniqueidentifier,JSON_VALUE(@scope,'$.base_run_code'))
 AND KnownAt=CONVERT(date,JSON_VALUE(@scope,'$.known_at')) AND AnalysisEnd=CONVERT(date,JSON_VALUE(@scope,'$.analysis_end'))
 AND SourceSnapshotHash=JSON_VALUE(@scope,'$.base_snapshot_sha256'))
 THROW 51000,'Existing inquiry source or dates differ',1;
 DECLARE @storedInquiryRequest nvarchar(max)=(SELECT RequestJSON FROM cxcontrol.Inquiry WHERE InquiryKey=@inquiryKey),
 @currentInquiryRequest nvarchar(max)=(SELECT Json FROM #files WHERE Name='request.json');
"""+SEMANTIC_TREE_SQL)
    change(" IF NOT EXISTS(SELECT 1 FROM cxcontrol.InquiryPurpose WHERE InquiryKey=@inquiryKey AND Purpose=@purposeValue\n  AND RequestHash=@requestHash AND MetadataHash=@purposeMetadataHash AND BindingHash=@purposeBindingHash)\n  THROW 51000,'Existing inquiry purpose metadata differs',1;",
           """ DECLARE @canonicalRequestHash char(64)=JSON_VALUE(@publicationPurpose,'$.request_canonical_sha256');
 IF ISNULL(LEN(JSON_VALUE(@publicationPurpose,'$.request_canonical_sha256')),0)<>64 OR @canonicalRequestHash COLLATE Latin1_General_100_BIN2 LIKE '%[^0-9a-f]%'
 THROW 51000,'Invalid canonical request identity',1;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.InquiryPurpose p JOIN cxcontrol.Inquiry i ON i.InquiryKey=p.InquiryKey
 WHERE p.InquiryKey=@inquiryKey AND p.Purpose=@purposeValue AND p.RequestHash=i.RequestHash AND p.MetadataHash=@purposeMetadataHash
 AND p.PurposeSource='OWNED_JOB_METADATA_V2'
 AND JSON_VALUE(p.BindingJSON,'$.request_canonical_sha256')=@canonicalRequestHash
 AND JSON_VALUE(p.BindingJSON,'$.parent_request_file_sha256')=JSON_VALUE(@publicationPurpose,'$.parent_request_file_sha256')
 AND JSON_VALUE(p.BindingJSON,'$.request_id')=JSON_VALUE(@publicationPurpose,'$.request_id')
 AND JSON_VALUE(p.BindingJSON,'$.inquiry_id')=JSON_VALUE(@publicationPurpose,'$.inquiry_id')
 AND JSON_VALUE(p.BindingJSON,'$.job_folder') COLLATE Latin1_General_100_BIN2=JSON_VALUE(@publicationPurpose,'$.job_folder') COLLATE Latin1_General_100_BIN2)
 THROW 51000,'Existing inquiry purpose semantic binding differs',1;
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.CandidateRequestIdentity WHERE PlanningRunKey=@runKey)
  INSERT cxcontrol.CandidateRequestIdentity(PlanningRunKey,InquiryKey,RequestFileHash,CanonicalRequestHash,PurposeBindingHash,MetadataHash,BindingJSON)
  VALUES(@runKey,@inquiryKey,@requestHash,@canonicalRequestHash,@purposeBindingHash,@purposeMetadataHash,@publicationPurpose);
 IF NOT EXISTS(SELECT 1 FROM cxcontrol.CandidateRequestIdentity WHERE PlanningRunKey=@runKey AND InquiryKey=@inquiryKey
 AND RequestFileHash=@requestHash AND CanonicalRequestHash=@canonicalRequestHash AND PurposeBindingHash=@purposeBindingHash AND MetadataHash=@purposeMetadataHash)
 THROW 51000,'Existing candidate raw request/purpose binding differs',1;""")
    # Materialize membership once: do not reparse the large scope per sales row.
    member="SELECT CONVERT(int,value) FROM OPENJSON(@scope,'$.synthetic_sales_order_line_ids')"
    if sql.count(member)!=6:raise ValueError('Synthetic line membership derivation changed')
    sql=sql.replace(member,"SELECT LineID FROM #SyntheticLineIDs")
    marker=" -- Recheck the same sales cohort and effective BOM as the original native adapter."
    if sql.count(marker)!=1:raise ValueError('Sales validation derivation point changed')
    sql=sql.replace(marker," CREATE TABLE #SyntheticLineIDs(LineID int NULL);\n INSERT #SyntheticLineIDs(LineID) "+member+";\n CREATE INDEX IX_SyntheticLineIDs ON #SyntheticLineIDs(LineID);\n"+marker)
    return sql

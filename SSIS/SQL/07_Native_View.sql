CREATE OR ALTER VIEW dss.v_ExperimentCaseExecution AS
SELECT c.*, e.ExperimentCode,
 CASE WHEN c.RuleSetVersion='companyx.ssis.native.v1' THEN 'SSIS_NATIVE'
      WHEN c.RuleSetVersion='companyx.dw.sql63.v2' THEN 'PORTABLE_V2'
      ELSE 'LEGACY_READ_ONLY' END ExecutionCompatibility
FROM dss.ExperimentCase c JOIN dss.Dim_ExperimentVersion e ON c.ExperimentVersionKey=e.ExperimentVersionKey;

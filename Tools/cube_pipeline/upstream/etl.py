"""Run the original SSIS ETL against the owned CompanyX warehouse copy."""
import argparse
from contextlib import closing, contextmanager, nullcontext
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from xml.etree import ElementTree as ET
from xml.sax.saxutils import escape
from zipfile import ZipFile

import pyodbc


HERE = Path(__file__).resolve().parent
DEMO = HERE.parents[2]
GPT = DEMO / '_local'
ISPAC = DEMO / 'SSIS/SourceTemplate/CompanyX.ispac.template.zip'
DTEXEC = Path(os.environ["ProgramFiles"]) / "Microsoft SQL Server" / "160" / "DTS" / "Binn" / "DTExec.exe"
PACKAGE = "20_ETL.dtsx"
SOURCE = "CompanyX_Demo"
ORIGINAL_TARGET = "InventorySafety_Demo"
TARGET = "CompanyX_DW_ACT_20261107"
TARGET_GUARD = (
    f"DB_NAME()<>N'{TARGET}' OR NOT EXISTS(SELECT 1 FROM sys.extended_properties "
    "WHERE class=0 AND name=N'CompanyXSplitOwner' AND "
    "CONVERT(nvarchar(100),value)=N'companyx-split-20261107')"
)
SQL_FILES = ("00_Acquire_Source.sql", "04_Guard_Warehouse.sql", "05_Verify_ETL.sql")
SSIS = "www.microsoft.com/SqlServer/SSIS"
NS = {"s": SSIS}
ET.register_namespace("SSIS", SSIS)


def timestamp():
    return datetime.now(timezone.utc).isoformat()


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest().upper()


def replace_exact(value, old, new, count=1):
    if value.count(old) != count:
        raise ValueError(f"Expected {count} occurrences of {old!r}. Review the SSIS project before running.")
    return value.replace(old, new)


def parameter_value(container, name):
    values = container.findall(f".//s:Parameter[@s:Name='{name}']/s:Properties/s:Property[@s:Name='Value']", NS)
    if len(values) != 1:
        raise ValueError(f"Expected exactly one value for SSIS parameter {name}.")
    return values[0]


def write_sql_inputs(stage):
    sql_dir = stage / "SSIS" / "SQL"
    sql_dir.mkdir(parents=True)
    for name in SQL_FILES:
        sql = (DEMO / "SSIS" / "SQL" / name).read_bytes().decode("utf-8-sig")
        if name == "00_Acquire_Source.sql":
            for param, original, expected in (
                ("SourceDatabase", SOURCE, SOURCE), ("TargetDatabase", ORIGINAL_TARGET, TARGET)
            ):
                sql = replace_exact(sql, f"LEFT(@{param},LEN(N'{original}'))<>N'{original}'", f"@{param}<>N'{expected}'")
        else:
            sql = replace_exact(sql, "LEFT(DB_NAME(),LEN(N'InventorySafety_Demo'))<>N'InventorySafety_Demo'", TARGET_GUARD)
        (sql_dir / name).write_bytes(sql.encode("utf-8"))
    db_dir = stage / "Database"
    db_dir.mkdir()
    shutil.copyfile(DEMO / "Database" / "03_ETL.sql", db_dir / "03_ETL.sql")


def configure_project(stage):
    """Edit settings in a private ZIP copy; keep the source data flows byte-for-byte."""
    output = stage / "CompanyX_ETL.ispac"
    parts = {}
    with ZipFile(ISPAC) as original:
        params = ET.fromstring(original.read("Project.params"))
        server = parameter_value(params, "ServerName").text
        source = parameter_value(params, "SourceDatabase").text
        target = parameter_value(params, "TargetDatabase")
        package_root = parameter_value(params, "PackageRoot")
        if (server, source, target.text) != ("localhost", SOURCE, ORIGINAL_TARGET) or not package_root.text:
            raise ValueError("Expected the original local CompanyX SSIS project parameters.")
        original_root = Path(package_root.text)
        target.text, package_root.text = TARGET, str(stage)
        parts["Project.params"] = ET.tostring(params, encoding="utf-8", xml_declaration=True)

        manifest = ET.fromstring(original.read("@Project.manifest"))
        packages = manifest.findall(f".//s:PackageMetaData[@s:Name='{PACKAGE}']", NS)
        if len(packages) != 1:
            raise ValueError("Expected a single 20_ETL package in the SSIS project manifest.")
        for name in ("FlowRead", "FlowWrite", "Warehouse"):
            value = parameter_value(packages[0], f"CM.{name}.InitialCatalog")
            if value.text != ORIGINAL_TARGET:
                raise ValueError(f"Unexpected original {name} connection.")
            value.text = TARGET
        # SSIS 2022 expects the Project element at the start of the manifest.
        parts["@Project.manifest"] = ET.tostring(manifest, encoding="utf-8", xml_declaration=False)

        # Keep expressions, task SQL, data-flow IDs, namespace declarations and designer
        # metadata intact. Update the serialized defaults as well as the project parameters.
        task = original.read(PACKAGE).decode("utf-8")
        for relative in [Path("SSIS", "SQL", name) for name in SQL_FILES] + [Path("Database", "03_ETL.sql")]:
            task = replace_exact(task, f'DTS:ConnectionString="{escape(str(original_root / relative))}"',
                                 f'DTS:ConnectionString="{escape(str(stage / relative))}"')
        task = replace_exact(task, f'DTS:ConnectionString="Data Source=localhost;Initial Catalog={ORIGINAL_TARGET};',
                             f'DTS:ConnectionString="Data Source=localhost;Initial Catalog={TARGET};', 3)
        task = replace_exact(task, '''SQLTask:SqlStatementSource="IF DB_NAME() NOT LIKE 'InventorySafety[_]Demo%' ''',
                             f'SQLTask:SqlStatementSource="IF {escape(TARGET_GUARD)} ')
        parts[PACKAGE] = task.encode("utf-8")

        with ZipFile(output, "x") as result:
            for member in original.infolist():
                payload = parts[member.filename] if member.filename in parts else original.read(member)
                result.writestr(member, payload)
    return output


def read_state(connection):
    file_root = str(DEMO / 'Warehouse/Data') + os.sep
    sql = "DECLARE @FileRoot nvarchar(4000)=?;\n" + (HERE / "Read-EtlState.sql").read_text(encoding="utf-8-sig")
    with closing(connection.cursor()) as cursor:
        cursor.execute(sql, file_root)
        return json.loads("".join(row[0] for row in cursor))


@contextmanager
def etl_lock(connection):
    resource = "CompanyX.Split.InputVersion"
    with closing(connection.cursor()) as cur:
        cur.execute("DECLARE @r int; EXEC @r=sys.sp_getapplock @Resource=?,"
                    "@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0; "
                    "IF @r<0 THROW 51050,'Another integrated ETL is running.',1;", resource)
        try:
            yield
        finally:
            cur.execute("EXEC sys.sp_releaseapplock @Resource=?,@LockOwner='Session';", resource)


def invoke_ssis(configured, stage, check_only):
    args = [str(DTEXEC), "/Project", str(configured), "/Package", PACKAGE, "/Reporting", "EW"]
    if check_only:
        args.append("/Validate")
    log = stage / ("dtexec-validate.log" if check_only else "dtexec.log")
    with log.open("wb") as stream:
        code = subprocess.run(args, cwd=stage, stdout=stream, stderr=subprocess.STDOUT).returncode
    if code:
        raise RuntimeError(f"{PACKAGE} failed (DTExec {code}). See {log}")


def run(run_directory, check_only=False):
    run_dir = Path(run_directory).resolve()
    if GPT not in run_dir.parents:
        raise ValueError("Run directory must be inside Project/GPT.")
    stage = run_dir / ("upstream-check" if check_only else "upstream")
    stage.mkdir(parents=True)
    receipt = dict(status="STARTED", startedUtc=timestamp(), source=SOURCE, warehouse=TARGET,
                   package=PACKAGE, originalIspac=str(ISPAC))
    try:
        if not DTEXEC.is_file():
            raise FileNotFoundError(DTEXEC)
        receipt["originalSha256"] = sha256(ISPAC)
        connection = pyodbc.connect(
            f"DRIVER={{ODBC Driver 17 for SQL Server}};SERVER=localhost;DATABASE={TARGET};"
            "Trusted_Connection=yes;TrustServerCertificate=yes;APP=CompanyX integrated demo ETL;",
            autocommit=True, timeout=10)
        with closing(connection), (nullcontext() if check_only else etl_lock(connection)):
            connection.timeout = 120
            before = receipt["before"] = read_state(connection)
            write_sql_inputs(stage)
            configured = configure_project(stage)
            receipt["configuredSha256"] = sha256(configured)
            if check_only:
                invoke_ssis(configured, stage, check_only=True)
                receipt["status"] = "READY"
                receipt["nativeValidation"] = "PASSED"
                print(f"SSIS {PACKAGE} ready for {SOURCE} -> {TARGET}.", flush=True)
                return receipt
            print(f"SSIS {PACKAGE}: {SOURCE} -> {TARGET}", flush=True)
            invoke_ssis(configured, stage, check_only=False)
            after = receipt["after"] = read_state(connection)
            if not (after["lastBatchId"] > before["lastBatchId"] and after["batchStatus"] == "SUCCEEDED"
                    and after["validationStatus"] in ("PASSED", "PASSED_WITH_WARNINGS")
                    and after["lastVersion"] == after["capturedVersion"]
                    and after["previousVersion"] == before["lastVersion"]):
                raise RuntimeError("Warehouse did not confirm a new validated batch at the expected watermark.")
            receipt["status"] = "SUCCEEDED"
            print(f"ETL batch {after['lastBatchId']}: {after['validationStatus']}.", flush=True)
            return receipt
    except Exception as error:
        receipt.update(status="FAILED", error=str(error))
        raise
    finally:
        receipt["completedUtc"] = timestamp()
        (stage / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-directory", required=True, type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    try:
        run(args.run_directory, args.check_only)
    except Exception as error:
        print(f"SSIS upstream: {error}", file=sys.stderr)
        sys.exit(1)

"""Validate SSIS input exports before simulation; never ETL or publish to SQL.

This module replaces the input checks previously hosted by CompanyX.SsisIO.
The numerical simulation under DSS/runtime remains unchanged. SQL access is
limited to SELECT statements against an owned local demo warehouse.
"""
from __future__ import annotations

import argparse
import csv
from datetime import datetime, timezone
from decimal import Decimal
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import sys
import uuid

VERSION = "companyx.ssis.native.v1"
OWNER = "CompanyX_Demo_20261103"
FLOW_COLUMNS = {
    "SalesOrders": ("SalesOrderDetailID", "SalesOrderID", "ProductID", "OrderQty", "OrderDate", "DueDate"),
    "BOM": ("ProductAssemblyID", "ComponentID", "PerAssemblyQty", "UnitMeasureCode"),
    "ProductKeys": ("ProductID", "ProductKey", "ProductName"),
    "SupplyKeys": ("ProductID", "VendorID", "ProductKey", "VendorKey"),
}


def need(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path):
    with path.open("r", encoding="utf-8-sig") as stream:
        return json.load(stream, parse_float=Decimal)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_json(path: Path, value: dict) -> None:
    temp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        with temp.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
    finally:
        if temp.exists():
            temp.unlink()


def invariant(value) -> str:
    """Match the invariant scalar formatting used by the former C# checker."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "True" if value else "False"
    if isinstance(value, Decimal):
        return format(value, "f")
    return str(value)


def validate_names(server: str, source: str, target: str) -> None:
    need(re.fullmatch(r"CompanyX_Demo[A-Za-z0-9_]{0,70}", source) is not None,
         "Only isolated demo source database names are allowed")
    need(re.fullmatch(r"InventorySafety_Demo[A-Za-z0-9_]{0,60}", target) is not None,
         "Only isolated demo target database names are allowed")
    local = {"localhost", ".", socket.gethostname().casefold(), os.environ.get("COMPUTERNAME", "").casefold()}
    local.discard("")
    need(server.casefold() in local, "Local SQL instance only")


def select_only(sql: str) -> str:
    """Reject executable statements in the checked-in input query contract.

    This is deliberately a restricted SELECT interface, not a general SQL
    parser or a replacement for SQL Server permissions. It also rejects SELECT
    INTO and external data sources. Contract data remain on the local server.
    """
    stripped = re.sub(r"N?'(?:''|[^'])*'|\[(?:\]\]|[^\]])*\]", " ", sql, flags=re.I)
    need("--" not in stripped and "/*" not in stripped and "*/" not in stripped,
         "SQL comments are not allowed in input validation queries")
    stripped = stripped.strip()
    if stripped.endswith(";"):
        stripped = stripped[:-1]
    need(";" not in stripped and re.match(r"^SELECT\b", stripped, re.I) is not None,
         "Input validation permits one SELECT statement only")
    forbidden = r"\b(?:INSERT|UPDATE|DELETE|MERGE|INTO|EXEC|EXECUTE|CREATE|ALTER|DROP|TRUNCATE|RESTORE|BACKUP|DBCC|USE|GRANT|DENY|REVOKE|OPENROWSET|OPENQUERY|OPENDATASOURCE)\b"
    need(re.search(forbidden, stripped, re.I) is None,
         "Input validation query contains a forbidden SQL operation")
    return sql


class SqlReader:
    """Windows-authenticated, read-only connection to the local demo target."""
    def __init__(self, server: str, source: str, target: str):
        validate_names(server, source, target)
        try:
            import pyodbc
        except ImportError as exc:
            raise RuntimeError("Install DSS/requirements-base.txt in the demo .venv; pyodbc is required") from exc
        drivers = set(pyodbc.drivers())
        need("ODBC Driver 17 for SQL Server" in drivers,
             "ODBC Driver 17 for SQL Server x64 is required")
        # Driver 17 and Windows authentication match the local SQL installation.
        # No system-wide ODBC, security or SQL configuration is modified.
        self.connection = pyodbc.connect(
            "DRIVER={ODBC Driver 17 for SQL Server};"
            f"SERVER={server};DATABASE={target};Trusted_Connection=Yes;"
            "APP=CompanyX Python input validation;",
            timeout=15, autocommit=True, readonly=True,
        )
        self.connection.timeout = 1800

    def query(self, sql: str, params=()) -> list[dict]:
        select_only(sql)
        cursor = self.connection.cursor()
        try:
            cursor.execute(sql, *params)
            columns = [item[0] for item in cursor.description]
            need(len(columns) == len(set(columns)), "Duplicate SQL result column")
            return [dict(zip(columns, row)) for row in cursor.fetchall()]
        finally:
            cursor.close()

    def scalar(self, sql: str, params=()):
        rows = self.query(sql, params)
        need(len(rows) == 1 and len(rows[0]) == 1, "Expected one SQL scalar")
        return next(iter(rows[0].values()))

    def close(self) -> None:
        self.connection.close()


def verify_core(root: Path) -> None:
    root = root.resolve()
    for relative, expected in read_json(root / "SSIS/core_hashes.json").items():
        path = (root / relative).resolve()
        need(path.is_relative_to(root), "Protected core path escapes the demo folder")
        need(sha256(path) == expected, "Core changed: " + relative)


def verify_guard(db: SqlReader, source: str) -> None:
    need(db.scalar("SELECT COUNT(*) FROM sys.extended_properties WHERE class=0 AND name='CompanyXDemoOwner' AND CONVERT(nvarchar(100),value)=?", (OWNER,)) == 1,
         "Unowned target; refusing input validation")
    need(db.scalar("SELECT COUNT(*) FROM etl_v2.State WHERE SourceDatabase=?", (source,)) == 1,
         "Wrong source binding")
    need(db.scalar("SELECT COUNT(*) FROM etl.ETL_LoadBatch WHERE PipelineName='DWH_INCREMENTAL_V2' AND Status='SUCCEEDED' AND ValidationStatus IN ('PASSED','PASSED_WITH_WARNINGS')") > 0,
         "No validated ETL batch")


def verify_schema(db: SqlReader, root: Path) -> None:
    expected = read_json(root / "SSIS/schema_pin.json")["columns"]
    rows = db.query("SELECT s.name+'.'+t.name TableName,c.name ColumnName,ty.name TypeName,c.max_length MaxLength,c.precision [Precision],c.scale Scale,c.is_nullable IsNullable,c.is_identity IsIdentity FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id JOIN sys.columns c ON c.object_id=t.object_id JOIN sys.types ty ON ty.user_type_id=c.user_type_id")
    actual = {(row["TableName"], row["ColumnName"]): row for row in rows}
    for column in expected:
        key = (column["TableName"], column["ColumnName"])
        need(key in actual, "Required SQL column missing: " + ".".join(key))
        for field in ("TypeName", "MaxLength", "Precision", "Scale", "IsNullable", "IsIdentity"):
            need(invariant(actual[key][field]) == invariant(column[field]),
                 "DW column contract changed: " + ".".join(key) + " " + field)


def verify_source(db: SqlReader, snapshot: dict) -> None:
    ids = sorted({row["SalesOrderID"] for row in snapshot["sales_order_lines"]})
    actual = db.query("SELECT f.SalesOrderDetailID,f.SalesOrderID,p.ProductID,f.OrderQty,CONVERT(char(10),CONVERT(date,CONVERT(char(8),f.OrderDateKey),112),23) OrderDate,CONVERT(char(10),CONVERT(date,CONVERT(char(8),f.DueDateKey),112),23) DueDate,f.IsDemandEligible FROM dw.Fact_SalesOrderLine f JOIN dw.Dim_Product p ON p.ProductKey=f.ProductKey WHERE f.SalesOrderID IN (SELECT value FROM OPENJSON(?)) ORDER BY f.SalesOrderDetailID", (json.dumps(ids),))
    expected = sorted(snapshot["sales_order_lines"], key=lambda row: row["SalesOrderDetailID"])
    need(len(actual) == len(expected), "DW sales cohort missing/extra siblings")
    for found, frozen in zip(actual, expected):
        need(bool(found["IsDemandEligible"]), "Ineligible demand")
        for column in FLOW_COLUMNS["SalesOrders"]:
            need(invariant(found[column]) == invariant(frozen[column]),
                 f"DW snapshot drift {column} detail {frozen['SalesOrderDetailID']}")

    manufactured = [row["ProductID"] for row in snapshot["products"] if row["IsManufactured"]]
    edges = db.query("SELECT a.ProductID ProductAssemblyID,c.ProductID ComponentID,b.PerAssemblyQty,RTRIM(u.UnitMeasureCode) UnitMeasureCode,b.IsStructureValid FROM dw.Bridge_BillOfMaterials b JOIN dw.Dim_Product a ON a.ProductKey=b.AssemblyProductKey JOIN dw.Dim_Product c ON c.ProductKey=b.ComponentProductKey JOIN dw.Dim_UnitMeasure u ON u.UnitMeasureKey=b.UnitMeasureKey WHERE a.ProductID IN (SELECT value FROM OPENJSON(?)) AND b.StartDate<=? AND (b.EndDate IS NULL OR b.EndDate>=?)", (json.dumps(manufactured), snapshot["start"], snapshot["start"]))
    def key(row):
        return f"{row['ProductAssemblyID']}:{row['ComponentID']}:{row['UnitMeasureCode'].strip()}"
    actual_bom = sorted(edges, key=key)
    expected_bom = sorted(snapshot["bom"], key=key)
    need(len(actual_bom) == len(expected_bom), "BOM scope changed")
    for found, frozen in zip(actual_bom, expected_bom):
        need(bool(found["IsStructureValid"]) and key(found) == key(frozen)
             and Decimal(str(found["PerAssemblyQty"])) == Decimal(str(frozen["PerAssemblyQty"])),
             "BOM snapshot drift")


def read_csv(path: Path, name: str) -> list[dict[str, str]]:
    with path.open("rb") as stream:
        prefix = stream.read(3)
    encoding = "utf-8-sig" if prefix == b"\xef\xbb\xbf" else ("utf-16" if prefix[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-16-le")
    with path.open("r", encoding=encoding, newline="") as stream:
        reader = csv.reader(stream, strict=True)
        headers = next(reader, None)
        need(headers == list(FLOW_COLUMNS[name]), f"SSIS input CSV columns changed: {name}")
        rows = []
        for values in reader:
            if not values:  # TextFieldParser also skips empty lines.
                continue
            need(len(values) == len(headers), "CSV column count mismatch: " + str(path))
            rows.append(dict(zip(headers, values)))
        return rows


def check_output_state(folder: Path, source: str, target: str, *, allow_completed=True) -> None:
    need(not folder.exists() or folder.is_dir(), "OutputFolder must be a directory")
    for lock in ("RUNNING.lock", "DW_PUBLISH.lock"):
        need(not (folder / lock).exists(), f"{lock} exists; inspect the retained run before retry")
    completed = (folder / "completion.json").exists()
    need(not (folder / "run.json").exists() or completed,
         "Incomplete run retained. Use a new output folder; no automatic restart or replay.")
    need(allow_completed or not completed,
         "Completed run retained. Use a new OutputFolder or execute 40_NapKetQua to reload results.")
    proof_path = folder / "dw_source_proof.json"
    if proof_path.exists():
        proof = read_json(proof_path)
        need(proof.get("database") == target and proof.get("source_database") == source,
             "Output belongs to another database")


def contracts(root: Path) -> list[dict]:
    flows = read_json(root / "SSIS/dss_input_flows.json")
    need([row.get("name") for row in flows] == list(FLOW_COLUMNS), "SSIS input flow contract changed")
    for flow in flows:
        select_only(flow["query"])
    return flows


def prepare_start(db: SqlReader, root: Path, folder: Path, source: str, target: str) -> None:
    verify_core(root)
    verify_guard(db, source)
    verify_schema(db, root)
    check_output_state(folder, source, target)
    snapshot_path = folder / "input_source.json"
    if snapshot_path.exists():
        need(sha256(snapshot_path) == sha256(root / "DSS/inputs/approved_snapshot.json"),
             "Existing snapshot mismatch")
    if (folder / "completion.json").exists():
        # Check the old run BEFORE SSIS gets a chance to overwrite an export.
        # Matching completed runs retain the former ALREADY_COMPLETE behavior.
        validate_before_simulation(folder, root)
        verify_source(db, read_json(root / "DSS/inputs/approved_snapshot.json"))
        verify_exports(db, root, folder)
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "ssis_input").mkdir(exist_ok=True)


def verify_exports(db: SqlReader, root: Path, folder: Path) -> dict:
    flow_proofs = {}
    for contract in contracts(root):
        name = contract["name"]
        path = folder / "ssis_input" / (name + ".csv")
        rows = read_csv(path, name)
        actual = db.query(contract["query"])
        need(len(rows) == len(actual), "SSIS input row count mismatch: " + name)
        for index, (row, expected) in enumerate(zip(rows, actual)):
            for column in FLOW_COLUMNS[name]:
                need(row[column] == invariant(expected[column]),
                     f"SSIS input mismatch {name} row {index} column {column}")
        flow_proofs[name] = {"rows": len(rows), "sha256": sha256(path)}
    return flow_proofs


def make_proof(db: SqlReader, folder: Path, source: str, target: str) -> dict:
    return {
        "status": "VERIFIED", "schema": VERSION,
        "database": target, "source_database": source,
        "snapshot_file_sha256": sha256(folder / "input_source.json"),
        "etl_batch": db.scalar("SELECT MAX(LoadBatchID) FROM etl.ETL_LoadBatch WHERE PipelineName='DWH_INCREMENTAL_V2' AND Status='SUCCEEDED'"),
        "verified_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def prepare_flow(db: SqlReader, root: Path, folder: Path, source: str, target: str) -> dict:
    verify_core(root)
    verify_guard(db, source)
    verify_schema(db, root)
    check_output_state(folder, source, target)
    approved_path = root / "DSS/inputs/approved_snapshot.json"
    verify_source(db, read_json(approved_path))
    flow_proofs = verify_exports(db, root, folder)
    if (folder / "completion.json").exists():
        proof = validate_before_simulation(folder, root)
        need(proof.get("ssis_data_flows") == flow_proofs,
             "Completed run input exports changed")
        return proof  # Do not rewrite an immutable completed run's proof.
    dest = folder / "input_source.json"
    if dest.exists():
        need(sha256(dest) == sha256(approved_path), "Existing snapshot mismatch")
    else:
        shutil.copy2(approved_path, dest)
    proof = make_proof(db, folder, source, target)
    proof.update({
        "ssis_data_flows": flow_proofs,
        "frozen_parameters": "Retained approved parameters; sales and BOM verified through SSIS exports and live DW",
    })
    atomic_json(folder / "dw_source_proof.json", proof)
    return proof


def prepare(db: SqlReader, root: Path, folder: Path, source: str, target: str) -> dict:
    """Keep the former snapshot-only prepare function for existing callers.

    Normal SSIS packages use prepare-start/prepare-flow and all four exports.
    This action still verifies the live DW cohort and frozen schema before
    copying the approved snapshot; it does not extract or transform SQL data.
    """
    verify_core(root)
    verify_guard(db, source)
    verify_schema(db, root)
    verify_source(db, read_json(root / "DSS/inputs/approved_snapshot.json"))
    check_output_state(folder, source, target)
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / "input_source.json"
    approved_path = root / "DSS/inputs/approved_snapshot.json"
    if dest.exists():
        need(sha256(dest) == sha256(approved_path), "Existing input belongs to another snapshot")
        proof = read_json(folder / "dw_source_proof.json")
        need(proof.get("database") == target and proof.get("source_database") == source,
             "Output belongs to another database")
        return proof
    need(not any(folder.iterdir()), "Use a fresh output folder")
    shutil.copy2(approved_path, dest)
    proof = make_proof(db, folder, source, target)
    proof["input_validation_mode"] = "APPROVED_SNAPSHOT"
    atomic_json(folder / "dw_source_proof.json", proof)
    return proof


def validate_before_simulation(folder: Path, root: Path) -> dict:
    """Recheck local evidence immediately before entering the unchanged core.

    This also accepts completed runs for simulate_only.py's ALREADY_COMPLETE
    path. It does not rewrite proofs, snapshots or completed artifacts.
    """
    root, folder = Path(root).resolve(), Path(folder).resolve()
    verify_core(root)
    proof = read_json(folder / "dw_source_proof.json")
    need(proof.get("status") == "VERIFIED" and proof.get("schema") == VERSION,
         "SSIS input proof missing or incompatible")
    source, target = proof.get("source_database", ""), proof.get("database", "")
    validate_names("localhost", source, target)
    check_output_state(folder, source, target, allow_completed=True)
    source_hash = sha256(folder / "input_source.json")
    need(source_hash == proof.get("snapshot_file_sha256")
         and source_hash == sha256(root / "DSS/inputs/approved_snapshot.json"),
         "SSIS input snapshot missing or changed")
    need(isinstance(proof.get("etl_batch"), int) and proof["etl_batch"] > 0,
         "SSIS input proof has no validated ETL batch")
    flow_proofs = proof.get("ssis_data_flows")
    if proof.get("input_validation_mode") == "APPROVED_SNAPSHOT":
        need(flow_proofs is None, "Ambiguous snapshot/SSIS input proof")
        return proof
    need(isinstance(flow_proofs, dict) and set(flow_proofs) == set(FLOW_COLUMNS),
         "SSIS input proof does not cover all four input flows")
    for contract in contracts(root):
        name = contract["name"]
        path = folder / "ssis_input" / (name + ".csv")
        entry = flow_proofs[name]
        need(sha256(path) == entry.get("sha256"), "SSIS input CSV changed: " + name)
        need(len(read_csv(path, name)) == entry.get("rows"), "SSIS input row count changed: " + name)
    return proof


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "prepare-start", "prepare-flow", "verify"))
    parser.add_argument("--root", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--folder")
    args = parser.parse_args(argv)
    db = None
    try:
        root = Path(args.root).resolve()
        need(args.action == "verify" or bool(args.folder), "--folder is required for input preparation")
        validate_names(args.server, args.source, args.target)
        db = SqlReader(args.server, args.source, args.target)
        if args.action == "verify":
            verify_core(root)
            verify_guard(db, args.source)
            verify_schema(db, root)
        else:
            folder = Path(args.folder).resolve()
            action = {"prepare": prepare, "prepare-start": prepare_start, "prepare-flow": prepare_flow}[args.action]
            action(db, root, folder, args.source, args.target)
        print(args.action + ": PASSED")
        return 0
    except Exception as exc:
        print(f"{args.action}: FAILED: {exc}", file=sys.stderr)
        return 1
    finally:
        if db is not None:
            db.close()


if __name__ == "__main__":
    raise SystemExit(main())

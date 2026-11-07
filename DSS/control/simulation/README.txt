SCOPED COMPANYX SIMULATION ADAPTER — 2026-11-05

Entry: adapter.py. Dependencies are the unchanged demo Python runtime and its
existing .venv. No framework, database connection, SSIS call or cube processing
is performed by this module. It prepares inputs and executes one MILP/DES run.

APIs
  build_request(request, project_root=None) -> prepared dict
  execute_prepared(prepared, output_folder, project_root=None) -> execution receipt
  execute_request(request, output_folder, project_root=None) -> convenience wrapper

The worker may serialize the prepared dict between SSIS stages. execute_prepared
checks snapshot/spec/scope hashes and frozen runtime code hash before execution;
it never silently rebuilds the input from changed configuration. Run folders must
be under Project/GPT. Existing completed/in-progress run files are not overwritten.
Set PYTHONDONTWRITEBYTECODE=1 and launch Python with -B. Adapter sets this too.

NEW_EXPERIMENT
The selected start is a new experiment initialization. Scenario stock is applied
at that date, with zero opening WIP, open purchases and customer obligations.
Only orders created inside [start_date,end_date] are admitted. Due dates after
end_date are retained so unfinished/future-due semantics are not hidden.
Available input window is 2013-07-01 through 2014-06-30. The adapter refuses dates
outside it. No observed inventory state or outstanding orders are reconstructed.
BOM, lead-time, vendor and valuation assumptions stay the frozen base assumptions;
they are not represented as newly reconstructed historical master data.

PRODUCT SCOPE
SELECTED_LINES retains only order lines for requested ProductIDs, then adds every
required BOM dependency recursively. Original order/line IDs stay unchanged but
the scope marks partial original orders as SELECTED_PRODUCT_ORDER_PROJECTION.
Whole-order OTIF then describes the retained part of the order, not the complete
original order. This distinction must remain visible in publication/reporting.

WHOLE_ORDERS first selects orders containing any requested ProductID in the date
window, then includes every original sibling line and all needed BOM dependencies.
It does not recursively add other orders merely because a sibling SKU was added.

Original frozen direct_mu is retained for included independent-demand products;
manufactured BOM-only dependencies have root=False/direct_mu=0 so the optimizer
does not create independent sales forecasts for products excluded from demand.
No forecasting is fitted from evaluation-period orders. For WHOLE_ORDERS, sibling
SKU forecasts are frozen full-SKU means, an explicitly retained approximation for
the selected order cohort. Prices/stock units/reference vendors are copied exactly;
the valuation hash is recomputed only to describe the subset of valuation rows.

RUNTIME BOUNDARIES
The unchanged core requires at least one manufactured demand product and a
manufactured line in every modeled SalesOrder. Purchased-only unsupported inputs
are rejected with structured error codes; no dummy products or fabricated orders
are created. A manufactured ProductID picker is appropriate for the first UI.

SUPPORTED CONTROLS
ScenarioIndex; ROP/QUETSCHLICH_ADAPT; GUROBI/CPLEX; production lead-time convention;
replication; solver seconds/threads; three positive penalty coefficients:
lost_unit_penalty, late_unit_day_penalty, terminal_unserved_unit_penalty.
Inventory/flow objective coefficients are not generalized by this adapter.

ARTIFACT CONTRACT
Prepared: request, snapshot, spec, scope; snapshot_sha256, execution_spec_sha256,
runtime_code_sha256. Scope carries original base dates/file hash, requested and
effective ProductIDs, demand roots, BOM-only IDs, selected original order/line IDs,
partial-order provenance, valuation hashes and explicit initialization meaning.

Execution output: request.json, scope.json, input_source.json, input.json,
execution_spec.json, execution_profile.json, run.json, completion.json,
metrics.json, daily_totals.json, table_manifest.json, valuation_basis.json,
tables/*.jsonl and solver audit artifacts when applicable. Additional receipt:
control_execution_receipt.json. Database/cube publication belongs to the separate
pipeline. Only COMPLETE validated artifacts should be passed to that pipeline.

TESTS
GPT/tmp/companyx-control-20261105/simulation/test_adapter.py contains read-only
preparation checks. Evidence: GPT/output/companyx-control-20261105/simulation/.
These preparation tests do not claim numerical simulation or solver execution.

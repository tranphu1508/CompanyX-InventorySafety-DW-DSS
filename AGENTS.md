# Isolated CompanyX ACT / SIM project

- Work only in this project and E:/Study-BKU/GPT for this branch.
- Logs, requests, simulations, test scripts and intermediate files belong under GPT.
- Keep the original project on D and CompanyX_MOLAP_Source_20261105 / CompanyX_InquirySimulation untouched.
- Owned SQL: CompanyX_DW_ACT_20261107 and CompanyX_DW_SIM_20261107. Owned SSAS: CompanyX_ACT_20261107 and CompanyX_SIM_20261107. Check CompanyXSplitOwner/Role before mutation.
- SSIS + existing Python + native SQL/SSAS providers only. No PowerShell runtime or added framework.
- ACT inputs must go through processed ACT MOLAP/MDX before entering SIM act_input. SQL ACT reads in validation do not authorize a bypass.
- Frozen DSS/runtime/src and model numerical semantics are preserved. historical_baseline_inputs.py is a hash-pinned comparison reference; do not run its legacy extraction CLI.
- See README.txt, HUONG_DAN_CUBE.txt and GPT/output/companyx-split-20261107/HANDOVER_STATUS.json. Power BI/Web integration is outside the completed phase.

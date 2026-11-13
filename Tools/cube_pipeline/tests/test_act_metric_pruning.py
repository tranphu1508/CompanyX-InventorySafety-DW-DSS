"""Regression checks for the ACT cleanup and historical-template rebuild."""
import json
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET

PIPELINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PIPELINE))
from act_metric_pruning import REMOVED_MEASURES, REMOVED_GROUPS, CREATE_MEMBER, prune_unused_act_metrics
from build_models import prune, SOURCE

ROOT = PIPELINE.parents[1]
# Consumer contract: the measures used by the four Power BI import queries.
# Keep this test fixture in source; execution/audit reports belong in _local.
POWERBI_IMPORT_MEASURES = {
    'Product': {'Actual Inventory Position Count'},
    'Inventory': {
        'Actual Inventory Source Qty', 'Actual Inventory Value',
        'Actual Inventory Position Count', 'Actual Inventory Zero Cost Positions',
        'Actual Inventory Negative Positions',
    },
    'Demand': {
        'Actual Independent Demand Qty', 'Actual Dependent Demand Qty',
        'Actual Total Demand Qty', 'Actual Demand Eligible Sales Line Count',
    },
    'WorkOrders': {
        'Actual WorkOrder Count', 'Actual WorkOrder Complete Count',
        'Actual WorkOrder Late Complete Count', 'Actual WorkOrder Lead Days Sum',
        'Actual WorkOrder Lead Observed Count', 'Actual WorkOrder Ordered Source Qty',
        'Actual WorkOrder Stocked Source Qty', 'Actual WorkOrder Scrapped Source Qty',
    },
}


def definitions(cube):
    physical = {m.findtext('{*}ID') for m in cube.findall('./{*}MeasureGroups/{*}MeasureGroup/{*}Measures/{*}Measure')}
    script = '\n'.join(t.text or '' for t in cube.findall('./{*}MdxScripts//{*}Text'))
    return physical | {m[1] for m in CREATE_MEMBER.finditer(script)}


class ActMetricPruningTests(unittest.TestCase):
    def setUp(self):
        self.cube = ET.parse(ROOT/'MOLAP/CompanyX.ACT.Analysis/CompanyX_ACT_20261107.cube').getroot()

    def test_powerbi_and_export_contract_survive(self):
        measures = definitions(self.cube)
        for required in POWERBI_IMPORT_MEASURES.values():
            self.assertTrue(set(required) <= measures)
        contract = json.loads((ROOT/'Warehouse/Split/input-contract.json').read_text(encoding='utf-8'))
        for dataset in contract['datasets'].values():
            if dataset.get('measure'):
                self.assertIn(dataset['measure'], measures)
        self.assertFalse(measures & REMOVED_MEASURES)
        self.assertEqual(len(measures), 34)

    def test_rebuild_from_historical_template_does_not_restore_metrics(self):
        base = ET.parse(SOURCE).find('./{*}ObjectDefinition/{*}Database')
        _, cube, _ = prune(base, 'ACT')
        measures = definitions(cube)
        self.assertFalse(measures & REMOVED_MEASURES)
        for table, required in POWERBI_IMPORT_MEASURES.items():
            if table != 'Demand':  # Added subsequently by build_business_model.
                self.assertTrue(set(required) <= measures)
        self.assertFalse(REMOVED_GROUPS & {g.findtext('{*}ID') for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup')})

    def test_native_xmla_and_partition_groups_agree(self):
        xmla = ET.parse(ROOT/'MOLAP/CompanyX.ACT.create.xmla').find('./{*}ObjectDefinition/{*}Database/{*}Cubes/{*}Cube')
        self.assertEqual(definitions(self.cube), definitions(xmla))
        partition = ET.parse(ROOT/'MOLAP/CompanyX.ACT.Analysis/CompanyX_ACT_20261107.partitions').getroot()
        ids = lambda cube: {g.findtext('{*}ID') for g in cube.findall('./{*}MeasureGroups/{*}MeasureGroup')}
        self.assertEqual(ids(self.cube), ids(xmla))
        self.assertEqual(ids(self.cube), ids(partition))

    def test_idempotent_and_act_only(self):
        before = ET.tostring(self.cube)
        prune_unused_act_metrics(self.cube)
        self.assertEqual(before, ET.tostring(self.cube))
        self.cube.find('{*}ID').text = 'CompanyX_SIM_20261107'
        with self.assertRaises(ValueError):
            prune_unused_act_metrics(self.cube)

    def test_future_dependency_on_removed_metric_fails(self):
        text = self.cube.find('./{*}MdxScripts//{*}Text')
        text.text += '\nCREATE MEMBER CURRENTCUBE.[Measures].[New KPI] AS [Measures].[Actual Purchase Line Count];'
        with self.assertRaisesRegex(ValueError, 'Dangling'):
            prune_unused_act_metrics(self.cube)


if __name__ == '__main__':
    unittest.main()

"""SIM retirement must preserve SQL refresh and prevent SSAS regeneration."""
from contextlib import nullcontext
from pathlib import Path
import re
import sys
import unittest
from unittest.mock import Mock, patch
import xml.etree.ElementTree as ET

PIPELINE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PIPELINE))
import build_models
import ssas
import sim_sql_refresh as refresh
from publish import active_sql_scope

ROOT = PIPELINE.parents[1]


class SimSqlRefreshTests(unittest.TestCase):
    def run_refresh(self, fail=False):
        cn = Mock()
        cn.execute.return_value.nextset.return_value = False
        if fail:
            cn.execute.side_effect = RuntimeError('SQL failed')
        with patch.object(refresh, 'sql', side_effect=lambda role: nullcontext(cn)), \
             patch.object(refresh, 'lease', return_value=nullcontext()), \
             patch.object(refresh, 'publish_operation_gate', return_value=nullcontext()), \
             patch.object(refresh, 'evidence', return_value=Path('unused')), \
             patch.object(refresh, 'save') as save, \
             patch.object(active_sql_scope, 'refresh_active_sql_scope') as scope:
            if fail:
                with self.assertRaisesRegex(RuntimeError, 'SQL failed'):
                    refresh.refresh_sim()
                scope.assert_not_called()
                save.assert_not_called()
            else:
                result = refresh.refresh_sim()
                self.assertEqual(result['refresh'], 'SQL_ONLY')
                scope.assert_called_once_with(Path('unused/active-scope.json'), project_root=ROOT, gate_held=True)
                expected = []
                for name in ('FactSourceCache.sql', 'BaselineActivitySourceCache.sql', 'RunDayCache.sql', 'ControlSourcePreflight.sql', 'RefreshOrderCache.sql'):
                    script = (ROOT/'DSS/control/publish'/name).read_text(encoding='utf-8-sig')
                    expected.extend(b for b in re.split(r'(?im)^[ \t]*GO[ \t]*(?:--[^\r\n]*)?$', script) if b.strip())
                self.assertEqual([c.args[0] for c in cn.execute.call_args_list], expected)
                save.assert_called_once()

    def test_refresh_retains_all_sql_batches_and_scope(self):
        self.run_refresh()

    def test_sql_failure_cannot_report_success(self):
        self.run_refresh(fail=True)

    def test_sim_rejected_before_build_deploy_or_process(self):
        with patch.object(build_models.ET, 'parse') as parse, patch.object(ssas, 'connect') as connect:
            for action in (lambda: build_models.build(('ACT', 'SIM')),
                           lambda: build_models.prune(None, 'SIM'),
                           lambda: build_models.export_native(None, 'SIM'),
                           lambda: ssas.deploy('SIM'), lambda: ssas.process('SIM')):
                with self.assertRaisesRegex(ValueError, 'Only ACT'):
                    action()
            parse.assert_not_called()
            connect.assert_not_called()
        self.assertEqual(build_models.build.__defaults__, (('ACT',),))

    def test_ssis_packages_resolve_and_refresh_sql(self):
        project = ET.parse(ROOT/'CompanyX.Split.Integration/CompanyX.Split.Integration.dtproj')
        # Manifest namespace varies by SSIS version; match local tag names.
        packages = [p for p in project.iter() if p.tag.split('}')[-1] == 'Package']
        self.assertTrue(packages)
        refreshed = set()
        for item in packages:
            name = next(v for k,v in item.attrib.items() if k.split('}')[-1] == 'Name')
            path = ROOT/'CompanyX.Split.Integration'/name
            package = ET.parse(path)
            text = path.read_text(encoding='utf-8')
            self.assertNotIn('process-sim', text)
            tasks = package.findall('.//ExecuteProcessData')
            if name.startswith(('00_', '80_', '90_')):
                self.assertIn('--stage refresh-sim', tasks[-1].get('Arguments'))
                refreshed.add(name[:2])
        self.assertEqual(refreshed, {'00', '80', '90'})
        self.assertNotIn('CompanyX.SIM.Analysis', (ROOT/'CompanyX.ACT_SIM.sln').read_text())
        self.assertFalse((ROOT/'MOLAP/CompanyX.SIM.create.xmla').exists())


if __name__ == '__main__':
    unittest.main()

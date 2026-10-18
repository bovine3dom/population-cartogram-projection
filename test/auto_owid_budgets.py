"""Test fixed-country budget inventory and explicit source scopes."""
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from audit_owid_budgets import apportion, parts, run, source_scope


class OwidBudgetTests(unittest.TestCase):
    def test_parts_keep_corners_separate(self):
        self.assertEqual(parts({(0,0),(1,0),(2,1)}), [{(0,0),(1,0)}, {(2,1)}])

    def test_exact_country_budget_and_stable_tie(self):
        quotas, budgets = apportion([1,1,1], 5)
        self.assertEqual(budgets, [2,2,1])
        self.assertEqual(sum(budgets), 5)
        self.assertAlmostEqual(sum(quotas), 5)

    def test_no_implicit_minimum_tile(self):
        self.assertEqual(apportion([1000,1,1], 3)[1], [3,0,0])
        self.assertEqual(apportion([1,2], 0)[1], [0,0])
        with self.assertRaises(ValueError): apportion([0,0], 3)

    def test_overseas_scope_not_sovereign_pool(self):
        self.assertEqual(source_scope(dict(map_unit='REU',country_id='FRA'), {'REU':638,'FRA':250}), 'REU')
        self.assertEqual(source_scope(dict(map_unit='FXX',country_id='FRA'), {'FRA':250}), 'FRA')
        self.assertEqual(source_scope(dict(map_unit='NIR',country_id='GBR'), {'GBR':826}), 'GBR')

    def test_inventory_retains_overlap_and_unmatched_scopes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); owid=root/'owid.csv'; components=root/'components.csv'
            polygons=root/'polygons.json'; iso=root/'iso.json'; output=root/'out'
            owid.write_text('0,0,250\n2,0,250\n2,0,638\n4,0,999\n')
            components.write_text('component_id,country_id,map_unit,name,population,west,east,south,north\na,FRA,FXX,France,100,0,1,0,1\nb,FRA,REU,Reunion,10,2,3,0,1\nc,XXX,XXX,Unknown,5,4,5,0,1\n')
            polygons.write_text('{"features":[]}')
            iso.write_text(json.dumps({'3166-1':[dict(alpha_3='FRA',numeric='250'),dict(alpha_3='REU',numeric='638')]}))
            original=owid.read_bytes()
            run(owid,components,polygons,iso,output,[])
            report=json.loads((output/'audit.json').read_text())
            self.assertEqual(report['unique_tiles'],3)
            self.assertEqual(report['conflicts'],[dict(x=2,y=0,codes=[250,638],inventory_owner=638)])
            with (output/'countries.csv').open() as stream: countries={r['country']:r for r in csv.DictReader(stream)}
            self.assertEqual(countries['FRA']['population'],'100.0')
            self.assertEqual(countries['REU']['population'],'10.0')
            self.assertEqual(countries['XXX']['status'],'no_owid_tiles')
            self.assertEqual(countries['OWID_999']['status'],'no_source_population')
            self.assertEqual(owid.read_bytes(),original)
            with self.assertRaises(ValueError): run(owid,components,polygons,iso,output,[])


if __name__ == '__main__': unittest.main()

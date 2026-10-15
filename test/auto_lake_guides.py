#!/usr/bin/env python3
import sys
import unittest
import tempfile
import json
import csv
from pathlib import Path

from shapely import STRtree
from shapely.geometry import box, Polygon, mapping, shape

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from prepare_lake_guides import measure_lake, run
from review_lake_flow import run as review_flow


class LakeGuideTests(unittest.TestCase):
    def test_cross_border_lake_is_not_an_existing_hole(self):
        land = [box(0, 0, 2, 2), box(2, 0, 4, 2)]
        covered, estimate, members = measure_lake(box(1, 1, 3, 2), land, ['a', 'b'], STRtree(land), {'a': 40, 'b': 80})
        self.assertEqual(covered, 1)
        self.assertEqual(estimate, 30)
        self.assertEqual(members, ['a', 'b'])

    def test_existing_water_is_not_administrative_land(self):
        lake = box(1, 1, 2, 2)
        land = [Polygon(box(0, 0, 3, 3).exterior, [lake.exterior])]
        covered, estimate, members = measure_lake(lake, land, ['a'], STRtree(land), {'a': 80})
        self.assertEqual((covered, estimate, members), (0, 0, []))

    def test_export_keeps_land_budgets_and_separates_water(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'groups.csv').write_text('component_id,tiles,country_id,west,east,south,north\na,40,A,0,2,0,2\nb,80,B,2,4,0,2\n')
            (root/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            features = [dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g))
                        for c, g in [('a', box(0, 0, 2, 2)), ('b', box(2, 0, 4, 2))]]
            (root/'land.json').write_text(json.dumps(dict(type='FeatureCollection', features=features)))
            lake = dict(type='Feature', properties=dict(ne_id=1, name='Test lake'), geometry=mapping(box(1, .5, 3, 1.5)))
            (root/'lakes.json').write_text(json.dumps(dict(type='FeatureCollection', features=[lake])))
            report = run(root, root/'land.json', root/'lakes.json', root/'out', minimum_area_km2=1)
            self.assertEqual(report['selected_lakes'], 1)
            self.assertEqual(report['land_tiles'], 120)
            self.assertEqual(report['lake_separated_contacts'], [])
            output = json.loads((root/'out/geometry.geojson').read_text())['features']
            water = shape(output[-1]['geometry'])
            for feature in output[:-1]:
                self.assertLess(shape(feature['geometry']).intersection(water).area, 1e-8)
            with (root/'out/areas.csv').open() as stream:
                areas = {r['component_id']: int(r['tiles']) for r in csv.DictReader(stream)}
            self.assertEqual((areas['a'], areas['b']), (40, 80))
            self.assertGreater(areas['water:1'], 0)
            checked = review_flow(root, root/'out', root/'out/geometry.geojson', root/'review')
            self.assertEqual(checked['overlap_pairs'], 0)
            self.assertFalse(checked['diagnostic_repairs'])
            output[0]['geometry'] = mapping(Polygon([(0, 0), (2, 2), (0, 2), (2, 0), (0, 0)]))
            (root/'invalid.json').write_text(json.dumps(dict(type='FeatureCollection', features=output)))
            with self.assertRaisesRegex(ValueError, 'Invalid flow geometry'):
                review_flow(root, root/'out', root/'invalid.json', root/'bad-review')
            diagnostic = review_flow(root, root/'out', root/'invalid.json', root/'diagnostic', allow_invalid_review=True)
            self.assertTrue(diagnostic['diagnostic_repairs'])
            self.assertIn('a', diagnostic['invalid_source_geometries'])
            self.assertFalse(diagnostic['approved'])
            lake['geometry'] = mapping(box(1, 0, 3, 2))
            (root/'separating-lake.json').write_text(json.dumps(dict(type='FeatureCollection', features=[lake])))
            separated = run(root, root/'land.json', root/'separating-lake.json', root/'separated', minimum_area_km2=1)
            self.assertEqual([(r['a'], r['b']) for r in separated['lake_separated_contacts']], [('a', 'b')])

    def test_unrepresented_land_adds_no_water_budget(self):
        land = [box(0, 0, 3, 3)]
        covered, estimate, _ = measure_lake(box(1, 1, 2, 2), land, ['a'], STRtree(land), {})
        self.assertEqual(covered, 1)
        self.assertEqual(estimate, 0)


if __name__ == '__main__':
    unittest.main()

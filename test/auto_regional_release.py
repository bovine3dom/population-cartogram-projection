#!/usr/bin/env python3
import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from shapely.geometry import box, mapping

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from release_regions import communities, fit_frame, lake_links, run
from prepare_flow import equal_earth
from review_layout import load
from save_review import digest


class ReleaseTests(unittest.TestCase):
    def test_hard_lake_group_survives_community_partition(self):
        groups = communities(['a', 'b', 'c', 'd'], [('a', 'b')], [('b', 'c', 1), ('c', 'd', 100)], 2)
        self.assertTrue(any({'a', 'b'} <= set(g) for g in groups))
        self.assertEqual(sorted(c for g in groups for c in g), ['a', 'b', 'c', 'd'])

    def test_empty_border_network_keeps_separate_atoms(self):
        self.assertEqual(communities(['a', 'b', 'c'], [('a', 'b')], [], 1), [['a', 'b'], ['c']])

    def test_lake_links_include_all_shore_labels(self):
        _, links = lake_links([dict(lake_id='lake', x=0, y=0)], {(-1, 0): 'a', (1, 0): 'b', (0, 1): 'c'})
        self.assertEqual(links, {('a', 'b'), ('a', 'c')})

    def test_frame_fits_one_world_scale_not_fixed_country_centres(self):
        source = np.array([[0., 0.], [1., 2.], [2., 0.]])
        target = source*40+np.array([100, 200])
        a, b, scale = fit_frame(source, target, [1, 2, 1])
        self.assertAlmostEqual(scale, 40)
        np.testing.assert_allclose((source-a)*scale+b, target)
        with self.assertRaises(ValueError):
            fit_frame(source, -source, [1, 2, 1])

    def test_export_preserves_counts_shapes_and_shared_lake(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            original = {'a': {(x, y) for x in range(2) for y in range(5)},
                        'b': {(x, y) for x in range(2, 5) for y in range(5)}-{(2, 2)},
                        'c': {(x, y) for x in range(20, 22) for y in range(2)}}
            (root/'groups.csv').write_text('component_id,tiles,country_id,group_population\na,10,A,100\nb,14,B,140\nc,4,C,40\n')
            (root/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (root/'complete.txt').write_text('mode=test\n')
            with (root/'cells.csv').open('w', newline='') as stream:
                writer = csv.writer(stream)
                writer.writerow(['component_id', 'x', 'y'])
                writer.writerows((c, x, y) for c, points in original.items() for x, y in sorted(points))
            (root/'lake-cells.csv').write_text('lake_id,name,x,y\nlake,Test lake,2,2\n')
            features = [dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g))
                        for c, g in [('a', box(0, 0, 2, 5)), ('b', box(2, 0, 5, 5)), ('c', box(20, 0, 22, 2))]]
            (root/'polygons.json').write_text(json.dumps(dict(type='FeatureCollection', features=features)))
            xy = equal_earth(np.array([[1, 2.5], [3.5, 2.5], [21, 1]]))/1000
            with (root/'sources.csv').open('w', newline='') as stream:
                writer = csv.writer(stream)
                writer.writerow(['group_id', 'value', 'x', 'y'])
                writer.writerows((c, value, *point) for c, value, point in zip(['a', 'b', 'c'], [100, 140, 40], xy))
            audit = dict(inputs={str(root/n): digest(root/n) for n in ['groups.csv', 'geographic-contacts.csv', 'sources.csv']},
                         borders=[dict(a='a', b='b', eligible=True, corridor_population=1)])
            (root/'audit.json').write_text(json.dumps(audit))
            result = run(root, root, root/'polygons.json', root/'sources.csv', root/'audit.json', root/'out', spacing=2)
            self.assertEqual(result['regions'], 2)
            _, after, owners = load(root, root/'out')
            shifts = {}
            for c in original:
                dx, dy = np.array(min(after[c]))-np.array(min(original[c]))
                shifts[c] = (dx, dy)
                self.assertEqual(after[c], {(x+dx, y+dy) for x, y in original[c]})
            self.assertEqual(shifts['a'], shifts['b'])
            self.assertNotEqual(shifts['a'], shifts['c'])
            dx, dy = shifts['a']
            self.assertNotIn((2+dx, 2+dy), owners)
            self.assertEqual(len(owners), 28)


if __name__ == '__main__':
    unittest.main()

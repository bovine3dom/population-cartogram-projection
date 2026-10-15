#!/usr/bin/env python3
import csv
import json
import sys
import tempfile
import unittest

from shapely.geometry import box, mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from lake_vacancies import VacancyLayout
from review_geography import exterior_water
from review_layout import connectivity, load
from prepare_lake_guides import run as prepare_guides
from place_lake_regions import run as place_lakes


class VacancyTests(unittest.TestCase):
    def rectangle(self):
        return {'a': {(x, y) for x in range(6) for y in range(8)},
                'b': {(x, y) for x in range(6, 12) for y in range(8)}}

    def test_cross_border_slide_keeps_counts_and_only_opens_target(self):
        state = VacancyLayout(self.rectangle(), {('a', 'b')})
        original = set(state.owners)
        action = state.attempt([(x, 4) for x in range(4, 13)])
        self.assertIsNotNone(action)
        self.assertEqual({c: len(p) for c, p in state.tiles.items()}, {'a': 48, 'b': 48})
        self.assertEqual(original-set(state.owners), {(4, 4)})
        self.assertEqual(set(state.owners)-original, {(12, 4)})
        self.assertNotIn((4, 4), state.exterior)
        self.assertEqual(state.exterior, exterior_water(state.owners) & state.exterior)
        self.assertEqual(state.owners[(6, 4)], 'a')
        self.assertTrue(all(connectivity(p) == 1 for p in state.tiles.values()))
        self.assertGreater(state.contacts[('a', 'b')], 0)

    def test_undo_restores_labels_contacts_and_water(self):
        state = VacancyLayout(self.rectangle(), {('a', 'b')})
        owners, ocean, contacts = dict(state.owners), set(state.exterior), dict(state.contacts)
        action = state.attempt([(x, 4) for x in range(4, 13)])
        state.undo(action)
        self.assertEqual(state.owners, owners)
        self.assertEqual(state.exterior, ocean)
        self.assertEqual({k: v for k, v in state.contacts.items() if v}, contacts)

    def test_country_split_is_rejected(self):
        a = ({(x, y) for x in [0, 1, 5, 6] for y in range(3)} |
             {(2, 1), (3, 1), (4, 1)})
        b = {(x, y) for x in range(-1, 8) for y in range(-1, 4)}-a
        state = VacancyLayout({'a': a, 'b': b})
        owners = dict(state.owners)
        self.assertIsNone(state.attempt([(3, 1), (3, 0), (3, -1), (3, -2)]))
        self.assertEqual(state.rejections['component-split'], 1)
        self.assertEqual(state.owners, owners)

    def test_protected_sea_and_open_water_are_not_used(self):
        state = VacancyLayout(self.rectangle(), protected_sea={(12, 4)})
        self.assertIsNone(state.attempt([(x, 4) for x in range(4, 13)]))
        self.assertIsNone(state.attempt([(x, 0) for x in range(4, 13)]))

    def test_fixed_islands_cannot_move(self):
        state = VacancyLayout(self.rectangle(), fixed={'b'})
        original = dict(state.owners)
        self.assertIsNone(state.attempt([(x, 4) for x in range(4, 13)]))
        self.assertEqual(state.owners, original)
        for path in state.paths((4, 4)):
            self.assertTrue(all(state.owners[p] != 'b' for p in path[:-1]))

    def test_shortest_routes_are_valid_and_bounded(self):
        state = VacancyLayout(self.rectangle(), {('a', 'b')})
        paths = list(state.paths((4, 4), maximum_cost=20, limit=5))
        self.assertEqual(len(paths), 5)
        for path in paths:
            self.assertLessEqual(len(path)-1, 20)
            self.assertEqual(path[0], (4, 4))
            self.assertIn(path[-1], state.exterior)
        with self.assertRaises(ValueError):
            state.attempt([(4, 4), (12, 4)])


class PlacementTests(unittest.TestCase):
    def test_export_and_failed_placement_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'groups.csv').write_text('component_id,tiles,country_id,west,east,south,north\na,48,A,0,6,0,8\nb,48,B,6,12,0,8\n')
            (root/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (root/'coasts.csv').write_text('component_id,uncovered_samples\na,1\nb,1\n')
            features = [dict(type='Feature', properties=dict(component_id=c), geometry=mapping(g))
                        for c, g in [('a', box(0, 0, 6, 8)), ('b', box(6, 0, 12, 8))]]
            (root/'land.json').write_text(json.dumps(dict(type='FeatureCollection', features=features)))
            lake = dict(type='Feature', properties=dict(ne_id=1, name='Test lake'), geometry=mapping(box(4, 3, 8, 5)))
            (root/'lakes.json').write_text(json.dumps(dict(type='FeatureCollection', features=[lake])))
            prepare_guides(root, root/'land.json', root/'lakes.json', root/'guides', minimum_area_km2=1)
            (root/'complete.txt').write_text('mode=test\n')
            original = VacancyTests().rectangle()
            with (root/'cells.csv').open('w', newline='') as stream:
                writer = csv.writer(stream)
                writer.writerow(['component_id', 'x', 'y'])
                writer.writerows((c, x, y) for c, points in original.items() for x, y in sorted(points))
            for cost, accepted in [(32, 1), (1, 0)]:
                output = root/f'result-{cost}'
                report = place_lakes(root, root, root/'land.json', root/'guides', root/'coasts.csv', output,
                                     search_radius=6, placement_attempts=32, maximum_path_cost=cost, bay_radius=1)
                self.assertEqual(report['accepted_lakes'], accepted)
                _, tiles, owners = load(root, output)
                self.assertEqual({c: len(p) for c, p in tiles.items()}, {'a': 48, 'b': 48})
                self.assertTrue(all(connectivity(p) == 1 for p in tiles.values()))
                if accepted:
                    self.assertGreater(report['water_cells'], 0)
                    water = set().union(*original.values())-set(owners)
                    self.assertEqual(len(water), report['water_cells'])
                    self.assertFalse(water & exterior_water(owners))
                else:
                    self.assertEqual(tiles, original)


if __name__ == '__main__':
    unittest.main()

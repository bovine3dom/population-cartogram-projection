"""Tests for coast order and balanced coastal cover."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from audit_coast_arcs import SEA, WATER, coast_pairs, runs, sea_runs, tile_loops
from review_geography import exterior_water
from review_layout import connectivity
from shield_coast import shield


class CoastArcTests(unittest.TestCase):
    def test_circular_runs(self):
        self.assertEqual(runs(['a', 'a', SEA, 'b', 'a']), ['a', SEA, 'b'])
        self.assertEqual(coast_pairs(['a', SEA, 'b']), [('a', 'b')])
        self.assertEqual(coast_pairs(['b', SEA, 'a']), [('a', 'b')])
        self.assertEqual(coast_pairs([SEA]*4), [(SEA, SEA)])
        self.assertEqual(coast_pairs([]), [])

    def test_single_tile_outside_coordinates(self):
        owner = {(0, 0): 'a'}
        loops = tile_loops(set(owner), owner, exterior_water(owner))
        self.assertEqual(len(loops), 1)
        arc, = sea_runs(loops[0])
        self.assertEqual(arc['neighbours'], (SEA, SEA))
        self.assertEqual(set(arc['water_cells']), {(1, 0), (-1, 0), (0, 1), (0, -1)})
        self.assertEqual(arc['edges'], 4)

    def test_lake_is_not_sea(self):
        points = {(x, y) for x in range(3) for y in range(3)}-{(1, 1)}
        owner = dict.fromkeys(points, 'a')
        loops = tile_loops(points, owner, exterior_water(owner))
        self.assertEqual(sorted(map(len, loops)), [4, 12])
        lake, = [loop for loop in loops if len(loop) == 4]
        self.assertEqual({e['neighbour'] for e in lake}, {WATER})
        self.assertEqual(sea_runs(lake), [])

    def test_diagonal_tiles_do_not_cross(self):
        points = {(0, 0), (1, 1)}
        owner = dict.fromkeys(points, 'a')
        loops = tile_loops(points, owner, exterior_water(owner))
        self.assertEqual(sorted(map(len, loops)), [4, 4])
        self.assertEqual(len({(e['a'], e['b']) for loop in loops for e in loop}), 8)

    def test_border_bounds_sea_arc(self):
        owner = {(0, 0): 'a', (1, 0): 'b', (-1, 0): 'c'}
        loop, = tile_loops({(0, 0)}, owner, exterior_water(owner))
        self.assertEqual([arc['neighbours'] for arc in sea_runs(loop)], [('b', 'c')]*2)

    def test_cover_keeps_budget_and_fixed_country(self):
        tiles = {'cover': {(x, y) for x in range(3) for y in range(3)},
                 'target': {(3, 1), (4, 1)}}
        result, move = shield(tiles, {('cover', 'target')}, set(), 'cover', {(3, 2), (4, 2)})
        self.assertEqual(result['target'], tiles['target'])
        self.assertEqual(len(result['cover']), len(tiles['cover']))
        self.assertEqual(connectivity(result['cover']), 1)
        self.assertTrue({(3, 2), (4, 2)} <= result['cover'])
        self.assertEqual(len(move['added']), len(move['removed']))
        self.assertEqual(len(tiles['cover']), 9)

    def test_cover_rejects_land_and_false_contact(self):
        tiles = {'cover': {(0, 0), (1, 0)}, 'other': {(3, 0)}}
        with self.assertRaisesRegex(ValueError, 'exterior-water'):
            shield(tiles, set(), set(), 'cover', {(1, 0)})
        with self.assertRaisesRegex(ValueError, 'false border'):
            shield(tiles, set(), set(), 'cover', {(2, 0)})


if __name__ == '__main__':
    unittest.main()

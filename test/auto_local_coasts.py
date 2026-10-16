import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from fit_local_coasts import fit
from repair_partition import pieces
from review_geography import exterior_water, water_edges


class LocalCoastTest(unittest.TestCase):
    def check(self, tiles, inland, margin=3):
        result, attempts = fit(tiles, {('a', 'b')}, inland, 'a', margin=margin, seconds=10)
        self.assertIsNotNone(result, attempts)
        self.assertEqual(set().union(*tiles.values()), set().union(*result.values()))
        self.assertEqual({c: len(p) for c,p in tiles.items()}, {c: len(p) for c,p in result.items()})
        self.assertTrue(all(len(pieces(p)) == 1 for p in result.values()))
        owner = {p:c for c,points in result.items() for p in points}
        return water_edges(result, owner, exterior_water(owner))['a']['exterior_water_edges']

    def test_restore_coast_with_exact_counts(self):
        a = {(1, 2), (2, 2)}
        tiles = {'a': a, 'b': {(x,y) for x in range(5) for y in range(5)}-a}
        self.assertGreater(self.check(tiles, set()), 0)

    def test_remove_false_coast_without_moving_water(self):
        a = {(0,2), (1,2), (1,1), (2,1)}
        tiles = {'a': a, 'b': {(x,y) for x in range(5) for y in range(5)}-a}
        self.assertEqual(self.check(tiles, {'a'}), 0)

    def test_fixed_exterior_is_connected_through_compressed_nodes(self):
        a = {(1,2), (2,2)}
        tiles = {'a':a, 'b':{(x,y) for x in range(8) for y in range(8)}-a}
        self.assertGreater(self.check(tiles, set(), margin=1), 0)

    def test_protected_shore_cells_cannot_be_relabelled(self):
        a = {(1,2), (2,2)}
        tiles = {'a':a, 'b':{(x,y) for x in range(5) for y in range(5)}-a}
        result, _ = fit(tiles, {('a','b')}, set(), 'a', seconds=10, fixed_cells=a)
        self.assertIsNone(result)

    def test_missing_source_contact_can_be_required(self):
        tiles = {'a':{(x,2) for x in range(3)}, 'b':{(x,0) for x in range(3)},
                 'c':{(x,1) for x in range(3)}}
        required = {('a','b'), ('a','c'), ('b','c')}
        result, attempts = fit(tiles, required, set(), 'a', seconds=10, required_extra={('a','b')})
        self.assertIsNotNone(result, attempts)
        self.assertTrue(any((x+dx,y+dy) in result['b'] for x,y in result['a'] for dx,dy in [(1,0),(-1,0),(0,1),(0,-1)]))

    def test_expansion_can_join_across_water_without_extra_tiles(self):
        tiles = {'a': {(x, 0) for x in range(3)}, 'b': {(x, 2) for x in range(3)}}
        kwargs = dict(required={('a', 'b')}, inland=set(), target='a', seconds=10,
                      required_extra={('a', 'b')})
        fixed, _ = fit(tiles, **kwargs)
        self.assertIsNone(fixed)
        result, attempts = fit(tiles, expansion=1, **kwargs)
        self.assertIsNotNone(result, attempts)
        self.assertEqual({c: len(p) for c, p in result.items()}, {'a': 3, 'b': 3})
        self.assertEqual(len(set().union(*result.values())), 6)
        self.assertTrue(all(len(pieces(p)) == 1 for p in result.values()))
        self.assertNotEqual(set().union(*result.values()), set().union(*tiles.values()))
        # Protect the intervening water, as for a lake or a fixed empty shore.
        blocked, _ = fit(tiles, expansion=1, fixed_cells={(x, 1) for x in range(-3, 6)}, **kwargs)
        self.assertIsNone(blocked)

    def test_expansion_keeps_inland_target_away_from_exterior_water(self):
        a = {(0, 2), (1, 2), (1, 1), (2, 1)}
        tiles = {'a': a, 'b': {(x, y) for x in range(5) for y in range(5)}-a}
        result, attempts = fit(tiles, {('a', 'b')}, {'a'}, 'a', expansion=1, seconds=10)
        self.assertIsNotNone(result, attempts)
        self.assertEqual({c: len(p) for c, p in result.items()}, {'a': 4, 'b': 21})
        owner = {p: c for c, points in result.items() for p in points}
        self.assertEqual(water_edges(result, owner, exterior_water(owner))['a']['exterior_water_edges'], 0)

    def test_expansion_can_fit_a_template_without_moving_other_labels(self):
        tiles = {'a': {(x, 0) for x in range(3)}, 'b': {(4, 0)}}
        preferred = {'a': {(1, y) for y in range(-1, 2)}}
        result, attempts = fit(tiles, set(), set(), 'a', expansion=1, seconds=10,
                               movable={'a'}, preferred=preferred, distance_weight=.3)
        self.assertIsNotNone(result, attempts)
        self.assertEqual(result['a'], preferred['a'])
        self.assertEqual(result['b'], tiles['b'])

    def test_perimeter_cost_discourages_a_thin_shape(self):
        from compact_regions import adjacent
        tiles = {'a': {(x, 0) for x in range(6)}}
        result, attempts = fit(tiles, set(), set(), 'a', expansion=2, seconds=10,
                               perimeter_weight=1.)
        self.assertIsNotNone(result, attempts)
        def perimeter(points):
            return sum(q not in points for p in points for q in adjacent(p))
        self.assertLess(perimeter(result['a']), perimeter(tiles['a']))
        self.assertEqual(len(result['a']), 6)
        self.assertEqual(len(pieces(result['a'])), 1)

    def test_negative_expansion_is_rejected(self):
        with self.assertRaises(ValueError):
            fit({'a': {(0, 0)}}, set(), set(), 'a', expansion=-1)

    def test_sea_flow_removes_an_unnamed_hole(self):
        tiles = {'a': {(x, y) for x in range(3) for y in range(3)}-{(1, 1)}}
        result, attempts = fit(tiles, set(), set(), 'a', expansion=1,
                               sea_connected=True, seconds=10)
        self.assertIsNotNone(result, attempts)
        owner = {p: 'a' for p in result['a']}
        ocean = exterior_water(owner)
        self.assertEqual(len(owner), 8)
        self.assertFalse({(x, y) for x in range(min(p[0] for p in owner), max(p[0] for p in owner)+1)
                          for y in range(min(p[1] for p in owner), max(p[1] for p in owner)+1)
                          if (x, y) not in owner and (x, y) not in ocean})
        self.assertEqual(len(pieces(result['a'])), 1)

    def test_sea_flow_retains_a_named_lake(self):
        from compact_regions import adjacent
        lake = {(1, 1)}
        tiles = {'a': {(x, y) for x in range(3) for y in range(3)}-lake}
        result, attempts = fit(tiles, set(), set(), 'a', expansion=1, seconds=10,
                               sea_connected=True, protected_water=lake,
                               fixed_cells=set(adjacent((1, 1))))
        self.assertIsNotNone(result, attempts)
        self.assertEqual(result, tiles)

    def test_invalid_shape_weights_are_rejected(self):
        for name in ('distance_weight', 'perimeter_weight'):
            for value in (-1, float('nan'), float('inf')):
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    fit({'a': {(0, 0)}}, set(), set(), 'a', **{name: value})

    def test_fixed_root_can_make_local_problem_infeasible(self):
        tiles = {'a': {(1,1)}, 'b': {(x,y) for x in range(3) for y in range(3)}-{(1,1)}}
        result, _ = fit(tiles, {('a','b')}, set(), 'a', seconds=10)
        self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()

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

    def test_fixed_root_can_make_local_problem_infeasible(self):
        tiles = {'a': {(1,1)}, 'b': {(x,y) for x in range(3) for y in range(3)}-{(1,1)}}
        result, _ = fit(tiles, {('a','b')}, set(), 'a', seconds=10)
        self.assertIsNone(result)


if __name__ == '__main__':
    unittest.main()

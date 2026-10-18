import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from relax_owid_islands import group_budgets, pack_archipelago, releasable_sea, redistribute_country
from fit_local_coasts import fit


class RelaxOwidTest(unittest.TestCase):
    def test_group_budgets_keep_country_total(self):
        rows = [dict(country='X', group=g, group_population=p, old_tiles=n, target_part=t)
                for g,p,n,t in [('T1',90,4,'T1'),('T1',90,2,'T2'),('T3',10,4,'T3')]]
        result = group_budgets(rows, 'X')
        self.assertEqual(result, {'X:T1':6, 'X:T2':3, 'X:T3':1})

    def test_only_selected_inter_piece_water_is_released(self):
        ring = {(x,y) for x in range(3) for y in range(3)}-{(1,1)}
        self.assertFalse(releasable_sea({'a':ring}, {'a'})[0])
        tiles = {'a':{p for p in ring if p[0]<2}, 'b':{p for p in ring if p[0]==2}}
        self.assertEqual(releasable_sea(tiles, {'a','b'})[0], {(1,1)})
        self.assertFalse(releasable_sea(tiles, {'a'})[0])

    def test_packing_preserves_counts_order_and_input(self):
        tiles = {'a':{(0,0),(1,0)}, 'b':{(4,0),(5,0)}}
        snapshot = {c:set(p) for c,p in tiles.items()}
        result, report = pack_archipelago(tiles, {'a':3,'b':1})
        self.assertEqual(tiles, snapshot)
        self.assertEqual({c:len(p) for c,p in result.items()}, {'a':3,'b':1})
        self.assertLess(max(x for x,y in result['a']), min(x for x,y in result['b'])-1)
        self.assertEqual(report['released_cells'], 0)

    def test_border_parts_cannot_be_freely_packed(self):
        with self.assertRaises(ValueError):
            pack_archipelago({'a':{(0,0)},'b':{(1,0)}}, {'a':1})

    def test_failed_second_border_fit_rolls_back_first(self):
        tiles = {'a':{(0,0),(1,0)},'b':{(5,0)}}
        changed = {'a':{(0,0)},'b':{(5,0)}}
        with patch('relax_owid_islands.fit', side_effect=[(changed,[]),(None,[])]):
            result, report = redistribute_country(tiles, {'a':1,'b':2})
        self.assertEqual(result, tiles)
        self.assertFalse(report['accepted'])

    def test_fit_allows_explicit_area_change(self):
        tiles = {'a':{(0,0),(1,0),(0,1),(1,1)}}
        result, attempts = fit(tiles, set(), set(), 'a', budgets={'a':6},
                               expansion=2, margin=2, seconds=10)
        self.assertIsNotNone(result, attempts)
        self.assertEqual(len(result['a']), 6)

    def test_shared_footprint_moves_roots_and_keeps_exact_outline(self):
        tiles = {'a':{(0,0),(1,0)}, 'b':{(2,0),(3,0)}}
        footprint = {(x,2) for x in range(4)}
        preferred = {'a':{(0,2),(1,2)}, 'b':{(2,2),(3,2)}}
        result, attempts = fit(tiles, {('a','b')}, set(), 'a', margin=5,
            expansion=3, preferred=preferred, footprint=footprint, seconds=10)
        self.assertIsNotNone(result, attempts)
        self.assertEqual(set().union(*result.values()), footprint)
        self.assertEqual({c:len(p) for c,p in result.items()}, {'a':2,'b':2})

    def test_footprint_budget_mismatch_rejected(self):
        with self.assertRaises(ValueError):
            fit({'a':{(0,0)}}, set(), set(), 'a', footprint={(0,0),(1,0)}, expansion=2)

    def test_invalid_budget_rejected(self):
        with self.assertRaises(ValueError):
            fit({'a':{(0,0)}}, set(), set(), 'a', budgets={'a':0})

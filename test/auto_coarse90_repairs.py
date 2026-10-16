import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from dock_true_borders import place
from repair_partition import preferred_piece, pieces
from repair_coast_access import repair
from restore_border_templates import restore
from separate_false_contacts import separate
from dock_true_borders import contacts


class CoarseRepairTests(unittest.TestCase):
    def test_strict_docking_does_not_trade_false_contacts(self):
        tiles = {'a': {(1, 0), (2, 0)}, 'b': {(-1, 0)}, 'c': {(0, 0)}, 'd': {(2, 2)}}
        required = {('a', 'b'), ('a', 'c')}
        with patch('dock_true_borders.candidates', return_value={(3, 1)}):
            _, moves = place(tiles, required)
            strict, strict_moves = place(tiles, required, no_new_false=True)
        self.assertTrue(moves)
        self.assertFalse(strict_moves)
        self.assertEqual(strict, tiles)

    def test_smaller_fragment_with_true_border_is_preferred(self):
        parts = [{(0, 0), (0, 1), (0, 2)}, {(4, 0), (4, 1)}]
        owners = {p: 'a' for part in parts for p in part} | {(1, 0): 'wrong', (5, 0): 'b'}
        self.assertEqual(preferred_piece(parts, 'a', owners, {('a', 'b')}), parts[1])
        self.assertIsNone(preferred_piece(parts, 'a', owners, {('a', 'wrong')}))

    def test_coast_swaps_leave_fixed_components_and_footprint(self):
        tiles = {'a': {(0, 0), (1, 0)}, 'b': {(0, 1), (1, 1)}}
        result, moves = repair(tiles, {('a', 'b')}, {'a'}, fixed={'a'})
        self.assertEqual(result, tiles)
        self.assertFalse(moves)
        self.assertEqual(set().union(*result.values()), set().union(*tiles.values()))

    def test_short_separation_keeps_borders_and_lake_shores(self):
        tiles = {'a': {(0, 0)}, 'b': {(1, 0), (2, 0)}, 'wrong': {(0, 1)}}
        required = {('a', 'b')}
        result, moves = separate(tiles, required, blocked={(1, -1)})
        self.assertTrue(moves)
        owner = {p:c for c,points in result.items() for p in points}
        self.assertNotIn((1, -1), owner)
        self.assertTrue(required <= contacts(owner))
        self.assertEqual({c:len(p) for c,p in result.items()}, {c:len(p) for c,p in tiles.items()})

    def test_template_restore_keeps_existing_true_borders(self):
        tiles = {'a': {(0, 0)}, 'b': {(1, 0), (2, 0)}}
        result, moves = restore(tiles, tiles, {('a', 'b')}, {'a': (0, 0), 'b': (1, 0)})
        self.assertFalse(moves)
        self.assertEqual(result, tiles)

    def test_template_restore_can_join_isolated_component(self):
        tiles = {'a': {(0, 0), (1, 0)}, 'b': {(4, 0)}}
        result, moves = restore(tiles, tiles, {('a', 'b')}, {'a': (0, 0), 'b': (5, 0)})
        self.assertTrue(moves)
        self.assertEqual(len(set().union(*result.values())), 3)
        self.assertEqual(len(pieces(set().union(*result.values()))), 1)


if __name__ == '__main__':
    unittest.main()

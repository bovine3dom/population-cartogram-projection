#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from dock_true_borders import contacts, place
from review_layout import connectivity


class DockTests(unittest.TestCase):
    def test_rigid_translation_replaces_false_contact(self):
        tiles = {'a': {(x, y) for x in range(1, 4) for y in range(3)},
                 'c': {(0, 0), (0, 1)}, 'b': {(-1, 1), (-1, 2)}}
        required = {('a', 'b'), ('a', 'c')}
        result, moves = place(tiles, required, radius=8)
        self.assertTrue(moves)
        actual = contacts({p: c for c, points in result.items() for p in points})
        self.assertTrue(required <= actual)
        self.assertNotIn(('b', 'c'), actual)
        self.assertEqual(result['a'], tiles['a'])
        self.assertEqual(result['c'], tiles['c'])
        for c in tiles:
            self.assertEqual(len(result[c]), len(tiles[c]))
            self.assertEqual(connectivity(result[c]), 1)
        self.assertEqual(connectivity(set().union(*result.values())), 1)
        self.assertEqual(sum(map(len, result.values())), len(set().union(*result.values())))

    def test_source_axis_order_is_kept(self):
        tiles = {'a': {(x, y) for x in range(1, 4) for y in range(3)},
                 'c': {(0, 0), (0, 1)}, 'b': {(-1, 1), (-1, 2)}}
        result, moves = place(tiles, {('a', 'b'), ('a', 'c')}, radius=8,
                              positions={'a': (10, 10), 'b': (0, 0), 'c': (0, 0)})
        self.assertTrue(moves)
        for axis in [0, 1]:
            self.assertLess(sum(p[axis] for p in result['b'])/len(result['b']),
                            sum(p[axis] for p in result['a'])/len(result['a']))

    def test_complete_contacts_need_no_move(self):
        tiles = {'a': {(0, 0), (1, 0)}, 'b': {(2, 0)}}
        result, moves = place(tiles, {('a', 'b')})
        self.assertEqual(result, tiles)
        self.assertFalse(moves)

    def test_disconnected_source_landmass_rejected(self):
        with self.assertRaisesRegex(ValueError, 'connected'):
            place({'a': {(0, 0)}, 'b': {(2, 0)}}, {('a', 'b')})


if __name__ == '__main__':
    unittest.main()

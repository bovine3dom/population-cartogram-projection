#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from refine_geography import GuardedDeformation
from review_layout import connectivity


class GuardTests(unittest.TestCase):
    def state(self):
        tiles = {'a': {(2, 2), (3, 2)}, 'b': {(4, 2), (5, 2)}}
        costs = {c: np.zeros((9, 9)) for c in tiles}
        costs['a'][2, 3] = 100
        return GuardedDeformation(tiles, {('a', 'b')}, costs, (0, 0), groups=[['a', 'b']])

    def test_split_is_rejected_and_rolled_back(self):
        state = self.state()
        before = state.energy()
        owners = dict(state.owners)
        self.assertFalse(state.exchange((3, 2), (2, 3)))
        self.assertEqual(state.rejected_splits, 1)
        self.assertEqual(state.owners, owners)
        self.assertEqual(state.land[0], set(owners))
        self.assertEqual(state.energy(), before)

    def test_accepted_move_keeps_counts_and_land(self):
        state = self.state()
        state.costs['b'][2, 5] = 100
        before = state.energy()
        self.assertTrue(state.exchange((5, 2), (4, 3)))
        self.assertLess(state.energy(), before)
        self.assertEqual([len(v) for v in state.tiles.values()], [2, 2])
        self.assertEqual(state.land[0], set(state.owners))
        self.assertEqual(connectivity(state.land[0]), 1)

    def test_fixed_and_coast_cost(self):
        state = self.state()
        state.fixed = {'a'}
        self.assertFalse(state.exchange((3, 2), (2, 3)))
        state.landlocked = {'a'}
        state.coast_weight = 32
        self.assertEqual(state.edge('a', None), 33)
        self.assertEqual(state.edge(None, 'a'), 33)
        self.assertEqual(state.edge('a', 'b'), 2)

    def test_contact_guard_and_rollback(self):
        state = self.state()
        state.preserve_contacts = True
        before = dict(state.contacts)
        self.assertFalse(state.exchange((3, 2), (2, 3)))
        self.assertEqual(state.rejected_contacts, 1)
        self.assertEqual(dict(state.contacts), before)
        self.assertEqual(state.contacts[('a', 'b')], 1)

    def test_steps_keep_contact_counts_consistent(self):
        state = self.state()
        state.preserve_contacts = True
        for _ in range(10):
            state.step(4)
            actual = sum((x+dx, y+dy) in state.tiles['b']
                         for x, y in state.tiles['a'] for dx, dy in [(1, 0), (-1, 0), (0, 1), (0, -1)])
            self.assertEqual(state.contacts[('a', 'b')], actual)
            self.assertGreater(actual, 0)
            self.assertEqual(state.land[0], set(state.owners))

    def test_disconnected_initial_land_rejected(self):
        with self.assertRaisesRegex(ValueError, 'landmasses'):
            GuardedDeformation({'a': {(1, 1)}, 'b': {(3, 1)}}, set(),
                {c: np.zeros((5, 5)) for c in ['a', 'b']}, (0, 0), groups=[['a', 'b']])


if __name__ == '__main__':
    unittest.main()

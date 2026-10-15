#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

import numpy as np
from shapely.geometry import LineString, box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from audit_border_population import measure
from relax_sparse_borders import SparseDeformation, gap_distance
from review_sparse_borders import shape_error


class ShapeReviewTests(unittest.TestCase):
    def test_shape_error_ignores_translation_and_uniform_scale(self):
        square = {(x, y) for x in range(2) for y in range(2)}
        self.assertAlmostEqual(shape_error(square, box(100, 100, 120, 120)), 0.)
        moved = {(x+20, y-30) for x, y in square}
        self.assertAlmostEqual(shape_error(moved, box(100, 100, 120, 120)), 0.)

    def test_shape_error_detects_distortion(self):
        self.assertGreater(shape_error({(0, y) for y in range(4)}, box(0, 0, 2, 2)), .5)


class BorderPopulationTests(unittest.TestCase):
    def test_corridor_uses_nearby_population_not_country_total(self):
        line = LineString([(0, 0), (0, 100)])
        xy = np.array([[0, 25], [1, 75], [9, 50]])
        result = measure(line, box(-10, 0, 10, 100), xy, np.array([100., 100., 1e9]), 2, 25)
        self.assertEqual(result['source_centres'], 2)
        self.assertAlmostEqual(result['corridor_area_km2'], 400)
        self.assertAlmostEqual(result['mean_density'], .5)
        self.assertAlmostEqual(result['p90_segment_density'], 1.)

    def test_no_shared_length_is_unknown_not_zero_density(self):
        self.assertIsNone(measure(LineString(), box(0, 0, 1, 1), np.empty((0, 2)), np.array([]), 2, 25))

    def test_empty_population_is_measured_zero(self):
        result = measure(LineString([(0, 0), (0, 100)]), box(-10, 0, 10, 100), np.empty((0, 2)), np.array([]), 2, 25)
        self.assertEqual(result['p90_segment_density'], 0)


class SparseBorderTests(unittest.TestCase):
    def state(self, soft=True, maximum_gap=3, locked=(), protected_water=()):
        tiles = {'a': {(x, y) for x in range(2) for y in range(3)} | {(2, 1)},
                 'b': {(x, y) for x in range(3, 6) for y in range(1, 4)}}
        costs = {c: np.zeros((20, 20), dtype=float) for c in tiles}
        costs['a'][5, 6] = 100  # Removing (2,1) strongly improves the test objective.
        return SparseDeformation(tiles, {('a', 'b')}, costs, (-4, -4),
                                 {('a', 'b')} if soft else set(), set(), locked, protected_water,
                                 set(tiles['a']) | tiles['b'], maximum_gap, 20, perimeter=0, false_contact=0)

    def test_sparse_contact_may_open_but_counts_stay_exact(self):
        state = self.state()
        counts = {c: len(p) for c, p in state.tiles.items()}
        self.assertTrue(state.exchange((2, 1), (0, 3)))
        self.assertEqual(state.contacts[('a', 'b')], 0)
        self.assertEqual({c: len(p) for c, p in state.tiles.items()}, counts)
        self.assertEqual(gap_distance(state.tiles['a'], state.tiles['b']), 2)
        self.assertNotIn(('a', 'b'), state.protected_contacts)

    def test_dense_contact_cannot_open(self):
        state = self.state(soft=False)
        before = dict(state.owners)
        self.assertFalse(state.exchange((2, 1), (0, 3)))
        self.assertEqual(state.owners, before)
        self.assertEqual(state.contacts[('a', 'b')], 1)

    def test_gap_limit_rejects_and_restores_full_state(self):
        state = self.state(maximum_gap=0)
        before = dict(state.owners)
        self.assertFalse(state.exchange((2, 1), (0, 3)))
        self.assertEqual(state.owners, before)
        self.assertEqual(state.contacts[('a', 'b')], 1)
        self.assertEqual(state.rejected_policy, 1)
        self.assertEqual(state.gaps, set())
        self.assertEqual(state.protected_contacts, set())

    def test_interior_gap_budget_and_band_are_hard_limits(self):
        tiles = {'a': {(x, y) for x in range(3) for y in range(3)},
                 'b': {(x, y) for x in range(3, 6) for y in range(3)}}
        costs = {c: np.zeros((20, 20)) for c in tiles}
        costs['a'][5, 6] = 100
        for band, budget in [(set(), 20), ({(2, 1)}, 0)]:
            state = SparseDeformation(tiles, {('a', 'b')}, costs, (-4, -4), {('a', 'b')},
                                      set(), set(), set(), band, 3, budget, perimeter=0)
            original = dict(state.owners)
            self.assertFalse(state.exchange((2, 1), (0, 3)))
            self.assertEqual(state.owners, original)
            self.assertEqual(state.gaps, set())

    def test_lake_shore_and_protected_water_are_fixed(self):
        for kwargs in [dict(locked={(2, 1)}), dict(protected_water={(0, 3)})]:
            state = self.state(**kwargs)
            before = dict(state.owners)
            self.assertFalse(state.exchange((2, 1), (0, 3)))
            self.assertEqual(state.owners, before)


if __name__ == '__main__':
    unittest.main()

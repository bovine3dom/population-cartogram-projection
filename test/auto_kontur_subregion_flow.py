import sys
from pathlib import Path
import unittest

import numpy as np
from shapely import box, union_all

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from kontur_subregion_flow import patches, targets, merge_small, merge_density


class KonturFlowTest(unittest.TestCase):
    def test_uniform_control_uses_area_not_mass(self):
        np.testing.assert_allclose(targets([1, 3], [90, 10], 80, 0), [20, 60])

    def test_blend_preserves_budget_and_positive_empty_patch(self):
        result = targets([1, 1], [100, 0], 80, .9)
        np.testing.assert_allclose(result, [76, 4])
        self.assertAlmostEqual(result.sum(), 80)

    def test_invalid_targets_rejected(self):
        for areas, mass, budget, strength in [([1], [0], 2, .5), ([1], [1], 2, 1),
                ([1, 2], [1], 2, .5), ([float('nan')], [1], 2, .5), ([1], [1], -1, .5)]:
            with self.assertRaises(ValueError):
                targets(areas, mass, budget, strength)

    def test_clipping_preserves_hole_and_area(self):
        original = box(-3, -2, 4, 5).difference(box(-1, 0, 1, 2))
        cells = patches(original, 2)
        self.assertAlmostEqual(sum(p.area for p in cells), original.area)
        self.assertLess(union_all(cells).symmetric_difference(original).area, 1e-9)

    def test_small_patch_merge_keeps_coverage(self):
        cells = [box(0, 0, .1, 1), box(.1, 0, 2, 1), box(2, 0, 3, 1)]
        merged = merge_small(cells, .5)
        self.assertEqual(len(merged), 2)
        self.assertTrue(all(g.area >= .5 for g in merged))
        self.assertLess(union_all(cells).symmetric_difference(union_all(merged)).area, 1e-9)

    def test_density_merge_clears_floor_for_all_variants(self):
        cells = [box(i, 0, i+1, 1) for i in range(4)]
        merged, mass = merge_density(cells, [100, 0, 100, 0], 40, [0, .9], 2)
        self.assertEqual(mass.sum(), 200)
        self.assertLess(union_all(cells).symmetric_difference(union_all(merged)).area, 1e-9)
        for strength in [0, .9]:
            self.assertTrue(np.all(targets([g.area for g in merged], mass, 40, strength) > 2))

    def test_cell_size_must_be_positive(self):
        with self.assertRaises(ValueError):
            patches(box(0, 0, 1, 1), 0)

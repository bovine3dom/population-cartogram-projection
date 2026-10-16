import copy
from pathlib import Path
import sys
import unittest

from shapely import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from independent_kontur_flow import normalized, select_patches


class IndependentFlowTest(unittest.TestCase):
    def setUp(self):
        self.features = [dict(properties=dict(component_id=c, patch_id=p)) for c,p in [('a','a0'), ('a','a1'), ('b','b0')]]
        self.data = [dict(component_id=c, patch_id=p, population=n) for c,p,n in [('a','a0',30), ('a','a1',70), ('b','b0',200)]]
        self.targets = [dict(patch_id=p, tiles=t) for p,t in [('a0','3.125'), ('a1','6.875'), ('b0','20')]]

    def test_selects_exact_patch_features_and_target_strings(self):
        before = copy.deepcopy((self.features, self.data, self.targets))
        features, rows = select_patches(self.features, self.data, self.targets, 'a', 10, 100)
        self.assertEqual(features, self.features[:2])
        self.assertEqual(rows, self.targets[:2])
        self.assertEqual(before, (self.features, self.data, self.targets))

    def test_rejects_missing_or_duplicate_labels(self):
        for rows in [self.targets[1:], [self.targets[0], self.targets[0], self.targets[2]]]:
            with self.assertRaisesRegex(ValueError, 'labels'):
                select_patches(self.features, self.data, rows, 'a', 10, 100)

    def test_checks_population_and_budget(self):
        for budget, population in [(11, 100), (10, 99)]:
            with self.assertRaises(ValueError):
                select_patches(self.features, self.data, self.targets, 'a', budget, population)

    def test_normalization_preserves_shape_and_sets_area(self):
        g = normalized(box(10, 20, 14, 22), 100)
        self.assertAlmostEqual(g.area, 100)
        self.assertAlmostEqual(g.centroid.x, 0)
        self.assertAlmostEqual(g.centroid.y, 0)
        self.assertAlmostEqual((g.bounds[2]-g.bounds[0])/(g.bounds[3]-g.bounds[1]), 2)

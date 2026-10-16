import sys
from pathlib import Path
import unittest

from shapely import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from run_kontur_planet import clean_overlaps


class KonturGuideCleanupTest(unittest.TestCase):
    def test_disjoint_shapes_are_unchanged(self):
        shapes = {'a': box(0, 0, 1, 1), 'b': box(2, 0, 3, 1)}
        clean, records = clean_overlaps(shapes)
        self.assertEqual(records, [])
        self.assertTrue(all(clean[c].equals(g) for c, g in shapes.items()))

    def test_numeric_overlap_removed_without_splitting(self):
        clean, records = clean_overlaps({'a': box(0, 0, 1, 1), 'b': box(1-1e-8, 0, 2, 1)})
        self.assertEqual(clean['a'].intersection(clean['b']).area, 0)
        self.assertTrue(all(g.geom_type == 'Polygon' and g.is_valid for g in clean.values()))
        self.assertAlmostEqual(sum(r['removed_area'] for r in records), 1e-8)

    def test_large_overlap_is_not_silently_trimmed(self):
        with self.assertRaisesRegex(ValueError, 'limit'):
            clean_overlaps({'a': box(0, 0, 1, 1), 'b': box(.5, 0, 2, 1)})

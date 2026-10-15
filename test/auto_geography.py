"""Tests for layout geography review measurements."""
import sys
import unittest
from pathlib import Path

import numpy as np
from shapely import STRtree
from shapely.geometry import box, Polygon

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from review_geography import exterior_water, water_edges, separated_axes
from review_source_coasts import uncovered_samples


class GeographyTests(unittest.TestCase):
    def test_enclosed_water(self):
        ring = {(x, y) for x in range(3) for y in range(3)}-{(1, 1)}
        owner = dict.fromkeys(ring, 'a')
        water = exterior_water(owner)
        self.assertNotIn((1, 1), water)
        self.assertEqual(water_edges({'a': ring}, owner, water)['a'],
                         dict(exterior_water_edges=12, enclosed_water_edges=4))

    def test_open_channel(self):
        ring = {(x, y) for x in range(3) for y in range(3)}-{(1, 1), (1, 0)}
        self.assertIn((1, 1), exterior_water(dict.fromkeys(ring, 'a')))

    def test_diagonal_is_not_a_channel(self):
        ring = {(x, y) for x in range(3) for y in range(3)}-{(1, 1), (0, 0)}
        self.assertNotIn((1, 1), exterior_water(dict.fromkeys(ring, 'a')))

    def test_separation(self):
        a, b = box(0, 0, 1, 1), box(2, 0, 3, 1)
        left, right = np.array([[0, 0]]), np.array([[2, 0]])
        self.assertEqual(separated_axes(a, b, left, right), [])
        self.assertEqual(separated_axes(a, b, right, left), ['east'])
        self.assertEqual(separated_axes(b, a, left, right), ['west'])

    def test_source_coast(self):
        a, b = box(0, 0, 1, 1), box(1, 0, 2, 1)
        self.assertEqual(uncovered_samples(a, 0, STRtree([a]), 128, 1e-6), 128)
        self.assertEqual(uncovered_samples(a, 0, STRtree([a, b]), 128, 1e-6), 96)
        surround = Polygon([(-1, -1), (2, -1), (2, 2), (-1, 2)], [list(a.exterior.coords)])
        self.assertEqual(uncovered_samples(a, 0, STRtree([a, surround]), 128, 1e-6), 0)

    def test_empty(self):
        with self.assertRaises(ValueError):
            exterior_water({})


if __name__ == '__main__':
    unittest.main()

import sys
from pathlib import Path
import unittest

import numpy as np
from shapely import transform
from shapely.geometry import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from geographic_baseline import grow
from prepare_flow import equal_earth
from review_layout import connectivity
from review_projection_shapes import mercator, normalize, tile_geometry


class ProjectionShapesTest(unittest.TestCase):
    def test_mercator_reference(self):
        result = mercator([[0, 0], [180, 45], [-180, -45]])
        np.testing.assert_allclose(result[0], [0, 0], atol=1e-12)
        np.testing.assert_allclose(result[1], [np.pi*1000, np.log(1+np.sqrt(2))*1000])
        np.testing.assert_allclose(result[2], -result[1])

    def test_poles_and_nonfinite_rejected(self):
        for point in [[0, 90], [0, -90], [0, 91], [float('nan'), 0], [0, float('inf')]]:
            with self.assertRaises(ValueError):
                mercator([point])

    def test_no_silent_web_map_latitude_clipping(self):
        self.assertGreater(mercator([[0, 89]])[0, 1], mercator([[0, 85]])[0, 1])

    def test_same_budget_different_shapes(self):
        source = box(20, 50, 40, 75)
        guides = [normalize(transform(source, p), 90) for p in [equal_earth, mercator]]
        for guide in guides:
            self.assertAlmostEqual(guide.area, 90)
            self.assertAlmostEqual(guide.centroid.x, 0)
            cells, _ = grow(guide, 90)
            self.assertEqual(len(cells), 90)
            self.assertEqual(connectivity(cells), 1)
            self.assertAlmostEqual(tile_geometry(cells).area, 90)
        self.assertNotAlmostEqual(guides[0].bounds[2], guides[1].bounds[2])


if __name__ == '__main__':
    unittest.main()

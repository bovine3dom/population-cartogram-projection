import sys
from pathlib import Path
import unittest

from shapely import affinity, box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from trace_kazakhstan import outline_error


class TraceOutlineTest(unittest.TestCase):
    def test_translation_and_uniform_scale_do_not_count_as_distortion(self):
        source = box(0, 0, 4, 1)
        moved = affinity.translate(affinity.scale(source, 3, 3), 40, -70)
        self.assertAlmostEqual(outline_error(moved, source), 0)

    def test_stretch_counts_as_distortion(self):
        source = box(0, 0, 4, 1)
        self.assertGreater(outline_error(affinity.scale(source, 2, .5), source), .5)

    def test_rotation_is_not_fitted_away(self):
        source = box(0, 0, 4, 1)
        self.assertGreater(outline_error(affinity.rotate(source, 90), source), .5)

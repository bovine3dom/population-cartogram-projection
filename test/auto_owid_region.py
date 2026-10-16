import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from compare_owid_region import largest_part


class MainlandReferenceTest(unittest.TestCase):
    def test_largest_four_connected_part_excludes_islands(self):
        mainland = {(0, 0), (0, 1), (1, 1)}
        self.assertEqual(largest_part(mainland | {(2, 2), (8, 8)}), mainland)

    def test_ties_are_deterministic(self):
        self.assertEqual(largest_part({(4, 4), (1, 1)}), {(1, 1)})

    def test_empty_country_is_rejected(self):
        with self.assertRaises(ValueError):
            largest_part(set())

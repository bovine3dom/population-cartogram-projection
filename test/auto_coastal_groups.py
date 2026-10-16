import sys
import unittest
from pathlib import Path

from shapely.geometry import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from restore_archipelagos import clusters


class CoastalGroupsTest(unittest.TestCase):
    def setUp(self):
        self.tiles = {c: {(i, 0)} for i, c in enumerate(['land', 'large', 'small'])}
        self.rows = {c: {'group_population': n} for c, n in [('land', 100), ('large', 10), ('small', 1)]}
        self.source = {'land': box(-10, -10, 0, 10), 'small': box(.01, 0, .11, .1),
                       'large': box(.2, 0, 1.2, 1)}

    def groups(self, enabled):
        return clusters(self.tiles, self.rows, self.source, {'land'}, .2,
                        bridge_groups=True, coastal_groups=enabled)[0]

    def test_default_retains_separate_coastal_islands(self):
        self.assertEqual(self.groups(False), {'large': ['large'], 'small': ['small']})

    def test_nearer_mainland_does_not_hide_nearby_island(self):
        self.assertEqual(self.groups(True), {'large': ['large', 'small']})

    def test_distant_island_remains_separate(self):
        self.source['large'] = box(3, 0, 4, 1)
        self.assertEqual(self.groups(True), self.groups(False))

    def test_no_other_island_is_safe(self):
        del self.tiles['large']
        self.assertEqual(self.groups(True), {'small': ['small']})


if __name__ == '__main__':
    unittest.main()

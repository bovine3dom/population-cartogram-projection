import sys
from pathlib import Path
import unittest

from shapely import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from cut_flow_source import contact_pairs, open_seams


class SourceCutTest(unittest.TestCase):
    def setUp(self):
        self.shapes = {'a': box(0, 0, 10, 10), 'b': box(10, 0, 20, 10)}
        self.selected = {('a', 'b')}

    def test_opens_only_selected_contact(self):
        self.shapes['c'] = box(0, 10, 10, 20)
        result, removed = open_seams(self.shapes, self.selected, 1)
        self.assertEqual(contact_pairs(result), {('a', 'c')})
        self.assertAlmostEqual(result['a'].distance(result['b']), 1)
        self.assertEqual(len(removed), 2)
        self.assertTrue(all(g.is_valid and g.geom_type == 'Polygon' for g in result.values()))

    def test_rejects_loss_of_unselected_short_border(self):
        self.shapes['c'] = box(9.9, 10, 10, 11)
        with self.assertRaisesRegex(ValueError, 'unselected'):
            open_seams(self.shapes, self.selected, 1)

    def test_rejects_large_area_loss(self):
        with self.assertRaisesRegex(ValueError, 'too much'):
            open_seams(self.shapes, self.selected, 3)

    def test_rejects_invalid_width(self):
        for width in [0, -1, float('nan'), float('inf')]:
            with self.subTest(width=width), self.assertRaises(ValueError):
                open_seams(self.shapes, self.selected, width)

    def test_fragment_removal_requires_explicit_limit(self):
        # A narrow spur lies beside b. The seam removes its neck.
        self.shapes['a'] = self.shapes['a'].union(box(9.8, 10, 10, 11)).union(box(9, 11, 10, 12))
        self.shapes['b'] = box(10, 0, 20, 12)
        with self.assertRaisesRegex(ValueError, 'splits'):
            open_seams(self.shapes, self.selected, 1)
        result, removed = open_seams(self.shapes, self.selected, 1, maximum_fragment_loss=.01)
        self.assertEqual(result['a'].geom_type, 'Polygon')
        self.assertGreater(next(r for r in removed if r['component'] == 'a')['fragment_area_fraction'], 0)

    def test_rejects_nonexistent_border(self):
        with self.assertRaisesRegex(ValueError, 'no shared'):
            open_seams(self.shapes, {('a', 'c')}, 1)

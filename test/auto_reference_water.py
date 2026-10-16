import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from restore_reference_water import enclosed, restore
from review_layout import connectivity


class ReferenceWaterTests(unittest.TestCase):
    def fixture(self):
        reference = {(x, y): 'a' for x in range(5) for y in range(5) if (x, y) != (2, 2)}
        tiles = {'a': (set(reference) | {(2, 2)})-{(0, 0)}}
        return reference, tiles

    def test_restore_water_changes_only_two_endpoints(self):
        reference, tiles = self.fixture()
        result, moves = restore(tiles, reference, set(), set())
        self.assertEqual(enclosed({p: 'a' for p in result['a']}), {(2, 2)})
        self.assertEqual(len(result['a']), len(tiles['a']))
        self.assertEqual(connectivity(result['a']), 1)
        self.assertEqual(len(result['a'] ^ tiles['a']), 2)
        self.assertEqual(len(moves), 1)
        self.assertEqual(moves[0]['restored_water'], (2, 2))
        self.assertIn((2, 2), tiles['a'])

    def test_order_guard_can_reject_all_paths(self):
        reference, tiles = self.fixture()
        with self.assertRaisesRegex(ValueError, 'No safe'):
            restore(tiles, reference, set(), set(), order_guard=lambda _: False)

    def test_changed_reference_shore_is_rejected(self):
        reference, tiles = self.fixture()
        tiles['a'].remove((1, 2)); tiles['a'].add((0, 0))
        with self.assertRaisesRegex(ValueError, 'shore labels'):
            restore(tiles, reference, set(), set())

    def test_different_budgets_are_rejected(self):
        reference, tiles = self.fixture()
        tiles['a'].add((0, 0))
        with self.assertRaisesRegex(ValueError, 'budgets'):
            restore(tiles, reference, set(), set())


if __name__ == '__main__':
    unittest.main()

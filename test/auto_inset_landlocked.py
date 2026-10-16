import itertools
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from inset_landlocked import trial
from dock_true_borders import contacts
from review_geography import exterior_water, water_edges
from review_layout import connectivity


class InlandExchangeTests(unittest.TestCase):
    def fixture(self):
        tiles = {'a': {(x, y) for x in range(3) for y in range(2, 5)},
                 'b': {(x, y) for x in range(3, 7) for y in range(2, 5)} | {(x, 5) for x in range(2, 7)},
                 'c': {(x, y) for x in range(7) for y in range(2)},
                 'd': {(0, 5), (1, 5)}}
        return tiles, set(itertools.combinations(sorted(tiles), 2))

    def test_exchange_retains_a_border_and_balances_all_three_budgets(self):
        tiles, required = self.fixture()
        original = {c: set(p) for c, p in tiles.items()}
        result, record = trial(tiles, required, {'a', 'd'}, 'a', 'b', 'c', (2, 0))
        self.assertIsNotNone(result, record)
        self.assertTrue(record['retained_border_cells'])
        self.assertTrue(record['cover_to_donor'])
        self.assertEqual(tiles, original)
        self.assertEqual({c: len(p) for c, p in result.items()}, {c: len(p) for c, p in tiles.items()})
        self.assertTrue(all(connectivity(p) == 1 for p in result.values()))
        before = {p: c for c, points in tiles.items() for p in points}
        after = {p: c for c, points in result.items() for p in points}
        self.assertEqual(set(before), set(after))
        self.assertTrue(contacts(before) <= contacts(after))
        self.assertFalse(contacts(after)-required)
        sea = exterior_water(before)
        self.assertGreater(water_edges(tiles, before, sea)['a']['exterior_water_edges'], 0)
        self.assertEqual(water_edges(result, after, sea)['a']['exterior_water_edges'], 0)
        self.assertEqual(result['d'], tiles['d'])

    def test_shore_pins_cannot_move(self):
        tiles, required = self.fixture()
        result, _ = trial(tiles, required, {'a', 'd'}, 'a', 'b', 'c', (2, 0), fixed_cells=tiles['a'])
        self.assertIsNone(result)

    def test_new_false_contact_is_rejected(self):
        tiles, required = self.fixture()
        result, reason = trial(tiles, required-{('c', 'd')}, {'a', 'd'}, 'a', 'b', 'c', (2, 0))
        self.assertIsNone(result)
        self.assertIn('border regression', reason)

    def test_short_compensation_limit_does_not_return_partial_counts(self):
        tiles, required = self.fixture()
        result, reason = trial(tiles, required, {'a', 'd'}, 'a', 'b', 'c', (2, 0), reach=1)
        self.assertIsNone(result)
        self.assertIn('balance', reason)

    def test_cover_cannot_be_another_inland_country(self):
        tiles, required = self.fixture()
        with self.assertRaises(ValueError):
            trial(tiles, required, {'a', 'c'}, 'a', 'b', 'c', (2, 0))


if __name__ == '__main__':
    unittest.main()

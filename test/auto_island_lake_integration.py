import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from check_island_lake_integration import check


class IslandLakeIntegrationTest(unittest.TestCase):
    def setUp(self):
        self.rows = {'land': {'tiles': 1}, 'island': {'tiles': 1}}
        self.base = {'land': {(0, 0)}, 'island': {(3, 0)}}
        self.islands = {'land': {(0, 0)}, 'island': {(5, 0)}}
        self.water = [dict(lake_id='lake', name='Lake', x=0, y=2)]

    def test_combination_keeps_islands_and_water(self):
        report = check(self.rows, self.base, self.islands, self.water, self.islands, self.water)
        self.assertEqual(report['preserved_moved_components'], 1)
        self.assertEqual(report['empty_lake_cells'], 1)
        self.assertTrue(report['contact_graph_exact'])

    def test_reverting_island_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'improvement'):
            check(self.rows, self.base, self.islands, self.water, self.base, self.water)

    def test_lake_replacement_is_rejected_even_with_same_total(self):
        water = [dict(self.water[0], lake_id='different')]
        with self.assertRaisesRegex(ValueError, 'identities'):
            check(self.rows, self.base, self.islands, self.water, self.islands, water)

    def test_water_cannot_consume_country_tile(self):
        with self.assertRaisesRegex(ValueError, 'overlap'):
            check(self.rows, self.base, self.islands, self.water, self.islands, [dict(self.water[0], y=0)])

    def test_new_contact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Contact graph'):
            check(self.rows, self.base, self.islands, self.water, dict(self.islands, land={(4, 0)}), self.water)


if __name__ == '__main__':
    unittest.main()

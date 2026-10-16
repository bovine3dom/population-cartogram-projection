import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from scope_sparse_borders import scope


class ScopeTest(unittest.TestCase):
    def setUp(self):
        self.rows = {c: dict(country_id=c) for c in 'ABCDE'}
        self.tiles = {c: set(range(20 if c != 'E' else 1)) for c in self.rows}
        self.report = dict(borders=[dict(a=a, b=b, eligible=eligible) for a, b, eligible in
                                   [('A', 'B', True), ('A', 'C', False), ('B', 'D', True), ('A', 'E', True)]])

    def test_scope_keeps_only_large_sparse_incident_borders(self):
        result = scope(self.report, self.rows, self.tiles, 'A')
        self.assertEqual([b['eligible'] for b in result['borders']], [True, False, False, False])
        self.assertTrue(self.report['borders'][2]['eligible'])
        self.assertFalse(result['borders'][1]['population_eligible'])

    def test_empty_scope_rejected(self):
        with self.assertRaisesRegex(ValueError, 'No eligible'):
            scope(self.report, self.rows, self.tiles, 'C')

    def test_invalid_scope_rejected(self):
        for country, limit in [('X', 16), ('A', 0)]:
            with self.assertRaises(ValueError):
                scope(self.report, self.rows, self.tiles, country, limit)

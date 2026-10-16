import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from audit_sparse_cut import cut


class SparseCutTest(unittest.TestCase):
    def test_dense_alternate_path_blocks_release(self):
        actual = {('a', 'b'), ('a', 'c'), ('b', 'c')}
        borders = [dict(a='a', b='b', eligible=True, corridor_population=0)]
        result = cut(actual, actual, borders, 'a', 'b')
        self.assertFalse(result['feasible'])
        self.assertTrue(any(r['protected'] for r in result['cut']))

    def test_sparse_cut_keeps_dense_edge(self):
        actual = {('a', 'b'), ('b', 'c')}
        borders = [dict(a='b', b='c', eligible=True, corridor_population=10)]
        result = cut(actual, actual, borders, 'a', 'c')
        self.assertTrue(result['feasible'])
        self.assertEqual([(r['a'], r['b']) for r in result['cut']], [('b', 'c')])

    def test_false_contact_can_be_removed(self):
        result = cut({('a', 'b')}, set(), [], 'a', 'b')
        self.assertTrue(result['feasible'])
        self.assertTrue(result['cut'][0]['false_contact'])

"""Tests for the experimental coast graph."""
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from shapely.geometry import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from place_coast_graph import coast_edges, mapped_coast_point, order_constraints, solve_translations
from transport_coast_frames import TransportCoastFrames


class CoastGraphTests(unittest.TestCase):
    def test_fixed_anchor(self):
        edges = [dict(a='a', b='b', weight=1., shift_difference=[4., -2.])]
        shifts = solve_translations(['a', 'b'], {'a'}, edges, 1.)
        np.testing.assert_allclose(shifts['a'], [0, 0])
        np.testing.assert_allclose(shifts['b'], [2, -1])

    def test_two_anchors(self):
        edges = [dict(a='a', b='b', weight=1., shift_difference=[4., 0.]),
                 dict(a='c', b='b', weight=1., shift_difference=[-4., 0.])]
        shifts = solve_translations(['a', 'b', 'c'], {'a', 'c'}, edges, .1)
        np.testing.assert_allclose(shifts['b'], [0, 0], atol=1e-12)

    def test_nearest_graph(self):
        source = {'a': box(0, 0, 1, 1), 'b': box(2, 0, 3, 1), 'c': box(20, 0, 21, 1)}
        self.assertEqual(coast_edges(source, 1), [('a', 'b'), ('b', 'c')])
        self.assertEqual(coast_edges({'a': source['a']}, 4), [])

    def test_local_coast_frame(self):
        source = {'a': box(0, 0, 1, 1), 'b': box(10, 0, 11, 1)}
        tiles = {'a': {(0, 0)}, 'b': {(100, 50)}}
        mapped = mapped_coast_point(np.array([11., .5]), ['a', 'b'], source, tiles)
        np.testing.assert_allclose(mapped, [100.5, 50.])

    def test_large_anchor_not_hidden_by_islets(self):
        source = {'a': box(0, 0, 1, 1), 'b': box(3, 0, 4, 1), 'tiny': box(1.01, 0, 1.02, .01)}
        self.assertIn(('a', 'b'), coast_edges(source, 1))

    def test_transport_frame_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'balanced/a').mkdir(parents=True)
            (root/'sources.csv').write_text('id,component_id,group_id,value,x,y\ns,a,a,1,0,0\n')
            mapping = root/'balanced/a/mapping.csv'
            mapping.write_text('x,y,id,weight,weight_mean\n5,6,s,1,1\n')
            frame = TransportCoastFrames(root, {'a': {(5, 6)}})
            point = frame.point('a', [0, 0])
            self.assertAlmostEqual(np.linalg.norm(point-[5, 6]), .5)
            with self.assertRaises(ValueError):
                TransportCoastFrames(root, {'a': {(7, 6)}})
            mapping.write_text('x,y,id,weight,weight_mean\n5,6,s,.5,1\n')
            with self.assertRaises(ValueError):
                TransportCoastFrames(root, {'a': {(5, 6)}})

    def test_preserved_order(self):
        native = {'a': box(0, 0, 1, 1), 'b': box(10, 0, 11, 1)}
        bodies = {'a': {(0, 0)}, 'b': {(5, 0)}}
        self.assertEqual(order_constraints(native, bodies, [('a', 'b')]),
                         [dict(a='a', b='b', axis=0, bound=4)])
        self.assertEqual(order_constraints(native, {'a': {(5, 0)}, 'b': {(0, 0)}}, [('a', 'b')]), [])


if __name__ == '__main__':
    unittest.main()

import sys
from pathlib import Path
import unittest

import numpy as np
from shapely import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from assemble_independent import Assembly, matrix


class IndependentAssemblyTest(unittest.TestCase):
    def setUp(self):
        self.shapes = {'a': box(-1,-1,1,1), 'b': box(-1,-1,1,1)}
        self.centres = {'a': np.array([0.,0.]), 'b': np.array([5.,0.])}

    def test_transform_preserves_area(self):
        state = Assembly(self.shapes, self.centres, {('a','b')})
        flat = state.start.reshape(-1,4).copy()
        flat[:,2:] = [[.6,.3],[-.7,-.5]]
        for g in state.geometries(flat.ravel()):
            self.assertTrue(g.is_valid)
            self.assertAlmostEqual(g.area, 4)
        self.assertAlmostEqual(np.linalg.det(matrix(.6,.3)), 1)

    def test_cut_removes_only_direct_contact_term(self):
        retained = Assembly(self.shapes, self.centres, {('a','b')})
        released = Assembly(self.shapes, self.centres, set())
        before, after = retained.terms(retained.start), released.terms(retained.start)
        self.assertEqual(before.pop('contact'), 9.)
        self.assertEqual(after.pop('contact'), 0.)
        self.assertEqual(before, after)
        self.assertAlmostEqual(retained.objective(retained.start, 10, 200, .1)-released.objective(retained.start, 10, 200, .1), 90)

    def test_cut_does_not_add_a_target_gap(self):
        released = Assembly(self.shapes, self.centres, set())
        for x in [2.,3.,5.,20.]:
            flat = released.start.reshape(-1,4).copy()
            flat[1,0] = x
            self.assertEqual(released.terms(flat.ravel())['contact'], 0.)

    def test_collision_still_applies_to_cut_pair(self):
        released = Assembly(self.shapes, self.centres, set())
        flat = released.start.reshape(-1,4).copy()
        flat[1,:2] = [1.,0.]
        self.assertAlmostEqual(released.terms(flat.ravel())['overlap'], 2.)

    def test_other_contact_survives_a_cut(self):
        self.shapes['c'] = box(-1,-1,1,1)
        self.centres['c'] = np.array([10.,0.])
        state = Assembly(self.shapes, self.centres, {('b','c')})
        self.assertEqual(state.required, {('b','c')})
        self.assertAlmostEqual(state.terms(state.start)['contact'], 9.)

    def test_rejects_unknown_contact(self):
        with self.assertRaises(ValueError):
            Assembly(self.shapes, self.centres, {('a','unknown')})

import importlib.util
import contextlib
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
from shapely import box
from shapely.geometry import Point, Polygon

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from kontur_boundary_map import BoundaryMap, ContourSamplingError
from independent_kontur_flow import normalized
from welded_boundary_fit import WeldedMesh, area_gradient, signed_area, fit


class WeldedBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.source = {'a':box(0,0,4,4), 'b':box(4,0,8,4)}
        self.preferred = {c:normalized(g,16) for c,g in self.source.items()}
        self.budgets = {'a':16,'b':16}

    def test_retained_border_uses_identical_variables(self):
        mesh = WeldedMesh(self.source,self.preferred,self.budgets,set())
        for pair,entries,cut in mesh.shared:
            (_,ai,aj),(_,bi,bj) = entries
            self.assertFalse(cut)
            self.assertEqual(set(mesh.node[[ai,aj]]),set(mesh.node[[bi,bj]]))
        xy = mesh.initial.reshape(-1,2).copy()
        xy[:mesh.n] += np.random.default_rng(2).normal(0,.01,(mesh.n,2))
        g = mesh.polygons(xy.ravel())
        self.assertEqual(g['a'].distance(g['b']),0)
        self.assertGreater(g['a'].boundary.intersection(g['b'].boundary).length,3.9)
        self.assertLess(g['a'].intersection(g['b']).area,1e-8)

    def test_cut_duplicates_border_variables(self):
        mesh = WeldedMesh(self.source,self.preferred,self.budgets,{('a','b')})
        a = {i for ring in mesh.rings['a'] for i in ring}
        b = {i for ring in mesh.rings['b'] for i in ring}
        self.assertFalse(a & b)
        xy = mesh.initial.reshape(-1,2).copy()
        xy[list(b),0] += 2
        g = mesh.polygons(xy.ravel())
        self.assertAlmostEqual(g['a'].distance(g['b']),2)
        self.assertAlmostEqual(g['a'].area,16)
        self.assertAlmostEqual(g['b'].area,16)

    def test_incomplete_edge_matching_is_not_silently_accepted(self):
        self.source['a'] = Polygon([(0,0),(4,0),(4,1),(4,4),(0,4)])
        with self.assertRaisesRegex(ValueError,'misses part'):
            WeldedMesh(self.source,self.preferred,self.budgets,set())

    def test_target_chord_refinement_is_shared_and_parameters_stay_fixed(self):
        target = Polygon([(0,0),(-1,0),(-1,3),(2,3),(2,2),(0,2),(0,1),(2,0)])
        self.assertTrue(target.is_valid)
        ring = target.exterior
        arc = dict(ring=ring,labels=['x','y'],starts=np.array([0.,.5]))
        mapper = BoundaryMap(arc,arc)
        parameters = np.array([ring.project(Point(p),normalized=True)
                               for p in [(0,0),(2,2),(0,2),(0,1),(2,0)]])
        with self.assertRaises(ContourSamplingError):
            mapper.sample(parameters)
        with patch.object(mapper,'locations_on_ring',return_value=parameters) as locate:
            mesh = WeldedMesh(self.source,{'a':target,'b':self.preferred['b']},self.budgets,set(),
                              edge_length=100,mappers={'a':[mapper],'b':[None]})
        self.assertEqual(locate.call_count,1)
        self.assertTrue(mesh.refinement)
        self.assertGreater(len(mesh.shared),2)
        for _,entries,_ in mesh.shared:
            (_,ai,aj),(_,bi,bj) = entries
            self.assertEqual(set(mesh.node[[ai,aj]]),set(mesh.node[[bi,bj]]))
        self.assertTrue(mesh.checks(mesh.initial)['valid'])
        self.assertAlmostEqual(mesh.polygons(mesh.initial)['a'].area,16)

    def test_area_derivative_matches_finite_difference(self):
        p = np.array([[0.,0.],[4.,.1],[3.,4.],[-1.,2.]])
        gradient = area_gradient(p)
        for i in range(len(p)):
            for axis in range(2):
                changed = p.copy();changed[i,axis] += 1e-6
                self.assertAlmostEqual((signed_area(changed)-signed_area(p))/1e-6,gradient[i,axis],places=6)

    def test_country_area_jacobian_matches_finite_difference(self):
        mesh = WeldedMesh(self.source,self.preferred,self.budgets,set())
        jac,_ = mesh.equalities(mesh.initial)
        changed = mesh.initial.copy();changed[2] += 1e-6
        numerical = (mesh.areas(changed)-mesh.areas(mesh.initial))/mesh.budgets/1e-6
        np.testing.assert_allclose(numerical,jac[:,2].toarray().ravel(),atol=1e-8)

    def test_valid_initial_geometry_satisfies_collision_inequalities(self):
        for cuts in [set(),{('a','b')}]:
            mesh = WeldedMesh(self.source,self.preferred,self.budgets,cuts)
            _,lower = mesh.inequalities(mesh.initial)
            self.assertLessEqual(float(lower.max()),1e-8)

    def test_narrow_water_gap_gets_self_collision_constraints(self):
        g = Polygon([(0,0),(4,0),(4,4),(2.1,4),(2.1,1),(1.9,1),(1.9,4),(0,4)])
        mesh = WeldedMesh({'a':g},{'a':normalized(g,g.area)},{'a':g.area},set())
        jac,lower = mesh.inequalities(mesh.initial)
        self.assertGreater(jac.shape[0],8*len(mesh.triangles))
        self.assertLessEqual(float(lower.max()),1e-8)

    @unittest.skipUnless(importlib.util.find_spec('osqp'),'Install mesh-requirements.txt for the QP test')
    def test_cut_releases_shape_without_breaking_other_border(self):
        source = {'a':box(0,0,4,4), 'b':Polygon([(4,0),(8,0),(8,2),(8,4),(4,4)]), 'c':box(8,0,16,2)}
        preferred = {c:normalized(box(0,0,4,4),16) for c in source}
        mesh = WeldedMesh(source,preferred,{c:16 for c in source},{('b','c')})
        with contextlib.redirect_stdout(io.StringIO()):
            flat,_ = fit(mesh,iterations=40)
        g = mesh.polygons(flat)
        self.assertGreater(g['a'].boundary.intersection(g['b'].boundary).length,3.9)
        self.assertGreater(g['b'].distance(g['c']),1.)
        self.assertLess(mesh.checks(flat)['maximum_area_error'],1e-4)
        self.assertLess(mesh.checks(flat)['overlap'],1e-8)
        self.assertLess((g['c'].bounds[2]-g['c'].bounds[0])/(g['c'].bounds[3]-g['c'].bounds[1]),1.5)

    @unittest.skipUnless(importlib.util.find_spec('osqp'),'Install mesh-requirements.txt for the QP test')
    def test_iteration_limit_retries_smaller_steps_without_accepting_solution(self):
        mesh = WeldedMesh(self.source,self.preferred,self.budgets,set())
        info = SimpleNamespace(status_val=7,status='maximum iterations reached',iter=30000,prim_res=.01,dual_res=.01)
        with patch('osqp.OSQP') as solver, contextlib.redirect_stdout(io.StringIO()):
            solver.return_value.solve.return_value = SimpleNamespace(info=info)
            flat,history = fit(mesh,iterations=3)
        np.testing.assert_array_equal(flat,mesh.initial)
        self.assertEqual([step['trust'] for step in history],[2.,1.,.5])
        self.assertFalse(any('alpha' in step for step in history))

    @unittest.skipUnless(importlib.util.find_spec('osqp'),'Install mesh-requirements.txt for the QP test')
    def test_rectangle_fit_preserves_full_contact(self):
        mesh = WeldedMesh(self.source,self.preferred,self.budgets,set())
        flat,_ = fit(mesh,iterations=3)
        g = mesh.polygons(flat)
        self.assertGreater(g['a'].boundary.intersection(g['b'].boundary).length,3.9)
        self.assertLess(mesh.checks(flat)['maximum_area_error'],1e-6)

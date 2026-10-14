#!/usr/bin/env python3
"""Check the experimental planar mesh objective and geometry, not map quality."""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from scipy.sparse import csr_matrix
from shapely.geometry import box,mapping

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from mesh_guide import MeshObjective,build_mesh,transform_pieces,run
from review_flow import read_shapes


class MeshTests(unittest.TestCase):
    def fixture(self):
        vertices=np.array([[0.,0.],[1,0],[1,1],[0,1]])
        triangles=np.array([[0,1,2],[0,2,3]])
        portions=csr_matrix([[.5,0],[0,.5]])
        return MeshObjective(vertices,triangles,portions,[.7,.3],[False]*4)

    def test_gradient(self):
        objective=self.fixture();values=objective.vertices.ravel()+np.random.default_rng(5).normal(0,.03,8)
        for weight in [.01,.3]:
            cost,gradient=objective.evaluate(values,weight)
            for i in range(len(values)):
                step=np.zeros_like(values);step[i]=1e-6
                estimate=(objective.evaluate(values+step,weight)[0]-objective.evaluate(values-step,weight)[0])/2e-6
                self.assertAlmostEqual(estimate,gradient[i],places=6)
            self.assertTrue(np.isfinite(cost))

    def test_rotation_translation_and_folds(self):
        objective=self.fixture();values=objective.vertices.ravel()
        rotation=np.array([[0.,-1],[1,0]])
        turned=(objective.vertices@rotation.T+np.array([3.,4.])).ravel()
        self.assertAlmostEqual(objective.evaluate(values)[0],objective.evaluate(turned)[0],places=12)
        flipped=objective.vertices.copy();flipped[:,0]*=-1
        values=flipped.ravel();cost,gradient=objective.evaluate(values)
        self.assertGreater(cost,1e6)
        estimates=[]
        for i in range(len(values)):
            step=np.zeros_like(values);step[i]=1e-6
            estimates.append((objective.evaluate(values+step)[0]-objective.evaluate(values-step)[0])/2e-6)
        np.testing.assert_allclose(gradient,estimates,rtol=1e-6,atol=1e6)
        self.assertEqual(objective.report(flipped.ravel())['folded_triangles'],2)

    def test_determinant_step_bound(self):
        objective=self.fixture();values=objective.vertices.ravel()
        rng=np.random.default_rng(9)
        for direction in [rng.normal(size=len(values)) for _ in range(50)]+[-2*values]:
            step=objective.step_bound(values,direction)
            self.assertGreater(step,0);self.assertLessEqual(step,1)
            for fraction in [.25,.5,1]:
                report=objective.report(values+fraction*step*direction)
                self.assertGreaterEqual(report['minimum_determinant'],.05)
        self.assertLess(objective.step_bound(values,-2*values),.5)

    def test_identity_mesh_and_small_region(self):
        geometries=[box(0,0,1,1),box(1,0,2,1),box(2.1,.1,2.1001,.1001)]
        vertices,triangles,portions,fixed,pieces,info=build_mesh(geometries,8)
        self.assertTrue(np.all(np.asarray(portions.sum(axis=1)).ravel()>0))
        self.assertTrue(all(n>=4 for n in info['region_triangle_counts']))
        targets=np.asarray(portions.sum(axis=1)).ravel();objective=MeshObjective(vertices,triangles,portions,targets,fixed)
        values=vertices[~fixed].ravel();cost,gradient=objective.evaluate(values)
        self.assertAlmostEqual(cost,0,places=10);self.assertLess(np.abs(gradient).max(),1e-8)
        mapped=transform_pieces(objective,values,pieces)
        np.testing.assert_allclose([g.area for g in mapped],targets,rtol=1e-5,atol=1e-12)
        np.testing.assert_array_equal(objective.unpack(values)[fixed],vertices[fixed])

    def test_file_pipeline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);prepared=root/'input';prepared.mkdir()
            features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in [('a',box(0,0,1,1)),('b',box(1,0,2,1))]]
            (prepared/'geometry.geojson').write_text(json.dumps(dict(type='FeatureCollection',features=features)))
            (prepared/'areas.csv').write_text('component_id,tiles\na,7\nb,3\n')
            with contextlib.redirect_stdout(io.StringIO()):report=run(prepared,root/'output',resolution=8,iterations=100,distortions=(.1,.01),stage_geometry=True)
            self.assertLess(report['stages'][-1]['weighted_absolute_area_error'],report['initial']['weighted_absolute_area_error'])
            self.assertEqual(report['stages'][-1]['folded_triangles'],0);self.assertEqual(report['overlap_pairs'],[])
            geometries=read_shapes(root/'output/geometry.geojson');self.assertEqual(set(geometries),{'a','b'})
            self.assertGreater(geometries['a'].area,geometries['b'].area)
            self.assertEqual(len(report['stages']),2)
            for stage in report['stages']:
                self.assertEqual(set(read_shapes(root/'output'/stage['geometry']['file'])),{'a','b'})
                self.assertEqual(stage['geometry']['overlap_pairs'],[])
            mesh=np.load(root/'output/mesh.npz',allow_pickle=False)
            np.testing.assert_array_equal(mesh['initial'][mesh['fixed']],mesh['transformed'][mesh['fixed']])
            with self.assertRaisesRegex(ValueError,'already exists'):run(prepared,root/'output')
            with self.assertRaisesRegex(ValueError,'Invalid solver'):run(prepared,root/'bad',resolution=2)
            (prepared/'areas.csv').write_text('component_id,tiles\na,7\na,3\n')
            with self.assertRaisesRegex(ValueError,'Invalid guide'):run(prepared,root/'duplicate')


if __name__=='__main__':unittest.main()

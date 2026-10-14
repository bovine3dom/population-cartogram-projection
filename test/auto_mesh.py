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
from warp_population_sites import interpolate,run as warp_sites
from scipy.spatial import Delaunay


class MeshTests(unittest.TestCase):
    def fixture(self):
        vertices=np.array([[0.,0.],[1,0],[1,1],[0,1]])
        triangles=np.array([[0,1,2],[0,2,3]])
        portions=csr_matrix([[.5,0],[0,.5]])
        return MeshObjective(vertices,triangles,portions,[.7,.3],[False]*4)

    def test_site_interpolation(self):
        initial=np.array([[0.,0.],[2,0],[2,2],[0,2],[.8,.9]])
        triangles=Delaunay(initial).simplices
        matrix=np.array([[2.,.3],[.1,1.]])
        transformed=initial@matrix.T+[4,5]
        points=np.array([[.2,.4],[1.5,1.2]])
        np.testing.assert_allclose(interpolate(initial,transformed,triangles,points),points@matrix.T+[4,5])
        with self.assertRaisesRegex(ValueError,'outside'):interpolate(initial,transformed,triangles,[[3,3]])
        with self.assertRaisesRegex(ValueError,'differs'):interpolate(initial,transformed,triangles[:-1],points)
        with self.assertRaisesRegex(ValueError,'Folded'):interpolate(initial,-initial[:,::-1],triangles,points)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);guide=root/'guide';guide.mkdir()
            np.savez(guide/'mesh.npz',initial=initial,transformed=transformed,triangles=triangles)
            (guide/'mesh-guide.json').write_text(json.dumps(dict(mesh=dict(span=1000,centre=[0,0]))))
            (root/'sites.csv').write_text('component_id,population,x,y\na,7,.2,.4\nb,3,1.5,1.2\n')
            report=warp_sites(root/'sites.csv',guide,root/'output')
            from population_sites import read_sites
            np.testing.assert_allclose(list(read_sites(root/'output/sites.csv',['a','b']).values()),points@matrix.T+[4,5])
            self.assertEqual(report['components'],2)
            self.assertEqual(len(report['sites_sha256']),64)
            self.assertIn('a,7,',(root/'output/sites.csv').read_text())

    def test_gradient(self):
        objective=self.fixture();values=objective.vertices.ravel()+np.random.default_rng(5).normal(0,.03,8)
        for weight in [.01,.3]:
            objective.rotation_weight=0 if weight==.01 else 3
            cost,gradient=objective.evaluate(values,weight)
            for i in range(len(values)):
                step=np.zeros_like(values);step[i]=1e-6
                estimate=(objective.evaluate(values+step,weight)[0]-objective.evaluate(values-step,weight)[0])/2e-6
                self.assertAlmostEqual(estimate,gradient[i],places=6)
            self.assertTrue(np.isfinite(cost))

    def test_distortion_weights(self):
        vertices,triangles,portions,fixed,_,_=build_mesh([box(0,0,1,1),box(1,0,2,1)],8)
        targets=np.asarray(portions.sum(axis=1)).ravel()*[1.5,.5]
        objective=MeshObjective(vertices,triangles,portions,targets,fixed,water_weight=.001,density_weight=0)
        land=np.asarray(portions.sum(axis=0)).ravel()>0
        np.testing.assert_allclose(objective.weight[land],objective.areas[land])
        np.testing.assert_allclose(objective.weight[~land],.001*objective.areas[~land])
        for options in [dict(water_weight=-1),dict(density_weight=2),dict(water_weight=float('nan'))]:
            with self.assertRaisesRegex(ValueError,'Invalid distortion'):MeshObjective(vertices,triangles,portions,targets,fixed,**options)

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
        # The reciprocal barrier must remain active above the accepted floor.
        self.assertGreater(objective.evaluate((objective.vertices*1e-4).ravel())[0],1e6)

    def test_polygon_second_moments(self):
        from mesh_shape_prior import moment_samples
        from shapely import affinity
        from shapely.geometry import Polygon,MultiPolygon
        for geometry,variance in [(box(3,4,5,8),[1/3,4/3]),(Polygon([(0,0),(2,0),(2,2),(0,2)],holes=[[(.5,.5),(1.5,.5),(1.5,1.5),(.5,1.5)]]),[5/12,5/12]),(MultiPolygon([box(0,0,1,1),box(2,0,3,1)]),[13/12,1/12])]:
            points=moment_samples(geometry);centre=np.asarray(geometry.centroid.coords[0])
            np.testing.assert_allclose(points.mean(axis=0),centre)
            np.testing.assert_allclose((points-centre).T@(points-centre)/4,np.diag(variance),atol=1e-12)
            rotated=affinity.rotate(geometry,37,origin=(0,0));sample=moment_samples(rotated)
            self.assertAlmostEqual(np.sum((sample-sample.mean(axis=0))**2)/4,sum(variance))

    def test_component_shape_prior(self):
        from mesh_shape_prior import RegionShapePrior
        vertices,triangles,portions,fixed,pieces,_=build_mesh([box(0,0,1,1),box(1,0,2,1)],8)
        targets=np.asarray(portions.sum(axis=1)).ravel()
        prior=RegionShapePrior(vertices,triangles,pieces,targets)
        self.assertAlmostEqual(prior.evaluate(vertices)[0],0)
        self.assertAlmostEqual(prior.evaluate(vertices+[3,4])[0],0)
        objective=MeshObjective(vertices,triangles,portions,targets,fixed)
        objective.shape_prior=prior;objective.region_shape_weight=3
        values=vertices[~fixed].ravel()+np.random.default_rng(7).normal(0,.001,np.sum(~fixed)*2)
        cost,gradient=objective.evaluate(values)
        for i in np.linspace(0,len(values)-1,20,dtype=int):
            step=np.zeros_like(values);step[i]=1e-6
            estimate=(objective.evaluate(values+step)[0]-objective.evaluate(values-step)[0])/2e-6
            self.assertAlmostEqual(estimate,gradient[i],places=5)
        self.assertGreater(cost,0)

    def test_orientation_prior(self):
        objective=self.fixture();objective.rotation_weight=2
        values=objective.vertices.ravel();rotation=np.array([[0.,-1],[1,0]])
        turned=(objective.vertices@rotation.T).ravel()
        self.assertGreater(objective.evaluate(turned)[0],objective.evaluate(values)[0])
        self.assertAlmostEqual(objective.evaluate((objective.vertices+[4,5]).ravel())[0],objective.evaluate(values)[0])
        objective.rotation_weight=0
        self.assertAlmostEqual(objective.evaluate(turned)[0],objective.evaluate(values)[0])

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
            with contextlib.redirect_stdout(io.StringIO()):report=run(prepared,root/'output',resolution=8,iterations=100,distortions=(.1,.01),stage_geometry=True,region_shape_weight=.1)
            self.assertLess(report['stages'][-1]['weighted_absolute_area_error'],report['initial']['weighted_absolute_area_error'])
            self.assertEqual(report['stages'][-1]['folded_triangles'],0);self.assertEqual(report['overlap_pairs'],[])
            geometries=read_shapes(root/'output/geometry.geojson');self.assertEqual(set(geometries),{'a','b'})
            self.assertGreater(geometries['a'].area,geometries['b'].area)
            self.assertEqual(len(report['stages']),2)
            self.assertTrue((root/'output/stage-1.npz').exists())
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

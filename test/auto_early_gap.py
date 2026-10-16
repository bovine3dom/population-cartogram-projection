import sys
import unittest
from pathlib import Path

import numpy as np
from shapely import box, union_all
from shapely.geometry import Polygon, mapping, shape

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from early_gap_flow import advect_patches, simplify_patches
from independent_kontur_flow import normalized
from welded_boundary_fit import WeldedMesh, seed_cut_gap, continuation_fit


class EarlyGapTest(unittest.TestCase):
    def mesh(self):
        source = {'A':box(0,0,4,4),'B':Polygon([(4,0),(8,0),(8,2),(8,4),(4,4)]),'C':box(8,0,16,2)}
        return WeldedMesh(source,{c:normalized(g,16) for c,g in source.items()},
                          {c:16 for c in source},{('B','C')})

    def test_seed_opens_only_the_cut_and_keeps_valid_geometry(self):
        mesh = self.mesh()
        record = seed_cut_gap(mesh,1.)
        self.assertGreater(record['applied_target'],0)
        g = mesh.polygons(mesh.initial)
        self.assertGreater(g['B'].distance(g['C']),.1)
        self.assertGreater(g['A'].boundary.intersection(g['B'].boundary).length,1.)
        self.assertTrue(mesh.checks(mesh.initial)['valid'])
        self.assertLess(mesh.checks(mesh.initial)['overlap'],1e-8)

    def test_local_seed_keeps_unrelated_country_fixed(self):
        mesh = self.mesh()
        before = mesh.polygons(mesh.initial)['A']
        seed_cut_gap(mesh,1.,local=True)
        self.assertTrue(before.equals_exact(mesh.polygons(mesh.initial)['A'],0.))
        with self.assertRaises(ValueError):
            seed_cut_gap(self.mesh(),1.,steps=1,local=True)

    def test_continuation_restores_final_area_targets(self):
        source = {'A':box(0,0,4,4)}
        mesh = WeldedMesh(source,{'A':normalized(source['A'],15.)},{'A':15.},set())
        flat,history = continuation_fit(mesh,2,10)
        self.assertEqual(len(history),2)
        self.assertEqual(mesh.budgets.tolist(),[15.])
        self.assertTrue(mesh.checks(flat)['valid'])
        self.assertLess(mesh.checks(flat)['maximum_area_error'],.001)
        with self.assertRaises(ValueError):
            continuation_fit(mesh,0,1)

    def test_optional_self_contact_constraints_keep_current_mesh_feasible(self):
        source = {'A':box(0,0,4,.2)}
        args = source,{'A':normalized(source['A'],.8)},{'A':.8},set()
        normal = WeldedMesh(*args,edge_length=8.)
        protected = WeldedMesh(*args,edge_length=8.,self_contact=True)
        _,before = normal.inequalities(normal.initial)
        _,after = protected.inequalities(protected.initial)
        self.assertGreater(len(after),len(before))
        self.assertLessEqual(after.max(),1e-8)

    def test_zero_gap_is_identity_and_invalid_gap_fails(self):
        mesh = self.mesh()
        before = mesh.initial.copy()
        seed_cut_gap(mesh,0.)
        np.testing.assert_array_equal(before,mesh.initial)
        for gap in [-1.,float('nan'),float('inf')]:
            with self.assertRaises(ValueError):
                seed_cut_gap(mesh,gap)

    def test_patch_simplification_preserves_labels_and_shared_coverage(self):
        features = [dict(type='Feature',properties=dict(component_id='A',patch_id=str(i),population=10+i),geometry=mapping(g))
                    for i,g in enumerate([box(0,0,2,4),box(2,0,4,4)])]
        result,changes = simplify_patches(features,1.,.1)
        self.assertEqual([f['properties'] for f in result],[f['properties'] for f in features])
        geometries = [shape(f['geometry']) for f in result]
        self.assertLess(union_all(geometries).symmetric_difference(box(0,0,4,4)).area,1e-8)
        self.assertEqual(geometries[0].boundary.intersection(geometries[1].boundary).length,4)
        self.assertEqual(sum(r['changed_area'] for r in changes),0)

    def test_patch_transport_covers_deformed_country_without_population_changes(self):
        mesh = self.mesh()
        before = mesh.initial.copy()
        triangles = mesh.triangles.copy()
        source = mesh.polygons(before)
        features = []
        for c,g in source.items():
            x = g.centroid.x
            for i,part in enumerate([g.intersection(box(-100,-100,x,100)),g.intersection(box(x,-100,100,100))]):
                features.append(dict(type='Feature',properties=dict(component_id=c,patch_id=c+str(i),population=i+1),geometry=mapping(part)))
        seed_cut_gap(mesh,1.)
        after = mesh.initial.copy()
        mesh.triangles = triangles
        warped = advect_patches(features,mesh,before,after,1.)
        self.assertEqual([f['properties'] for f in warped],[f['properties'] for f in features])
        for c,g in mesh.polygons(after).items():
            transported = union_all([shape(f['geometry']) for f in warped if f['properties']['component_id']==c])
            self.assertLess(transported.symmetric_difference(g).area,1e-6)

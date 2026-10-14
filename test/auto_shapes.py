"""Shape-first experiments. Run with the geometry Python environment."""
import json
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from shapely.geometry import Polygon, MultiPolygon, box, mapping

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
import audit_shapes as audit
import prepare_flow as flow
import compact_regions as compact
import review_flow
from cycle_deformation import CycleDeformation
from fit_counts import CountFit
import shape_placement
import place_shapes
import review_regions
import geographic_baseline
from atomic_deformation import AtomicDeformation
from regrow_regions import Regrowth
import shape_stress
from shape_stress import Stress
from concave_stress import ConcaveStress, convex_pieces
from raster_stress import RasterStress, bilinear
from smooth_raster_stress import SmoothRasterStress


class ShapeTests(unittest.TestCase):
    def test_opening_detects_a_thin_tail_not_a_solid_square(self):
        square={(x,y) for x in range(5) for y in range(5)}
        self.assertEqual(audit.thin_shape(square)['opening_loss'],0)
        extended=square|{(x,2) for x in range(5,12)}
        result=audit.thin_shape(extended)
        self.assertEqual(result['opening_loss'],7)
        self.assertEqual(result['cells_outside_two_by_two'],7)
        self.assertEqual(result['connected_parts'],1)
        self.assertEqual(result['holes'],0)

    def test_exchange_energy_and_counts(self):
        points={(x,y) for x in range(5) for y in range(5)}|{(x,2) for x in range(5,12)}
        state=compact.Deformation({'a':points},set(),{'a':np.zeros((30,30))},(-5,-5))
        state.costs['a'][7,16]=5.
        before=state.energy()
        self.assertTrue(state.exchange((11,2),(2,5)))
        self.assertLess(state.energy(),before)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        saved=set(state.tiles['a'])
        self.assertFalse(state.exchange((2,2),(20,20)))
        self.assertEqual(state.tiles['a'],saved)
        for p in sorted(state.owners):
            if not state.possible(p,None):continue
            energy=state.energy();delta=state.delta(p,None)
            owner=state.change(p,None)
            self.assertAlmostEqual(state.energy()-energy,delta)
            state.change(p,owner)

    def test_rounds_keep_all_regions_connected(self):
        tiles={'a':{(x,y) for x in range(4) for y in range(5)},'b':{(x,y) for x in range(4,8) for y in range(5)}}
        rng=np.random.default_rng(17)
        state=compact.Deformation(tiles,{('a','b')},{c:rng.random((20,20))*10 for c in tiles},(-5,-5))
        for _ in range(10):
            before=state.energy();state.step()
            self.assertLessEqual(state.energy(),before+1e-8)
            for c,points in state.tiles.items():
                self.assertEqual(len(points),len(tiles[c]))
                self.assertEqual(compact.connectivity(points),1)
                self.assertEqual(compact.holes(points),0)

    def test_cycle_and_budget_fit(self):
        tiles={'a':{(x,y) for x in range(4) for y in range(5)},'b':{(x,y) for x in range(4,8) for y in range(5)}}
        rng=np.random.default_rng(19)
        costs={c:rng.random((20,20))*10 for c in tiles}
        state=CycleDeformation(tiles,{('a','b')},costs,(-5,-5))
        for _ in range(5):
            energy=state.energy();state.step()
            self.assertLessEqual(state.energy(),energy+1e-8)
            self.assertEqual({c:len(p) for c,p in state.tiles.items()},{'a':20,'b':20})
        state=CountFit(tiles,{('a','b')},costs,(-5,-5))
        targets={'a':16,'b':26}
        for _ in range(20):
            old=sum(abs(len(state.tiles[c])-targets[c]) for c in targets)
            if not state.fit_step(targets):break
            self.assertLess(sum(abs(len(state.tiles[c])-targets[c]) for c in targets),old)
        self.assertEqual({c:len(p) for c,p in state.tiles.items()},targets)
        for points in state.tiles.values():
            self.assertEqual(compact.connectivity(points),1)
            self.assertEqual(compact.holes(points),0)
        saved={c:set(p) for c,p in state.tiles.items()}
        self.assertFalse(state.transfer([(next(iter(state.tiles['a'])),None),((18,18),'b')]))
        self.assertEqual(state.tiles,saved)

    def test_fast_placement_matches_exhaustive_search(self):
        rng=np.random.default_rng(31)
        for _ in range(100):
            cells={(int(x),int(y)) for x,y in rng.integers(-3,4,size=(8,2))}
            blocked={(int(x),int(y)) for x,y in rng.integers(-8,9,size=(100,2))}
            desired=tuple(rng.random(2)*10-5)
            self.assertEqual(shape_placement.place(cells,desired,blocked),geographic_baseline.place(cells,desired,blocked))

    def test_atomic_exchange_can_remove_a_long_detour(self):
        points={(x,y) for x in range(6) for y in [0,2]}|{(0,1)}
        costs={'a':np.zeros((20,20))};costs['a'][6,5]=10.
        sequential=compact.Deformation({'a':points},set(),costs,(-5,-5))
        self.assertFalse(sequential.exchange((0,1),(5,1)))
        self.assertFalse(sequential.exchange((5,1),(0,1)))
        state=AtomicDeformation({'a':points},set(),costs,(-5,-5))
        before=state.energy()
        self.assertTrue(state.exchange((0,1),(5,1)))
        self.assertLess(state.energy(),before)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        saved=set(state.tiles['a'])
        self.assertFalse(state.exchange((2,0),(10,10)))
        self.assertEqual(state.tiles['a'],saved)

    def test_deformation_and_placement_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'input';layout=root/'layout';inputs.mkdir();layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles,west,east,south,north\na,5,0,1,40,41\nb,3,2,3,40,41\n')
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (inputs/'validated.wkt').write_text('STAGE 1\nOUTLINES 2\nOUT 0\ta\n0 0\t2 0\t2 2\t0 2\nSITECOUNT 0\nOUT 1\tb\n2 0\t4 0\t4 2\t2 2\nSITECOUNT 0\n')
            (layout/'cells.csv').write_text('component_id,x,y\na,0,0\na,1,0\na,0,1\na,1,1\nb,2,0\nb,3,0\nb,2,1\nb,3,1\n')
            (layout/'complete.txt').write_text('mode=test\n')
            with contextlib.redirect_stdout(io.StringIO()):
                metadata=compact.run(inputs,layout,root/'deformed',rounds=5,fit_rounds=10,atomic=True)
                self.assertEqual(metadata['absolute_tile_error'],0)
                place_shapes.run(inputs,root/'deformed',root/'placed',anchors=root/'deformed')
                stress=shape_stress.run(inputs,root/'deformed',root/'stress',iterations=30,raster=True,no_false_contacts=True,start_from_templates=True)
                self.assertEqual(stress['collision_geometry'],'signed-distance raster')
                geographic_baseline.run(inputs,root/'slow-baseline')
                geographic_baseline.run(inputs,root/'fast-baseline',fast_placement=True)
                self.assertEqual((root/'slow-baseline/cells.csv').read_bytes(),(root/'fast-baseline/cells.csv').read_bytes())
            _,tiles,owners=compact.load(inputs,root/'placed')
            self.assertEqual(len(owners),8)
            self.assertEqual({c:len(p) for c,p in tiles.items()},{'a':5,'b':3})
            (root/'placed/metrics.json').write_text(json.dumps(dict(tiles=8,absolute_tile_error=0,missing_contacts=0,false_contacts=0)))
            (root/'placed/review.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg"/>')
            crops=review_regions.run(inputs,root/'placed',root/'crops',render=False)
            self.assertEqual([r['name'] for r in crops['regions']],['europe'])
            self.assertIn('Positions are unchanged',(root/'crops/europe.svg').read_text())
            with self.assertRaisesRegex(ValueError,'already exists'):compact.run(inputs,layout,root/'deformed')
            with self.assertRaisesRegex(ValueError,'Invalid'):compact.run(inputs,layout,root/'bad',rounds=0)

    def test_regrowth_removes_detours_without_changing_counts(self):
        points={(x,y) for x in range(8) for y in [0,4]}|{(0,y) for y in range(1,4)}
        state=Regrowth({'a':points,'b':{(4,2)}},set(),{c:np.zeros((30,30)) for c in ['a','b']},(-10,-10))
        energy=state.energy();local=state.region_energy('a',points)
        self.assertTrue(state.regrow('a'))
        self.assertAlmostEqual(state.energy()-energy,state.region_energy('a',state.tiles['a'])-local)
        self.assertLess(state.energy(),energy)
        self.assertEqual(len(state.tiles['a']),len(points))
        self.assertEqual(state.tiles['b'],{(4,2)})
        self.assertEqual(compact.connectivity(state.tiles['a']),1)
        self.assertEqual(compact.holes(state.tiles['a']),0)
        self.assertFalse(state.tiles['a'] & state.tiles['b'])

    def test_region_energy_includes_the_other_regions_coast(self):
        costs={c:np.zeros((20,20)) for c in ['a','b']}
        state=Regrowth({'a':{(0,0),(1,0)},'b':{(2,0),(2,1)}},set(),costs,(-5,-5))
        old=state.energy();local=state.region_energy('a',state.tiles['a'])
        state.change((1,0),None);state.change((0,1),'a')
        self.assertAlmostEqual(state.energy()-old,state.region_energy('a',state.tiles['a'])-local)
        rng=np.random.default_rng(43)
        for _ in range(30):
            tiles={str(i):{(x,y) for x in range(3*i,3*i+3) for y in range(4)} for i in range(3)}
            state=Regrowth(tiles,set(),{c:rng.random((25,25)) for c in tiles},(-5,-5))
            for c in tiles:
                old=state.energy();local=state.region_energy(c,state.tiles[c]);state.regrow(c)
                self.assertAlmostEqual(state.energy()-old,state.region_energy(c,state.tiles[c])-local)
                self.assertLessEqual(state.energy(),old+1e-8)

    def test_stress_gradient_and_collision_separation(self):
        from scipy.optimize import minimize
        tiles={c:{(x,y) for x in range(3) for y in range(4)} for c in ['a','b']}
        state=Stress(tiles,{'a':(0.,0.),'b':(1.3,.7)},{('a','b')})
        x=state.initial.ravel().copy()+np.array([.03,.01,-.02,.04])
        value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)
        fit=minimize(state.objective,x,jac=True,method='L-BFGS-B')
        self.assertLess(fit.fun,value)
        self.assertLess(state.penetration(0,1,fit.x.reshape(-1,2))[0],.01)

    def test_concave_collision_keeps_space_in_a_bay(self):
        from shapely import union_all
        points={(x,y) for x in range(7) for y in range(7) if x<2 or y<2 or y>4}
        pieces=convex_pieces(points,tolerance=0)
        centre=np.mean(list(points),axis=0)
        geometry=union_all([Polygon(v+centre) for v,n in pieces])
        self.assertAlmostEqual(geometry.area,len(points))
        self.assertLess(geometry.area,geometry.convex_hull.area)
        tiles={'a':points,'b':{(0,0)}}
        positions={'a':centre,'b':np.array([4.,3.])}
        state=ConcaveStress(tiles,positions,set(),gap=0)
        self.assertEqual(state.pair_energy_gradient(0,1,state.initial)[0],0)
        self.assertGreater(state.penetration(0,1,state.initial)[0],0)
        x=state.initial.ravel()+np.array([.03,.02,-2.1,.07])
        value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)

    def test_border_targets_use_a_shared_source_point(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'source.json'
            source={'a':box(0,0,1,1),'b':box(1,0,2,1)}
            path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(p)) for c,p in source.items()])))
            tiles={'a':{(0,0)},'b':{(x,y) for x in range(2) for y in range(2)}}
            state=ConcaveStress(tiles,{'a':(0.,0.),'b':(2.,0.)},{('a','b')},gap=0)
            state.border_targets(path,tiles,{('a','b')})
            self.assertTrue(np.isfinite(state.targets).all())
            self.assertGreater(state.targets[0,0],1)
            self.assertLess(abs(state.targets[0,1]),.01)
            source['b']=box(3,0,4,1)
            path.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(p)) for c,p in source.items()])))
            with self.assertRaisesRegex(ValueError,'No source border'):state.border_targets(path,tiles,{('a','b')})

    def test_placement_can_forbid_false_contacts_without_adding_paths(self):
        tiles={'a':{(0,0),(1,0)},'b':{(0,0),(1,0)}};desired={'a':(.5,0),'b':(.5,1)}
        separate=shape_placement.place_all(tiles,desired,required=set())
        self.assertFalse(any(q in separate['b'] for p in separate['a'] for q in compact.adjacent(p)))
        touching=shape_placement.place_all(tiles,desired,required={('a','b')})
        self.assertTrue(any(q in touching['b'] for p in touching['a'] for q in compact.adjacent(p)))
        for result in [separate,touching]:
            self.assertEqual({c:len(p) for c,p in result.items()},{'a':2,'b':2})
            self.assertFalse(result['a'] & result['b'])

    def test_raster_collision_matches_direct_distance_samples(self):
        tiles={'a':{(x,y) for x in range(3) for y in range(4)},'b':{(0,0),(1,0),(0,1)}}
        state=RasterStress(tiles,{'a':(0.,0.),'b':(1.37,.22)},set(),gap=.3)
        value,gradient=state.pair_energy_gradient(0,1,state.initial);direct=0.
        for a,b in [(0,1),(1,0)]:
            points=np.array(sorted(tiles[state.labels[a]]),dtype=float);points-=points.mean(axis=0)
            _,penalty,origin=state.fields[b]
            for point in points:
                direct+=bilinear(penalty,*(point+state.initial[a]-state.initial[b]-origin))[0]
        self.assertAlmostEqual(value,.5*state.collision*direct)
        x=state.initial.ravel();numeric=[]
        for i in range(2):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.pair_energy_gradient(0,1,(x+shift).reshape(-1,2))[0]-state.pair_energy_gradient(0,1,(x-shift).reshape(-1,2))[0])/2e-6)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)
        bay={(x,y) for x in range(7) for y in range(7) if x<2 or y<2 or y>4}
        state=RasterStress({'a':bay,'b':{(0,0)}},{'a':np.mean(list(bay),axis=0),'b':(4.,3.)},set(),gap=0)
        self.assertAlmostEqual(state.pair_energy_gradient(0,1,state.initial)[0],0)
        state.initial[1]=[0.,3.]
        self.assertGreater(state.pair_energy_gradient(0,1,state.initial)[0],0)

    def test_smooth_raster_gradient(self):
        tiles={'a':{(x,y) for x in range(3) for y in range(4)},'b':{(0,0),(1,0),(0,1)}}
        state=SmoothRasterStress(tiles,{'a':(0.,0.),'b':(1.37,.22)},set(),gap=.3)
        x=state.initial.ravel();value,gradient=state.objective(x);numeric=[]
        for i in range(len(x)):
            shift=np.zeros_like(x);shift[i]=1e-6
            numeric.append((state.objective(x+shift)[0]-state.objective(x-shift)[0])/2e-6)
        self.assertGreater(value,0)
        np.testing.assert_allclose(gradient,numeric,rtol=1e-6,atol=1e-6)

    def test_single_cell_is_not_removed(self):
        state=compact.Deformation({'a':{(0,0)}},set(),{'a':np.zeros((10,10))},(-5,-5))
        self.assertFalse(state.exchange((0,0),(1,0)))
        self.assertEqual(state.tiles['a'],{(0,0)})

    def test_outline_score_is_translation_and_scale_invariant(self):
        cells={(x,y) for x in range(4) for y in range(4)}
        self.assertAlmostEqual(audit.outline_similarity(cells,box(-10,-10,10,10)),1)
        self.assertAlmostEqual(audit.outline_similarity({(x+100,y-60) for x,y in cells},box(0,0,1,1)),1)
        self.assertLess(audit.outline_similarity(cells,box(0,0,1,10)),.3)

    def test_equal_earth_symmetry_and_origin(self):
        points=flow.equal_earth(np.array([[0.,0.],[30.,50.],[-30.,50.],[30.,-50.]]))
        np.testing.assert_allclose(points[0],[0,0])
        np.testing.assert_allclose(points[1],points[2]*[-1,1])
        np.testing.assert_allclose(points[1],points[3]*[1,-1])
        self.assertTrue(np.all(np.isfinite(points)))

    def test_flow_reader_rejects_split_or_duplicate_components(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'shapes.json'
            def write(geometry,duplicate=False):
                feature=dict(type='Feature',properties=dict(component_id='a'),geometry=mapping(geometry))
                path.write_text(json.dumps(dict(type='FeatureCollection',features=[feature]*(2 if duplicate else 1))))
            write(MultiPolygon([box(0,0,1,1)]))
            self.assertEqual(review_flow.read_shapes(path)['a'].geom_type,'Polygon')
            write(MultiPolygon([box(0,0,1,1),box(2,0,3,1)]))
            with self.assertRaisesRegex(ValueError,'disconnected'):review_flow.read_shapes(path)
            write(box(0,0,1,1),duplicate=True)
            with self.assertRaisesRegex(ValueError,'Duplicate'):review_flow.read_shapes(path)

    def test_flow_keeps_islands_and_holes_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'inputs';inputs.mkdir()
            (inputs/'groups.csv').write_text('component_id,country_id,name,tiles\na,X,Main,10\nb,X,Island,2\nc,X,Grouped,0\n')
            (inputs/'manifest.json').write_text('{}')
            geometry=[Polygon([(0,0),(3,0),(3,3),(0,3)],holes=[[(1,1),(2,1),(2,2),(1,2)]]),box(8,0,9,1),box(10,0,11,1)]
            source=root/'polygons.geojson'
            source.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in zip('abc',geometry)])))
            result=flow.run(inputs,source,root/'out')
            self.assertEqual((result['components'],result['tiles'],result['holes']),(2,12,1))
            features=json.loads((root/'out/geometry.geojson').read_text())['features']
            self.assertEqual([f['properties']['component_id'] for f in features],['a','b'])
            self.assertEqual(len(features[0]['geometry']['coordinates']),2)
            with self.assertRaisesRegex(ValueError,'already exists'):flow.run(inputs,source,root/'out')
            source.write_text(json.dumps(dict(type='FeatureCollection',features=[])))
            with self.assertRaisesRegex(ValueError,'Missing'):flow.run(inputs,source,root/'bad')
            self.assertFalse((root/'bad').exists())


if __name__=='__main__':unittest.main()

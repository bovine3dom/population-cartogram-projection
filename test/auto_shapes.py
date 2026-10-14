"""Shape-first experiments. Run with the geometry Python environment."""
import json
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

    def test_single_cell_is_not_removed(self):
        state=compact.Deformation({'a':{(0,0)}},set(),{'a':np.zeros((10,10))},(-5,-5))
        self.assertFalse(state.exchange((0,0),(1,0)))
        self.assertEqual(state.tiles['a'],{(0,0)})

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

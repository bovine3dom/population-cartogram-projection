#!/usr/bin/env python3
"""Check the diagnostic capacity partition, not cartogram quality."""
import contextlib
import io
import json
from pathlib import Path
import sys
import shutil
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import pyarrow as pa

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from partition_land import dual, partition, round_capacities, contact_groups, run
from review_layout import load, viewport
from repair_partition import Repair, run as repair
import population_sites
import place_islands
import run_compact_pipeline


class CapacityPartitionTests(unittest.TestCase):
    def test_gradient(self):
        rng=np.random.default_rng(4);costs=rng.random((12,3));weights=rng.random(3);budgets=np.array([2,4,6])
        value,gradient=dual(weights,costs,budgets,.3)
        for i in range(3):
            delta=np.zeros(3);delta[i]=1e-6
            actual=(dual(weights+delta,costs,budgets,.3)[0]-dual(weights-delta,costs,budgets,.3)[0])/2e-6
            self.assertAlmostEqual(actual,gradient[i],places=7)
        self.assertAlmostEqual(value,dual(weights+10,costs,budgets,.3)[0],places=10)
        self.assertAlmostEqual(gradient.sum(),0.)

    def test_residual_correction(self):
        costs=np.array([[0,9],[0,4],[0,2],[0,1.]])
        labels,error=round_capacities(costs,np.array([2,2]),np.zeros(2))
        np.testing.assert_array_equal(labels,[0,0,1,1]);self.assertEqual(error,4)

    def test_counts_ties_and_determinism(self):
        for costs in [np.zeros((12,3)),np.random.default_rng(5).random((12,3))]:
            with contextlib.redirect_stdout(io.StringIO()):
                first,record=partition(costs,[2,4,6],40);second,_=partition(costs,[2,4,6],40)
            np.testing.assert_array_equal(first,second)
            np.testing.assert_array_equal(np.bincount(first),[2,4,6])
            self.assertGreaterEqual(record['residual_tiles_reassigned'],0)

    def test_single_label(self):
        with contextlib.redirect_stdout(io.StringIO()):labels,_=partition(np.arange(5.)[:,None],[5])
        np.testing.assert_array_equal(labels,np.zeros(5,dtype=int))

    def test_landmass_groups(self):
        self.assertEqual(contact_groups([('b','a'),('c','d'),('b','e')]),[['a','b','e'],['c','d']])
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'inputs';layout=root/'layout';inputs.mkdir();layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles\na,2\nb,2\nc,2\nd,2\ne,1\n')
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\nc,d,true\n')
            (inputs/'validated.wkt').write_text('header\nheader\n'+''.join(f'OUT\t{c}\n0 0\t1 0\t1 1\t0 1\nend\n' for c in 'abcde'))
            (layout/'complete.txt').write_text('mode=test\n')
            (layout/'cells.csv').write_text('component_id,x,y\na,0,0\na,0,1\nb,1,0\nb,1,1\nc,20,0\nc,20,1\nd,21,0\nd,21,1\ne,10,10\n')
            with contextlib.redirect_stdout(io.StringIO()):record=run(inputs,layout,root/'result',sigma=1,iterations=20,power=True,by_landmass=True)
            self.assertEqual([p['components'] for p in record['partitions']],[['a','b'],['c','d']])
            _,tiles,owners=load(inputs,root/'result')
            self.assertEqual(len(owners),9);self.assertEqual(tiles['e'],{(10,10)})
            self.assertEqual({c:len(points) for c,points in tiles.items()},{'a':2,'b':2,'c':2,'d':2,'e':1})
            self.assertTrue(all(x<10 for c in 'ab' for x,y in tiles[c]))
            self.assertTrue(all(x>10 for c in 'cd' for x,y in tiles[c]))
            original=(layout/'cells.csv').read_text()
            (layout/'cells.csv').write_text(original.replace('e,10,10','e,0,2'))
            with contextlib.redirect_stdout(io.StringIO()):floating=run(inputs,layout,root/'floating',sigma=1,iterations=20,power=True,by_landmass=True,float_islands=True)
            (layout/'cells.csv').write_text(original)
            _,floating_tiles,_=load(inputs,root/'floating')
            self.assertNotEqual(floating['translated_islands']['e'],[0.,0.])
            self.assertTrue(floating['float_islands']);self.assertEqual(set(floating['translated_islands']),{'e'})
            self.assertEqual({c:len(p) for c,p in floating_tiles.items()},{c:len(p) for c,p in tiles.items()})
            for x,y in floating_tiles['e']:
                self.assertFalse({(x+1,y),(x-1,y),(x,y+1),(x,y-1)} & set().union(*(p for c,p in floating_tiles.items() if c!='e')))
            sites=root/'sites.csv';sites.write_text('component_id,x,y\n'+''.join(f'{c},{x},0\n' for c,x in zip('abcde',[0,1,20,21,10])))
            with patch('partition_land.guide_costs',side_effect=AssertionError('Power costs must not build outline grids')),contextlib.redirect_stdout(io.StringIO()):
                site_record=run(inputs,layout,root/'site-result',sigma=1,iterations=20,power=True,by_landmass=True,sites=sites)
            self.assertEqual(site_record['sites'],str(sites));self.assertGreater(site_record['guide_alignment']['scale'],0)
            self.assertIn(str(sites),site_record['inputs'])
            self.assertEqual({c:len(p) for c,p in load(inputs,root/'site-result')[1].items()},{c:len(p) for c,p in tiles.items()})
            with self.assertRaisesRegex(ValueError,'either'):run(inputs,layout,root/'bad-sites',sites=sites,guide_layout=layout)
            features=[]
            for c,x in zip('abcde',[0,1,20,21,10]):
                size=.01 if c=='a' else 1.;x+=.05;y=.05
                features.append(dict(type='Feature',properties=dict(component_id=c),geometry=dict(type='Polygon',coordinates=[[[x,y],[x+size,y],[x+size,y+size],[x,y+size],[x,y]]])))
            geometry=root/'flow.geojson';geometry.write_text(json.dumps(dict(type='FeatureCollection',features=features)))
            with contextlib.redirect_stdout(io.StringIO()):flow=run(inputs,layout,root/'flow-result',sigma=1,iterations=20,power=True,by_landmass=True,flow_geometry=geometry,flow_stretch=1.5,flow_guide_weight=.5)
            self.assertEqual(flow['flow_guide_weight'],.5)
            self.assertIn('a',flow['flow']['subtile_fallback_components'])
            self.assertAlmostEqual(flow['flow']['x_scale']*flow['flow']['y_scale'],flow['flow']['scale']**2)
            self.assertEqual(sum(p['envelope']['target_cells'] for p in flow['partitions']),8)
            _,flow_tiles,_=load(inputs,root/'flow-result')
            self.assertEqual({c:len(p) for c,p in flow_tiles.items()},{c:len(p) for c,p in tiles.items()})
            self.assertIn(str(geometry),flow['inputs'])
            with contextlib.redirect_stdout(io.StringIO()):fixed=repair(inputs,root/'flow-result',root/'repaired',rounds=10)
            self.assertLessEqual(fixed['after']['fragment_cells'],fixed['before']['fragment_cells'])
            self.assertTrue((root/'repaired/parent-partition.json').exists())
            with self.assertRaisesRegex(ValueError,'either'):run(inputs,layout,root/'bad-flow',flow_geometry=geometry,guide_layout=layout)

    def test_fragment_swap(self):
        tiles={'a':{(0,0),(0,1),(3,0)},'b':{(1,0),(1,1),(2,0),(2,1),(3,1)},'island':{(9,9)}}
        state=Repair(tiles,{'island'});before=set(state.owners)
        self.assertEqual(state.report()['fragment_cells'],1)
        self.assertIsNotNone(state.step());self.assertEqual(state.report()['disconnected_regions'],0)
        self.assertEqual(set(state.owners),before)
        self.assertEqual({c:len(p) for c,p in state.tiles.items()},{c:len(p) for c,p in tiles.items()})
        self.assertEqual(state.tiles['island'],tiles['island']);self.assertIsNone(state.step())
        blocked=Repair(tiles,{'a','b','island'});self.assertIsNone(blocked.step());self.assertEqual(blocked.tiles,tiles)

    def test_fragment_relocation(self):
        tiles={'a':{(0,0),(100,0)},'island':{(20,20)}}
        state=Repair(tiles,{'island'});moved=state.relocate('a')
        self.assertEqual(moved['removed'],[(100,0)])
        self.assertEqual(state.report()['disconnected_regions'],0)
        self.assertEqual(len(state.tiles['a']),2);self.assertEqual(state.tiles['island'],tiles['island'])
        self.assertTrue(all(abs(x)+abs(y)<=1 for x,y in state.tiles['a']))
        blocked={'a':{(0,0),(100,0)},'b':{(-1,0),(1,0),(0,1),(0,-1)}}
        state=Repair(blocked,{'b'});self.assertIsNone(state.relocate('a'));self.assertEqual(state.tiles,blocked)

    def test_random_fragment_swaps(self):
        rng=np.random.default_rng(11)
        for _ in range(20):
            tiles={c:set() for c in 'abc'}
            for x in range(9):
                for y in range(5):tiles['abc'[x//3]].add((x,y))
            for _ in range(5):
                a,b=rng.choice(list(tiles),size=2,replace=False)
                p=sorted(tiles[a])[int(rng.integers(len(tiles[a])))];q=sorted(tiles[b])[int(rng.integers(len(tiles[b])))]
                tiles[a].remove(p);tiles[a].add(q);tiles[b].remove(q);tiles[b].add(p)
            state=Repair(tiles);footprint=set(state.owners)
            for _ in range(100):
                before=state.report()['fragment_cells'];parts={c:len(p) for c,p in state.parts.items()}
                if state.step() is None:break
                self.assertLess(state.report()['fragment_cells'],before)
                self.assertTrue(all(len(state.parts[c])<=parts[c] for c in tiles))
                self.assertEqual(set(state.owners),footprint)
                self.assertTrue(all(len(state.tiles[c])==15 for c in tiles))

    def test_islands_preserve_explicit_mainland_defects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'input';layout=root/'layout';inputs.mkdir();layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles,group_population\na,8,8\nb,1,1\n')
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\n')
            (inputs/'validated.wkt').write_text('header\nheader\nOUT\ta\n0 0\t3 0\t3 3\t0 3\nend\nOUT\tb\n1 1\t2 1\t2 2\t1 2\nend\n')
            (layout/'complete.txt').write_text('mode=test\n')
            (layout/'cells.csv').write_text('component_id,x,y\n'+''.join(f'{"b" if (x,y)==(1,1) else "a"},{x},{y}\n' for x in range(3) for y in range(3)))
            features=[dict(type='Feature',properties=dict(component_id=c),geometry=dict(type='Polygon',coordinates=[ring])) for c,ring in [('a',[[0,0],[3,0],[3,3],[0,3],[0,0]]),('b',[[1,1],[2,1],[2,2],[1,2],[1,1]])]]
            source=root/'polygons.geojson';source.write_text(json.dumps(dict(type='FeatureCollection',features=features)))
            with self.assertRaisesRegex(ValueError,'Invalid input shapes'):place_islands.run(inputs,layout,source,root/'rejected')
            report=place_islands.run(inputs,layout,source,root/'preserved',preserve_mainland_defects=True)
            self.assertEqual(report['unchanged_invalid_fixed_components'],['a'])
            self.assertEqual(report['initial_false_contacts'],report['final_false_contacts'])
            self.assertEqual(load(inputs,layout)[1],load(inputs,root/'preserved')[1])

    def test_read_sites(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'sites.csv'
            path.write_text('component_id,x,y\na,1,2\n')
            self.assertEqual(population_sites.read_sites(path,['a']),{'a':(1.,2.)})
            for rows in ['a,1,2\na,3,4\n','b,1,2\n','a,nan,2\n','a,1,inf\n']:
                path.write_text('component_id,x,y\n'+rows)
                with self.assertRaises(ValueError):population_sites.read_sites(path,['a'])

    def test_population_sites(self):
        mass,sites=population_sites.spherical_sites([179,-179],[0,0],[1,2],[0,0],1)
        self.assertEqual(mass.tolist(),[3.]);self.assertGreater(abs(sites[0,0]),179)
        with self.assertRaisesRegex(ValueError,'Undefined'):population_sites.spherical_sites([0,180],[0,0],[1,1],[0,0],1)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'input';inputs.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles,group_id,group_population\na,1,a,3\nb,0,a,0\n')
            tables={'sources':pa.table(dict(id=pa.array([1,2],type=pa.uint64()),value=[2.,1.],component_id=pa.DictionaryArray.from_arrays(pa.array([0,1]),pa.array(['a','b','unused'])))),
                    'centres':pa.table(dict(id=pa.array([2,1,3],type=pa.uint64()),value=[1.,2.,9.],longitude=[179.,-179.,45.],latitude=[0.,0.,0.]))}
            for name,table in tables.items():
                with pa.OSFile(str(root/(name+'.arrow')),'wb') as stream:
                    with pa.ipc.new_file(stream,table.schema) as writer:writer.write_table(table)
            report=population_sites.run(inputs,root/'sources.arrow',root/'centres.arrow',root/'sites')
            self.assertEqual(report['source_cells'],2);self.assertEqual(report['population'],3.)
            self.assertTrue((root/'sites/sites.csv').exists())

    @unittest.skipUnless(shutil.which('rsvg-convert'),'Install rsvg-convert for the headless pipeline test')
    def test_compact_pipeline(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs=root/'input';layout=root/'templates';inputs.mkdir();layout.mkdir()
            (inputs/'groups.csv').write_text('component_id,tiles,west,east,south,north,country_id,group_population,name,holes\na,5,0,2,40,42,A,50000000,A,0\nb,3,2,4,40,42,B,30000000,B,0\n')
            (inputs/'manifest.json').write_text(json.dumps(dict(tile_budget=8,population_total=80000000,represented_population=80000000,grouped_population=0,omitted_population=0,holes_not_encoded_in_wkt=0,policy='group')))
            (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
            (inputs/'validated.wkt').write_text('header\nheader\nOUT\ta\n0 0\t2 0\t2 2\t0 2\nend\nOUT\tb\n2 0\t4 0\t4 2\t2 2\nend\n')
            (layout/'complete.txt').write_text('mode=test\n')
            (layout/'cells.csv').write_text('component_id,x,y\na,0,0\na,0,1\na,1,0\na,1,1\na,2,0\nb,2,1\nb,3,0\nb,3,1\n')
            features=[dict(type='Feature',properties=dict(component_id=c),geometry=dict(type='Polygon',coordinates=[[[x,0],[x+2,0],[x+2,2],[x,2],[x,0]]])) for c,x in [('a',0),('b',2)]]
            geometry=root/'geometry.geojson';geometry.write_text(json.dumps(dict(type='FeatureCollection',features=features)))
            report=run_compact_pipeline.run(inputs,layout,geometry,root/'pipeline',flow_geometry=geometry,sigma=1,iterations=20)
            self.assertTrue(report['complete']);self.assertFalse(report['approved_for_production'])
            self.assertEqual(report['metrics']['absolute_tile_error'],0)
            self.assertTrue(all(step['complete'] for step in report['steps']))
            self.assertTrue((root/'pipeline/layout/review.png').is_file())
            for options in [dict(flow_grid=17),dict(flow_area_error=0),dict(flow_area_error=float('nan'))]:
                with self.assertRaisesRegex(ValueError,'[Ff]low'):
                    run_compact_pipeline.run(inputs,layout,geometry,root/'bad',flow_geometry=geometry,**options)
                self.assertFalse((root/'bad').exists())

    def test_review_viewport(self):
        owners={(0,0):'a',(1,100):'a'}
        metrics=dict(disconnected_regions=1,regions_with_holes=0)
        current=viewport(owners,metrics);legacy=viewport(owners,metrics,140)
        self.assertEqual(current[-1],160);self.assertEqual(legacy[-1],140)
        self.assertAlmostEqual(current[4],915/102);self.assertAlmostEqual(legacy[4],935/102)

    def test_invalid(self):
        for costs,budgets in [(np.zeros((4,2)),[1,1]),(np.zeros((4,2)),[0,4]),(np.zeros((4,2)),[1.5,2.5]),(np.full((4,2),np.nan),[2,2])]:
            with self.assertRaises(ValueError):partition(costs,budgets)


if __name__=='__main__':unittest.main()

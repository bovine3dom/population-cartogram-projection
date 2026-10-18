import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

from shapely.geometry import box

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from dock_true_borders import contacts
from partition_landmass import partition
from relax_owid_islands import owners
from review_layout import connectivity
from split_owid_scopes import connected_seed, run, source_contacts, transformed_guides


class ScopeSplitTest(unittest.TestCase):
    def test_seed_and_complement_are_connected(self):
        points={(x,y) for x in range(6) for y in range(4)}
        seed=connected_seed(points,box(0,0,2,2),7)
        self.assertEqual(len(seed),7)
        self.assertEqual(connectivity(seed),1)
        self.assertEqual(connectivity(points-seed),1)
        self.assertEqual(len(points),24)

    def test_seed_rejects_empty_remainder(self):
        with self.assertRaises(ValueError):connected_seed({(0,0)},box(0,0,1,1),1)

    def test_source_border_requires_length_not_a_corner(self):
        geos={'a':box(0,0,1,1),'b':box(1,0,2,1),'c':box(2,1,3,2)}
        self.assertEqual(source_contacts(geos),{('a','b')})

    def test_guides_preserve_north_and_south(self):
        geos={'north':box(0,1,1,2),'south':box(0,0,1,1)}
        guides=transformed_guides(geos,{(10,-5),(10,-4),(11,-5),(11,-4)})
        self.assertGreater(guides['north'].centroid.y,guides['south'].centroid.y)
        self.assertEqual(guides['north'].bounds,(9.5,-4.5,11.5,-3.5))

    def test_explicit_graph_replaces_old_contacts(self):
        before={c:{(x,0),(x,1)} for c,x in [('a',0),('b',1),('c',2)]}
        preferred={'a':before['b'],'b':before['a'],'c':before['c']}
        expected={('a','b'),('a','c')}
        result,report=partition(before,set(owners(before)),{c:2 for c in before},seconds=10,
            preferred=preferred,exact_contacts=expected)
        self.assertIsNotNone(result,report)
        self.assertEqual(contacts(owners(result)),expected)
        self.assertEqual(set(owners(result)),set(owners(before)))
        self.assertEqual({c:len(ps) for c,ps in result.items()},{'a':2,'b':2,'c':2})

    def test_fixed_outside_contacts_are_enforced(self):
        before={'a':{(0,0),(0,1)},'b':{(1,0),(1,1)}}
        outside={(2,0):'c',(-1,0):'d'};expected={('a','b'),('a','d'),('b','c')}
        result,report=partition(before,set(owners(before)),{'a':3,'b':1},seconds=10,
            outside=outside,exact_contacts=expected)
        self.assertIsNotNone(result,report)
        self.assertEqual(result['b'],{(1,0)})
        self.assertEqual(contacts({**outside,**owners(result)}),expected)
        self.assertEqual(outside,{(2,0):'c',(-1,0):'d'})

    def test_export_conserves_land_and_recovers_population_once(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);parent=root/'parent';parent.mkdir()
            def table(path,rr):
                with path.open('w',newline='') as stream:
                    writer=csv.DictWriter(stream,fieldnames=list(rr[0]));writer.writeheader();writer.writerows(rr)
            table(parent/'cells.csv',[dict(component_id='A:T1',x=x,y=y) for x in range(3) for y in range(2)])
            table(parent/'matches.csv',[dict(country='A',target_part='T1',actual_tiles=6)])
            table(parent/'source-assignments.csv',[dict(country='A',component_id='A:source',target_part='T1',population=100,assignment='old',source_distance=0)])
            table(parent/'source-scopes-without-tiles.csv',[dict(country='N',population=100)])
            table(root/'components.csv',[dict(component_id=c+':source',country_id=c,population=100) for c in ('A','N')])
            table(root/'crosswalk.csv',[dict(pool='A',source_scope=c,target_scope=c) for c in ('A','N')])
            (root/'polygons.json').write_text(json.dumps(dict(type='FeatureCollection',features=[
                dict(type='Feature',properties={'component_id':c+':source'},geometry=box(x,0,x+1,1).__geo_interface__)
                for c,x in [('A',0),('N',1)]])))
            report=run(parent,root/'components.csv',root/'polygons.json',root/'crosswalk.csv',root/'out',seconds=10,margin=2)
            self.assertTrue(report['complete'])
            self.assertEqual(report['total_tiles'],6)
            self.assertEqual(report['recovered_population'],100)
            self.assertEqual(report['remaining_unrepresented_population'],0)
            self.assertEqual((root/'out'/'source-scopes-without-tiles.csv').read_text().strip(),'country,population')
            self.assertFalse((root/'out'/'owid-cartogram.csv').exists())

    def test_explicit_graph_rejects_unknown_scope(self):
        with self.assertRaises(ValueError):partition({'a':{(0,0)}},{(0,0)},{'a':1},exact_contacts={('a','unknown')})

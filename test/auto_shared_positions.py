"""Checks for experimental shared-island translations."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from shapely.geometry import box, mapping

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
import place_shared_islands as positions
from review_layout import load


class SharedIslandPositionsTests(unittest.TestCase):
    def fixture(self,root):
        inputs=root/'input';layout=root/'layout';inputs.mkdir();layout.mkdir()
        (inputs/'groups.csv').write_text('component_id,tiles\na,1\nb,1\nc,1\n')
        (inputs/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
        (layout/'cells.csv').write_text('component_id,x,y\na,1,0\nb,2,0\nc,0,0\n')
        (layout/'complete.txt').write_text('mode=test\n')
        polygons=root/'polygons.geojson';geometries={'a':box(0,0,1,1),'b':box(1,0,2,1),'c':box(10,-50,50,50)}
        polygons.write_text(json.dumps(dict(type='FeatureCollection',features=[dict(type='Feature',properties=dict(component_id=c),geometry=mapping(g)) for c,g in geometries.items()])))
        return inputs,layout,polygons

    def test_shared_body_keeps_internal_border_and_fixed_cells(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs,layout,polygons=self.fixture(root)
            report=positions.run(inputs,layout,polygons,root/'out',minimum_tiles=1,radius_km=2000)
            _,tiles,_=load(inputs,root/'out')
            self.assertEqual(tiles['c'],{(0,0)})
            a=next(iter(tiles['a']));b=next(iter(tiles['b']))
            self.assertEqual((b[0]-a[0],b[1]-a[1]),(1,0))
            self.assertLess(b[0],-1)
            self.assertEqual(report['members'],{'a':['a','b']})

    def test_no_selected_groups_is_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs,layout,polygons=self.fixture(root)
            report=positions.run(inputs,layout,polygons,root/'out')
            self.assertEqual(report['packing'],[])
            self.assertEqual(load(inputs,layout)[1],load(inputs,root/'out')[1])

    def test_conflicting_bounds_leave_no_completed_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);inputs,layout,polygons=self.fixture(root)
            with self.assertRaisesRegex(ValueError,'Conflicting island direction bounds'):
                positions.run(inputs,layout,polygons,root/'out',minimum_tiles=1,radius_km=2000,shift_scale=.1)
            self.assertFalse((root/'out').exists())

    def test_direction_threshold_and_dateline(self):
        tiles={'a':{(0,0)},'b':{(4,0)}}
        native={'a':box(178,0,179,1),'b':box(-179,0,-178,1)}
        source={'a':box(0,0,.01,.01),'b':box(.01,0,.02,.01)}
        self.assertEqual(positions.directions(tiles,native,source,set(),1000,3),[])
        native['b']=box(170,0,171,1)
        edges=positions.directions(tiles,native,source,set(),1000,3)
        self.assertEqual([(e['a'],e['b'],e['axis']) for e in edges],[('b','a',0)])
        shifts,_=positions.propose(tiles,{'a'},edges,10,6)
        self.assertTrue(np.array_equal(shifts['a'],[0,0]))
        placed,_=positions.pack(tiles,{'a'},edges,shifts,6)
        self.assertLess(max(x for x,y in placed['b']),0)


if __name__=='__main__':unittest.main()

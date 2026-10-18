"""Tests for population grouping and bounded OWID shape edits."""
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

from shapely.geometry import box, mapping

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from resize_owid_islands import local_geometry, match_components, resize_piece, run, visible_budgets
from review_layout import connectivity


class OwidResizeTests(unittest.TestCase):
    def test_floor_only_changes_small_groups(self):
        self.assertEqual(visible_budgets([90,9,1],10,[1,1,1]),[8,1,1])
        self.assertEqual(visible_budgets([70,30],10,[1,1]),[7,3])
        self.assertEqual(visible_budgets([99,1],10,[1,4]),[6,4])
        with self.assertRaises(ValueError):visible_budgets([1,1],1,[1,1])
        with self.assertRaises(ValueError):visible_budgets([1,0],4,[1,1])

    def test_locked_identities_do_not_follow_area_rank(self):
        tiles=[{(x,y) for x in range(3) for y in range(3)},{(10,0)}]
        rows=[dict(component_id='small',population=4),dict(component_id='large',population=5),dict(component_id='near-small',population=1)]
        shapes=[box(0,0,2,2),box(10,0,12,2),box(2.1,0,2.2,.1)]
        budgets,records,audit=match_components(tiles,rows,shapes,{0:'small',1:'large'})
        self.assertEqual(budgets,{0:5,1:5})
        self.assertEqual(records[2]['target_part'],'T1')
        self.assertEqual(records[2]['assignment'],'nearest_source_component')
        self.assertEqual(audit[0]['anchor_component'],'small')

    def test_unmatched_target_joins_nearest_target(self):
        tiles=[{(0,0),(1,0)}, {(10,0)}, {(2,2)}]
        rows=[dict(component_id='a',population=2),dict(component_id='b',population=2)]
        _,_,audit=match_components(tiles,rows,[box(0,0,1,1),box(10,0,11,1)],{0:'a',1:'b'})
        self.assertEqual(audit[2]['group'],'T1')
        self.assertEqual(audit[2]['identity'],'nearest_target_group')

    def test_real_border_selects_component_and_artwork_border_is_ignored(self):
        tiles=[{(0,0),(1,0)}, {(10,0)}]
        rows=[dict(component_id='a',population=2),dict(component_id='b',population=1)]
        shapes=[box(0,0,1,1),box(10,0,11,1)]
        _,_,audit=match_components(tiles,rows,shapes,{},target_neighbours=[{'X','artwork-only'},set()],source_neighbours=[set(),{'X'}])
        self.assertEqual(audit[0]['anchor_component'],'b')
        with self.assertRaisesRegex(ValueError,'border context'):
            match_components(tiles,rows,shapes,{0:'a'},target_neighbours=[{'X'},set()],source_neighbours=[set(),{'X'}])

    def test_dateline_is_local(self):
        a,b=local_geometry([box(178,0,179,1),box(-179,0,-178,1)],179,0)
        self.assertAlmostEqual(a.distance(b),2)

    def test_free_island_exact_and_connected(self):
        cells={(x,y) for x in range(5) for y in range(3)}
        for count in (1,8,27):
            owner=dict.fromkeys(cells,'a');owner[20,20]='b'
            result,record=resize_piece(cells,count,owner,'a',set())
            self.assertEqual(len(result),count)
            self.assertEqual(connectivity(result),1)
            self.assertEqual({p for p,c in owner.items() if c=='a'},result)
            self.assertEqual(owner[20,20],'b')
            self.assertGreater(record['shape_iou'],0)

    def test_failed_edit_restores_owner(self):
        cells={(0,0),(1,0)};owner=dict.fromkeys(cells,'a');before=dict(owner)
        with self.assertRaises(ValueError):resize_piece(cells,1,owner,'a',set(cells))
        self.assertEqual(owner,before)

    def test_full_trial_preserves_country_and_coordinate_convention(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);owid=root/'owid.csv';components=root/'components.csv'
            polygons=root/'polygons.json';iso=root/'iso.json';reviewed=root/'reviewed.csv';out=root/'out'
            cells={(x,y) for x in range(3) for y in range(3)}|{(10,0)}
            owid.write_text(''.join(f'{100+2*x},{200-2*y},250\n' for x,y in sorted(cells)))
            original=owid.read_bytes()
            components.write_text('component_id,country_id,map_unit,population\na,FRA,FXX,4\nb,FRA,FXX,6\n')
            polygons.write_text(json.dumps(dict(features=[dict(properties=dict(component_id=c),geometry=mapping(g)) for c,g in [('a',box(0,0,3,3)),('b',box(10,0,11,1))]])))
            iso.write_text(json.dumps({'3166-1':[dict(alpha_3='FRA',numeric='250')]}))
            reviewed.write_text('country,target_part,component_id\nFRA,T1,a\nFRA,T2,b\n')
            result,_,matches=run(owid,components,polygons,iso,reviewed,out)
            self.assertEqual([len(result[k]) for k in ['FRA:T1','FRA:T2']],[4,6])
            self.assertEqual(sum(len(p) for p in result.values()),10)
            self.assertEqual(owid.read_bytes(),original)
            with (out/'owid-cartogram.csv').open() as stream: exported=[tuple(map(int,r)) for r in csv.reader(stream)]
            self.assertEqual(len(exported),10)
            self.assertTrue(all(code==250 and x%2==0 and y%2==0 for x,y,code in exported))
            self.assertEqual(sum(r['group_population'] for r in matches),10)
            with self.assertRaises(ValueError):run(owid,components,polygons,iso,reviewed,out)


if __name__=='__main__':unittest.main()

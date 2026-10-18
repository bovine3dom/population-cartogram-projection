import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from dock_true_borders import contacts
from owid_landmass_world import footprint, landmasses, relax_outline, run
from partition_landmass import partition
from relax_owid_islands import owners
from restore_reference_water import enclosed
from review_layout import connectivity


class LandmassWorldTest(unittest.TestCase):
    def test_groups_ignore_country_boundaries(self):
        source={'a':{(0,0)},'b':{(1,0)},'c':{(3,0)},'d':{(2,1)}}
        self.assertEqual(landmasses(source), [['a','b'],['d'],['c']])

    def test_relaxed_outline_rejects_excess_change(self):
        source={'a':{(x,y) for x in range(3) for y in range(3)}}
        guide={(x+2,y) for x,y in source['a']}
        result,report=relax_outline(source,guide,{'a':9},10,.01)
        self.assertIsNone(result)
        self.assertFalse(report['complete'])
        self.assertGreater(report['outline_difference'],report['outline_difference_limit'])

    def test_unchanged_footprint_is_exact(self):
        source={(0,0),(0,1),(1,0)}
        result=footprint(source,3)
        self.assertEqual(result,source)
        self.assertIsNot(result,source)

    def test_lake_and_shores_survive_growth_and_shrink(self):
        source={(x,y) for x in range(9) for y in range(9)}-{(4,4)}
        for n in (70,90):
            result=footprint(source,n)
            self.assertEqual(len(result),n)
            self.assertEqual(enclosed(owners({'a':result})),{(4,4)})
            self.assertEqual(connectivity(result),1)
            self.assertTrue({(3,4),(4,3),(5,4),(4,5)}<=result)

    def test_partition_exact_counts_outline_and_contacts(self):
        reference={'a':{(x,y) for x in range(3) for y in range(3)},
                   'b':{(x,y) for x in range(3,6) for y in range(3)}}
        shape=set().union(*reference.values())
        result,report=partition(reference,shape,{'a':6,'b':12},seconds=10)
        self.assertIsNotNone(result,report)
        self.assertEqual(set(owners(result)),shape)
        self.assertEqual({c:len(p) for c,p in result.items()},{'a':6,'b':12})
        self.assertEqual(contacts(owners(result)),{('a','b')})
        self.assertTrue(all(connectivity(p)==1 for p in result.values()))

    def test_no_new_contact_between_end_parts(self):
        reference={c:{(x,y) for x in range(start,start+3) for y in range(3)}
                   for c,start in [('a',0),('b',3),('c',6)]}
        result,report=partition(reference,set(owners(reference)),{'a':10,'b':7,'c':10},seconds=10)
        self.assertIsNotNone(result,report)
        self.assertEqual(contacts(owners(result)),{('a','b'),('b','c')})

    def test_part_can_move_away_from_its_old_root(self):
        reference={'a':{(x,0) for x in range(6)},'b':{(x,0) for x in range(6,12)}}
        result,report=partition(reference,set(owners(reference)),{'a':10,'b':2},radius=.1,seconds=10)
        self.assertIsNotNone(result,report)
        self.assertEqual(result['b'],{(10,0),(11,0)})

    def test_complete_world_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);parent=root/'parent';parent.mkdir();owid=root/'original.csv'
            with owid.open('w') as stream:
                csv.writer(stream).writerows((x*2,0,250 if x<3 else 826) for x in range(6))
            (parent/'cells.csv').write_text('component_id,x,y\n'+''.join(f'{"FRA" if x<2 else "GBR"}:T1,{x},0\n' for x in range(6)))
            for name in ('matches.csv','source-assignments.csv','source-scopes-without-tiles.csv'):
                (parent/name).write_text('placeholder\n')
            (parent/'report.json').write_text(json.dumps(dict(grid={'input_grid_step':2},limits=[],countries=[{'country':'FRA'},{'country':'GBR'}])))
            report=run(owid,parent,root/'result',seconds=10)
            self.assertTrue(report['complete'])
            self.assertEqual(report['total_tiles'],6)
            self.assertTrue((root/'result'/'owid-cartogram.csv').exists())
            self.assertEqual(owid.read_text().count('\n'),6)

    def test_incompatible_budget_rejected(self):
        with self.assertRaises(ValueError):partition({'a':{(0,0)}},{(0,0)},{'a':2})

    def test_inland_part_stays_inland(self):
        source={'a':{(2,2)},'b':{(x,y) for x in range(5) for y in range(5)}-{(2,2)}}
        result,report=partition(source,set(owners(source)),{'a':2,'b':23},seconds=10)
        self.assertIsNotNone(result,report)
        self.assertTrue(all(0<x<4 and 0<y<4 for x,y in result['a']))

import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from block_cut_flow import separator


class BlockCutTest(unittest.TestCase):
    def records(self):
        return [dict(a=a,b=b,eligible=eligible,corridor_population=population,length_km=100.,mean_density=density,p90_segment_density=density)
                for a,b,eligible,population,density in [('A','B',True,100.,1.),('A','C',False,50.,60.),('C','B',False,200.,200.)]]

    def test_retained_bypass_prevents_strict_separation(self):
        _,cost,_,_ = separator(self.records(),'A','B','strict')
        self.assertGreaterEqual(cost,1e15)

    def test_relaxed_separator_preserves_within_block_edge(self):
        graph,cost,cut,parts = separator(self.records(),'A','B','relaxed')
        self.assertEqual(cost,150.)
        self.assertEqual({(r['a'],r['b']) for r in cut},{('A','B'),('A','C')})
        self.assertEqual(parts,[{'A'},{'B','C'}])
        self.assertTrue(graph.has_edge('B','C'))

    def test_unknown_policy_fails(self):
        with self.assertRaises(ValueError):
            separator(self.records(),'A','B','anything')

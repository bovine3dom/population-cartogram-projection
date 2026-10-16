import sys
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from wide_source_cut_trials import short_closures


class ShortClosureTest(unittest.TestCase):
    def records(self, length=40., population=300000.):
        return [dict(a=a,b=b,length_km=km,corridor_population=pop)
                for a,b,km,pop in [('A','B',1000.,1000000.),
                                    ('A','C',length,population),
                                    ('B','C',500.,2000000.)]]

    def test_short_low_total_population_bypass_is_explicit(self):
        self.assertEqual(short_closures({('A','B')},self.records()),{('A','C')})

    def test_long_or_high_population_edges_remain(self):
        self.assertEqual(short_closures({('A','B')},self.records(length=51.)),set())
        self.assertEqual(short_closures({('A','B')},self.records(population=500001.)),set())

    def test_missing_audit_measurements_cannot_authorize_a_cut(self):
        records = self.records()
        del records[1]['length_km']
        self.assertEqual(short_closures({('A','B')},records),set())

    def test_already_open_bypass_needs_no_extra_cut(self):
        self.assertEqual(short_closures({('A','B'),('B','C')},self.records()),set())

#!/usr/bin/env python3
"""Check the diagnostic capacity partition, not cartogram quality."""
import contextlib
import io
from pathlib import Path
import sys
import unittest

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from partition_land import dual, partition, round_capacities


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

    def test_invalid(self):
        for costs,budgets in [(np.zeros((4,2)),[1,1]),(np.zeros((4,2)),[0,4]),(np.zeros((4,2)),[1.5,2.5]),(np.full((4,2),np.nan),[2,2])]:
            with self.assertRaises(ValueError):partition(costs,budgets)


if __name__=='__main__':unittest.main()

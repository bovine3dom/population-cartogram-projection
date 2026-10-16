import sys
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from restore_archipelagos import displacement_cost


class SeparationDisplacementTest(unittest.TestCase):
    def test_large_required_move_has_no_optional_displacement(self):
        bounds = np.array([[159.,-np.inf],[np.inf,-40.]])
        self.assertEqual(displacement_cost([159.,-40.],bounds,True),0.)
        self.assertGreater(displacement_cost([159.,-40.],bounds),160.)
        self.assertEqual(displacement_cost([162.,-44.],bounds,True),5.)

    def test_already_satisfied_order_keeps_the_old_limit(self):
        bounds = np.array([[-20.,-np.inf],[30.,10.]])
        self.assertEqual(displacement_cost([3.,4.],bounds,True),5.)

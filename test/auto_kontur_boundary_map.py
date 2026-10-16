import sys
from pathlib import Path
import unittest

import numpy as np
from shapely import box
from shapely.geometry import mapping

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from kontur_boundary_map import BoundaryMap, labelled_arcs
from audit_boundary_labels import cyclic_match


def features(left,right):
    return [dict(type='Feature',properties=dict(patch_id=label),geometry=mapping(g)) for label,g in [('a',left),('b',right)]]


class KonturBoundaryMapTest(unittest.TestCase):
    def test_patch_junctions_match_after_aspect_change(self):
        source,arcs = labelled_arcs(features(box(0,0,2,2),box(2,0,4,2)))
        _,target = labelled_arcs(features(box(0,0,1,4),box(1,0,2,4)))
        mapper = BoundaryMap(arcs[0],target[0])
        xy = np.asarray(source.exterior.coords)[:-1]
        mapped = mapper.map(xy)
        for original,wanted in [([2,0],[1,0]),([2,2],[1,4])]:
            i = np.flatnonzero(np.all(xy == original,axis=1))[0]
            np.testing.assert_allclose(mapped[i],wanted,atol=1e-8)

    def test_missing_and_ambiguous_labels_fail(self):
        for left,right in [(['a','b'],['a','c']),(['a','b','a','b'],['a','b','a','b'])]:
            with self.assertRaises(ValueError):
                BoundaryMap(dict(labels=left),dict(labels=right))

    def test_audit_allows_only_cyclic_rotation(self):
        self.assertTrue(cyclic_match(['a','b','c'],['c','a','b']))
        self.assertFalse(cyclic_match(['a','b','c'],['a','c','b']))
        self.assertFalse(cyclic_match(['a','b'],['a','b','c']))

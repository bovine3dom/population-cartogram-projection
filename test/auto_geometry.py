"""Run with output/auto-cartogram/geometry-env/bin/python."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

import networkx as nx
import numpy as np
from shapely.geometry import Polygon, box

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"examples"/"auto-cartogram"))
import assign_population as population
import geographic_baseline as baseline
import geographic_embedding as geographic
import planar_embedding as embedding
import review_layout as review
import repair_contacts as repair
import validate_outlines as outlines


class PopulationTests(unittest.TestCase):
    def test_holes_boundaries_and_ambiguous_ownership(self):
        polygons = [Polygon([(0,0),(4,0),(4,4),(0,4)], [[(1,1),(2,1),(2,2),(1,2)]]),
                    box(3,3,5,5), None]
        x = np.array([.5,1.5,0,3.5,4.5,20])
        y = np.array([.5,1.5,0,3.5,4.5,20])
        expected = [1,0,0,-1,2,0]
        self.assertEqual(population.assign_batch(polygons,x,y).tolist(),expected)
        batched = np.concatenate([population.assign_batch(polygons,x[i:i+2],y[i:i+2]) for i in range(0,6,2)])
        self.assertEqual(batched.tolist(),expected)


class EmbeddingTests(unittest.TestCase):
    def test_cut_vertices_add_only_sea_borders(self):
        for original in [nx.path_graph(5),nx.star_graph(6),nx.cycle_graph(5),nx.complete_graph(4)]:
            original=nx.relabel_nodes(original,lambda n:f"land:{n}")
            _, prescribed=nx.check_planarity(original)
            graph,sea,drawing=embedding.augment(original,prescribed)
            for v in original:
                expected=list(prescribed.neighbors_cw_order(v))
                actual=[n for n in drawing.neighbors_cw_order(v) if n in original]
                start=actual.index(expected[0])
                self.assertEqual(actual[start:]+actual[:start],expected)
            self.assertTrue(nx.is_biconnected(graph))
            self.assertTrue(nx.check_planarity(graph)[0])
            self.assertEqual(set(graph.subgraph(original).edges),set(original.edges))
            self.assertTrue(all(label.startswith("SEA:") and graph.degree[label] == 2 for label in sea))
            geography={label:(i,i%3) for i,label in enumerate(graph)}
            positions=embedding.integer_positions(graph,geography,drawing)
            self.assertEqual(len({tuple(p) for p in positions.values()}),len(graph))
            self.assertEqual(positions,embedding.integer_positions(graph,geography,drawing))

    def test_two_vertex_drawings_are_not_axis_aligned(self):
        graph=nx.Graph([("a","b")])
        for point in [(0,10),(10,0),(0,-10),(-10,0)]:
            positions=embedding.integer_positions(graph,{"a":(0,0),"b":point})
            self.assertNotEqual(positions["a"][0],positions["b"][0])
            self.assertNotEqual(positions["a"][1],positions["b"][1])

    def test_shared_border_portal_is_consistent_on_both_sides(self):
        rings={
            "a":[(0,0),(1,0),(1,1),(1,2),(1,3),(0,3),(0,0)],
            "b":[(1,0),(2,0),(2,3),(1,3),(1,2),(1.5,2),(1.5,1),(1,1),(1,0)],
            "c":[(1,1),(1.5,1),(1.5,2),(1,2),(1,1)],
            "d":[(0,-1),(2,-1),(2,0),(1,0),(0,0),(0,-1)]}
        features=[{"properties":{"component_id":label},"geometry":{"coordinates":[ring]}} for label,ring in rings.items()]
        order=geographic.rotations(features,set(rings))
        graph=nx.PlanarEmbedding(); graph.set_data(order); graph.check_structure()
        reversed_features=[{"properties":f["properties"],"geometry":{"coordinates":[list(reversed(f["geometry"]["coordinates"][0]))]}} for f in reversed(features)]
        other=geographic.rotations(reversed_features,set(rings))
        for v in order:
            start=other[v].index(order[v][0])
            self.assertEqual(other[v][start:]+other[v][:start],order[v])

    def test_reject_nonplanar_graph(self):
        with self.assertRaises(ValueError):
            embedding.augment(nx.complete_graph(5))


class OutlineTests(unittest.TestCase):
    def test_invalid_simplification_uses_original_ring(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            (root/"input.wkt").write_text("STAGE 1\nOUTLINES 1\nOUT 0\ta\t0 0\t0 0 0\n0 0\t1 1\t0 1\t1 0\nSITECOUNT 0\n")
            (root/"original-outlines.json").write_text(json.dumps({"a":[[0,0],[1,0],[1,1],[0,1]]}))
            result=outlines.run(root)
            self.assertEqual(len(result["fallbacks"]),1)
            self.assertIn("0.0 0.0\t1.0 0.0",(root/"validated.wkt").read_text())
            with self.assertRaises(ValueError):
                outlines.run(root)


class RepairTests(unittest.TestCase):
    def test_reject_invalid_starting_regions(self):
        for cells in [{(0,0),(2,0)}, {(x,y) for x in range(3) for y in range(3)}-{(1,1)}, set()]:
            with self.assertRaises(ValueError):
                repair.Repair({"a":cells},set())

    def test_repeated_repairs_preserve_constraints(self):
        for count in [1,2,5,20]:
            tiles={str(i):{(i%3*12+x,i//3*12+y) for x,y in baseline.grow(box(0,0,2,1),count)[0]} for i in range(9)}
            required={tuple(sorted((str(i),str(j)))) for i in range(9) for j in range(i+1,9) if j == i+3 or (j == i+1 and i//3 == j//3)}
            state=repair.Repair(tiles,required,max_search=1000)
            for a,b in sorted(required):
                old=set(state.contacts)
                if (a,b) not in old:
                    state.connect(a,b)
                self.assertTrue(old <= set(state.contacts) <= required)
                checked=repair.Repair(state.tiles,required)
                self.assertEqual(checked.contacts,state.contacts)
                self.assertEqual(checked.owners,state.owners)
                self.assertTrue(all(len(p) == count for p in state.tiles.values()))

    def test_exact_counts_connectivity_and_no_false_contacts(self):
        tiles={"a":{(0,0)},"b":{(4,0)},"c":{(2,0)}}
        state=repair.Repair(tiles,{("a","b")},max_search=1000)
        success,_=state.connect("a","b")
        self.assertTrue(success)
        self.assertEqual(set(state.contacts),{("a","b")})
        self.assertEqual({c:len(p) for c,p in state.tiles.items()},{"a":1,"b":1,"c":1})
        self.assertEqual(state.tiles["c"],tiles["c"])
        for cells in state.tiles.values():
            self.assertEqual(review.connectivity(cells),1)
            self.assertEqual(review.holes(cells),0)

    def test_failed_bridge_rolls_back_tiles_and_contacts(self):
        tiles={"a":{(0,0)},"b":{(-1,0)},"c":{(4,0)}}
        state=repair.Repair(tiles,{("a","b"),("a","c")},max_search=1000)
        owners=dict(state.owners); contacts=dict(state.contacts)
        success,_=state.connect("a","c")
        self.assertFalse(success)
        self.assertEqual(state.tiles,tiles)
        self.assertEqual(state.owners,owners)
        self.assertEqual(dict(state.contacts),contacts)
        self.assertTrue(state.connect("c","a")[0])
        self.assertEqual(set(state.contacts),{("a","b"),("a","c")})


class BaselineTests(unittest.TestCase):
    def test_growth_and_placement(self):
        shapes=[box(0,0,1,1),box(0,0,20,1),Polygon([(0,0),(4,0),(4,1),(1,1),(1,4),(0,4)])]
        for shape in shapes:
            for count in [1,2,17,100]:
                cells,centre=baseline.grow(shape,count)
                self.assertEqual(len(cells),count)
                self.assertEqual(review.connectivity(cells),1)
                self.assertEqual(review.holes(cells),0)
                blocked=cells|{(x+dx,y+dy) for x,y in cells for dx,dy in review.NEIGHBOURS}
                moved=baseline.place(cells,centre,blocked)
                self.assertFalse(moved & blocked)
                self.assertEqual(len(moved),count)
                self.assertEqual(baseline.grow(shape,count)[0],cells)

    def test_hole_detector(self):
        cells={(x,y) for x in range(3) for y in range(3)}-{(1,1)}
        self.assertEqual(review.holes(cells),1)
        cells.remove((0,1))
        self.assertEqual(review.holes(cells),0)


if __name__ == "__main__":
    unittest.main()

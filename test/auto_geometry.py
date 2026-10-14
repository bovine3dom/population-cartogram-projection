"""Run with output/auto-cartogram/geometry-env/bin/python."""
import json
import sys
import tempfile
import unittest
from pathlib import Path

import networkx as nx
import numpy as np
from shapely.geometry import Polygon, box, mapping, shape

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"examples"/"auto-cartogram"))
import assign_population as population
import balance_transport as balance
import check_native_sources as native_check
import dissolve_map_units as dissolve
import geographic_baseline as baseline
import geographic_embedding as geographic
import planar_embedding as embedding
import prepare_transport_sources as transport_sources
import review_layout as review
import repair_contacts as repair
import relax_layout as relax
import validate_outlines as outlines


class DissolveTests(unittest.TestCase):
    def test_country_borders_and_point_contacts_stay_separate(self):
        geometry=[box(0,0,1,1),box(1,0,2,1),box(2,0,3,1),box(2,1,3,2)]
        features=[dict(properties=dict(component_id=str(i)),geometry=mapping(p)) for i,p in enumerate(geometry)]
        summaries={str(i):dict(country_id="Y" if i==2 else "X",map_unit=str(i),name=str(i),raw_country_code="1",population=10*(i+1),source_cells=1) for i in range(4)}
        merged=dissolve.merge(features,summaries)
        self.assertEqual(len(merged),3)
        self.assertEqual(merged[0]["properties"]["original_components"],["0","1"])
        self.assertEqual(shape(merged[0]["geometry"]).area,2)
        self.assertEqual(sum(f["properties"]["population"] for f in merged),100)
        self.assertEqual(merged[1]["geometry"],features[2]["geometry"])
        self.assertEqual(merged[2]["geometry"],features[3]["geometry"])


class NativeSourceTests(unittest.TestCase):
    def test_identity_mass_and_group_parity(self):
        import pyarrow as pa
        import pyarrow.ipc as ipc
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); source=root/"source.arrow"; groups=root/"groups.csv"
            table=pa.table({"id":[123,456],"value":[30.0,70.0],"component_id":["old:a","old:b"]})
            with ipc.new_file(str(source),table.schema) as writer: writer.write_table(table)
            groups.write_text("component_id,group_id\nnew:a,new:a\nnew:b,new:a\n")
            original="id,component_id,group_id,value\nnew:a:123,new:a,new:a,30\nnew:b:456,new:b,new:a,70\n"
            (root/"sources.csv").write_text(original)
            metadata=dict(coarse_h3_resolution=8,coarse_sources=2,source_population=100,
                inputs=[dict(sha256=native_check.digest(p)) for p in [source,groups]])
            (root/"manifest.json").write_text(json.dumps(metadata))
            self.assertEqual(native_check.check(source,groups,root)["native_sources"],2)
            for old,new in [("new:a,30","new:b,30"),("new:a,70","new:a,71"),("new:b:456","new:b:123")]:
                (root/"sources.csv").write_text(original.replace(old,new))
                with self.assertRaises(ValueError): native_check.check(source,groups,root)


class BalanceTests(unittest.TestCase):
    def test_marginals_and_structural_zeros(self):
        row=np.array([0,0,1,1,2]); column=np.array([0,1,0,1,2])
        mass,iterations,error=balance.scale(row,column,[3,1,2,4,2],[6,4,2],[5,5,2])
        np.testing.assert_allclose(np.bincount(row,weights=mass),[6,4,2],rtol=1e-12)
        np.testing.assert_allclose(np.bincount(column,weights=mass),[5,5,2],rtol=1e-8)
        self.assertLessEqual(error,1e-8)
        self.assertGreater(iterations,1)
        self.assertEqual(len(mass),5)

    def test_infeasible_support_and_invalid_marginals_fail(self):
        with self.assertRaisesRegex(ValueError,"Disconnected support"):
            balance.scale([0,1],[0,1],[1,1],[1,3],[2,2],iterations=10)
        with self.assertRaisesRegex(ValueError,"did not converge"):
            balance.scale([0,0,1],[0,1,1],[1,1,1],[3,1],[1,3],iterations=2)
        self.assertAlmostEqual(balance.support_error_bound([0,1],[0,1],[1,3],[2,2]),.5)
        with self.assertRaisesRegex(ValueError,"differ"):
            balance.scale([0],[0],[1],[1],[2])
        with self.assertRaisesRegex(ValueError,"no positive support"):
            balance.scale([0],[0],[1],[1,1],[2])


class TransportSourceTests(unittest.TestCase):
    def test_native_ids_values_and_original_labels_survive_union(self):
        import pyarrow as pa
        import pyarrow.ipc as ipc
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); members=root/"members.arrow"; components=root/"components.csv"; crosswalk=root/"crosswalk.csv"
            table=pa.table(dict(id=pa.array([1,2,3,4],type=pa.uint64()),value=[10.,20.,30.,40.],component_index=[1,2,3,0]))
            with ipc.new_file(str(members),table.schema) as writer: writer.write_table(table)
            components.write_text("component_id,country_id,population,source_cells\na,A,10,1\nb,A,20,1\nc,A,30,1\n")
            crosswalk.write_text("original_component_id,component_id,country_id\na,ab,A\nb,ab,A\nc,c,A\n")
            report=transport_sources.run(members,components,crosswalk,root/"out")
            actual=ipc.open_file(str(root/"out"/"sources.arrow")).read_all().to_pydict()
            self.assertEqual(actual,dict(id=[1,2,3],value=[10.,20.,30.],component_id=["ab","ab","c"],original_component_id=["a","b","c"]))
            self.assertEqual(report["source_population"],60)
            self.assertEqual(report["unmatched_population"],40)
            with self.assertRaisesRegex(ValueError,"already exists"):
                transport_sources.run(members,components,crosswalk,root/"out")
            components.write_text(components.read_text().replace("b,A,20","b,B,20"))
            with self.assertRaisesRegex(ValueError,"different countries"):
                transport_sources.run(members,components,crosswalk,root/"bad")
            components.write_text(components.read_text().replace("b,B,20","b,A,21"))
            with self.assertRaisesRegex(ValueError,"counts or population"):
                transport_sources.run(members,components,crosswalk,root/"bad")
            self.assertFalse((root/"bad").exists())
            duplicate=table.set_column(0,"id",pa.array([1,1,3,4],type=pa.uint64()))
            with ipc.new_file(str(members),duplicate.schema) as writer: writer.write_table(duplicate)
            with self.assertRaisesRegex(ValueError,"Duplicate or null source ID"):
                transport_sources.run(members,components,crosswalk,root/"bad")


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

    def test_degree_budget_bound_is_necessary_not_sufficient(self):
        self.assertFalse(embedding.degree_conflicts([("a",str(i)) for i in range(4)],{"a":1}))
        self.assertEqual(embedding.degree_conflicts([("a",str(i)) for i in range(5)],{"a":1}),
                         [{"component_id":"a","tiles":1,"degree":5,"minimum_tiles":2}])
        self.assertFalse(embedding.degree_conflicts([("a",str(i)) for i in range(6)],{"a":2}))
        self.assertFalse(embedding.degree_conflicts([],{"a":1}))

    def test_original_dual_drawing_does_not_add_constraints(self):
        for original in [nx.path_graph(5),nx.star_graph(6),nx.cycle_graph(5),nx.complete_graph(4)]:
            original=nx.relabel_nodes(original,lambda n:f"land:{n}")
            _, prescribed=nx.check_planarity(original)
            graph,sea,drawing=embedding.augment(original,prescribed,sea_regions=False)
            before=drawing.get_data()
            positions=embedding.integer_positions(graph,{v:(i,i%3) for i,v in enumerate(graph)},drawing)
            self.assertEqual(set(graph.edges),set(original.edges))
            self.assertEqual(drawing.get_data(),before)
            self.assertFalse(sea)
            self.assertEqual(len({tuple(p) for p in positions.values()}),len(graph))

    def test_two_vertex_drawings_are_not_axis_aligned(self):
        graph=nx.Graph([("a","b")])
        for point in [(0,10),(10,0),(0,-10),(-10,0)]:
            positions=embedding.integer_positions(graph,{"a":(0,0),"b":point})
            self.assertNotEqual(positions["a"][0],positions["b"][0])
            self.assertNotEqual(positions["a"][1],positions["b"][1])

    def test_barycentric_drawing_is_planar_after_rounding(self):
        for original in [nx.path_graph(5),nx.star_graph(6),nx.wheel_graph(8),nx.complete_graph(4)]:
            original=nx.relabel_nodes(original,lambda n:f"land:{n}")
            graph,_,rotation=embedding.augment(original)
            before=rotation.get_data()
            geography={v:(i,i%3) for i,v in enumerate(graph)}
            positions=embedding.integer_positions(graph,geography,rotation,drawing="tutte")
            embedding.check_drawing(graph,positions)
            self.assertEqual(rotation.get_data(),before)
        graph=nx.Graph([("a","b"),("c","d")])
        with self.assertRaisesRegex(ValueError,"crossing"):
            embedding.check_drawing(graph,{"a":(0,0),"b":(2,2),"c":(0,2),"d":(2,0)})

    def test_fixed_drawing_transforms_are_rigid(self):
        graph=nx.Graph([("a","b"),("b","c"),("c","a")])
        geography={"a":(0,0),"b":(2,0),"c":(1,1)}
        distances=[]
        for transform in range(8):
            positions=embedding.integer_positions(graph,geography,transform=transform)
            distances.append([sum((a-b)**2 for a,b in zip(positions[u],positions[v])) for u,v in graph.edges])
        self.assertTrue(all(d==distances[0] for d in distances))
        with self.assertRaises(ValueError):
            embedding.integer_positions(graph,geography,transform=8)

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


class RelaxTests(unittest.TestCase):
    def test_translation_preserves_shapes_and_reduces_energy(self):
        tiles={"a":{(x,y) for x in range(2) for y in range(2)},
               "b":{(x+10,y) for x in range(2) for y in range(2)},"c":{(5,3)}}
        moved,metadata=relax.relax(tiles,{("a","b")},rounds=30,stiffness=.01)
        self.assertLess(metadata["final_energy"],metadata["initial_energy"])
        self.assertGreater(metadata["moves"],0)
        self.assertEqual(moved["c"],tiles["c"])
        for c,points in moved.items():
            dx=min(x for x,y in points)-min(x for x,y in tiles[c])
            dy=min(y for x,y in points)-min(y for x,y in tiles[c])
            self.assertEqual(points,{(x+dx,y+dy) for x,y in tiles[c]})
        checked=repair.Repair(moved,{("a","b")})
        self.assertEqual(set(checked.contacts),{("a","b")})
        self.assertEqual(relax.relax(tiles,{("a","b")},rounds=30,stiffness=.01)[0],moved)


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

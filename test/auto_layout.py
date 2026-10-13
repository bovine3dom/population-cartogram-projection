"""Run with stdlib Python; adapter checks require bootstrap.sh first."""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "examples" / "auto-cartogram"
spec = importlib.util.spec_from_file_location("review_layout", EXAMPLE / "review_layout.py")
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)
VENDOR = ROOT / "output" / "auto-cartogram" / "vendor"


class ReviewTests(unittest.TestCase):
    def test_connectivity_uses_shared_edges(self):
        self.assertEqual(review.connectivity({(0, 0), (1, 0), (1, 1)}), 1)
        self.assertEqual(review.connectivity({(0, 0), (1, 1)}), 2)
        self.assertEqual(review.quality({(0, 0)})["perimeter"], 4)

    def test_review_reports_uniform_tile_capacity_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp:
            inputs,layout=Path(tmp)/"input",Path(tmp)/"layout"
            inputs.mkdir(); layout.mkdir()
            (inputs/"groups.csv").write_text("component_id,tiles,country_id,name,group_population,west,east,south,north\n"
                "a,4,XX,A,60,0,1,0,1\nb,2,XX,B,40,4,5,0,1\n")
            (inputs/"manifest.json").write_text(json.dumps(dict(tile_budget=6,population_total=100,
                represented_population=100,grouped_population=0,omitted_population=0,
                holes_not_encoded_in_wkt=0,policy="group")))
            (inputs/"geographic-contacts.csv").write_text("a,b,both_represented\n")
            (layout/"complete.txt").write_text("mode=test\n")
            (layout/"cells.csv").write_text("component_id,x,y\na,0,0\na,1,0\na,0,1\na,1,1\nb,4,0\nb,4,1\n")
            metrics=review.run(inputs,layout,"Test")
            self.assertTrue(metrics["passes_represented_constraints"])
            self.assertAlmostEqual(metrics["country_uniform_tile_cross_group_lower_bound"],100/15)
            self.assertEqual(metrics["island_axis_order_errors"],0)

    def test_unknown_duplicate_and_missing_owners(self):
        with tempfile.TemporaryDirectory() as tmp:
            inputs, layout = Path(tmp)/"input", Path(tmp)/"layout"
            inputs.mkdir(); layout.mkdir()
            (inputs/"groups.csv").write_text("component_id,tiles\na,1\nb,1\n")
            (layout/"complete.txt").write_text("mode=topology\n")
            for rows in ["a,0,0\nb,0,0\n", "a,0,0\nx,1,0\n", "a,0,0\n"]:
                (layout/"cells.csv").write_text("component_id,x,y\n"+rows)
                with self.assertRaises(ValueError):
                    review.load(inputs, layout)


@unittest.skipUnless((VENDOR/"java-path.txt").exists(), "run bootstrap.sh for Java integration checks")
class AdapterTests(unittest.TestCase):
    def command(self, inputs, weights, output, mode="topology", placement="agnostic"):
        java = (VENDOR/"java-path.txt").read_text().strip()
        return [java,"-ea","-Xmx2g","-Djava.awt.headless=true","-cp",str(VENDOR/"classes"),
                "MosaicAdapter",str(inputs),str(weights),str(output),mode,placement]

    def fixture(self, directory, adjacent=False):
        x = 1 if adjacent else 3
        inputs, weights = directory/"input.wkt", directory/"weights.tsv"
        inputs.write_text("STAGE 1\nOUTLINES 2\nOUT 0\ta\t0.5 0.5\t20 40 60\n"
                          "0 0\t1 0\t1 1\t0 1\nSITECOUNT 0\n"
                          f"OUT 1\tb\t{x+.5} 0.5\t60 40 20\n"
                          f"{x} 0\t{x+1} 0\t{x+1} 1\t{x} 1\nSITECOUNT 0\n")
        weights.write_text("a\t9\nb\t3\n")
        return inputs, weights

    def test_exact_counts_unique_cells_and_deterministic_placement(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            inputs, weights = self.fixture(directory)
            for placement in ["agnostic", "directional"]:
                results = []
                for attempt in [1, 2]:
                    output = directory/f"{placement}-{attempt}"
                    subprocess.run(self.command(inputs, weights, output, placement=placement), check=True,
                                   capture_output=True, text=True, timeout=30)
                    cells = review.read_csv(output/"cells.csv")
                    self.assertEqual(len(cells), 12)
                    self.assertEqual(len({(r["x"],r["y"]) for r in cells}), 12)
                    counts = {r["component_id"]:int(r["actual"]) for r in review.read_csv(output/"counts.csv")}
                    self.assertEqual(counts, {"a":9,"b":3})
                    self.assertTrue((output/"complete.txt").exists())
                    results.append(sorted((r["component_id"],r["x"],r["y"]) for r in cells))
                self.assertEqual(*results)

    def test_refuses_invalid_weights_and_existing_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            inputs, weights = self.fixture(directory)
            for text in ["a\t0\nb\t3\n", "a\t9\na\t3\n", "a\t9\nx\t3\n"]:
                weights.write_text(text)
                output = directory/"failed"
                result = subprocess.run(self.command(inputs,weights,output),capture_output=True,timeout=30)
                self.assertNotEqual(result.returncode,0)
                self.assertFalse(output.exists())
            weights.write_text("a\t9\nb\t3\n")
            result = subprocess.run(self.command(inputs,weights,directory),capture_output=True,timeout=30)
            self.assertNotEqual(result.returncode,0)

    def test_local_moves_against_independent_flood_fill(self):
        java = Path((VENDOR/"java-path.txt").read_text().strip())
        with tempfile.TemporaryDirectory() as tmp:
            subprocess.run([str(java.with_name("javac")), "-cp", str(VENDOR/"classes"),
                            "-d", tmp, str(ROOT/"test"/"MosaicConnectivity.java")], check=True, timeout=30)
            subprocess.run([str(java), "-ea", "-cp", f"{VENDOR/'classes'}:{tmp}",
                            "MosaicConnectivity"], check=True, timeout=30)

    def test_native_graph_layout_retains_a_shared_border(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            inputs, weights = self.fixture(directory,adjacent=True)
            output = directory/"adjacent"
            subprocess.run(self.command(inputs,weights,output),check=True,capture_output=True,timeout=60)
            cells = {(int(r["x"]),int(r["y"])):r["component_id"] for r in review.read_csv(output/"cells.csv")}
            self.assertTrue(any(cells.get((x+dx,y+dy),owner) != owner
                                for (x,y),owner in cells.items() for dx,dy in review.NEIGHBOURS))


if __name__ == "__main__":
    unittest.main()

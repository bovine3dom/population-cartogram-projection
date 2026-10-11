import csv
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


class SharedBordersTest(unittest.TestCase):
    def test_segment_not_point_and_no_overwrite(self):
        script = Path(__file__).resolve().parents[1] / "examples/continuity/shared_borders.py"
        rings = [[(0, 0), (1, 0), (1, 1), (0, 1), (0, 0)],
                 [(1, 0), (2, 0), (2, 1), (1, 1), (1, 0)],
                 [(1, 1), (2, 2), (0, 2), (1, 1)]]
        features = [{"properties": {"ISO_N3_EH": str(code)},
                     "geometry": {"type": "Polygon", "coordinates": [ring]}}
                    for code, ring in enumerate(rings, 1)]
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "source.json", Path(directory) / "pairs.csv"
            source.write_text(json.dumps({"features": features}))
            command = [sys.executable, str(script), str(source), str(output), "1", "2", "3"]
            subprocess.run(command, check=True, capture_output=True)
            with output.open() as stream:
                self.assertEqual(list(csv.DictReader(stream)),
                                 [{"country_a": "1", "country_b": "2", "shared_segments": "1"}])
            before = output.read_bytes()
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            self.assertEqual(output.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()

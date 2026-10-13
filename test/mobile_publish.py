import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("mobile_publish", Path(__file__).parents[1] / "examples/continuity/mobile/publish.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationTest(unittest.TestCase):
    def test_staging_and_hash_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            candidate, reference, destination = [root / name for name in ("candidate", "reference", "public")]
            candidate.mkdir(); reference.mkdir()
            for name in (publisher.TRANSPORT, publisher.DENSITY, "query-errors.csv", "provenance.csv", "shared-cell-owners.csv", "countries.csv"):
                (candidate / name).write_bytes(name.encode())
            for name in (publisher.TRANSPORT, "baseline-seams.csv", "candidate-seams.csv", "candidate-orientation.csv", "contacts.csv",
                         "countries.csv", "fit-config.csv", "metrics.csv", "provenance.txt", "compact.md", "README.md"):
                (reference / name).write_bytes(name.encode())
            (reference / "settings.csv").write_text("outer_steps\n4\n")
            input_hash = hashlib.sha256(b"input").hexdigest()
            (candidate / "export.toml").write_text(f'rows = 6\ninput_sha256 = "{input_hash}"\n')
            audit = root / "audit.toml"
            queries = root / "audit.queries.csv"
            queries.write_text("field,targets,lost,absolute_max\nhalf_missing_log_density,2,1,0.1\n")
            audit.write_text(f'query_report_sha256 = "{publisher.digest(queries)}"\n'
                             'rows = 6\nsources = 3\ntargets = 2\nlabels = 1\nrequested_target_retained = 0.7\n'
                             'target_tv_max = 0.25\ngeographic_error_km_max = 0.0001\n[sha256]\n' +
                             f'input = "{input_hash}"\n' + ''.join(f'{key} = "{publisher.digest(path)}"\n' for key, path in
                             (("transport", candidate / publisher.TRANSPORT), ("density", candidate / publisher.DENSITY),
                              ("reference", reference / publisher.TRANSPORT))))
            publisher.publish(candidate, audit, reference, destination)
            hashes = json.loads((destination / "sha256.json").read_text())
            self.assertEqual(hashes[publisher.TRANSPORT], publisher.digest(candidate / publisher.TRANSPORT))
            self.assertIn("4 passes", (destination / "README.md").read_text())
            self.assertIn("loses values at 1 of 2 targets", (destination / "README.md").read_text())
            self.assertEqual(json.loads((destination / "population_density_hilo.json").read_text())["cartogram"],
                             f"public/{publisher.TRANSPORT}")
            self.assertTrue(json.loads((destination / "population_density_hilo.json").read_text())["viewportGeometry"])
            self.assertEqual((destination / "query-errors.csv").read_bytes(), queries.read_bytes())
            self.assertFalse((root / "public.pending").exists())
            with self.assertRaises(ValueError):
                publisher.publish(candidate, audit, reference, destination)
            with patch.object(publisher, "MAX_ARROW_BYTES", 1):
                with self.assertRaisesRegex(ValueError, "exceed 100 MB"):
                    publisher.publish(candidate, audit, reference, root / "over-budget")
            self.assertFalse((root / "over-budget.pending").exists())
            (candidate / publisher.TRANSPORT).write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                publisher.publish(candidate, audit, reference, root / "rejected")
            self.assertFalse((root / "rejected").exists())
            self.assertFalse((root / "rejected.pending").exists())


if __name__ == "__main__":
    unittest.main()

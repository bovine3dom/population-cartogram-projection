import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("publisher", Path(__file__).resolve().parents[1] / "examples/continuity/publish_native.py")
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


def write_toml(path, values):
    path.write_text("\n".join(f"{k} = {json.dumps(v)}" for k, v in values.items()) + "\n")


class Publication(unittest.TestCase):
    def fixture(self, root):
        raw, packed, quality, destination = [root / n for n in ("raw", "stream", "quality", "published")]
        for p in (raw, packed, quality):
            p.mkdir()
        audit = dict(parts_sha256="parts", factor=2, resolution=6, countries=206, sources=10,
                     physical_targets=20, rows=30, population=1000, labelled_sources=2, model="Test model")
        for kind, name in publisher.FILES.items():
            (raw / name).write_bytes(b"original")
            (packed / name).write_bytes(b"stream")
            original, final = publisher.digest(raw / name), publisher.digest(packed / name)
            audit[f"{kind}_sha256"] = original
            write_toml(packed / f"{kind}-verified.toml", dict(all_columns_equal=True, reader="Arrow.Stream",
                       reference_sha256=original, stream_sha256=final, stream_bytes=6))
            (packed / Path(name).with_suffix(".packing.json")).write_text(json.dumps(dict(input_sha256=original, output_sha256=final)))
        write_toml(raw / "audit.toml", audit)
        write_toml(raw / "fit-input.toml", dict(model="Test model"))
        for name in ("fit-countries.csv", "country-mass.csv"):
            (raw / name).write_text("code\n24\n")
        write_toml(quality / "geometry.toml", dict(parts_sha256="parts", factor=2, ratio995=2., capacity_lower995=1., low_population_ratio995=1.5))
        return raw, packed, quality, destination

    def test_publish_and_refuse_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            args = self.fixture(Path(d))
            self.assertEqual(publisher.publish(*args), 12)
            metadata = json.loads((args[-1] / "population_density_hilo.json").read_text())
            self.assertNotIn("viewportGeometry", metadata)
            self.assertEqual(metadata["trimFactor"], 0)
            self.assertTrue(metadata["cartogramLineProbe"])
            audit = json.loads((args[-1] / "audit.json").read_text())
            self.assertEqual(audit["transport_bytes"], 6)
            self.assertEqual(audit["transport_sha256"], publisher.digest(args[-1] / publisher.FILES["transport"]))
            with self.assertRaises(ValueError):
                publisher.publish(*args)

    def test_tampered_stream(self):
        with tempfile.TemporaryDirectory() as d:
            args = self.fixture(Path(d))
            (args[1] / publisher.FILES["transport"]).write_bytes(b"changed")
            with self.assertRaises(ValueError):
                publisher.publish(*args)
            self.assertFalse(args[-1].exists())

    def test_packing_needs_binary_audit(self):
        with tempfile.TemporaryDirectory() as d:
            args = self.fixture(Path(d))
            write_toml(args[0] / "fit-input.toml", dict(target_retained=.99))
            with self.assertRaises(ValueError):
                publisher.publish(*args)


if __name__ == "__main__":
    unittest.main()

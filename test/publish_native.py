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
        raw, quality, destination = [root / n for n in ("raw", "quality", "published")]
        for p in (raw, quality):
            p.mkdir()
        audit = dict(parts_sha256="parts", factor=2, resolution=6, countries=206, sources=10,
                     physical_targets=20, rows=30, population=1000, labelled_sources=2, model="Test model")
        for kind, name in publisher.FILES.items():
            path = raw / name
            path.write_bytes(b"ARROW1dataARROW1")
            audit[f"{kind}_sha256"] = publisher.digest(path)
            audit[f"{kind}_bytes"] = path.stat().st_size
        write_toml(raw / "audit.toml", audit)
        write_toml(raw / "fit-input.toml", dict(model="Test model"))
        for name in ("fit-countries.csv", "country-mass.csv"):
            (raw / name).write_text("code\n24\n")
        write_toml(quality / "geometry.toml", dict(parts_sha256="parts", factor=2, ratio995=2., low_population_ratio995=1.5))
        return raw, quality, destination

    def test_publish_and_refuse_overwrite(self):
        with tempfile.TemporaryDirectory() as d:
            args = self.fixture(Path(d))
            self.assertEqual(publisher.publish(*args), 32)
            metadata = json.loads((args[-1] / "population_density_hilo.json").read_text())
            self.assertNotIn("viewportGeometry", metadata)
            self.assertEqual(metadata["trimFactor"], 0)
            self.assertTrue(metadata["cartogramLineProbe"])
            audit = json.loads((args[-1] / "audit.json").read_text())
            self.assertEqual(audit["encoding"], "Arrow IPC file")
            self.assertEqual(audit["transport_sha256"], publisher.digest(args[-1] / publisher.FILES["transport"]))
            with self.assertRaises(ValueError):
                publisher.publish(*args)

    def test_reject_invalid_inputs(self):
        for failure in ("hash", "stream", "footer", "reduction", "geometry"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as d:
                args = self.fixture(Path(d))
                raw, quality, destination = args
                if failure in ("hash", "stream", "footer"):
                    content = {"hash": b"ARROW1editARROW1", "stream": b"stream", "footer": b"ARROW1dataBROKEN"}[failure]
                    path = raw / publisher.FILES["transport"]
                    path.write_bytes(content)
                    if failure != "hash":
                        audit = publisher.toml(raw / "audit.toml")
                        audit.update(transport_sha256=publisher.digest(path), transport_bytes=path.stat().st_size)
                        write_toml(raw / "audit.toml", audit)
                elif failure == "reduction":
                    write_toml(raw / "fit-input.toml", dict(target_retained=.99))
                else:
                    write_toml(quality / "geometry.toml", dict(parts_sha256="other", factor=2))
                with self.assertRaises(ValueError):
                    publisher.publish(*args)
                self.assertFalse(destination.exists())
                self.assertFalse(destination.with_name(destination.name + ".pending").exists())


if __name__ == "__main__":
    unittest.main()

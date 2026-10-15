import importlib.util
from pathlib import Path
import tempfile
import unittest

import pyarrow as pa

path = Path(__file__).resolve().parents[1] / "examples/continuity/mobile/pack_stream.py"
spec = importlib.util.spec_from_file_location("pack_stream", path)
packing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packing)


class StreamPacking(unittest.TestCase):
    def check_roundtrip(self, table, root):
        source, output, repeat = [Path(root) / name for name in ("input.arrow", "output.arrow", "repeat.arrow")]
        with pa.OSFile(str(source), "wb") as sink, pa.ipc.new_file(sink, table.schema) as writer:
            writer.write_table(table)
        report = packing.pack(source, output)
        self.assertEqual(report["rows"], table.num_rows)
        self.assertGreater(report["batches"], 1)
        self.assertIsNone(report["compression"])
        with pa.memory_map(str(output), "r") as memory:
            actual = pa.ipc.open_stream(memory).read_all()
        self.assertEqual(actual.schema.metadata, table.schema.metadata)
        for name in table.schema.names:
            self.assertTrue(packing.decoded(actual[name]).equals(packing.decoded(table[name])))
        # Repacking must also work across replacement-dictionary boundaries.
        self.assertEqual(packing.pack(output, repeat)["rows"], table.num_rows)
        with self.assertRaises(ValueError):
            packing.pack(source, output)

    def test_transport(self):
        n = 400
        table = pa.table({
            "x": pa.array(range(n), type=pa.int16()),
            "y": pa.array(range(n, 0, -1), type=pa.int16()),
            "code": pa.array([i % 206 for i in range(n)], type=pa.uint16()),
            "population": pa.array([i + .5 for i in range(n)], type=pa.float64()),
            "weight": pa.array([.5] * n, type=pa.float32()),
            "weight_mean": pa.array([.25] * n, type=pa.float32()),
            "label": pa.array([None if i % 3 else f"City {i}" for i in range(n)]),
            "index_lower": pa.array([2**32 - i - 1 for i in range(n)], type=pa.uint32()),
            "index_upper": pa.array(range(n), type=pa.uint32()),
        }).replace_schema_metadata({b"test": b"preserved"})
        with tempfile.TemporaryDirectory() as root:
            self.check_roundtrip(table, root)

    def test_density(self):
        n = 70000
        table = pa.table({
            "index_lower": pa.array([i % 28 for i in range(n)], type=pa.uint32()),
            "index_upper": pa.array(range(n), type=pa.uint32()),
            "value": pa.array([i / 13 for i in range(n)], type=pa.float32()),
        })
        with tempfile.TemporaryDirectory() as root:
            self.check_roundtrip(table, root)


if __name__ == "__main__":
    unittest.main()

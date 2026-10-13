"""Independent transport export checks. Run with Python's standard library."""
import csv
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"examples"/"auto-cartogram"))
import check_transport as audit


class TransportTests(unittest.TestCase):
    def fixture(self, root):
        tables={
            "sources.csv": [["id","group_id","value"],["a","A",30],["b","B",70]],
            "targets.csv": [["x","y","group_id"],[0,0,"A"],[1,0,"B"]],
            "mapping.csv": [["id","x","y","weight"],["a",0,0,1],["b",1,0,1]],
            "target-quality.csv": [["x","y","group_id","population","expected_population","relative_error"],
                                   [0,0,"A",30,30,0],[1,0,"B",70,70,0]]}
        for name,table in tables.items():
            with (root/name).open("w") as stream: csv.writer(stream).writerows(table)
        metadata=dict(pooled=False,source_population=100,retained_population=100,retained_share=1,
            cross_group_population=0,minimum_source_retained_share=1,maximum_source_retained_share=1,
            maximum_relative_target_error=0,coarse_sources=2,targets=2,groups=2)
        (root/"manifest.json").write_text(json.dumps(metadata))

    def test_valid_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); self.fixture(root)
            result=audit.check(root)
            self.assertTrue(result["checked"])
            self.assertEqual(result["mapping_rows"],2)
            self.assertEqual(result["source_rows_below_99_5_percent"],0)

    def test_reject_corrupt_exports(self):
        for name,old,new in [
            ("mapping.csv","a,0,0,1","a,1,0,1"),
            ("mapping.csv","a,0,0,1","a,0,0,nan"),
            ("mapping.csv","a,0,0,1","a,0,0,-1"),
            ("mapping.csv","a,0,0,1","a,0,0,1\na,0,0,1"),
            ("mapping.csv","a,0,0,1","a,0,0,0.5"),
            ("mapping.csv","a,0,0,1","unknown,0,0,1"),
            ("mapping.csv","a,0,0,1","a,2,0,1"),
            ("sources.csv","b,B,70","a,B,70"),
            ("targets.csv","1,0,B","0,0,B"),
            ("target-quality.csv","30,30,0","31,30,0")]:
            with self.subTest(name=name,new=new), tempfile.TemporaryDirectory() as tmp:
                root=Path(tmp); self.fixture(root)
                path=root/name; path.write_text(path.read_text().replace(old,new))
                with self.assertRaises(ValueError): audit.check(root)


if __name__ == "__main__": unittest.main()

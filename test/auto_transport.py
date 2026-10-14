"""Independent transport export checks. Run with Python's standard library."""
import csv
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"examples"/"auto-cartogram"))
import check_transport as audit
import review_balance as picture
import check_transport_shift as shift


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
        metadata=dict(coarse_h3_resolution=8,pooled=False,source_population=100,retained_population=100,retained_share=1,
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

    def test_balance_figure_checks_files_and_support(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); raw=root/"raw"; raw.mkdir(); self.fixture(raw)
            corrected=root/"corrected"; shutil.copytree(raw,corrected)
            for d in [raw,corrected]: (d/"independent-checks.json").write_text(json.dumps(audit.check(d)))
            picture.run(raw,corrected,root/"picture")
            self.assertTrue(json.loads((root/"picture/checks.json").read_text())["ordered_support_unchanged"])
            self.assertEqual(shift.compare(raw,corrected)["summary"]["maximum_shift"],0)
            self.assertEqual(picture.color(0,.075),"#fafafa")
            self.assertEqual(picture.color(1,.075),picture.color(.075,.075))
            path=corrected/"mapping.csv"; lines=path.read_text().splitlines()
            path.write_text("\n".join([lines[0],lines[2],lines[1]])+"\n")
            with self.assertRaisesRegex(ValueError,"Files differ"):
                picture.run(raw,corrected,root/"invalid")
            with self.assertRaisesRegex(ValueError,"Files differ"):
                shift.compare(raw,corrected)
            (corrected/"independent-checks.json").write_text(json.dumps(audit.check(corrected)))
            with self.assertRaisesRegex(ValueError,"support differs"):
                picture.run(raw,corrected,root/"invalid")
            with self.assertRaisesRegex(ValueError,"support differs"):
                shift.compare(raw,corrected)

    def test_expected_position_change_normalizes_retained_weights(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            for name,weights in [("raw",(.4,.1)),("corrected",(.5,.5))]:
                d=root/name; d.mkdir()
                (d/"sources.csv").write_text("id,group_id,value\na,ALL,100\n")
                (d/"targets.csv").write_text("x,y,group_id\n0,0,ALL\n2,0,ALL\n")
                (d/"mapping.csv").write_text("id,x,y,weight\n"+"".join(f"a,{x},0,{w}\n" for x,w in zip((0,2),weights)))
                (d/"target-quality.csv").write_text("x,y,group_id,population,expected_population,relative_error\n"+
                    "".join(f"{x},0,ALL,{100*w},50,{2*w-1}\n" for x,w in zip((0,2),weights)))
                metadata=dict(pooled=False,source_population=100,retained_population=100*sum(weights),retained_share=sum(weights),
                    cross_group_population=0,minimum_source_retained_share=sum(weights),maximum_source_retained_share=sum(weights),
                    maximum_relative_target_error=max(abs(2*w-1) for w in weights),coarse_sources=1,targets=2,groups=1)
                (d/"manifest.json").write_text(json.dumps(metadata))
                (d/"independent-checks.json").write_text(json.dumps(audit.check(d)))
            result=shift.compare(root/"raw",root/"corrected")
            self.assertAlmostEqual(result["summary"]["population_weighted_mean_shift"],.6)
            self.assertAlmostEqual(result["summary"]["population_weighted_rms_shift"],.6)
            self.assertEqual(result["summary"]["source_cells"],1)
            self.assertEqual(result["groups"]["ALL"]["source_cells"],1)
            self.assertAlmostEqual(result["absolute_pair_mass_change"],50)

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

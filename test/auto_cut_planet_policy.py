import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from run_kontur_planet import run
from save_review import digest


class CutPlanetPolicyTest(unittest.TestCase):
    def test_verified_hashes_do_not_allow_a_required_cut(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contacts = root/'geographic-contacts.csv'
            contacts.write_text('a,b,both_represented\nA,B,true\n')
            guide = root/'guide.geojson'
            guide.write_text('{}\n')
            record = root/'record.json'
            record.write_text(json.dumps(dict(geometry_sha256=digest(guide),cuts=[['A','B']],inputs={str(contacts):digest(contacts)})))
            with self.assertRaisesRegex(ValueError,'still requires a selected cut'):
                run(root/'output',guide=guide,guide_record=record,inputs=root)
            self.assertFalse((root/'output').exists())

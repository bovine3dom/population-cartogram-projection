import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from transport_moved_lakes import run
from save_review import digest
from review_layout import read_csv


class MovedLakeTest(unittest.TestCase):
    def fixture(self, root, blocked=False):
        inputs=root/'inputs';inputs.mkdir()
        (inputs/'groups.csv').write_text('component_id,tiles\na,8\n')
        reference=root/'reference';layout=root/'layout'
        for directory,dx in [(reference,0),(layout,5)]:
            directory.mkdir();(directory/'complete.txt').write_text('test\n')
            points={(x+dx,y) for x in range(3) for y in range(3)}-{(1+dx,1)}
            if blocked and dx:points.remove((dx,0));points.add((dx+1,1))
            with (directory/'cells.csv').open('w',newline='') as stream:
                writer=csv.writer(stream);writer.writerow(['component_id','x','y'])
                writer.writerows(('a',x,y) for x,y in sorted(points))
        (reference/'lake-cells.csv').write_text('lake_id,name,x,y\nl,Lake,1,1\n')
        (reference/'lake-placement.json').write_text(json.dumps(dict(lakes=[dict(lake_id='l',name='Lake',accepted=True,required_shores=['a'],allowed_shores=['a'])])))
        separation=root/'moves.json'
        separation.write_text(json.dumps(dict(inputs={str(reference/'cells.csv'):digest(reference/'cells.csv')},moves=[dict(component='a',dx=5,dy=0)])))
        return inputs,layout,reference,separation

    def test_empty_lake_moves_without_land_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);args=self.fixture(root);output=root/'result'
            run(*args,output)
            self.assertEqual((output/'cells.csv').read_bytes(),(args[1]/'cells.csv').read_bytes())
            self.assertEqual([(r['x'],r['y']) for r in read_csv(output/'lake-cells.csv')],[('6','1')])

    def test_occupied_destination_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            with self.assertRaisesRegex(ValueError,'overlaps'):
                run(*self.fixture(root,blocked=True),root/'result')


if __name__=='__main__':
    unittest.main()

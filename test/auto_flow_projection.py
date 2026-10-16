import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np
from shapely.geometry import Polygon, mapping, shape

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from prepare_flow import equal_earth, mercator, run


class FlowProjectionTest(unittest.TestCase):
    def fixture(self, root):
        source = Polygon([(10, 50), (20, 50), (20, 60), (10, 60)],
                         holes=[[(12, 52), (12, 54), (14, 54), (14, 52)]])
        (root/'groups.csv').write_text('component_id,country_id,name,tiles\na,A,Test,17\nb,B,Other,9\n')
        (root/'manifest.json').write_text('{}')
        (root/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\n')
        polygons = root/'polygons.json'
        polygons.write_text(json.dumps(dict(features=[dict(properties=dict(component_id=c), geometry=mapping(source)) for c in ['a', 'b']])))
        return polygons, source

    def test_default_is_unchanged_equal_earth(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            polygons, source = self.fixture(root)
            run(root, polygons, root/'default')
            run(root, polygons, root/'explicit', projection='equal-earth')
            self.assertEqual((root/'default/geometry.geojson').read_bytes(), (root/'explicit/geometry.geojson').read_bytes())
            geometry = json.loads((root/'default/geometry.geojson').read_text())['features'][0]['geometry']
            np.testing.assert_allclose(geometry['coordinates'][0], equal_earth(np.array(source.exterior.coords)))

    def test_mercator_changes_only_geometry_not_budgets_or_holes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            polygons, source = self.fixture(root)
            earth = run(root, polygons, root/'earth', mainland_only=True)
            merc = run(root, polygons, root/'merc', mainland_only=True, projection='mercator')
            self.assertEqual((root/'earth/areas.csv').read_bytes(), (root/'merc/areas.csv').read_bytes())
            self.assertEqual(earth['tiles'], merc['tiles'])
            self.assertEqual(earth['holes'], merc['holes'])
            self.assertEqual(merc['holes'], 2)
            geometry = json.loads((root/'merc/geometry.geojson').read_text())['features'][0]['geometry']
            np.testing.assert_allclose(geometry['coordinates'][0], mercator(np.array(source.exterior.coords)))
            self.assertEqual(len(shape(geometry).interiors), 1)
            self.assertNotEqual((root/'earth/geometry.geojson').read_bytes(), (root/'merc/geometry.geojson').read_bytes())

    def test_mainland_selection_is_unchanged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            polygons, _ = self.fixture(root)
            with (root/'groups.csv').open('a') as stream:
                stream.write('island,I,Island,1\n')
            for projection in ['equal-earth', 'mercator']:
                report = run(root, polygons, root/projection, mainland_only=True, projection=projection)
                self.assertEqual(report['excluded_isolated_components'], ['island'])
                self.assertEqual(report['tiles'], 26)
                self.assertEqual(report['components'], 2)


if __name__ == '__main__':
    unittest.main()

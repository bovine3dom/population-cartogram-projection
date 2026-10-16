import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from shapely.geometry import box, mapping

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from fit_mercator_shapes import border_energy, inverse_equal_earth, pack, population_centres, run, select
from prepare_flow import equal_earth
from review_layout import read_csv
from save_review import digest


def row(country, x=0, y=0, tiles=8):
    return dict(country_id=country, group_population=100., tiles=tiles, west=x, east=x, south=y, north=y)


class MercatorFitTest(unittest.TestCase):
    def test_inverse_projection_roundtrip(self):
        points = np.array([[-179, -80], [0, 0], [90, 60], [179, 85], [30, -20]])
        np.testing.assert_allclose(inverse_equal_earth(equal_earth(points)/1000), points, atol=1e-10)

    def test_border_gradient(self):
        delta = np.array([[2., -3.], [40., 12.]])
        weights = np.array([.5, 3.])
        for release in [0., 8.]:
            _, gradient = border_energy(delta, weights, release)
            for i in range(delta.size):
                plus, minus = delta.copy(), delta.copy()
                plus.flat[i] += 1e-5
                minus.flat[i] -= 1e-5
                numerical = (border_energy(plus, weights, release)[0]-border_energy(minus, weights, release)[0])/2e-5
                self.assertAlmostEqual(gradient.flat[i], numerical, places=6)

    def test_released_border_force_decays(self):
        force = lambda d: border_energy(np.array([[d, 0.]]), np.ones(1), 8)[1][0, 0]
        self.assertGreater(force(8), force(80))

    def test_selection_keeps_primary_components(self):
        rows = {'a': row('A'), 'island': row('A', tiles=1), 'b': row('B'), 'c': row('C')}
        edges = {('a', 'b'), ('b', 'c'), ('a', 'island')}
        self.assertEqual(select(rows, edges, ['A'], 1), {'a', 'b'})
        self.assertEqual(select(rows, edges, ['A'], 2), {'a', 'b', 'c'})

    def test_packing_preserves_shapes_and_axis_order(self):
        tiles = {'a': {(0, 0), (1, 0)}, 'b': {(0, 0), (0, 1)}}
        rows = {'a': row('A'), 'b': row('B', 10, 10)}
        result = pack(tiles, {'a': np.array([0., 0.]), 'b': np.array([-5., -5.])}, rows, set())
        self.assertFalse(result['a'] & result['b'])
        self.assertTrue(np.all(np.mean(sorted(result['b']), axis=0) > np.mean(sorted(result['a']), axis=0)))
        for c in tiles:
            shift = np.array(min(result[c]))-np.array(min(tiles[c]))
            self.assertEqual(result[c], {tuple(np.array(p)+shift) for p in tiles[c]})

    def test_population_centres_and_budget_guard(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'sources.csv'
            projected = equal_earth(np.array([[10., 30.], [20., 40.]]))/1000
            with path.open('w') as stream:
                writer = csv.writer(stream)
                writer.writerow(['group_id', 'value', 'x', 'y'])
                writer.writerows([('a', 75, *projected[0]), ('a', 25, *projected[1])])
            centres, rows = population_centres(path, {'a': row('A')})
            self.assertTrue(np.isfinite(centres['a']).all())
            self.assertAlmostEqual(rows['a']['west'], 12.5)
            self.assertAlmostEqual(rows['a']['north'], 32.5)
            with self.assertRaises(ValueError):
                population_centres(path, {'a': dict(row('A'), group_population=101.)})

    def test_small_fit_exports_exact_templates(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            rows = {'a': row('A', 0, 0), 'b': row('B', 10, 10), 'c': row('C', 20, 0)}
            with (root/'groups.csv').open('w') as stream:
                writer = csv.DictWriter(stream, fieldnames=['component_id', *rows['a']])
                writer.writeheader()
                writer.writerows(dict(r, component_id=c) for c, r in rows.items())
            (root/'geographic-contacts.csv').write_text('a,b,both_represented\na,b,true\nb,c,true\n')
            polygons = root/'polygons.json'
            polygons.write_text(json.dumps(dict(features=[dict(properties=dict(component_id=c), geometry=mapping(box(i, int(i == 1), i+1, 1+int(i == 1)))) for i, c in enumerate(rows)])))
            audit = root/'audit.json'
            audit.write_text(json.dumps(dict(inputs={str(root/n): digest(root/n) for n in ['groups.csv', 'geographic-contacts.csv']},
                borders=[dict(a=a, b=b, corridor_population=1000, eligible=True) for a, b in [('a', 'b'), ('b', 'c')]])))
            output = root/'fit'
            with patch('fit_mercator_shapes.draw'):
                result = run(root, polygons, audit, output, countries=['A', 'B', 'C'], neighbours=0, iterations=50)
            self.assertEqual(result['tiles'], 24)
            self.assertEqual(len(read_csv(output/'cells.csv')), 24)
            self.assertEqual(len(read_csv(output/'templates.csv')), 24)
            self.assertTrue((output/'fit.json').exists())


if __name__ == '__main__':
    unittest.main()

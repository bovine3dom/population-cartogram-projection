"""Test bounded recovery control. Julia validates the numerical checkpoints."""
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'examples/auto-cartogram'))
from resume_h3_borders import recover, warm_stage


class BorderResumeTests(unittest.TestCase):
    def test_numeric_temperature_order(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self.assertIsNone(warm_stage(root))
            for factor in (256, 16, 2):
                (root/f'stage-{factor}.0.jls').touch()
            self.assertEqual(warm_stage(root).name, 'stage-2.0.jls')

    def test_checked_resume_then_promotion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); fit = root/'fit'; out = root/'recovery'
            fit.mkdir(); calls = []
            def run(command, **kwargs):
                calls.append(command)
                if any(str(p).endswith('promote_h3_recovery.jl') for p in command):
                    dest = Path(command[-1]); dest.mkdir()
                    (dest/'research-fit-complete.txt').touch()
                else:
                    i = next(i for i, p in enumerate(command) if str(p).endswith('recover_h3_borders.jl'))
                    trial = Path(command[i+2]); trial.mkdir()
                    if len(calls) == 1:
                        (trial/'stage-2.0.jls').touch()
                        return subprocess.CompletedProcess(command, 124)
                    self.assertEqual(Path(command[-1]).name, 'stage-2.0.jls')
                    (trial/'accepted.jls').touch()
                return subprocess.CompletedProcess(command, 0)
            with patch('resume_h3_borders.subprocess.run', side_effect=run):
                result = recover(fit, out, root)
            self.assertEqual(result, out/'checkpoint-1')
            self.assertEqual(len(calls), 3)
            self.assertEqual((out/'complete-fit.txt').read_text().strip(), str(result.resolve()))

    def test_failure_without_stage_cannot_publish(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'recovery'
            with patch('resume_h3_borders.subprocess.run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaisesRegex(RuntimeError, 'no checked temperature progress'):
                    recover(root/'fit', out, root)
            self.assertFalse((out/'complete-fit.txt').exists())

    def test_attempt_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'recovery'
            def run(command, **kwargs):
                trial = Path(command[-2]); trial.mkdir(); (trial/'stage-2.0.jls').touch()
                return subprocess.CompletedProcess(command, 124)
            with patch('resume_h3_borders.subprocess.run', side_effect=run):
                with self.assertRaisesRegex(RuntimeError, 'attempt limit'):
                    recover(root/'fit', out, root, attempts=1)
            self.assertFalse((out/'complete-fit.txt').exists())

    def test_failed_promotion_cannot_publish(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'recovery'
            def run(command, **kwargs):
                if kwargs.get('check'):
                    raise subprocess.CalledProcessError(1, command)
                trial = Path(command[-2]); trial.mkdir(); (trial/'accepted.jls').touch()
                return subprocess.CompletedProcess(command, 0)
            with patch('resume_h3_borders.subprocess.run', side_effect=run):
                with self.assertRaises(subprocess.CalledProcessError):
                    recover(root/'fit', out, root)
            self.assertFalse((out/'complete-fit.txt').exists())

    def test_repeated_temperature_stops(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'recovery'
            def run(command, **kwargs):
                i = next(i for i, p in enumerate(command) if str(p).endswith('recover_h3_borders.jl'))
                trial = Path(command[i+2]); trial.mkdir(); (trial/'stage-2.0.jls').touch()
                return subprocess.CompletedProcess(command, 124)
            with patch('resume_h3_borders.subprocess.run', side_effect=run) as runner:
                with self.assertRaisesRegex(RuntimeError, 'no checked temperature progress'):
                    recover(root/'fit', out, root)
            self.assertEqual(runner.call_count, 2)

    def test_partial_promotion_is_not_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); out = root/'recovery'
            def run(command, **kwargs):
                if kwargs.get('check'):
                    Path(command[-1]).mkdir()
                else:
                    trial = Path(command[-2]); trial.mkdir(); (trial/'accepted.jls').touch()
                return subprocess.CompletedProcess(command, 0)
            with patch('resume_h3_borders.subprocess.run', side_effect=run):
                with self.assertRaisesRegex(RuntimeError, 'update limit'):
                    recover(root/'fit', out, root, updates=1)
            self.assertFalse((out/'complete-fit.txt').exists())

    def test_existing_output_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ValueError):
                recover(root, root, root)


if __name__ == '__main__':
    unittest.main()

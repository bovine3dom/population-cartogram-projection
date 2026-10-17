#!/usr/bin/env python3
"""Recover a checked partial border sweep with bounded solver attempts."""
import argparse
import json
from pathlib import Path
import subprocess


def warm_stage(directory):
    stages = list(directory.glob('stage-*.jls'))
    return min(stages, key=lambda p: float(p.stem.removeprefix('stage-'))) if stages else None


def recover(fit, output, project, attempts=4, updates=4, seconds=1200):
    if output.exists() or min(attempts, updates, seconds) < 1:
        raise ValueError('Use a new output and positive recovery limits')
    output.mkdir(parents=True)
    scripts = Path(__file__).resolve().parent
    julia = ['julia', '--threads=2', f'--project={project}']
    history = []
    for update in range(updates):
        if (fit/'research-fit-complete.txt').exists():
            break
        warm = None
        for attempt in range(attempts):
            trial = output/f'update-{update+1}-attempt-{attempt+1}'
            command = julia + [str(scripts/'recover_h3_borders.jl'), str(fit), str(trial), '1000']
            if warm is not None:
                command.append(str(warm))
            # The Julia pilot checks checkpoint identity, masses, forces, and
            # warm-stage temperature before it accepts any continuation.
            with (output/f'{trial.name}.log').open('w') as log:
                result = subprocess.run(['timeout', '-k', '30s', f'{seconds}s', *command], stdout=log, stderr=subprocess.STDOUT)
            history.append(dict(fit=str(fit), trial=str(trial), warm=str(warm) if warm else None, exit_code=result.returncode))
            (output/'attempts.json').write_text(json.dumps(history, indent=2)+'\n')
            if (trial/'accepted.jls').exists():
                promoted = output/f'checkpoint-{update+1}'
                with (output/f'promotion-{update+1}.log').open('w') as log:
                    subprocess.run(['timeout', '-k', '30s', f'{seconds}s', *julia,
                                    str(scripts/'promote_h3_recovery.jl'), str(fit), str(trial), str(promoted)],
                                   stdout=log, stderr=subprocess.STDOUT, check=True)
                fit = promoted
                break
            stage = warm_stage(trial)
            if stage is None or (warm is not None and float(stage.stem[6:]) >= float(warm.stem[6:])):
                raise RuntimeError(f'Recovery made no checked temperature progress: {trial}')
            warm = stage
        else:
            raise RuntimeError('Recovery attempt limit reached; inspect saved stages')
    if not (fit/'research-fit-complete.txt').exists():
        raise RuntimeError('Recovery update limit reached; inspect saved checkpoints')
    (output/'complete-fit.txt').write_text(str(fit.resolve())+'\n')
    return fit


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('fit', 'output', 'project'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--attempts', type=int, default=4)
    parser.add_argument('--updates', type=int, default=4)
    parser.add_argument('--seconds', type=int, default=1200)
    recover(**vars(parser.parse_args()))

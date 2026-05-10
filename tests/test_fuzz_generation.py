"""End-to-end generation fuzzer for the MH Rise apworld (gh issue #10).

Two phases:
- `test_stability_default` — N runs with default options, different
  seed each time. Catches nondeterministic baseline failures.
- `test_fuzz_random` — M runs with random configs (plus the
  always-run edge configs from fuzz_config.EDGE_CONFIGS). Catches
  config-dependent failures.

Run counts are configurable via `--default-runs` / `--random-runs`
or `MHRISE_FUZZ_DEFAULT_RUNS` / `MHRISE_FUZZ_RANDOM_RUNS`.
"""
from __future__ import annotations

import random
import subprocess
from pathlib import Path

import pytest

from . import fuzz_config


def _run_generation(ap_install, installed_apworld, yaml_text: str,
                    seed: int, tmp_path: Path) -> None:
    players_dir = tmp_path / "Players"
    players_dir.mkdir()
    output_dir = tmp_path / "output"
    output_dir.mkdir()

    yaml_path = players_dir / "mhrise_fuzz.yaml"
    yaml_path.write_text(yaml_text, encoding="utf-8")

    cmd = [
        str(ap_install["generate_exe"]),
        "--player_files_path", str(players_dir),
        "--outputpath", str(output_dir),
        "--seed", str(seed),
        "--skip_output",
    ]
    result = subprocess.run(
        cmd,
        cwd=str(ap_install["install_dir"]),
        capture_output=True, text=True,
        stdin=subprocess.DEVNULL,
        timeout=300,
    )
    if result.returncode != 0:
        stderr_tail = "\n".join(result.stderr.splitlines()[-50:])
        stdout_tail = "\n".join(result.stdout.splitlines()[-50:])
        pytest.fail(
            f"ArchipelagoGenerate failed (exit={result.returncode}, seed={seed})\n"
            f"--- YAML ---\n{yaml_text}\n"
            f"--- stdout (tail) ---\n{stdout_tail}\n"
            f"--- stderr (tail) ---\n{stderr_tail}"
        )


def test_stability_default(ap_install, installed_apworld, default_runs,
                           tmp_path_factory):
    """Run gen N times with all-default options, different seed each time."""
    yaml_text = fuzz_config.to_yaml(fuzz_config.DEFAULT_CONFIG, "stability")
    for i in range(default_runs):
        seed = 1_000_000 + i
        run_tmp = tmp_path_factory.mktemp(f"stability_{i}")
        _run_generation(ap_install, installed_apworld, yaml_text, seed, run_tmp)


def test_fuzz_random(ap_install, installed_apworld, random_runs, fuzz_seed,
                     tmp_path_factory):
    """Run gen with edge configs first, then random_runs random configs."""
    rng = random.Random(fuzz_seed)
    configs: list[tuple[str, dict]] = [
        (f"edge_{i}", cfg) for i, cfg in enumerate(fuzz_config.EDGE_CONFIGS)
    ]
    for i in range(random_runs):
        configs.append((f"rand_{i}", fuzz_config.random_config(rng)))

    for label, cfg in configs:
        yaml_text = fuzz_config.to_yaml(cfg, label)
        seed = rng.randint(1, 2**31 - 1)
        run_tmp = tmp_path_factory.mktemp(label)
        _run_generation(ap_install, installed_apworld, yaml_text, seed, run_tmp)

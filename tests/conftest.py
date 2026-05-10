"""Pytest fixtures for the MH Rise fuzzer.

The fuzzer drives the user's installed Archipelago via
`ArchipelagoGenerate.exe` (Windows) or `ArchipelagoGenerate` (POSIX).
Path comes from the `AP_INSTALL` env var only — never hardcoded.

TODO: When/if AP source becomes available locally, swap the
subprocess-driven fuzzer for in-process generation so we can assert
richer invariants (slot_data shape, item-pool counts, spare-slot
math from ap_world/items.py:118-182) without paying per-iteration
process spawn cost. Tracked under gh issue #10.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_RUNS_DEFAULT = 10
RANDOM_RUNS_DEFAULT = 50


def pytest_addoption(parser):
    parser.addoption("--default-runs", type=int, default=None,
                     help="Number of stability iterations (default options).")
    parser.addoption("--random-runs", type=int, default=None,
                     help="Number of random-config iterations.")
    parser.addoption("--fuzz-seed", type=int, default=None,
                     help="Seed for the fuzz RNG (for repro).")


def _resolve_count(cli_val, env_var, default):
    if cli_val is not None:
        return cli_val
    env_val = os.environ.get(env_var)
    if env_val is not None:
        return int(env_val)
    return default


@pytest.fixture(scope="session")
def default_runs(pytestconfig):
    return _resolve_count(
        pytestconfig.getoption("--default-runs"),
        "MHRISE_FUZZ_DEFAULT_RUNS",
        DEFAULT_RUNS_DEFAULT,
    )


@pytest.fixture(scope="session")
def random_runs(pytestconfig):
    return _resolve_count(
        pytestconfig.getoption("--random-runs"),
        "MHRISE_FUZZ_RANDOM_RUNS",
        RANDOM_RUNS_DEFAULT,
    )


@pytest.fixture(scope="session")
def fuzz_seed(pytestconfig):
    cli = pytestconfig.getoption("--fuzz-seed")
    if cli is not None:
        return cli
    env = os.environ.get("MHRISE_FUZZ_SEED")
    if env is not None:
        return int(env)
    return None


@pytest.fixture(scope="session")
def ap_install():
    path = os.environ.get("AP_INSTALL")
    if not path:
        pytest.skip("AP_INSTALL env var not set; pointing at a local "
                    "Archipelago install is required for the fuzzer.")
    install_dir = Path(path)
    if not install_dir.is_dir():
        pytest.skip(f"AP_INSTALL='{path}' is not a directory.")

    if sys.platform == "win32":
        generate_exe = install_dir / "ArchipelagoGenerate.exe"
    else:
        generate_exe = install_dir / "ArchipelagoGenerate"
    if not generate_exe.exists():
        pytest.skip(f"Generate entrypoint not found at {generate_exe}.")

    custom_worlds = install_dir / "custom_worlds"
    custom_worlds.mkdir(exist_ok=True)

    return {"install_dir": install_dir, "generate_exe": generate_exe,
            "custom_worlds": custom_worlds}


@pytest.fixture(scope="session")
def installed_apworld(ap_install):
    """Build the apworld from source and install it into the AP custom_worlds
    dir for the test session. Removed on session teardown."""
    build_script = REPO_ROOT / "ap_world" / "build_apworld.py"
    result = subprocess.run(
        [sys.executable, str(build_script)],
        cwd=str(REPO_ROOT),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        pytest.fail(f"build_apworld.py failed:\n{result.stdout}\n{result.stderr}")

    built = REPO_ROOT / "mhrise.apworld"
    if not built.exists():
        pytest.fail(f"build_apworld.py succeeded but {built} not found.")

    installed = ap_install["custom_worlds"] / "mhrise.apworld"
    shutil.copy2(built, installed)
    yield installed
    try:
        installed.unlink()
    except OSError:
        pass

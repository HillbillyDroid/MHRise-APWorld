"""Fuzz config space for MH Rise apworld generation.

Each config is a dict matching the apworld's option keys. `to_yaml`
emits a valid Archipelago YAML wrapping the config under the
"Monster Hunter Rise" game key.

Constraint respected by `random_config`: when `include_weapons` is
true, `weapon_pool` is always a non-empty subset (else `generate_early`
raises in ap_world/world.py).
"""
from __future__ import annotations

import random
import sys
from pathlib import Path
from typing import Any

import yaml

_REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_REPO_ROOT / "ap_world" / "data"))
from weapons import WEAPONS  # noqa: E402

WEAPON_NAMES = [w["name"] for w in WEAPONS]
GAME_NAME = "Monster Hunter Rise"

DEFAULT_CONFIG: dict[str, Any] = {
    "mode": "hunt_a_thon",
    "include_sunbreak": True,
    "include_risen": False,
    "include_weapons": True,
    "weapon_pool": list(WEAPON_NAMES),
    "monster_count": 15,
}

QUEST_RANDO_CONFIG: dict[str, Any] = {
    **DEFAULT_CONFIG,
    "mode": "quest_rando",
}


def random_config(rng: random.Random) -> dict[str, Any]:
    mode = rng.choice(["hunt_a_thon", "quest_rando"])
    include_weapons = rng.random() < 0.7
    if include_weapons:
        pool_size = rng.randint(1, len(WEAPON_NAMES))
        weapon_pool = rng.sample(WEAPON_NAMES, pool_size)
    else:
        weapon_pool = list(WEAPON_NAMES)

    return {
        "mode": mode,
        "include_sunbreak": rng.random() < 0.7,
        "include_risen": rng.random() < 0.3,
        "include_weapons": include_weapons,
        "weapon_pool": weapon_pool,
        "monster_count": rng.randint(3, 72),
    }


EDGE_CONFIGS: list[dict[str, Any]] = [
    DEFAULT_CONFIG,
    {**DEFAULT_CONFIG, "include_sunbreak": False, "include_risen": False, "include_weapons": False, "monster_count": 3},
    {**DEFAULT_CONFIG, "include_sunbreak": True, "include_risen": True, "include_weapons": True, "monster_count": 72},
    {**DEFAULT_CONFIG, "monster_count": 3},
    {**DEFAULT_CONFIG, "monster_count": 72},
    # Sunbreak off + monster_count > base-game pool → exercises the
    # generate_early clamp (`n = min(requested, len(available))`).
    {**DEFAULT_CONFIG, "include_sunbreak": False, "monster_count": 60},
    {**DEFAULT_CONFIG, "weapon_pool": [WEAPON_NAMES[0]]},
    {**DEFAULT_CONFIG, "include_sunbreak": False, "include_risen": False, "monster_count": 32},
    # QuestRando: now honors include_weapons / weapon_pool too. Exercise
    # the toggles and weapon-pool truncation.
    QUEST_RANDO_CONFIG,
    {**QUEST_RANDO_CONFIG, "include_sunbreak": False},
    {**QUEST_RANDO_CONFIG, "include_risen": True},
    {**QUEST_RANDO_CONFIG, "include_weapons": False},
    {**QUEST_RANDO_CONFIG, "include_sunbreak": False, "include_weapons": False},
    {**QUEST_RANDO_CONFIG, "weapon_pool": [WEAPON_NAMES[0]]},
    {**QUEST_RANDO_CONFIG, "weapon_pool": WEAPON_NAMES[:3]},
]


def to_yaml(config: dict[str, Any], slot_name: str) -> str:
    doc = {
        "name": slot_name,
        "game": GAME_NAME,
        "description": f"fuzz slot {slot_name}",
        GAME_NAME: config,
        "requires": {"version": "0.6.7"},
    }
    return yaml.safe_dump(doc, sort_keys=False)

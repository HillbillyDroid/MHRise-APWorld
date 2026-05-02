"""Master weapon-type table for the MH Rise Archipelago world.

Mirror of data/monsters.py shape. Source of truth for the 14 huntable
weapon types when the IncludeWeapons option is enabled. The Python
apworld imports WEAPONS to build item IDs and slot_data; the in-game
Lua client receives the resolved name<->weapon_type map via slot_data
so the two sides cannot drift.

Each entry is a dict with keys:
- name: display name. MUST match client/AP_CLIENT/Weapons.lua:NAMES so
  the client can resolve `current weapon int -> license name`.
- weapon_type: the snow.player.PlayerWeaponType enum value.
- tags: list of strings, currently empty. Reserved for future
  categorisation (e.g. "blademaster", "gunner").
"""

from __future__ import annotations
from typing import Any


WEAPONS: tuple[dict[str, Any], ...] = (
    {"name": "Great Sword",    "weapon_type":  0, "tags": []},
    {"name": "Switch Axe",     "weapon_type":  1, "tags": []},
    {"name": "Long Sword",     "weapon_type":  2, "tags": []},
    {"name": "Light Bowgun",   "weapon_type":  3, "tags": []},
    {"name": "Heavy Bowgun",   "weapon_type":  4, "tags": []},
    {"name": "Hammer",         "weapon_type":  5, "tags": []},
    {"name": "Gunlance",       "weapon_type":  6, "tags": []},
    {"name": "Lance",          "weapon_type":  7, "tags": []},
    {"name": "Sword & Shield", "weapon_type":  8, "tags": []},
    {"name": "Dual Blades",    "weapon_type":  9, "tags": []},
    {"name": "Hunting Horn",   "weapon_type": 10, "tags": []},
    {"name": "Charge Blade",   "weapon_type": 11, "tags": []},
    {"name": "Insect Glaive",  "weapon_type": 12, "tags": []},
    {"name": "Bow",            "weapon_type": 13, "tags": []},
)


# ----- Sanity checks at import time -----

assert len({w["weapon_type"] for w in WEAPONS}) == len(WEAPONS), "duplicate weapon_type"
assert len({w["name"] for w in WEAPONS}) == len(WEAPONS), "duplicate name"
assert all(isinstance(w["tags"], list) for w in WEAPONS), "tags must be a list"

"""MHRiseWorld — the apworld entrypoint.

Wires options, items, locations, regions, and rules together, plus emits
the slot_data blob the in-game Lua client needs (see CLAUDE.md decision #1
for why we ship the EmType map this way rather than via a static file)."""

from __future__ import annotations

import json
import logging
import pkgutil
from collections.abc import Mapping
from typing import Any

from worlds.AutoWorld import World

from . import items, locations, regions, rules
from . import options as mhrise_options  # rename due to a name conflict with World.options
from .data.monsters import MONSTERS
from .data.weapons import WEAPONS
from .web_world import MHRiseWebWorld

# Read world_version from the manifest via pkgutil so this works whether
# the apworld is loaded from an unpacked source tree or from inside a
# .apworld zip (custom_worlds/). `os.path.join + open()` would only work
# in the unpacked case — inside a zip, `__file__` points into the
# archive and is not a real filesystem path.
_MANIFEST_BYTES = pkgutil.get_data(__package__, "archipelago.json")
if _MANIFEST_BYTES is None:
    raise RuntimeError("archipelago.json missing from apworld package")
WORLD_VERSION = json.loads(_MANIFEST_BYTES.decode("utf-8"))["world_version"]


class MHRiseWorld(World):
    """
    Monster Hunter Rise + Sunbreak. Hunting a large monster requires its
    license; licenses are scattered across the multiworld. Hunting a
    licensed monster sends a check, which causes the multiworld to release
    more items (including more licenses). Standard hunt-for-keys loop.
    """

    game = "Monster Hunter Rise"

    web = MHRiseWebWorld()

    options_dataclass = mhrise_options.MHRiseOptions
    options: mhrise_options.MHRiseOptions

    location_name_to_id = locations.LOCATION_NAME_TO_ID
    item_name_to_id = items.ITEM_NAME_TO_ID

    origin_region_name = regions.ORIGIN_REGION_NAME

    # Populated by generate_early. The single monster whose license is
    # precollected at seed start, so the player has something huntable
    # from t=0.
    starting_monster: dict

    # Populated by generate_early. The monster whose (2/2) hunt location
    # carries the locked Victory item. Picked random for v1; future
    # versions may anchor to a story-final monster (Gaismagorm, etc.).
    goal_monster: dict

    # Populated by generate_early when include_weapons is enabled. The
    # weapon whose license is precollected so the player can hunt from
    # t=0. None when weapons are disabled.
    starting_weapon: dict | None = None

    # Populated by generate_early when include_weapons is enabled.
    # Subset of WEAPONS allowed by the weapon_pool option — drives
    # starter pick and the non-starter weapon licenses placed in the
    # itempool. Excluded weapons are absent from the pool entirely;
    # the client's slot_data still ships the full enum->name map so
    # the soft gate naturally filters hunts wielding excluded weapons
    # (player never receives those licenses, so Items.held never
    # contains them).
    weapon_pool: list[dict]

    # Populated by generate_early. The randomly-chosen subset of monsters
    # this seed actually uses — drives location creation, item pool,
    # rules, and the slot_data em_type map. Source of truth for "is this
    # monster part of the seed?" downstream of generate_early.
    seed_monsters: list[dict]

    def generate_early(self) -> None:
        available = [m for m in MONSTERS if self._monster_allowed(m)]
        if not available:
            raise ValueError(
                "No monsters available. Sunbreak is disabled and the Rise "
                "monster list is empty — this should be impossible."
            )

        requested = int(self.options.monster_count.value)
        n = min(requested, len(available))
        if n < requested:
            logging.warning(
                "[MHRise] monster_count=%d clamped to %d (available pool size)",
                requested, n,
            )
        assert n >= 2, "monster_count Range should enforce min=2"

        # Pick starter first from the full available pool, then goal from
        # the elder-dragons (minus starter, in case the starter happens
        # to be one). This way both are guaranteed to land in
        # seed_monsters regardless of how the random sample falls.
        self.starting_monster = self.random.choice(available)

        elder_dragon_candidates = [
            m for m in available
            if "elder-dragon" in m["tags"]
            and m["name"] != self.starting_monster["name"]
        ]
        if not elder_dragon_candidates:
            raise ValueError(
                "No elder-dragon monsters available for goal — enable "
                "Sunbreak / Risen, or expand the monster table."
            )
        self.goal_monster = self.random.choice(elder_dragon_candidates)

        # Fill out the seed with random other monsters until we hit n.
        # Starter and goal are always in. n>=2 guarantees this fits.
        rest_pool = [
            m for m in available
            if m["name"] != self.starting_monster["name"]
            and m["name"] != self.goal_monster["name"]
        ]
        rest = self.random.sample(rest_pool, n - 2)
        self.seed_monsters = [self.starting_monster, self.goal_monster] + rest

        if bool(self.options.include_weapons.value):
            allowed_weapon_names = set(self.options.weapon_pool.value)
            if not allowed_weapon_names:
                raise ValueError(
                    "weapon_pool must contain at least one weapon name "
                    "when include_weapons is enabled."
                )
            self.weapon_pool = [
                w for w in WEAPONS if w["name"] in allowed_weapon_names
            ]
            assert self.weapon_pool, (
                "weapon_pool resolved to empty after filtering — "
                "OptionSet.valid_keys should have caught unknown names."
            )
            self.starting_weapon = self.random.choice(self.weapon_pool)

    def create_regions(self) -> None:
        regions.create_and_connect_regions(self)
        locations.create_all_locations(self)

    def set_rules(self) -> None:
        rules.set_all_rules(self)

    def create_items(self) -> None:
        items.create_all_items(self)

    def create_item(self, name: str) -> items.MHRiseItem:
        return items.create_item_with_correct_classification(self, name)

    def get_filler_item_name(self) -> str:
        return items.get_filler_item_name()

    def fill_slot_data(self) -> Mapping[str, Any]:
        """Send client-side config to the in-game Lua plugin.

        The critical piece is `monster_em_type_map`: a dict from license
        item name (e.g. "Rathian License") to the in-game EmType integer
        the death hook reads off `<EnemyType>k__BackingField`. The client
        uses it to map a hunted monster's EmType back to a license, and
        from there to the AP location ID it needs to send.
        """
        em_type_map = {
            items.license_item_name(m): m["em_type"]
            for m in self.seed_monsters
        }

        slot_data: dict[str, Any] = {
            "world_version": WORLD_VERSION,
            "monster_em_type_map": em_type_map,
            "include_sunbreak": bool(self.options.include_sunbreak.value),
            "starting_monster": self.starting_monster["name"],
            "goal_monster": self.goal_monster["name"],
            "include_weapons": bool(self.options.include_weapons.value),
            "monster_count": len(self.seed_monsters),
        }

        if bool(self.options.include_weapons.value):
            # weapon_type (int enum) -> license item name. The Lua client
            # reads the current player's _playerWeaponType field and uses
            # this to look up the license name to check against Items.held.
            slot_data["weapon_type_to_item_name"] = {
                w["weapon_type"]: items.weapon_license_item_name(w)
                for w in WEAPONS
            }
            slot_data["starting_weapon"] = (
                self.starting_weapon["name"] if self.starting_weapon else None
            )

        return slot_data

    def _monster_allowed(self, monster: dict) -> bool:
        """Whether a monster is eligible to be drawn into the seed,
        based on the per-bucket toggles. Used during generate_early to
        compute the universe of monsters the random subset is drawn
        from. Downstream code should consult `self.seed_monsters` rather
        than re-running this filter."""
        if monster["dlc"] == "sunbreak" and not bool(self.options.include_sunbreak.value):
            return False
        if "risen" in monster["tags"] and not bool(self.options.include_risen.value):
            return False
        return True

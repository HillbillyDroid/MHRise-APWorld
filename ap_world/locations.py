"""Location table for the MH Rise apworld.

Two modes, two location families (see options.py:Mode):

- HuntAThon: two locations per curated monster, `f"Hunt {name} (1/2)"`
  and `f"Hunt {name} (2/2)"`. Both fire on the same in-game hunt event
  — the two-slot structure exists purely to double the multiworld item
  slots per monster.

- QuestRando: one location per village quest, `f"Clear: {quest.name}"`.
  Fires once when the quest is cleared.

IDs are static and known at module import time (same stability story as
items.py) so the datapackage stays frozen across seeds and option/mode
choices.

ID layout:
- 1..(2N): monster hunt locations. Order matches items.py
  (`MONSTERS + APEX_MONSTERS + SMALL_MONSTERS`); each monster reserves
  two consecutive IDs (`(1/2)` then `(2/2)`).
- 2000..2999: per-village-quest clear locations. One per
  `EnemyLv.Village` entry in QUESTS, parallel to the matching unlock
  item ID. Reserved unconditionally so the datapackage stays frozen
  across modes.

Only locations the active mode uses get added to the multiworld; the
rest sit in the static map for datapackage stability.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from BaseClasses import Location, LocationProgressType

from .items import ALL_CURATED_MONSTERS, VILLAGE_QUESTS, quest_display_name
from .options import Mode

if TYPE_CHECKING:
    from .world import MHRiseWorld


LOCATION_ID_BASE = 0
LOCATIONS_PER_MONSTER = 2
QUEST_CLEAR_ID_BASE = 2000

LOCATION_NAME_TO_ID: dict[str, int] = {}

for _i, _monster in enumerate(ALL_CURATED_MONSTERS):
    for _slot in range(LOCATIONS_PER_MONSTER):
        _id = LOCATION_ID_BASE + _i * LOCATIONS_PER_MONSTER + _slot + 1
        _name = f"Hunt {_monster['name']} ({_slot + 1}/{LOCATIONS_PER_MONSTER})"
        assert _name not in LOCATION_NAME_TO_ID, f"duplicate location name {_name}"
        LOCATION_NAME_TO_ID[_name] = _id

for _i, _quest in enumerate(VILLAGE_QUESTS):
    _id = QUEST_CLEAR_ID_BASE + _i
    assert _id < 9000, "village quest count overflowed reserved range"
    _name = f"Clear: {quest_display_name(_quest)}"
    assert _name not in LOCATION_NAME_TO_ID, f"duplicate location name {_name}"
    LOCATION_NAME_TO_ID[_name] = _id


def hunt_location_names(monster: dict) -> list[str]:
    """Return the AP location names for hunting a given monster — one per
    slot. Both fire on the same in-game hunt event."""
    return [
        f"Hunt {monster['name']} ({slot + 1}/{LOCATIONS_PER_MONSTER})"
        for slot in range(LOCATIONS_PER_MONSTER)
    ]


def quest_clear_location_name(quest: dict) -> str:
    """AP location name for clearing a village quest."""
    return f"Clear: {quest_display_name(quest)}"


class MHRiseLocation(Location):
    game = "Monster Hunter Rise"


def create_all_locations(world: MHRiseWorld) -> None:
    """Dispatch on mode."""
    if world.options.mode.value == Mode.option_quest_rando:
        _create_locations_questrando(world)
    else:
        _create_locations_huntathon(world)


def _create_locations_huntathon(world: MHRiseWorld) -> None:
    """Add hunt locations for every monster in the seed to the Origin region.

    The seed subset is computed in `world.generate_early` and stored on
    `world.seed_monsters`."""
    from .regions import ORIGIN_REGION_NAME

    origin = world.get_region(ORIGIN_REGION_NAME)

    location_map: dict[str, int] = {}
    for monster in world.seed_monsters:
        for name in hunt_location_names(monster):
            location_map[name] = LOCATION_NAME_TO_ID[name]

    origin.add_locations(location_map, MHRiseLocation)

    # Both goal-monster hunt locations are EXCLUDED so AP fill never
    # places progression/useful items at them. (2/2) is then locked with
    # Victory in items.place_victory; place_locked_item bypasses the
    # progress_type flag, so the lock still works. Hunting the goal ends
    # the run — anything stranded at goal (1/2) would be unreachable.
    for name in hunt_location_names(world.goal_monster):
        world.get_location(name).progress_type = LocationProgressType.EXCLUDED


def _create_locations_questrando(world: MHRiseWorld) -> None:
    """Add one Clear-location per village quest in the active pool."""
    from .regions import ORIGIN_REGION_NAME

    origin = world.get_region(ORIGIN_REGION_NAME)

    location_map: dict[str, int] = {}
    for quest in world.quest_pool:
        name = quest_clear_location_name(quest)
        location_map[name] = LOCATION_NAME_TO_ID[name]

    origin.add_locations(location_map, MHRiseLocation)

    # Goal quest's clear location is EXCLUDED so AP fill doesn't strand
    # progression items at it. place_locked_item bypasses the
    # progress_type flag, so the Victory lock still works.
    goal_loc = quest_clear_location_name(world.goal_quest)
    world.get_location(goal_loc).progress_type = LocationProgressType.EXCLUDED

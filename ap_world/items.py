"""Item table for the MH Rise apworld.

Spans two modes (see options.py:Mode):
- HuntAThon: one license item per curated monster. Hunting the monster
  sends checks; license soft-gates.
- QuestRando: one "Unlock: <quest>" item per village quest (except the
  goal). Hard-gates the village questboard.

IDs are static and known at module import time so the AP datapackage is
stable across seeds AND across option/mode choices. A quest-unlock item
has the same ID whether the seed uses QuestRando or HuntAThon.

ID layout:
- 1..N: monster license items. Order is `MONSTERS + APEX_MONSTERS +
       SMALL_MONSTERS`, so existing IDs are preserved if a future option
       merges Apex or Small into the active pool. event_id=0 -> id=1 to
       keep us off the AP-reserved id 0 sentinel.
- 2000..2999: per-village-quest unlock items. One per `EnemyLv.Village`
       entry in QUESTS, indexed by position in the village list (which
       is itself stable: order in `data/quests.py`). Used only by
       QuestRando mode but reserved unconditionally so HuntAThon doesn't
       shift them.
- 9001: Victory (delivered when the goal monster is hunted in HuntAThon
       or when Comeuppance clears in QuestRando).
- 9100..9113: weapon license items (14 contiguous, indexed by WEAPONS
       order). Parked alongside the existing fixed-id items so they
       don't collide with the monster range or the future Apex/Small
       reservations.
- 9999: Poogie (filler).

Names are slot-logical:
- monster licenses: `f"{monster.name} License"`
- quest unlocks: `f"Unlock: {quest.name}"` (falls back to `dbg_name` when
  `name is None`).

The Lua client receives the EmType / quest-id maps via slot_data on
connect, so it never needs to read the master tables from disk.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from BaseClasses import Item, ItemClassification

from .data.monsters import MONSTERS, APEX_MONSTERS, SMALL_MONSTERS
from .data.quests import QUESTS, EnemyLv
from .data.weapons import WEAPONS
from .options import Mode

if TYPE_CHECKING:
    from .world import MHRiseWorld


# Full universe of curated monsters. Stable ordering matters here — IDs are
# assigned by position, so prepending or reordering buckets would break the
# datapackage for existing seeds.
ALL_CURATED_MONSTERS: tuple[dict, ...] = MONSTERS + APEX_MONSTERS + SMALL_MONSTERS

# Village quests in declaration order. Stable for ID assignment.
VILLAGE_QUESTS: tuple[dict, ...] = tuple(
    q for q in QUESTS if q["enemy_level"] == EnemyLv.Village
)

# quest_no for the goal quest ("Comeuppance"). Confirmed against the
# vanilla catalog; intentionally hardcoded by quest_no rather than
# looked up by name because the `name` field is locale-dependent.
COMEUPPANCE_QUEST_NO = 501

FILLER_ITEM_NAME = "Poogie"

QUEST_UNLOCK_ID_BASE = 2000
WEAPON_LICENSE_ID_BASE = 9100


def quest_display_name(quest: dict) -> str:
    """Display name for a quest. Prefers the localized `name`; falls
    back to `dbg_name` when the dumper couldn't resolve it (some 33
    no-monster entries lack a resolved name)."""
    return quest["name"] if quest["name"] is not None else quest["dbg_name"]


def quest_unlock_item_name(quest: dict) -> str:
    """AP item name for a village quest's unlock token."""
    return f"Unlock: {quest_display_name(quest)}"


ITEM_NAME_TO_ID: dict[str, int] = {}

for _i, _monster in enumerate(ALL_CURATED_MONSTERS):
    _id = _i + 1
    assert _id != 0, "AP reserves item id 0 as invalid"
    _name = f"{_monster['name']} License"
    assert _name not in ITEM_NAME_TO_ID, f"duplicate license name {_name}"
    ITEM_NAME_TO_ID[_name] = _id

for _i, _quest in enumerate(VILLAGE_QUESTS):
    _id = QUEST_UNLOCK_ID_BASE + _i
    assert _id < 9000, "village quest count overflowed reserved range"
    _name = quest_unlock_item_name(_quest)
    assert _name not in ITEM_NAME_TO_ID, f"duplicate unlock name {_name}"
    ITEM_NAME_TO_ID[_name] = _id

ITEM_NAME_TO_ID["Victory"] = 9001
ITEM_NAME_TO_ID[FILLER_ITEM_NAME] = 9999

for _i, _weapon in enumerate(WEAPONS):
    _name = f"{_weapon['name']} License"
    assert _name not in ITEM_NAME_TO_ID, f"duplicate license name {_name}"
    ITEM_NAME_TO_ID[_name] = WEAPON_LICENSE_ID_BASE + _i


def license_item_name(monster: dict) -> str:
    """Return the AP item name for the license of a given monster."""
    return f"{monster['name']} License"


def weapon_license_item_name(weapon: dict) -> str:
    """Return the AP item name for the license of a given weapon type."""
    return f"{weapon['name']} License"


class MHRiseItem(Item):
    game = "Monster Hunter Rise"


_WEAPON_LICENSE_NAMES = frozenset(weapon_license_item_name(w) for w in WEAPONS)
_QUEST_UNLOCK_NAMES = frozenset(quest_unlock_item_name(q) for q in VILLAGE_QUESTS)


def create_item_with_correct_classification(world: MHRiseWorld, name: str) -> MHRiseItem:
    if name == FILLER_ITEM_NAME:
        classification = ItemClassification.filler
    elif name == "Victory":
        # Skip-balancing on the goal item — receiving it ends the run,
        # so AP's progression balancer pulling it forward to relieve
        # another player's BK collapses pacing.
        classification = ItemClassification.progression_skip_balancing
    elif (
        world.options.mode.value == Mode.option_hunt_a_thon
        and getattr(world, "goal_monster", None) is not None
        and name == license_item_name(world.goal_monster)
    ):
        # HuntAThon: the goal monster's license gates Victory. Same
        # skip-balancing logic as Victory itself.
        classification = ItemClassification.progression_skip_balancing
    elif (
        world.options.mode.value == Mode.option_quest_rando
        and getattr(world, "goal_quest", None) is not None
        and name == quest_unlock_item_name(world.goal_quest)
    ):
        # QuestRando: the goal quest's unlock gates Victory.
        classification = ItemClassification.progression_skip_balancing
    elif name in _WEAPON_LICENSE_NAMES:
        # Weapon licenses are soft-gated client-side only (no apworld
        # rules reference them). Marking them progression makes fill
        # treat them as gating items competing for reachable locations,
        # which over-constrains placement at low monster_count and
        # produces FillError. `useful` keeps them prioritized for
        # placement without entering the progression-balancing math.
        classification = ItemClassification.useful
    elif name in _QUEST_UNLOCK_NAMES:
        # Quest unlocks are real apworld-level gates (unlike weapon
        # licenses) — they restrict access to the Clear: <quest>
        # locations. Classify as progression so fill respects the
        # topology.
        classification = ItemClassification.progression
    else:
        # Monster licenses are progression — each one gates the player's
        # access to its monster's hunt locations.
        classification = ItemClassification.progression
    return MHRiseItem(name, classification, ITEM_NAME_TO_ID[name], world.player)


def get_filler_item_name() -> str:
    """Wrapped by `MHRiseWorld.get_filler_item_name(self)`. Called by AP
    whenever it needs an extra filler item — e.g. when the item pool is
    short relative to location count, or for plando."""
    return FILLER_ITEM_NAME


def place_victory(world: MHRiseWorld) -> None:
    """Lock the Victory item at the mode-appropriate goal location.

    Runs before `create_all_items` counts unfilled locations so the goal
    slot is excluded from the filler math (locked items don't go into the
    multiworld itempool).

    - HuntAThon: goal monster's (2/2) hunt location.
    - QuestRando: Comeuppance's clear location.
    """
    if world.options.mode.value == Mode.option_quest_rando:
        from .locations import quest_clear_location_name

        goal_loc_name = quest_clear_location_name(world.goal_quest)
    else:
        from .locations import hunt_location_names

        goal_loc_name = hunt_location_names(world.goal_monster)[1]  # (2/2)
    location = world.get_location(goal_loc_name)
    location.place_locked_item(create_item_with_correct_classification(world, "Victory"))


def create_all_items(world: MHRiseWorld) -> None:
    """Dispatch on mode."""
    if world.options.mode.value == Mode.option_quest_rando:
        _create_items_questrando(world)
    else:
        _create_items_huntathon(world)


def _create_items_huntathon(world: MHRiseWorld) -> None:
    """Build the item pool.

    For N = len(world.seed_monsters), the multiworld will create 2N
    locations. `place_victory` consumes one of them (locked, no itempool
    slot), so 2N-1 itempool slots need filling. Of those:

    - N-1 monster licenses (the starter's license is precollected).
    - "Spare" slots = N. Filled, in priority order, by:
      1. The starter weapon license (precollected if weapons enabled).
      2. Up to (spare - 1) random non-starter weapon licenses (if
         weapons enabled), capped at 13. The (spare - 1) cap reserves
         at least one slot for Poogie filler so AP's excluded-location
         fill has something to draw from — the goal monster's two
         hunt locations are EXCLUDED (see locations.py), and AP's
         excluded fill only consumes filler items (not `useful` like
         weapon licenses, not `progression` like monster licenses).
      3. Poogie filler for any leftover slots.

    Spare ≥ 3 is guaranteed by the option floor of monster_count=3.
    """
    place_victory(world)

    starting_name = world.starting_monster["name"]

    itempool: list[Item] = []
    precollected: list[MHRiseItem] = []

    for monster in world.seed_monsters:
        item_name = license_item_name(monster)
        item = create_item_with_correct_classification(world, item_name)
        if monster["name"] == starting_name:
            precollected.append(item)
        else:
            itempool.append(item)

    # Spare slot count = unfilled locations (Victory already locked) minus
    # the monster licenses we just placed in the pool.
    unfilled = len(world.multiworld.get_unfilled_locations(world.player))
    spare = unfilled - len(itempool)
    assert spare >= 1, "spare-slot invariant broken (need ≥1 slot beyond licenses)"

    # Weapon licenses (when enabled). Starter is always precollected,
    # never truncated. The non-starter pool is drawn from
    # `world.weapon_pool` (the weapon_pool option's resolved subset),
    # shuffled and as many as fit go into the pool — when
    # monster_count is small or weapon_pool is small, we drop the rest.
    #
    # Reserve 1 spare slot for filler so that the goal monster's (1/2)
    # location (marked EXCLUDED in locations.py) can be filled. AP's
    # excluded-location fill pulls from the filler pool only —
    # `useful`-classified weapon licenses don't qualify, so without a
    # reserved filler the gen fails with "Not enough filler items for
    # excluded locations".
    if bool(world.options.include_weapons.value):
        starting_weapon_name = world.starting_weapon["name"]
        precollected.append(create_item_with_correct_classification(
            world, weapon_license_item_name(world.starting_weapon)))
        non_starter_weapons = [
            w for w in world.weapon_pool if w["name"] != starting_weapon_name
        ]
        world.random.shuffle(non_starter_weapons)
        weapon_budget = max(spare - 1, 0)
        weapons_to_add = non_starter_weapons[:weapon_budget]
        for weapon in weapons_to_add:
            itempool.append(create_item_with_correct_classification(
                world, weapon_license_item_name(weapon)))
        spare -= len(weapons_to_add)

    # Poogie filler mops up any leftover slots.
    for _ in range(spare):
        itempool.append(create_item_with_correct_classification(world, FILLER_ITEM_NAME))

    world.multiworld.itempool += itempool
    for item in precollected:
        world.push_precollected(item)


def _create_items_questrando(world: MHRiseWorld) -> None:
    """Build the QuestRando item pool.

    Topology:
    - V village quests in `world.quest_pool` → V `Clear: <name>` locations.
    - Goal quest's Clear location is locked with Victory by
      `place_victory` → V-1 unfilled locations to fill.
    - V `Unlock: <quest>` items created, including the goal unlock
      (gates Comeuppance's Clear).
    - Starter quest's unlock is precollected (handed to the player at
      game start; does not consume an itempool slot).
    - Remaining V-1 unlocks go into the itempool, exactly matching
      V-1 unfilled locations.

    Zero spare slots, no Poogie filler in this mode. The goal Clear
    location is marked EXCLUDED in locations.py for safety (AP fill
    shouldn't strand progression items at the goal), but it has
    Victory locked in place already so excluded-fill never runs there.
    """
    place_victory(world)

    starter_quest_no = world.starting_quest_no

    itempool: list[Item] = []
    precollected: list[MHRiseItem] = []

    for quest in world.quest_pool:
        name = quest_unlock_item_name(quest)
        item = create_item_with_correct_classification(world, name)
        if quest["quest_no"] == starter_quest_no:
            precollected.append(item)
        else:
            itempool.append(item)

    unfilled = len(world.multiworld.get_unfilled_locations(world.player))
    assert unfilled == len(itempool), (
        f"QuestRando itempool/location mismatch: "
        f"unfilled={unfilled} pool={len(itempool)}"
    )

    world.multiworld.itempool += itempool
    for item in precollected:
        world.push_precollected(item)

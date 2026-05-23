"""Access rules for the MH Rise apworld.

- HuntAThon: each hunt location requires the corresponding monster's
  license. Both (1/2) and (2/2) share the same rule since both fire on
  the same in-game hunt event.
- QuestRando (swap-only design): no apworld-level rules. Vanilla
  engine progression gates which village quests the player can
  physically accept and clear, so AP fill doesn't need any topology
  beyond "every Clear: location is reachable from Origin". Goal quest
  has Victory locked at its Clear location.

Precollected items satisfy their own rule trivially — `state.has`
returns True for precollected items just like items received from the
multiworld.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from rule_builder.rules import Has

from .items import license_item_name
from .locations import hunt_location_names
from .options import Mode

if TYPE_CHECKING:
    from .world import MHRiseWorld


def set_all_rules(world: MHRiseWorld) -> None:
    if world.options.mode.value == Mode.option_hunt_a_thon:
        _set_rules_huntathon(world)
    # QuestRando: no rules. All Clear: locations are reachable from
    # Origin; engine-side progression is the only effective gate.
    set_completion_condition(world)


def _set_rules_huntathon(world: MHRiseWorld) -> None:
    for monster in world.seed_monsters:
        rule = Has(license_item_name(monster))
        for loc_name in hunt_location_names(monster):
            world.set_rule(world.get_location(loc_name), rule)


def set_completion_condition(world: MHRiseWorld) -> None:
    """The player has received the Victory item. Same condition both modes
    — what locks Victory differs (goal monster hunt vs Comeuppance clear)
    but Victory itself is the completion signal."""
    world.multiworld.completion_condition[world.player] = (
        lambda state: state.has("Victory", world.player)
    )

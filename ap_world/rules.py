"""Access rules for the MH Rise apworld.

- HuntAThon: each hunt location requires the corresponding monster's
  license. Both (1/2) and (2/2) share the same rule since both fire on
  the same in-game hunt event.
- QuestRando: each `Clear: <quest>` location requires the corresponding
  `Unlock: <quest>` item.

Precollected items (starter license / starter quest unlock) satisfy
their own rule trivially — `state.has` returns True for precollected
items just like items the player received from the multiworld.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from rule_builder.rules import Has

from .items import license_item_name, quest_unlock_item_name
from .locations import hunt_location_names, quest_clear_location_name
from .options import Mode

if TYPE_CHECKING:
    from .world import MHRiseWorld


def set_all_rules(world: MHRiseWorld) -> None:
    if world.options.mode.value == Mode.option_quest_rando:
        _set_rules_questrando(world)
    else:
        _set_rules_huntathon(world)
    set_completion_condition(world)


def _set_rules_huntathon(world: MHRiseWorld) -> None:
    for monster in world.seed_monsters:
        rule = Has(license_item_name(monster))
        for loc_name in hunt_location_names(monster):
            world.set_rule(world.get_location(loc_name), rule)


def _set_rules_questrando(world: MHRiseWorld) -> None:
    for quest in world.quest_pool:
        rule = Has(quest_unlock_item_name(quest))
        world.set_rule(world.get_location(quest_clear_location_name(quest)), rule)


def set_completion_condition(world: MHRiseWorld) -> None:
    """The player has received the Victory item. Same condition both modes
    — what locks Victory differs (goal monster hunt vs Comeuppance clear)
    but Victory itself is the completion signal."""
    world.multiworld.completion_condition[world.player] = (
        lambda state: state.has("Victory", world.player)
    )

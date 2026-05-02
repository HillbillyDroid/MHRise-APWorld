"""Access rules for the MH Rise apworld.

Each hunt location requires the player to hold the corresponding monster's
license. Both location slots for a monster (1/2 and 2/2) share the same
rule, since both fire on the same in-game hunt event.

Starting monsters (precollected via the StartingMonsters option) satisfy
their own rule trivially — `state.has` returns True for precollected items
the same way it does for items the player has received from the multiworld.
That means starting monsters need no special-case handling here.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from rule_builder.rules import Has

from .items import license_item_name
from .locations import hunt_location_names

if TYPE_CHECKING:
    from .world import MHRiseWorld


def set_all_rules(world: MHRiseWorld) -> None:
    set_all_location_rules(world)
    set_completion_condition(world)


def set_all_location_rules(world: MHRiseWorld) -> None:
    """For every in-seed monster, gate both of its hunt locations on the
    monster's license."""
    for monster in world.seed_monsters:
        rule = Has(license_item_name(monster))
        for loc_name in hunt_location_names(monster):
            world.set_rule(world.get_location(loc_name), rule)


def set_completion_condition(world: MHRiseWorld) -> None:
    """v1 victory: the player has received the Victory item."""
    world.multiworld.completion_condition[world.player] = (
        lambda state: state.has("Victory", world.player)
    )

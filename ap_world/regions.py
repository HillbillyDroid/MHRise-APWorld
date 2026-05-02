"""Region graph for the MH Rise apworld.

v1 has a single `Origin` region that holds every hunt location. There are
no league tiers, area unlocks, or progression-gated regions — the entire
gating story is per-monster license rules in rules.py. The region exists
only because AP's location model requires every location to live in a
region.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from BaseClasses import Region

if TYPE_CHECKING:
    from .world import MHRiseWorld


ORIGIN_REGION_NAME = "Origin"


def create_and_connect_regions(world: MHRiseWorld) -> None:
    origin = Region(ORIGIN_REGION_NAME, world.player, world.multiworld)
    world.multiworld.regions.append(origin)

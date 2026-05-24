"""Access rules for the MH Rise apworld.

- HuntAThon: each hunt location requires the corresponding monster's
  license. Both (1/2) and (2/2) share the same rule since both fire on
  the same in-game hunt event.
- QuestRando:
  - Each Clear location requires the matching `Unlock: X` item.
  - QL3+ non-urgent quests additionally require their tier's urgent
    unlock (engine won't show the rest of the tier until the urgent
    has been cleared).
  - The tier urgent quests themselves additionally require every
    `Unlock:` from the prior tier — over-approximation of the
    engine's "clear N key quests before the urgent appears" gate.
    Concentrates the heavy prior-tier dependency on a single quest
    per tier (3 urgents total) so AP fill stays manageable.

Precollected items satisfy their own rule trivially — `state.has`
returns True for precollected items just like items received from the
multiworld.
"""

from __future__ import annotations

from collections import defaultdict
from typing import TYPE_CHECKING

from rule_builder.rules import Has, HasAll

from .data.quests import QuestLevel
from .items import (
    TIER_URGENT_QUEST_NOS,
    license_item_name,
    unlock_item_name,
)
from .locations import hunt_location_names, quest_clear_location_names
from .options import Mode

if TYPE_CHECKING:
    from .world import MHRiseWorld


# Each tier's urgent additionally requires every Unlock: in the
# prior tier (over-approximating the engine's "clear N key quests"
# with "clear all prior tier"). Maps urgent's QL -> prior QL.
_PRIOR_TIER_FOR_URGENT: dict[QuestLevel, QuestLevel] = {
    QuestLevel.QL3: QuestLevel.QL2,
    QuestLevel.QL4: QuestLevel.QL3,
    QuestLevel.QL5: QuestLevel.QL4,
}


def set_all_rules(world: MHRiseWorld) -> None:
    if world.options.mode.value == Mode.option_hunt_a_thon:
        _set_rules_huntathon(world)
    else:
        _set_rules_questrando(world)
    set_completion_condition(world)


def _set_rules_huntathon(world: MHRiseWorld) -> None:
    for monster in world.seed_monsters:
        rule = Has(license_item_name(monster))
        for loc_name in hunt_location_names(monster):
            world.set_rule(world.get_location(loc_name), rule)


def _set_rules_questrando(world: MHRiseWorld) -> None:
    """Build per-quest Clear rules.

    Two rule shapes:
    - Tier-urgent quest U (the lowest-quest_no quest at QLn, the
      engine's tier-key gate): `Has(Unlock: U) AND HasAll(every
      Unlock: in prior tier)`. Over-approximates the engine's
      "clear N specific keys then U becomes available" gate by
      requiring the entire prior tier.
    - Non-urgent quest X at QLn: the tier urgent's full rule plus
      X's own unlock. That is, X reachable iff the tier urgent
      is reachable AND the player holds Unlock: X. This ensures
      AP fill never grants a player-receivable check (e.g.,
      placing Unlock: Y at Clear: X) until Y is actually
      sphere-clearable in-game — clearing X requires both X's
      unlock AND the engine's tier gate (urgent unlocked) AND
      the prior tier's full clear set.

    QL2 has no urgent / no prior-tier requirement: clearing any
    QL2 quest just requires its own unlock. The precollected
    starter (qn=202) seeds sphere 0.
    """
    quest_by_no = {q["quest_no"]: q for q in world.quest_pool}
    by_tier: dict[QuestLevel, list[dict]] = defaultdict(list)
    for q in world.quest_pool:
        by_tier[q["quest_level"]].append(q)

    # Build the urgent's rule for each tier first, then non-urgents
    # in that tier chain off it.
    urgent_rule_by_tier: dict[QuestLevel, object] = {}
    for tier, qn in TIER_URGENT_QUEST_NOS.items():
        urgent_quest = quest_by_no.get(qn)
        if urgent_quest is None:
            continue
        own = Has(unlock_item_name(urgent_quest))
        prior_tier = _PRIOR_TIER_FOR_URGENT.get(tier)
        if prior_tier is not None:
            prior_unlocks = [
                unlock_item_name(q) for q in by_tier.get(prior_tier, [])
            ]
            if prior_unlocks:
                urgent_rule_by_tier[tier] = own & HasAll(*prior_unlocks)
                continue
        urgent_rule_by_tier[tier] = own

    urgent_quest_nos = set(TIER_URGENT_QUEST_NOS.values())

    for quest in world.quest_pool:
        own = Has(unlock_item_name(quest))
        if quest["quest_no"] in urgent_quest_nos:
            rule = urgent_rule_by_tier.get(quest["quest_level"], own)
        else:
            urgent_rule = urgent_rule_by_tier.get(quest["quest_level"])
            if urgent_rule is not None:
                rule = own & urgent_rule
            else:
                # No urgent for this tier (QL2 — no chain).
                rule = own
        for loc_name in quest_clear_location_names(quest):
            world.set_rule(world.get_location(loc_name), rule)


def set_completion_condition(world: MHRiseWorld) -> None:
    """The player has received the Victory item. Same condition both modes
    — what locks Victory differs (goal monster hunt vs Comeuppance clear)
    but Victory itself is the completion signal."""
    world.multiworld.completion_condition[world.player] = (
        lambda state: state.has("Victory", world.player)
    )

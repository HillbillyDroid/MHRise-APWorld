"""Per-slot options for the MH Rise apworld.

v1 keeps the option surface minimal: just the include-Sunbreak toggle. The
starting monster (the one whose license is precollected so the player can
hunt from t=0) is chosen at random in `world.generate_early` from the world's
in-pool monsters; there's no option to pick it.
"""

from __future__ import annotations

from dataclasses import dataclass

from Options import DefaultOnToggle, PerGameCommonOptions, Range, Toggle


class IncludeSunbreak(DefaultOnToggle):
    """Include Sunbreak monsters (and their subspecies / Risen variants) in
    the world. When disabled, only base-game Rise monsters are randomized."""

    display_name = "Include Sunbreak"


class IncludeRisen(Toggle):
    """Include Risen elder dragons (Anomaly Investigation endgame —
    Risen Kushala Daora, Chameleos, Teostra, Shagaru Magala, Crimson
    Glow Valstrax). Default off because they are post-credits / very
    high difficulty. Has no effect when Sunbreak is disabled."""

    display_name = "Include Risen"


class IncludeWeapons(DefaultOnToggle):
    """Add weapon-type licenses to the pool. When enabled, weapon
    licenses fill the spare itempool slots (after monster licenses);
    the player needs the license for their currently-equipped weapon to
    complete a hunt (client-side soft gate). One random weapon license
    is always precollected."""

    display_name = "Include Weapons"


class MonsterCount(Range):
    """Number of monsters randomly drawn into the world. Determines how
    many hunts are randomized. Clamped to the available pool size at
    generation time (max 32 with Sunbreak off, 72 with Sunbreak on).
    Min 2 — need a distinct starter and goal."""

    display_name = "Monster Count"
    range_start = 2
    range_end = 72
    default = 15


@dataclass
class MHRiseOptions(PerGameCommonOptions):
    include_sunbreak: IncludeSunbreak
    include_risen: IncludeRisen
    include_weapons: IncludeWeapons
    monster_count: MonsterCount

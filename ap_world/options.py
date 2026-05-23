"""Per-slot options for the MH Rise apworld.

Two mutually-exclusive modes via the `mode` option:
- HuntAThon (default): per-monster license soft-gate. All other options
  (IncludeSunbreak / IncludeRisen / IncludeWeapons / WeaponPool /
  MonsterCount) apply here.
- QuestRando: per-quest unlock items hard-gate village quests; each quest's
  spawned monster is randomly swapped. Goal = clearing "Comeuppance".
  Other options are silently ignored in this mode.
"""

from __future__ import annotations

from dataclasses import dataclass

from Options import Choice, DefaultOnToggle, OptionSet, PerGameCommonOptions, Range, Toggle

from .data.weapons import WEAPONS

_WEAPON_NAMES = {w["name"] for w in WEAPONS}


class Mode(Choice):
    """Game mode.

    - `hunt_a_thon` (default): hunting a large monster requires its license.
      Licenses are scattered across the multiworld. Standard hunt-for-keys
      loop. IncludeSunbreak / IncludeRisen / IncludeWeapons / WeaponPool /
      MonsterCount all apply.
    - `quest_rando`: per-quest unlocks hard-gate the village questboard;
      each randomized village quest's boss monster is swapped to a random
      other monster. Goal = clearing the final village urgent quest
      "Comeuppance" (its boss stays as the intended Magnamalo). The other
      options are silently ignored in this mode."""

    display_name = "Mode"
    option_hunt_a_thon = 0
    option_quest_rando = 1
    default = 0


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


class WeaponPool(OptionSet):
    """Restrict which weapon-type licenses are eligible for the pool
    (and for the precollected starter weapon). Defaults to all 14
    weapons. To play with a smaller set, list the weapon names you
    want — e.g.:

        weapon_pool:
          - Long Sword
          - Bow
          - Switch Axe

    Must contain at least one valid weapon name. Names are
    case-sensitive and must match the entries in `data/weapons.py`.
    No effect when `include_weapons` is disabled."""

    display_name = "Weapon Pool"
    valid_keys = _WEAPON_NAMES
    default = _WEAPON_NAMES


class MonsterCount(Range):
    """Number of monsters randomly drawn into the world. Determines how
    many hunts are randomized. Clamped to the available pool size at
    generation time (max 32 with Sunbreak off, 72 with Sunbreak on).
    Min 3 — at N=2 the spare-slot budget is too tight to fit weapon
    licenses without overrunning available locations."""

    display_name = "Monster Count"
    range_start = 3
    range_end = 72
    default = 15


@dataclass
class MHRiseOptions(PerGameCommonOptions):
    mode: Mode
    include_sunbreak: IncludeSunbreak
    include_risen: IncludeRisen
    include_weapons: IncludeWeapons
    weapon_pool: WeaponPool
    monster_count: MonsterCount

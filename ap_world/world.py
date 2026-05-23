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
from .data.monsters import MONSTERS, SUNBREAK_MONSTERS
from .data.quests import EnemyLv, QuestType, QUESTS
from .data.weapons import WEAPONS
from .options import Mode
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

    # Populated by generate_early (HuntAThon only). The randomly-chosen
    # subset of monsters this seed actually uses — drives location
    # creation, item pool, rules, and the slot_data em_type map.
    seed_monsters: list[dict]

    # Populated by generate_early (QuestRando only).
    # quest_pool: every EnemyLv.Village quest with a real boss (the
    # universe of locations sent on clear). Source of truth for "is
    # this quest part of the seed?" downstream of generate_early.
    quest_pool: list[dict]
    # The goal quest (Comeuppance, quest_no=501). Boss NOT swapped;
    # its Clear location is locked with Victory.
    goal_quest: dict
    # quest_no -> new boss em_type. The Lua client applies these by
    # mutating QuestData._BossEmType[0] / _TgtEmType[0] on the
    # initQuestDataDictionary post-hook (Probe 3 idiom). Training
    # quests and the goal quest are NOT in this map (vanilla bosses
    # preserved).
    quest_swaps: dict[int, int]

    def generate_early(self) -> None:
        if self.options.mode.value == Mode.option_quest_rando:
            self._generate_early_questrando()
        else:
            self._generate_early_huntathon()

    def _generate_early_huntathon(self) -> None:
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
        assert n >= 3, "monster_count Range should enforce min=3"

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

    def _generate_early_questrando(self) -> None:
        """QuestRando mode (swap-only design).

        Vanilla village quest progression drives questboard visibility:
        the engine handles tier unlocks as the player clears each
        tier's urgent normally. AP randomization is **only** the boss
        monster of each village quest — every quest with a randomizable
        boss gets a random swap. Quest CLEARS send AP location checks.

        Quest pool: every `EnemyLv.Village` quest with a real boss
        (`monster_bucket == "monster"`, including training quests so
        the player can clear them and advance to QL2). Goal is
        Comeuppance (QL5 Magnamalo), not swapped.

        Swap pool (which monsters can replace a quest's boss): the
        per-host-quest set of monsters Capcom themselves placed as a
        boss on **the host quest's map** in some vanilla quest (any
        rank). The relevant compatibility axis is `(em_type, map_no)`,
        not just em_type: live testing showed Barroth crash on
        ShrineRuins and Zinogre crash on FrostCaverns even though
        both are ordinary Rise village bosses — Barroth had never
        been authored for ShrineRuins, Zinogre never for
        FrostCaverns. The missing data is per-map (spawn nodes,
        navmesh hookups, scripted intro camera) rather than per-rank
        stat tables. Lunagaron-on-ShrineRuins worked because some MR
        quest puts Lunagaron there.

        `IncludeSunbreak` widens the per-map pool by allowing
        Sunbreak-DLC monsters as swap targets; `IncludeRisen` is a
        no-op for the current catalog (no vanilla quest uses a Risen
        variant) but stays wired.

        Training quests are in the pool (so the player gets an AP
        check for clearing them, which they MUST do to advance the
        engine's tier gating), but they are NOT swapped — their
        clear logic is more than "kill the target", so a swap
        soft-locks the tutorial.

        No item/quest-unlock layer in this mode — visibility is
        engine-driven. The itempool is filled with Poogie filler;
        future work can layer rarity-license / crafting-material AP
        items on top.
        """
        village_with_monster = [
            q for q in QUESTS
            if q["enemy_level"] == EnemyLv.Village
            and q["monster_bucket"] == "monster"
        ]
        if not village_with_monster:
            raise ValueError(
                "QuestRando quest pool is empty — quest catalog out of sync"
            )

        goal_quest = next(
            (q for q in village_with_monster if q["quest_no"] == items.COMEUPPANCE_QUEST_NO),
            None,
        )
        if goal_quest is None:
            raise ValueError(
                f"goal quest (quest_no={items.COMEUPPANCE_QUEST_NO}, Comeuppance) "
                "not found in village-with-monster pool — quest catalog out of sync"
            )
        self.goal_quest = goal_quest
        self.quest_pool = list(village_with_monster)

        # Per-map safe-swap pools: monsters Capcom placed as a boss
        # on each map in any vanilla quest. Built from the full
        # catalog (all ranks, all sources), then filtered by
        # non-randomizable / DLC / Risen tags + options.
        em_to_monster = {
            m["em_type"]: m
            for m in MONSTERS + SUNBREAK_MONSTERS
            if "non-randomizable" not in m["tags"]
        }
        include_sunbreak = bool(self.options.include_sunbreak.value)
        include_risen = bool(self.options.include_risen.value)

        def _eligible(em: int) -> bool:
            mon = em_to_monster.get(em)
            if mon is None:
                return False
            if mon["dlc"] == "sunbreak" and not include_sunbreak:
                return False
            if "risen" in mon["tags"] and not include_risen:
                return False
            return True

        map_to_safe_ems: dict[Any, list[int]] = {}
        for q in QUESTS:
            if q["boss_em_type"] == 0:
                continue
            if q["monster_bucket"] != "monster":
                continue
            if not _eligible(q["boss_em_type"]):
                continue
            map_to_safe_ems.setdefault(q["map_no"], set()).add(q["boss_em_type"])
        # Convert sets to sorted lists so self.random.choice is
        # deterministic given the seed.
        map_to_safe_ems = {mp: sorted(s) for mp, s in map_to_safe_ems.items()}

        # Swap every non-goal, non-training quest. Training quests
        # stay vanilla (their clear logic isn't a simple kill) — the
        # engine still needs them cleared to advance tiers.
        self.quest_swaps = {}
        for quest in self.quest_pool:
            if quest["quest_no"] == goal_quest["quest_no"]:
                continue
            if QuestType.TRAINING in quest["quest_type"]:
                continue
            candidates = map_to_safe_ems.get(quest["map_no"])
            if not candidates:
                # No safe target authored for this map under current
                # options — leave the quest vanilla rather than crash.
                continue
            target_em = self.random.choice(candidates)
            self.quest_swaps[quest["quest_no"]] = target_em

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
        """Send client-side config to the in-game Lua plugin."""
        mode_str = (
            "quest_rando"
            if self.options.mode.value == Mode.option_quest_rando
            else "hunt_a_thon"
        )
        slot_data: dict[str, Any] = {
            "world_version": WORLD_VERSION,
            "mode": mode_str,
        }
        if self.options.mode.value == Mode.option_quest_rando:
            # quest_no keys MUST be strings — REFramework's Lua VM
            # mishandles int-keyed tables (see CLAUDE.md gotcha).
            slot_data["quest_swaps"] = {
                str(qn): em for qn, em in self.quest_swaps.items()
            }
            # Display name (English where dumper resolved it) per
            # quest_no, so the client tracker / chat can show titles
            # without shipping the whole quests.py.
            slot_data["quest_names"] = {
                str(q["quest_no"]): items.quest_display_name(q)
                for q in self.quest_pool
            }
            # Set of village quest_nos that send AP location checks
            # on clear. The client uses this to decide whether to
            # send a check (or silently drop, for hub / event clears).
            # Value is just `1` (placeholder) — only key membership matters.
            slot_data["quest_locations"] = {
                str(q["quest_no"]): 1 for q in self.quest_pool
            }
            slot_data["goal_quest"] = self.goal_quest["quest_no"]
            slot_data["include_sunbreak"] = bool(self.options.include_sunbreak.value)
            slot_data["include_risen"] = bool(self.options.include_risen.value)
        else:
            # The critical piece is `monster_em_type_map`: a dict from
            # license item name to the in-game EmType integer the death
            # hook reads off `<EnemyType>k__BackingField`.
            em_type_map = {
                items.license_item_name(m): m["em_type"]
                for m in self.seed_monsters
            }
            slot_data.update({
                "monster_em_type_map": em_type_map,
                "include_sunbreak": bool(self.options.include_sunbreak.value),
                "starting_monster": self.starting_monster["name"],
                "goal_monster": self.goal_monster["name"],
                "include_weapons": bool(self.options.include_weapons.value),
                "monster_count": len(self.seed_monsters),
            })
            if bool(self.options.include_weapons.value):
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

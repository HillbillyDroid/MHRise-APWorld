"""Dump the per-map QuestRando swap pools to JSON for reference.

Mirrors the `map_to_safe_ems` construction in
ap_world/world.py:_generate_early_questrando. For each map, lists every
em_type Capcom authored as a boss on that map across the full quest
catalog (any rank, any source), with the same filters applied:
- monster_bucket == "monster"
- boss_em_type != 0
- "non-randomizable" tag excluded
- Sunbreak-DLC monsters excluded unless include_sunbreak
- Risen variants excluded unless include_risen

Dumps three variants of the map so you can see how the pool widens:
- rise_only:        include_sunbreak=False, include_risen=False
- rise_and_sunbreak: include_sunbreak=True,  include_risen=False
- all_including_risen: include_sunbreak=True, include_risen=True

Usage: python debug_tools/dump_map_swap_pools.py
Output: debug_tools/map_swap_pools.json
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent


def _load(name: str, relpath: str) -> ModuleType:
    path = REPO_ROOT / relpath
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


monsters_mod = _load("_ap_monsters", "ap_world/data/monsters.py")
quests_mod = _load("_ap_quests", "ap_world/data/quests.py")

MONSTERS = monsters_mod.MONSTERS
SUNBREAK_MONSTERS = monsters_mod.SUNBREAK_MONSTERS
QUESTS = quests_mod.QUESTS
MapNoType = quests_mod.MapNoType


def build_pool(include_sunbreak: bool, include_risen: bool) -> dict[str, list[dict[str, Any]]]:
    em_to_monster = {
        m["em_type"]: m
        for m in MONSTERS + SUNBREAK_MONSTERS
        if "non-randomizable" not in m["tags"]
    }

    def eligible(em: int) -> bool:
        mon = em_to_monster.get(em)
        if mon is None:
            return False
        if mon["dlc"] == "sunbreak" and not include_sunbreak:
            return False
        if "risen" in mon["tags"] and not include_risen:
            return False
        return True

    map_to_safe_ems: dict[Any, set[int]] = {}
    for q in QUESTS:
        if q["boss_em_type"] == 0:
            continue
        if q["monster_bucket"] != "monster":
            continue
        if not eligible(q["boss_em_type"]):
            continue
        map_to_safe_ems.setdefault(q["map_no"], set()).add(q["boss_em_type"])

    em_to_name = {m["em_type"]: m["name"] for m in MONSTERS + SUNBREAK_MONSTERS}

    out: dict[str, list[dict[str, Any]]] = {}
    for map_no, ems in map_to_safe_ems.items():
        map_name = map_no.name if hasattr(map_no, "name") else str(map_no)
        entries = sorted(
            ({"em_type": em, "name": em_to_name.get(em, f"em_{em}")} for em in ems),
            key=lambda d: d["name"],
        )
        out[map_name] = entries
    return dict(sorted(out.items()))


def main() -> None:
    payload = {
        "rise_only": build_pool(include_sunbreak=False, include_risen=False),
        "rise_and_sunbreak": build_pool(include_sunbreak=True, include_risen=False),
        "all_including_risen": build_pool(include_sunbreak=True, include_risen=True),
    }
    out_path = REPO_ROOT / "debug_tools" / "map_swap_pools.json"
    out_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"wrote {out_path}")
    for variant, by_map in payload.items():
        total = sum(len(v) for v in by_map.values())
        print(f"  {variant}: {len(by_map)} maps, {total} (map, em) pairs")


if __name__ == "__main__":
    main()

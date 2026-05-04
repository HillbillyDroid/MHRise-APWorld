# debug_tools/

Dev-only REFramework plugin for spelunking MH Rise managed types.
**Never ships to players** — the release workflow's `AUTORUN_FILES`
allow-list excludes this folder by construction.

JSON output lands at `<install>/reframework/data/<name>` — confirmed
by observation, matches the CLAUDE.md gotcha. The older one-shot
dumpers' in-window claim that they wrote next to `MonsterHunterRise.exe`
was wrong.

## Install

1. Copy `MHRiseDebug.lua` to
   `<game install root>/reframework/autorun/MHRiseDebug.lua`.
2. Open REFramework overlay (Insert) and click "Reset Scripts".
3. A "MHRise Debug" button appears in the script-drawn UI. Click it
   to open the window.

No `lua-apclientpp.dll` required — this plugin is independent of the
AP client and does not connect to an AP server.

## Sections

### Type dump

Type a managed-type name (default: `snow.QuestManager`) and click
Dump. The plugin walks `sdk.find_type_definition(name)` and prints:

- parent type
- every field — name, type, `static`/`literal` flags, value (for
  static fields where `get_data(nil)` returns a primitive)
- every method — name, return type, parameter types

Inline preview renders in a scrollable child pane. The same payload
is also written as JSON to
`<install>/reframework/data/mhrise_type_<sanitized>.json` (slashes /
dots in the type name → underscores).

Unresolvable types print `<type not found: ...>` inline and log to
`re2_framework_log.txt`.

### Tree search

Case-insensitive substring search across the full type database.
Enumeration goes through managed reflection
(`System.AppDomain.CurrentDomain.GetAssemblies()` →
`Assembly.GetTypes()`), since this REFramework build doesn't expose a
direct TDB enumeration API. Three checkboxes — match types, match
fields, match methods — at least one must be on (all default on).

Result lines are formatted:
- `<type>` — type name match
- `<type>.<field>` — field match
- `<type>:<method>(<params>)` — method match

Hard cap: 500 results. Results past the cap are dropped and a
`(truncated, refine keyword)` note appears at the top. Results also
written to
`<install>/reframework/data/mhrise_search_<sanitized_keyword>.json`.

Empty keyword → `Enter a keyword first` (no walk performed; an empty
substring match would hit the cap instantly with useless output).

## Verification recipe

1. Default input `snow.QuestManager` → click Dump. Preview should
   list `setQuestFail`, `isActiveQuest` among methods.
2. Tree search `setQuestFail`, defaults on → at least one hit on
   `snow.QuestManager:setQuestFail(...)`.
3. Tree search `EmTypes` → matches `snow.enemy.EnemyDef.EmTypes` and
   the individual enum field rows on it.

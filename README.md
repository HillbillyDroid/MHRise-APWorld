# Monster Hunter Rise Archipelago Randomizer

An [Archipelago](https://archipelago.gg/) (AP) multiworld randomizer for
**Monster Hunter Rise + Sunbreak**.

Hunting large monsters requires a **license**. Each monster's license is
an Archipelago item placed somewhere in the multiworld. Hunting a
licensed monster sends checks to the AP server, which causes the
multiworld to release more items — including more licenses. Standard
hunt-for-keys loop.

The license requirement is a **soft gate**: nothing about the game is
blocked or hidden, the player can fight any monster — but the check
only sends when the player holds the matching license. An optional
weapon-license layer (on by default) adds the same gate over the 14
weapon types.

## Project layout

The project ships as **two separate distributables**, each used by a
different audience:

- **`ap_world/`** — Python Archipelago world. Generates the multiworld.
  Built into `mhrise.apworld` via `python ap_world/build_apworld.py`.
  Only the seed host needs this. **Requires Archipelago 0.6.7 or
  higher** — generation will fail on older versions.
- **`client/`** — REFramework Lua plugin (plus the bundled
  `lua-apclientpp.dll`). Runs in-game and talks to the AP server over
  websocket. Every player needs this installed in their game folder.

## Getting started

Player setup, including REFramework install, file placement, and
in-game connect flow, lives in
[ap_world/docs/setup_en.md](ap_world/docs/setup_en.md). That file is
also rendered as the official setup guide on archipelago.gg.

A high-level overview of how randomization affects the game lives in
[ap_world/docs/en_Monster Hunter Rise.md](ap_world/docs/en_Monster%20Hunter%20Rise.md)
(also rendered on archipelago.gg).

## Disclaimer

This mod may be considered cheating. MH Rise has no known anti-cheat
and there are no reports of bans for using mods, but Capcom's stance
could change. Online play with this mod installed is **discouraged** —
stick to singleplayer or offline. Back up your save before playing.
You use this mod at your own risk; see
[ap_world/docs/setup_en.md](ap_world/docs/setup_en.md) for the full
disclaimer.

## License

[MIT](LICENSE.md). The bundled
`lua-apclientpp.dll` carries its own license at
[client/lua-apclientpp-license.txt](client/lua-apclientpp-license.txt).

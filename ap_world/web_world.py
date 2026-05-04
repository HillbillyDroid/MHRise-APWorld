"""WebWorld config — how the apworld appears on the AP website."""

from __future__ import annotations

from BaseClasses import Tutorial
from worlds.AutoWorld import WebWorld


class MHRiseWebWorld(WebWorld):
    game = "Monster Hunter Rise"

    theme = "grass"

    setup_en = Tutorial(
        "Multiworld Setup Guide",
        "A guide to setting up Monster Hunter Rise for MultiWorld.",
        "English",
        "setup_en.md",
        "setup/en",
        ["SolomonW"],
    )

    tutorials = [setup_en]

    # Not set: option_groups / options_presets. The option surface is
    # small enough that the website's default flat list is
    # fine. Add them here if the option count grows or we want named
    # preset configurations on the YAML generator page.

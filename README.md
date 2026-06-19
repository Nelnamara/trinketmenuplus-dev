# TrinketMenu Plus

> **Requires:** [TrinketMenu](https://www.curseforge.com/wow/addons/trinketmenu) · **WoW:** 12.0.7 (Midnight) · **Author:** Nelnamara

TrinketMenu Plus adds two fully configurable spell/macro action boxes alongside the TrinketMenu bar, plus a built-in aim-assist overlay for ground-targeted spells (e.g. Force of Nature, Starfall, Rain of Fire). Both boxes use `SecureActionButtonTemplate` exclusively and are fully combat-safe — no taint, no blocked actions.

---

## Features

- **Two independent spell/macro boxes** (Box A and Box B) docked to TrinketMenu
- **Four cast modes** per box — `@cursor`, `@player`, `@target`, or raw macro
- **Aim-assist overlay** — when a box is in `@cursor` mode with a hostile target in range, a glow ring appears near the target's feet to show where the spell will land
- **Three-click scheme** with no taint:
  - **Left-click** — cast using the configured mode
  - **Right-click** — instant `@target` cast (bypasses aim, fires immediately)
  - **Ctrl+Right-click** — opens the spellbook/macro picker for that box
- **Spellbook picker popup** — browse and assign any known, castable, non-passive spell without typing
- **Cooldown overlay** on each box
- **Minimap button** (supports LibDBIcon-1.0 if present, falls back to a hand-rolled button)
- **Config panel** — adjust box size, scale, glow color, aim feet-offset
- **Dock** to any side of TrinketMenu (left / right / top / bottom)
- **Lock/unlock** to prevent accidental dragging

---

## Requirements

- [TrinketMenu](https://www.curseforge.com/wow/addons/trinketmenu) *(required)* — the core bar this addon attaches to
- LibDBIcon-1.0 *(optional)* — minimap button integrates with MBB, Bazooka, etc. if present

---

## Installation

1. Download the latest release zip
2. Extract to `World of Warcraft\_retail_\Interface\AddOns\`
   - The folder should be named **`TrinketMenuPlus`**
   - It should contain `TrinketMenuPlus.lua` and `TrinketMenuPlus.toc`
3. Make sure **TrinketMenu** is also installed and enabled
4. Log in — the two boxes will appear attached to the TrinketMenu bar

> **No configuration is needed to get started.** The boxes are empty by default. Use `/tmp a spell "Spell Name"` or Ctrl+Right-click a box to assign spells.

---

## Usage

### Assigning Spells

The easiest way is to **Ctrl+Right-click** any box — a spellbook popup opens and you can click any spell to assign it to that box.

Alternatively, use slash commands:

```
/tmp a spell "Force of Nature"
/tmp b spell "Starsurge"
```

### Slash Commands

All commands start with `/tmp`.

- **`/tmp a spell "Name"`** / **`/tmp b spell "Name"`** — Assign a spell to Box A / B
- **`/tmp a item "Name"`** — Assign an item to a box
- **`/tmp a macro "/cast ..."`** — Assign a raw macro to a box
- **`/tmp a mode cursor`** — Set cast mode (`cursor` / `player` / `target` / `macro`)
- **`/tmp a clear`** — Clear a box
- **`/tmp a config`** — Open the spellbook picker for a box
- **`/tmp dock right`** — Dock to a side of TrinketMenu (`left` / `right` / `top` / `bottom`)
- **`/tmp config`** — Open the config panel
- **`/tmp lock`** / **`/tmp unlock`** — Lock/unlock position
- **`/tmp status`** — Print current configuration and aim-assist debug info

### Cast Modes

- **`cursor`** — Casts at your mouse cursor position in the world (`@cursor`)
- **`player`** — Casts centered on your character (`@player`)
- **`target`** — Casts on your current target (`@target`)
- **`macro`** — Fires a raw macro you provide via `/tmp a macro "..."`

### Aim Assist

When a box is in **cursor mode** and all conditions are met, a pulsing glow ring appears near your target's feet to show exactly where a `@cursor` cast will land:

- **Shows when:** cursor mode · spell assigned · hostile target in range · spell ready · not channeling
- **Glow ring** tracks the target's nameplate position in real time
- **Left-click** the icon to cast at cursor; the ring shows where your cursor needs to be
- **Right-click** the icon for an instant `@target` cast if you don't want to aim

> **Combat note:** Due to Midnight (12.0.7) secure frame restrictions, the clickable button freezes at its last position when you enter combat. The visual glow ring continues tracking the target freely. The button snaps back to the correct position immediately when combat ends.

### Config Panel

Open with `/tmp config` or click the minimap button.

- **Box Size** — pixel width/height of each box
- **Scale** — overall scale multiplier
- **Glow Color** — RGB sliders for the aim-assist ring color
- **Feet Offset** — vertical offset in pixels for the aim ring (tune to your screen resolution / camera angle)

---

## Known Issues

- **Aim button doesn't track target during combat** — by design; a Midnight secure-frame restriction. The visual ring still tracks and the button re-syncs on combat end.
- The spellbook picker may briefly show iconless spells on first open — cosmetic; icons load on the second open or after a `/reload`.
- Right-click fires `@target` even when the target is out of range — no range check on the secure macro; WoW shows the normal "out of range" error.
- TrinketMenu must be visible for the dock to position correctly — log out and back in if boxes appear at 0,0 on first install.

---

## Compatibility / Midnight Notes

Built for Midnight's secure-frame rules: the aim button syncs position via `GetCenter()` → UIParent absolute coords rather than a secure anchor chain (which would trigger `ADDON_ACTION_BLOCKED`), and re-syncs on combat exit. The cooldown overlay reads timing inside a `pcall` closure to avoid touching secret fields.

---

## Changelog

### v0.3.1
- Minimap button now points at the addon artwork; added AddOns-list `IconTexture`
- Interface bumped to 120007
- Release pipeline fixes — corrected the CurseForge/Wago secret names and project IDs (`X-Wago-ID`, `WAGO_API_TOKEN`)

### v0.3.0
- Full architecture rewrite — boxes now use `SecureActionButtonTemplate` exclusively (removed `ActionButtonTemplate` which was overriding `OnClick` and breaking macro execution)
- Aim assist: replaced direct secure-frame repositioning with a mover-proxy pattern
- **Midnight (12.0.5) fix:** Decoupled aim button from mover anchor chain — in Midnight, frames referenced by a secure frame's anchors become implicitly protected, causing `ClearAllPoints` to trigger `ADDON_ACTION_BLOCKED`. Aim button now syncs position via `GetCenter()` → UIParent absolute coords, bypassing the anchor chain entirely
- Added `PLAYER_REGEN_ENABLED` handler to re-sync aim button position immediately on combat exit
- Cooldown overlay wrapped in anonymous-function `pcall` to avoid touching secret fields outside a closure
- Spellbook picker popup: tabs for Spells and Macros
- Config panel: size, scale, color, backdrop, feet-offset
- LibDBIcon-1.0 support for minimap button

### v0.1.0
- Initial release
- Two configurable boxes docked to TrinketMenu
- Basic spell/macro assignment via slash commands
- Aim assist overlay for `@cursor` spells
- Left / right-click bindings

---

## Roadmap

<details>
<summary>Planned</summary>

- **Per-box glow color** — independent color setting per box instead of shared
- **Keybind support** — register each box as a bindable action (no mouse click required)
- **Range indicator** — tint the box icon red when the assigned spell is out of range
- **Aim ring shape options** — circle, crosshair, or arrow variants
- **Profiles** — save and switch named configurations (e.g. raid ST vs M+ AoE)
- **Multi-box expansion** — optional 3rd/4th box for players with more spells to track

</details>

---

## Feature Requests

<details>
<summary>How to request</summary>

Open an issue on [GitHub](https://github.com/Nelnamara/trinketmenuplus-dev/issues) or leave a CurseForge comment — include your spec and the spell/behavior you want.

</details>

---

## License

Personal use. Not affiliated with the original TrinketMenu addon.

# TrinketMenu Plus — CLAUDE.md

Companion to **TrinketMenu** for WoW Midnight (12.x). Author: Nelnamara.
Adds two configurable spell/macro/item action boxes (A/B) beside TrinketMenu, with
aim assist for ground-targeted spells, a cooldown overlay, and a minimap button.

## ⚠️ Repo branch is `master`, not `main`
Push with `git push origin master`. (The rest of the suite uses `main`.)

## Files
- `TrinketMenuPlus.lua` — single-file addon. Deployed AddOn folder: `TrinketMenuPlus`.
- Depends on **TrinketMenu** (`## Dependencies: TrinketMenu`). OptionalDeps: LibStub, LibDBIcon-1.0, LibDataBroker-1.1.

## Notes
- Minimap button: **LibDBIcon-1.0 primary path** (so MBB/Bazooka pick it up if present), hand-rolled fallback when LibDBIcon is absent. Both icon paths point at `Media\minimap.png` (a square crop — LibDBIcon frames it). AddOns-list `IconTexture` → `Media\icon.png`.
- Aura spellIds are SECRET on Midnight; use `C_UnitAuras.GetPlayerAuraBySpellID(knownID)`.

## Slash
`/tmp` · `/tmp config` (or click the minimap button)

## Build / release / deploy
- BigWigs packager on **`v*` tag push**. Secrets: CurseForge **`CURSFORGE_API_KEY`** (misspelled, leave as-is), Wago **`WAGO_API_TOKEN`** (X-Wago-ID set in TOC).
- Local test: copy to `D:\World of Warcraft\_retail_\Interface\AddOns\TrinketMenuPlus\`.
- Current version: **0.3.1** (Interface 120007).

## Conventions
- **Never** append a `Co-Authored-By` trailer to commits.

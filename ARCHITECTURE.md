# Runtime architecture

## Repository layout

`src/` is the mod: exactly the files the game loads and every release ships.
Everything else is development-only: `docs/`, `images/`, `tests/` and metadata.

## UI Lua (`src/ui.xml`, `src/ui/swap_crew/`)

Pure UI Lua, no MD and no saved state (`save="false"`). `ui.xml` loads the
modules in order into the `menus` environment after `ego_detailmonitor`; they
share the global table `SwapCrew`.

| Module | Responsibility |
|---|---|
| `ffi.lua` | Declares only the FFI types/functions vanilla has not declared yet (re-declaring vanilla's anonymous structs would create incompatible types); `SwapCrew.log`, `seedKey`, `id64`, `text`. |
| `model.lua` | Pure logic, no engine calls: star rating, at-least-N counts, candidate choice (weakest qualifying, or highest for "best"; ties: same ship, same sector, distance). Covered by `tests/test_lua.py`. |
| `scheduler.lua` | Deferred and polled callbacks on Helper's shared one-time update list, always inside `pcall`; timeouts in game time. |
| `candidates.lua` | Player ships, crew rosters, and the service crew candidates with their skill for the target post or role. |
| `target.lua` | Turns MapMenu's `contextMenuData` into a target (`post_occupied`, `post_empty`, `crew`) and decides whether a swap is allowed. |
| `executor.lua` | Runs a swap with native engine calls and the follow-up steps that wait for the engine to settle. |
| `dialog.lua` | Context menu content: "Swap crew" entry, "Recruit from crew" entry, and the replacement selection list. |
| `menu_hooks.lua` | Wraps MapMenu fields (`setupCrewInfoSubmenuRows`, `prepareInfoContext`, `createInfoContext`) and retries until MapMenu exists. |

Flow: right-click a crew row in the map's object info -> vanilla
`prepareInfoContext` -> `info_context` frame -> our `createInfoContext` wrapper
appends "Swap crew". Choosing it re-renders the same frame with
`contextMenuData.swapcrew` set, which makes the wrapper draw `dialog.lua`'s
selection list instead of vanilla content. Empty pilot/manager rows get custom
rowdata so they become right-clickable and open the "Recruit from crew" entry.

## Tests

`tests/test_lua.py` (pytest + lupa's LuaJIT) compiles every module, checks
`ui.xml` lists them all, and tests `model.lua`. Run via `just lua-tests`.

## Translations

`src/t/0001.xml` is the English source for text page 990483; the 15
`0001-lNNN.xml` files carry the same page/text ids for every other game locale.

## Release tooling

Release, publication, translation checks, `just link` and `just log` come from
x4-modkit; see its README and ARCHITECTURE.md.

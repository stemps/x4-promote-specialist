# Runtime architecture

## Repository layout

`src/` is the mod: exactly the files the game loads and every release ships.
Everything else is development-only: `docs/`, `images/`, `tests/` and metadata.

## UI Lua (`src/ui.xml`, `src/ui/promote_specialist/`)

Pure UI Lua, no MD and no saved state (`save="false"`). `ui.xml` loads the
modules in order into the `menus` environment after `ego_detailmonitor`; they
share the global table `PromoteSpecialist`.

| Module | Responsibility |
|---|---|
| `ffi.lua` | Declares only the FFI types/functions vanilla has not declared yet (re-declaring vanilla's anonymous structs would create incompatible types); `PromoteSpecialist.log`, `seedKey`, `id64`, `text`. |
| `model.lua` | Pure logic, no engine calls: star rating, exactly-N-stars counts, the candidate list sorted best first (ties: same ship, same sector, distance), the star filter, and best/worst as indexes into a list. Covered by `tests/test_lua.py`. |
| `scheduler.lua` | Deferred and polled callbacks on Helper's shared one-time update list, always inside `pcall`; timeouts in game time. |
| `candidates.lua` | Player ships, crew rosters, free crew slots, and the candidates from the chosen sources (service and marine crew seeds; other ships' AI pilots as entities, for ship pilot targets only) with their combined and individual skills for the target post or role. |
| `target.lua` | Turns MapMenu's `contextMenuData`, or a whole ship/station, into a target (`post_occupied`, `post_empty`, `crew`) and decides whether a swap, and staying aboard, is allowed. |
| `executor.lua` | Runs a promotion with native engine calls and the follow-up steps that wait for the engine to settle; the replaced person either swaps to the candidate's ship and role or stays aboard as service crew. Pilot candidates go through vanilla's captain exchange. |
| `manager_move.lua` | Moves another station's manager into a station's manager post: directly into an empty post, otherwise via a ship stopover (candidate to service crew on the nearest ship, settle, dismissal flow, old manager into the candidate's old post), with a rollback if the chain breaks. |
| `candidate_card.lua` | The dialog's "Candidate" card: the person under the cursor, their skills, and the best/previous/next/worst buttons. |
| `dialog.lua` | Context menu content: the "Promote specialist" entries and the selection dialog (current person with stay/swap choice, crew role toggles, star filter, card, promote button). Holds the session-only role toggles. |
| `interact_hooks.lua` | Wraps `InteractMenu.prepareActions` to add "Promote specialist" for player ships and stations opened from the map, and hands the object back to MapMenu. |
| `menu_hooks.lua` | Wraps MapMenu fields (`setupCrewInfoSubmenuRows`, `prepareInfoContext`, `createInfoContext`, `onInteractMenuCallback`) and retries until MapMenu exists. |

Flow: right-click a crew row in the map's object info -> vanilla
`prepareInfoContext` -> `info_context` frame -> our `createInfoContext` wrapper
appends "Promote specialist". Choosing it re-renders the same frame with
`contextMenuData.promotespecialist` set, which makes the wrapper draw `dialog.lua`'s
selection dialog instead of vanilla content. Empty pilot/manager rows get custom
rowdata so they become right-clickable and open the same entry.

Right-clicking a ship or station opens the InteractMenu instead. Its
"Promote specialist" action leaves the menu like vanilla's "Comm" entry
(`Helper.returnFromInteractMenu`) with type `promotespecialist_promote`; MapMenu's
wrapped `onInteractMenuCallback` then opens the dialog for the pilot (ship) or
manager (station) post in its info context.

The dialog never acts on a filter click: the star filter (exactly N stars, or
any) narrows the sorted candidate list to a pool, the card's buttons move a
cursor over that pool, and only the promote button runs
the executor (after re-collecting candidates and re-finding the person by key).

## Tests

`tests/test_lua.py` (pytest + lupa's LuaJIT) compiles every module, checks
`ui.xml` lists them all, and tests `model.lua`. Run via `just lua-tests`.

## Translations

`src/t/0001.xml` is the English source for text page 990483; the 15
`0001-lNNN.xml` files carry the same page/text ids for every other game locale.

## Release tooling

Release, publication, translation checks, `just link` and `just log` come from
x4-modkit; see its README and ARCHITECTURE.md.

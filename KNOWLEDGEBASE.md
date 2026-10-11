# Mod-local Knowledgebase

Durable, non-obvious findings for developing this mod. New entries are headed
`## YYYY-MM-DD - slug`.

## 2026-10-10 - native-crew-swap-paths

Read in the extracted 9.00 files while building the mod. None of this has been
confirmed in-game yet.

- Right-clicking a person in the map's object info never reaches the
  InteractMenu. It goes to `MapMenu.prepareInfoContext` -> mode `info_context` ->
  `menu.createInfoContext` (menu_map.lua:28649, 26123). The sn Interact_Menu_API
  and UIX interact callbacks cannot target persons. Crew rows carry an NPCSeed
  (`info_crewperson`); pilot/manager/ship trader rows carry the entity.
- Row selectability is `not not row.rowdata` and is read only at display time
  (helper.lua:5111), so setting `row.rowdata` on a built row makes it
  right-clickable. Empty pilot/manager rows are `addRow(false)` with `"-"` texts
  (menu_map.lua:15114, 15325).
- Occupied post swap: `SignalObjectWithNPCSeed(holder, "npc__control_dismissed",
  seed, sourceShip)` (vanilla use: menu_playerinfo.lua:6730). The handler
  (npc_state_machines.xml:1971-1996) removes the replacement from the source
  FIRST, then puts the old holder (as the replacement's old role) on the target
  if `people.free > 0`, else on the source. So two full ships swap cleanly; a
  target with room keeps the old holder, and the mod follows up with
  `PerformCrewExchange2(target, source, {demoted})`. The demoted person gets a
  new seed; the mod finds it by roster diff plus name.
- `AssignHiredActor` onto an OCCUPIED post sends the replaced person to the
  target with `force="true"` (conversations.xml:1404), over capacity. The mod
  uses it only for empty posts.
- `PerformCrewExchange2` nets capacity per call, so a one-for-one crew exchange
  works between full ships. Roles travel with the person; a reassign in the same
  frame is ignored (mycu_advanced_crew_transfer finding), so the mod polls
  `ReassignPeople` until `GetPersonRole` reads back the new role.
- Crew pod travel time is clamped to 10 s whenever the estimate exceeds 10 s
  (conversations.xml:1606-1612), plus up to 15 s launch stagger. Vanilla crew
  transfer is therefore distance-based only for short hops.
- Helper's `onUpdate` one-time callback loop has no `pcall` and clears the list
  first: an error in one callback drops every other callback queued that frame
  (helper.lua:922).

## 2026-10-10 - empty-manager-fill-observed

In-game test (user, 9.00): "Recruit from crew" on a station with no manager,
candidate from a ship. `AssignHiredActor(..., "manager")` returned "" and MD
logged `LogAssignedToObject` at once, but the station first listed her as an
employee on board and its manager row stayed "-". She became manager a short
while later, once game time ran. So the manager row (`tradenpc`) seems to show
the new holder only after arrival, not at assignment. Not yet known whether
ship pilots (`assignedaipilot`) behave the same. `executor.lua` logs `post ...
now held by` when the post fills and refreshes the crew view then.

## 2026-10-11 - interact-menu-and-post-holders

Read in the extracted 9.00 files for "Promote specialist" on ships and
stations. Not confirmed in-game yet.

- Right-clicking a ship or station (map or object list) opens the separate
  InteractMenu (`menu_interactmenu.lua`, same `menus` Lua environment) via
  `Helper.openInteractMenu`. Entries come from `menu.prepareActions` and are
  added with `menu.insertInteractionContent(section, entry)`; section `main`
  must already exist. `menu.shown` is true only when opened outside the map.
- An entry leaves the interact menu and returns to the map like vanilla "Comm":
  `Helper.resetUpdateHandler()`, `Helper.clearFrame(menu, 2)` (the file-local
  `config.layer`), `Helper.returnFromInteractMenu(menu.currentOverTable, type,
  param)`, `menu.cleanup()`. That calls `MapMenu.onInteractMenuCallback(type,
  param)`, captured when the interact menu opens, so wrapping it at load works.
- Pilots and managers are entities, not crew seeds; `GetPeopleAfterOrders` does
  not list them. Vanilla moves them between ships only through crew transfer's
  "Exchange captains" (`PerformCrewExchange2(..., 0, 0, true, checkonly)`,
  menu_map.lua:24211, ships only). It has no ship-to-station or
  station-to-station path for managers. The mod therefore offers pilots only
  ship-to-ship (via that exchange) and no manager candidates. Unverified: that
  the exchange also works when the target ship has no pilot (vanilla shows the
  checkbox when either ship has one), and whether the moved pilot keeps its
  entity id (the executor does not rely on it).
- Vanilla "Replace pilot with best crewmember" (menu_map.lua:17654) is a plain
  max search over service and marine crew with `GetPersonCombinedSkill(ship,
  seed, nil, post)` followed by `AssignHiredActor({personcontrollable = ship,
  personseed = best}, ship, post, nil, false)`. There is no manager equivalent.
- Individual skills of a crew seed for an assignment:
  `GetPersonSkillsForAssignment(Skill2[GetNumSkills()+1], seed, ship, role,
  post)`, read at indexes 1..n; `value` is 0-15 and `relevance > 0` marks the
  skills that count for that post or role (menu_map.lua:15733).
- No radio widget exists; vanilla emulates one with checkboxes whose `checked`
  compares against shared state (menu_docked.lua:677).

## 2026-10-11 - manager-move-experiment

Question: can a post-holding entity (station manager, ship pilot) be moved
into another object's control post with `AssignHiredActor` and `actor.entity`
(vanilla "Work somewhere else" hire mode, menu_map.lua:4166)? Measured in-game
(9.00, user's save, `experiment.lua`), debug.txt of 2026-10-11:

- checkonly, 16 entities (8 station managers, 8 ship pilots) per target:
  - occupied station manager post (2 stations): all 16 `postoccupied`.
  - empty station manager post (1 station): all 16 `""` (OK), pilots included.
  - occupied ship pilot post (1 ship): all 16 `""` (OK), managers included.
- Real move, manager into an EMPTY station manager post (1 case): returned
  `""`; within 1 s of game time the target post held the candidate, the source
  station's post was empty, and the entity (same id) sat in the target
  station. No travel time. No further change in the ~80 s watched after that.
- Real move into an OCCUPIED station manager post: refused `postoccupied`
  (6 attempts, 5 candidates, 1 station), nothing changed.
- Not measured: a real move into an occupied ship pilot post (where the
  displaced pilot goes), and any way to vacate an occupied manager post.

## 2026-10-11 - manager-trainee-swap-experiment

Read: a station's only crew role is the group trainee (`trainee_group`,
offered by vanilla hire mode when `CanControllableHaveAnyTrainees`,
menu_map.lua:24509); an entity given that role despawns into the station's
people (npc_state_machines.xml:3142).

Measured in-game (9.00, user's save, debug.txt 2026-10-11, game time
251617-251659, the session ended there):
- `CanControllableHaveAnyTrainees` was false for both stations tried (the HQ
  and a shipyard), so the trainee route was not available there at all.
- Service crew from a ship into the HQ's OCCUPIED manager post with
  `npc__control_dismissed` (the mod's normal post_occupied flow): 11 s later
  the post read empty (`tradenpc` nil) while every checkonly
  `AssignHiredActor` into it still returned `postoccupied`, i.e. the post is
  reserved for the replacement in transit. Whether the replacement arrived,
  and where the old manager went, is unknown: the session ended 42 s after
  the signal, before the 60 s handover poll timed out.
- A manager candidate into that seemingly empty post was therefore refused
  `postoccupied` at stage 2; nothing changed.

## 2026-10-11 - manager-stopover-experiment

Escape pods are not a stopover: they exist only as MD actions `eject_npcs` /
`eject_people`, which eject ALL NPCs or people of an object
(libraries/common.xsd), and the pod self-destructs once docked
(aiscripts/move.escapepod.xml:125-127).

Round 3 of `experiment.lua`: candidate manager -> service crew on the
closest ship that accepts them (`AssignHiredActor(entity, ship, "",
"service")`), then the normal dismissal flow into the target post, then (swap)
the old manager from that ship into the source post. Measured in-game (9.00,
debug.txt 2026-10-11), 2 stations, swap:

- Step A worked both times: the entity became service crew on a ship 3.4-3.6
  km away within 0.4-1 s; the source station's post emptied at once.
- Station 2: dismissal signal 1 s after step A. The old manager became
  service crew on the target station; the candidate's entity (same id) walked
  over and held the post after 14 s; the executor then sent the old manager to
  the stopover ship. Step C did not run: the session ended 3.5 s later.
- Station 1: dismissal signal 0.4 s after step A's assign. Within 0.25 s the
  engine logged `ENTER_worker_at_post: Property lookup failed: $NPC.role.tag`
  and "`Vence Corter ... is in ENTER_worker_move_to_post when something is
  wrong. $NPCRole: null`"; 1 s later the candidate entity was invalid, gone
  from the ship's roster, and never reached the target. The old manager was
  dismissed anyway (service crew on the target). The candidate is presumed
  LOST. INFERRED cause: the signal raced step A's move (the handler,
  npc_state_machines.xml ~1925-2020, reuses an existing NPC instance, clears
  its role and assigns the post while it is still mid-transition), although
  `HasPersonArrived` already returned true.
- The dismissal handler removes the replacement from its old object and
  dismisses the old holder BEFORE it knows the replacement can be placed
  (npc_state_machines.xml ~1975-1990), so a failed replacement loses a person.

Round 4 (same flow, plus: after step A wait until the candidate entity has
despawned or 10 s, then re-check the seed is still settled on the ship).
Measured in-game (9.00, debug.txt 2026-10-11, game time 252164-252318), 3
swaps into the same station, all via the same stopover ship 3.4 km away:

- The candidate entity never despawned on the ship; all 3 settles ended on
  the 10 s fallback (10.1-10.5 s).
- No `something is wrong` or other NPC_State_Machines error in the session (0).
- All 3 step B handovers worked: old manager dismissed 0.3-0.8 s after the
  signal, the candidate's entity walked over and held the post 12-13 s later;
  the executor returned the old manager to the stopover ship 1 s after that.
- Step C ran twice (the third run's log ended 1 s after the return) and both
  times worked: `AssignHiredActor` with the old manager as a seed actor on the
  ship into the source station's empty manager post, checkonly and assign OK,
  post filled 0.6-0.9 s later (as a NEW entity id). A full swap took 36-37 s
  of game time.
- Not measured: stay, a stopover ship or source station far away (other
  sector), more than one stopover ship.

The experiment module was removed on 2026-10-11 and the round 4 flow became
`manager_move.lua` (swap only; Stay is not offered for manager candidates).

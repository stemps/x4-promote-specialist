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

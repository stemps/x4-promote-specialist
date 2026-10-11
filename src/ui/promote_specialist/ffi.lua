-- FFI declarations and logging shared by all Promote Specialist modules.
--
-- Vanilla menus declare most of these in the same Lua state. Their structs are
-- anonymous typedefs, so declaring one again would create a second, incompatible
-- type. Only names that are still missing are declared here.

local ffi = require("ffi")
local C = ffi.C

PromoteSpecialist = PromoteSpecialist or {}
PromoteSpecialist.PAGE = 990483

local function log(fmt, ...)
	local ok, msg = pcall(string.format, fmt, ...)
	DebugError("[PromoteSpecialist] " .. (ok and msg or tostring(fmt)))
end
PromoteSpecialist.log = log

local function hasType(name)
	return (pcall(ffi.typeof, name))
end

local function hasFunc(name)
	return (pcall(function() return C[name] end))
end

local types = {
	{ "UniverseID", "typedef uint64_t UniverseID;" },
	{ "NPCSeed", "typedef uint64_t NPCSeed;" },
	{ "GenericActor", "typedef struct { UniverseID entity; UniverseID personcontrollable; NPCSeed personseed; } GenericActor;" },
	{ "CrewTransferContainer", "typedef struct { const char* newroleid; NPCSeed seed; uint32_t amount; } CrewTransferContainer;" },
	{ "NPCInfo", "typedef struct { NPCSeed seed; const char* roleid; int32_t tierid; const char* name; int32_t combinedskill; } NPCInfo;" },
	{ "UICrewExchangeResult", "typedef struct { const char* reason; NPCSeed person; NPCSeed partnerperson; } UICrewExchangeResult;" },
	{ "Skill2", "typedef struct { uint32_t textid; uint32_t descriptionid; uint32_t value; uint32_t relevance; } Skill2;" },
}

local funcs = {
	{ "AssignHiredActor", "const char* AssignHiredActor(GenericActor actor, UniverseID targetcontrollableid, const char* postid, const char* roleid, bool checkonly);" },
	{ "CanControllableHaveControlEntity", "bool CanControllableHaveControlEntity(UniverseID controllableid, const char* postid);" },
	{ "SignalObjectWithNPCSeed", "void SignalObjectWithNPCSeed(UniverseID objecttosignalid, const char* param, NPCSeed person, UniverseID controllableid);" },
	{ "PerformCrewExchange2", "UICrewExchangeResult PerformCrewExchange2(UniverseID controllableid, UniverseID partnercontrollableid, NPCSeed* npcs, uint32_t numnpcs, NPCSeed* partnernpcs, uint32_t numpartnernpcs, NPCSeed captainfromcontainer, NPCSeed captainfrompartner, bool exchangecaptains, bool checkonly);" },
	{ "ReassignPeople", "void ReassignPeople(UniverseID controllableid, CrewTransferContainer* reassignedcrew, uint32_t amount);" },
	{ "GetNumPeopleAfterOrders", "uint32_t GetNumPeopleAfterOrders(UniverseID controllableid, int32_t numorders);" },
	{ "GetPeopleAfterOrders", "uint32_t GetPeopleAfterOrders(NPCInfo* result, uint32_t resultlen, UniverseID controllableid, int32_t numorders);" },
	{ "GetPersonCombinedSkill", "int32_t GetPersonCombinedSkill(UniverseID controllableid, NPCSeed person, const char* role, const char* postid);" },
	{ "GetEntityCombinedSkill", "int32_t GetEntityCombinedSkill(UniverseID entityid, const char* role, const char* postid);" },
	{ "GetPersonName", "const char* GetPersonName(NPCSeed person, UniverseID controllableid);" },
	{ "GetPersonRole", "const char* GetPersonRole(NPCSeed person, UniverseID controllableid);" },
	{ "HasPersonArrived", "bool HasPersonArrived(UniverseID controllableid, NPCSeed person);" },
	{ "IsPersonTransferScheduled", "bool IsPersonTransferScheduled(UniverseID controllableid, NPCSeed person);" },
	{ "IsPerson", "bool IsPerson(NPCSeed person, UniverseID controllableid);" },
	{ "GetNumAllFactionShips", "uint32_t GetNumAllFactionShips(const char* factionid);" },
	{ "GetAllFactionShips", "uint32_t GetAllFactionShips(UniverseID* result, uint32_t resultlen, const char* factionid);" },
	{ "GetNumAllFactionStations", "uint32_t GetNumAllFactionStations(const char* factionid);" },
	{ "GetAllFactionStations", "uint32_t GetAllFactionStations(UniverseID* result, uint32_t resultlen, const char* factionid);" },
	{ "IsComponentClass", "bool IsComponentClass(UniverseID componentid, const char* classname);" },
	{ "IsComponentOperational", "bool IsComponentOperational(UniverseID componentid);" },
	{ "IsUnit", "bool IsUnit(UniverseID controllableid);" },
	{ "IsCurrentOrderCritical", "bool IsCurrentOrderCritical(UniverseID controllableid);" },
	{ "GetPlayerID", "UniverseID GetPlayerID(void);" },
	{ "GetDistanceBetween", "float GetDistanceBetween(UniverseID component1id, UniverseID component2id);" },
	{ "GetContextByClass", "UniverseID GetContextByClass(UniverseID componentid, const char* classname, bool includeself);" },
	{ "GetComponentName", "const char* GetComponentName(UniverseID componentid);" },
	{ "GetNumSkills", "uint32_t GetNumSkills(void);" },
	{ "GetPersonSkillsForAssignment", "uint32_t GetPersonSkillsForAssignment(Skill2* result, NPCSeed person, UniverseID controllableid, const char* role, const char* postid);" },
	{ "GetPeopleCapacity", "uint32_t GetPeopleCapacity(UniverseID controllableid, const char* macroname, bool includepilot);" },
	{ "GetNumBuildTasks", "uint32_t GetNumBuildTasks(UniverseID containerid, UniverseID buildmoduleid, bool isinprogress, bool includeupgrade);" },
}

local declared = {}
for _, entry in ipairs(types) do
	if not hasType(entry[1]) then
		local ok, err = pcall(ffi.cdef, entry[2])
		if ok then
			table.insert(declared, entry[1])
		else
			log("failed to declare type %s: %s", entry[1], tostring(err))
		end
	end
end
for _, entry in ipairs(funcs) do
	if not hasFunc(entry[1]) then
		local ok, err = pcall(ffi.cdef, entry[2])
		if ok then
			table.insert(declared, entry[1])
		else
			log("failed to declare function %s: %s", entry[1], tostring(err))
		end
	end
end
if #declared > 0 then
	log("ffi declared missing names: %s", table.concat(declared, ", "))
end

-- Stable string key for an NPCSeed. Seeds are full 64-bit values, so they must
-- never pass through a Lua number.
function PromoteSpecialist.seedKey(seed)
	return tostring(ffi.cast("uint64_t", seed))
end

-- Component id (LuaID, string or cdata) as a Lua number, like vanilla menus use.
function PromoteSpecialist.id64(component)
	return ConvertStringTo64Bit(tostring(component))
end

-- Localised text from this mod's page.
function PromoteSpecialist.text(id)
	return ReadText(PromoteSpecialist.PAGE, id)
end

local CheckIntervalSeconds <const> = 5.0
local SlowCheckIntervalSeconds <const> = 30.0
local MaxRemovalAttempts <const> = 3
local MaxRestoreAttempts <const> = 3
local MinIndustrialCapacity <const> = 10
local FallbackCapacity <const> = 60

-- a town is an industrial estate when its name starts with one of these words (any case)
local Keywords : {string} = {
	"indus", "fabrik", "factory",
	"[i]", "[ind]", "#ind",
}

local isEstate = function(name : string) : boolean
	local lowered = string.lower(name or "")
	for _, keyword in ipairs(Keywords) do
		if string.sub(lowered, 1, #keyword) == keyword then
			return true
		end
	end
	return false
end

local describe = function(town : Engine.Component.Town) : string
	local capacities : {string} = {}
	local sizes : {string} = {}
	for i = 1, 3 do
		capacities[i] = tostring(town.initialLandUseCapacities[i])
		sizes[i] = tostring(town.sizeFactors[i])
	end
	return "capacities=" .. table.concat(capacities, "/") .. " sizes=" .. table.concat(sizes, "/") .. " active=" .. tostring(town.developmentActive)
end

-- state keys per town entity e:
--   "c"..e  0/nil = untouched, 1 = turned into an industrial estate, 2 = restoring (capacities sent)
--   "oR","oC","oI"..e  original capacities, "oS1","oS2"..e  original sizes (saved with the savegame)
--   "r"..e removal attempts, "a"..e restore attempts
local ret : GameScript<{string : number}> = {
	update = function(_userParams : table, state : GameScriptState<{string : number}>, dt : number) : any
		if dt == 0.0 then
			return
		end

		local state2 = state:get() or { elapsed = 0.0 }
		state2.elapsed = (state2.elapsed or 0.0) + dt
		if state2.elapsed < CheckIntervalSeconds then
			state:set(state2)
			return
		end
		state2.elapsed = 0.0

		state2.slowElapsed = (state2.slowElapsed or 0.0) + CheckIntervalSeconds
		local slowNow = false
		if state2.slowElapsed >= SlowCheckIntervalSeconds then
			state2.slowElapsed = 0.0
			slowNow = true
		end

		api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
			local town = api.engine.getComponent(entity, api.type.ComponentType.TOWN) as Engine.Component.Town
			if not (town and town.initialLandUseCapacities and town.sizeFactors) then
				return
			end

			local e = tostring(entity)
			local name = api.engine.util.getEntityName(entity)
			local marked = isEstate(name)
			local phase = state2["c" .. e] or 0

			local residential = town.initialLandUseCapacities[1] or 0
			local commercial = town.initialLandUseCapacities[2] or 0
			local industrial = town.initialLandUseCapacities[3] or 0

			if marked then
				if phase == 0 or phase == 2 then
					-- a (re)marked town: remember how it looked, if it still has housing or commerce
					if residential > 0 or commercial > 0 then
						state2["oR" .. e] = residential
						state2["oC" .. e] = commercial
						state2["oI" .. e] = industrial
						state2["oS1" .. e] = town.sizeFactors[1] or 1.0
						state2["oS2" .. e] = town.sizeFactors[2] or 1.0
					end
					state2["c" .. e] = 1
					state2["r" .. e] = 0
					state2["a" .. e] = 0
					log.message("IndustrialEstateTowns: industrial estate found: town " .. e .. " '" .. tostring(name) .. "' " .. describe(town))
				end

				if residential > 0 or commercial > 0 then
					-- step 1: housing and commerce are set to zero, the town needs an industrial district
					if industrial <= 0 then
						industrial = math.floor((residential + commercial) * 0.4 + 0.5)
						if industrial < MinIndustrialCapacity then
							industrial = MinIndustrialCapacity
						end
					end
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, { 0, 0, industrial }))
				elseif (town.sizeFactors[3] or 0) <= 0 and industrial > 0 then
					-- step 2: the industrial district is scaled to zero, scale it up
					api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, { town.sizeFactors[1], town.sizeFactors[2], 1.0 }, true))
				elseif slowNow then
					-- step 3: housing or commerce buildings still stand, ask the town to update its buildings
					local built = api.engine.system.townBuildingSystem.getLandUsePersonCapacities(entity)
					local builtOther = (built and built[1] or 0) + (built and built[2] or 0)
					local attempts = state2["r" .. e] or 0
					if builtOther > 0 and attempts < MaxRemovalAttempts then
						state2["r" .. e] = attempts + 1
						log.message("IndustrialEstateTowns: removal request " .. tostring(attempts + 1) .. " for town " .. e)
						api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, { town.sizeFactors[1], town.sizeFactors[2], town.sizeFactors[3] }, true))
					end
				end
			elseif phase == 1 then
				-- the keyword was removed from the name: restore housing and commerce
				local originalResidential = state2["oR" .. e] or 0
				local originalCommercial = state2["oC" .. e] or 0
				log.message("IndustrialEstateTowns: keyword removed, restoring town " .. e .. " '" .. tostring(name) .. "' originals=" .. tostring(originalResidential) .. "/" .. tostring(originalCommercial))
				if originalResidential > 0 and originalCommercial > 0 then
					if industrial <= 0 then
						industrial = state2["oI" .. e] or MinIndustrialCapacity
					end
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, { originalResidential, originalCommercial, industrial }))
				else
					-- no originals known (the town was already an estate before): let the game recalculate
					api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity))
				end
				state2["c" .. e] = 2
				state2["a" .. e] = 0
			elseif phase == 0 and residential <= 0 and commercial <= 0 then
				-- no keyword, no memory (the game drops the script state when the mod is missing at load),
				-- but housing and commerce are both zero: a leftover industrial estate, restore it
				log.message("IndustrialEstateTowns: leftover industrial estate, restoring town " .. e .. " '" .. tostring(name) .. "' " .. describe(town))
				api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity))
				state2["c" .. e] = 2
				state2["a" .. e] = 0
			elseif phase == 2 then
				if residential > 0 and commercial > 0 then
					-- the capacities are back: scale housing and commerce up and let the town rebuild
					local s1 = state2["oS1" .. e] or 1.0
					local s2 = state2["oS2" .. e] or 1.0
					if s1 <= 0 then
						s1 = 1.0
					end
					if s2 <= 0 then
						s2 = 1.0
					end
					log.message("IndustrialEstateTowns: town " .. e .. " restored, sizes " .. tostring(s1) .. "/" .. tostring(s2))
					api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(entity, { s1, s2, town.sizeFactors[3] }, true))
					state2["c" .. e] = 0
				else
					local attempts = state2["a" .. e] or 0
					state2["a" .. e] = attempts + 1
					if attempts >= MaxRestoreAttempts then
						-- typical ratio of the towns of the test savegames: housing 1.4 and commerce 1.0 per industry
						local fallbackResidential = FallbackCapacity
						local fallbackCommercial = FallbackCapacity
						if industrial > 0 then
							fallbackResidential = math.floor(industrial * 1.4 + 0.5)
							fallbackCommercial = industrial
						end
						if fallbackResidential < MinIndustrialCapacity then
							fallbackResidential = MinIndustrialCapacity
						end
						if fallbackCommercial < MinIndustrialCapacity then
							fallbackCommercial = MinIndustrialCapacity
						end
						if residential <= 0 then
							residential = fallbackResidential
						end
						if commercial <= 0 then
							commercial = fallbackCommercial
						end
						log.message("IndustrialEstateTowns: fallback capacities for town " .. e)
						api.cmd.sendCommand(api.cmd.makeTownSetInitialLandUseCapacitiesCmd(entity, { residential, commercial, industrial }))
					end
				end
			end
		end, api.type.ComponentType.TOWN)

		state:set(state2)
	end,
}

return ret

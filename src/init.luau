--!strict
-- Puppet -- clips, markers, blends, layers, masks, and the pose a body is in without playing it.
--
-- ⚠⚠ THE HEADLINE CAPABILITY IS RESOLVING A POSE THAT IS NOT BEING PLAYED. The server holds no
-- `AnimationTrack` for a client-played animation -- measured: the client reports two playing tracks
-- and the server reports zero, same character, same instant. The pose replicates; the track object
-- does not. So an authoritative side that needs to know where a hand IS has to compute it, and that
-- is this file.
--
-- ⚠ Everything simulation needs comes from the BAKE, never from a runtime signal: marker times are
-- declared data, because `GetMarkerReachedSignal` is unreachable where it would be needed.
--
-- ⚠ The transform algebra is injected (`Ops`), so the core holds no engine type.

local Ops = require("@self/Ops")

local Puppet = {}
Puppet.__index = Puppet

Puppet.Ops = Ops

function Puppet.new(config: any?): any
	local settings = config or {}
	local ops = settings.ops or Ops.cframe
	if ops == nil then
		-- ⚠ Loud rather than a nil index six calls later: on a host with no `CFrame` the caller has
		-- to say which algebra it means, and saying so is one line.
		error("no transform ops: pass `ops` (this host has no CFrame)", 2)
	end
	return setmetatable({
		ops = ops,
		clips = {},
		clipOrder = {},
		masks = {},
		transitions = {},
		rigs = {},
		compiled = false,
		-- ⚠ Reused across `pose` calls: a pose is asked for every frame per body on the
		-- authoritative side, and returning a fresh table each time is the churn this package
		-- exists to avoid. A caller wanting to keep one asks for a copy.
		scratch = {},
		counts = { poses = 0, blended = 0, frames = 0, markerLookups = 0 },
	}, Puppet)
end

--- A named set of joints. ⚠ A mask naming no joints is refused rather than treated as "everything":
--- an empty mask reads as "mask nothing off" to one person and "allow nothing" to another, and
--- being wrong either way is silent.
function Puppet:mask(name: string, joints: { string }): any
	if type(name) ~= "string" or name == "" then
		error("a mask needs a name", 2)
	end
	if type(joints) ~= "table" or #joints == 0 then
		error(("mask '%s' names no joints"):format(name), 2)
	end
	local set: { [string]: boolean } = {}
	for _, joint in joints do
		set[joint] = true
	end
	self.masks[name] = set
	return self
end

--- Register a rig adapter. ⚠ A constraint-driven rig and a Motor6D rig are two declarations rather
--- than two code paths. On some constraint rigs a `Transform` write is inert -- the property holds
--- and the body ignores it -- so an adapter that pretends otherwise fails silently and reads as an
--- animation bug rather than as a wrong adapter.
function Puppet:rig(name: string, adapter: any): any
	if type(name) ~= "string" or name == "" then
		error("a rig adapter needs a name", 2)
	end
	for _, required in { "apply", "jointsOf" } do
		if type(adapter[required]) ~= "function" then
			error(("rig adapter '%s' has no %s function"):format(name, required), 2)
		end
	end
	self.rigs[name] = adapter
	return self
end

--- Declare clips and transitions. Throws with every fault found, not the first.
function Puppet:define(declarations: { [string]: any }): any
	local errors: { string } = {}

	local names: { string } = {}
	for name in declarations do
		table.insert(names, name)
	end
	table.sort(names)

	local clips: { [string]: any } = {}
	local transitions: { [string]: any } = {}

	for _, name in names do
		local row = declarations[name]
		if type(row) ~= "table" then
			table.insert(errors, ("'%s' is not a table"):format(name))
			continue
		end
		if row.from ~= nil or row.to ~= nil then
			transitions[name] = row
			continue
		end
		if type(row.length) ~= "number" or row.length <= 0 then
			table.insert(errors, ("clip '%s' has no positive length -- a blend cannot normalise time against it"):format(name))
			continue
		end
		if row.mask ~= nil and self.masks[row.mask] == nil then
			table.insert(errors, ("clip '%s' names mask '%s', which is not declared"):format(name, tostring(row.mask)))
		end
		local markers: { [string]: number } = {}
		if row.markers ~= nil then
			if type(row.markers) ~= "table" then
				table.insert(errors, ("clip '%s' has non-table markers"):format(name))
			else
				for marker, at in row.markers do
					if type(at) ~= "number" or at < 0 or at > row.length then
						table.insert(errors, ("clip '%s' marker '%s' at %s is outside [0, %s] -- it would never fire, and silently"):format(name, tostring(marker), tostring(at), tostring(row.length)))
					else
						markers[marker] = at
					end
				end
			end
		end
		clips[name] = {
			length = row.length,
			loops = row.loops == true,
			layer = row.layer or "base",
			mask = row.mask,
			markers = markers,
			joints = row.joints or {},
		}
	end

	for name, row in transitions do
		if row.from == nil or clips[row.from] == nil then
			table.insert(errors, ("transition '%s' comes from '%s', which is not a clip"):format(name, tostring(row.from)))
		end
		if row.to == nil or clips[row.to] == nil then
			table.insert(errors, ("transition '%s' goes to '%s', which is not a clip"):format(name, tostring(row.to)))
		end
		if row.fade ~= nil and (type(row.fade) ~= "number" or row.fade <= 0) then
			-- ⚠ An instant transition is `fade = nil`, not `fade = 0`. Zero reads as "I set a fade"
			-- and behaves as "I did not", which is the worst of both.
			table.insert(errors, ("transition '%s' has a fade of %s -- an instant transition is no fade at all"):format(name, tostring(row.fade)))
		end
	end

	-- ⚠ Two clips on ONE LAYER declaring the same marker at different times: a listener could not
	-- tell which fired. Across layers it is legitimate, because a layer is the thing that
	-- distinguishes them.
	local byLayer: { [string]: { [string]: { clip: string, at: number } } } = {}
	local clipNames: { string } = {}
	for name in clips do
		table.insert(clipNames, name)
	end
	table.sort(clipNames)
	for _, name in clipNames do
		local clip = clips[name]
		local seen = byLayer[clip.layer]
		if seen == nil then
			seen = {}
			byLayer[clip.layer] = seen
		end
		for marker, at in clip.markers do
			local already = seen[marker]
			if already ~= nil and already.at ~= at then
				table.insert(errors, ("marker '%s' is declared on layer '%s' by both '%s' (%s) and '%s' (%s)"):format(marker, clip.layer, already.clip, tostring(already.at), name, tostring(at)))
			else
				seen[marker] = { clip = name, at = at }
			end
		end
	end

	if #errors > 0 then
		table.sort(errors)
		error("puppet declarations refused:\n  " .. table.concat(errors, "\n  "), 2)
	end

	self.clips = clips
	self.transitions = transitions
	self.clipOrder = clipNames
	self.compiled = true
	return self
end

function Puppet:clip(name: string): any
	return self.clips[name]
end

--- The time a marker fires, from the bake. ⚠ Data, not a signal: this is reachable on a side that
--- holds no `AnimationTrack`, which is the entire reason the bake exists.
function Puppet:markerAt(clipName: string, marker: string): number?
	self.counts.markerLookups += 1
	local clip = self.clips[clipName]
	if clip == nil then
		return nil
	end
	return clip.markers[marker]
end

--- Every marker a clip crosses between two times. ⚠ Handles a LOOPING clip wrapping past its end,
--- which a naive `t0 < at and at <= t1` misses entirely -- and misses it exactly once per loop, so
--- it looks like an occasional dropped event rather than a bug.
function Puppet:markersBetween(clipName: string, fromTime: number, toTime: number, into: { string }?): { string }
	local out = into or {}
	table.clear(out)
	local clip = self.clips[clipName]
	if clip == nil then
		return out
	end
	if toTime >= fromTime then
		for marker, at in clip.markers do
			if at > fromTime and at <= toTime then
				table.insert(out, marker)
			end
		end
	else
		-- Wrapped: [from, length] plus [0, to].
		for marker, at in clip.markers do
			if at > fromTime or at <= toTime then
				table.insert(out, marker)
			end
		end
	end
	table.sort(out)
	return out
end

local function sampleJoint(track: any, time: number, ops: Ops.Ops): any
	local times = track.times
	local values = track.values
	local n = #times
	if n == 0 then
		return ops.identity
	end
	if time <= times[1] then
		return values[1]
	end
	if time >= times[n] then
		return values[n]
	end
	for index = 1, n - 1 do
		local a, b = times[index], times[index + 1]
		if time >= a and time <= b then
			local span = b - a
			if span <= 0 then
				return values[index + 1]
			end
			return ops.lerp(values[index], values[index + 1], (time - a) / span)
		end
	end
	return values[n]
end

Puppet.sampleJoint = sampleJoint

--- ⚠⚠ THE POSE A BODY IS IN, WITHOUT PLAYING ANYTHING. `entries` is what the body is playing --
--- clip, time, weight, and optionally a mask that narrows which joints it contributes to.
---
--- ⚠ Blending is SUCCESSIVE WEIGHTED LERP rather than an average: `acc = lerp(acc, next, w / (W +
--- w))`. That needs only `lerp`, which is why the injected algebra is three functions rather than a
--- matrix library -- and it is order-independent in weight, which an average of pre-scaled
--- transforms is not.
function Puppet:pose(entries: { any }, into: { [string]: any }?): { [string]: any }
	local ops = self.ops
	local out = into or self.scratch
	table.clear(out)
	self.counts.poses += 1

	local weightSoFar: { [string]: number } = {}

	for _, entry in entries do
		local clip = self.clips[entry.clip]
		if clip == nil then
			continue
		end
		local weight = entry.weight or 1
		if weight <= 0 then
			continue
		end
		local time = entry.time or 0
		if clip.loops and clip.length > 0 then
			time = time % clip.length
		end
		-- A per-entry mask narrows further than the clip's own; both apply.
		local entryMask = if entry.mask then self.masks[entry.mask] else nil
		local clipMask = if clip.mask then self.masks[clip.mask] else nil

		for joint, track in clip.joints do
			if entryMask ~= nil and not entryMask[joint] then
				continue
			end
			if clipMask ~= nil and not clipMask[joint] then
				continue
			end
			local sampled = sampleJoint(track, time, ops)
			local had = weightSoFar[joint]
			if had == nil then
				out[joint] = sampled
				weightSoFar[joint] = weight
			else
				local total = had + weight
				out[joint] = ops.lerp(out[joint], sampled, weight / total)
				weightSoFar[joint] = total
			end
			self.counts.blended += 1
		end
	end

	return out
end

--- The frame of one joint in ROOT space, by walking the parent chain. A skeleton is
--- `{ root = name, parentOf = { joint -> parent }, bindOf = { joint -> transform } }`.
---
--- ⚠ Pure forward kinematics, and it reads no rig -- which is the point: an authoritative side has
--- no rig to read, and a rig it could read would be one the client owns.
function Puppet:frameOf(skeleton: any, pose: { [string]: any }, joint: string): any?
	local ops = self.ops
	self.counts.frames += 1
	local chain: { string } = {}
	local at: string? = joint
	local guard = 0
	while at ~= nil and at ~= skeleton.root do
		table.insert(chain, at)
		at = skeleton.parentOf[at]
		guard += 1
		if guard > 512 then
			-- A cycle in the parent map. Refused loudly rather than hung: a skeleton is authored
			-- data and a cycle in it is a fault somebody can fix.
			error(("skeleton parent chain from '%s' does not reach the root"):format(joint), 2)
		end
	end
	if at == nil then
		return nil
	end
	local frame = ops.identity
	for index = #chain, 1, -1 do
		local name = chain[index]
		local bind = skeleton.bindOf[name] or ops.identity
		local animated = pose[name]
		frame = ops.mul(frame, bind)
		if animated ~= nil then
			frame = ops.mul(frame, animated)
		end
	end
	return frame
end

function Puppet:stats(): any
	local out = table.clone(self.counts)
	out.clips = #self.clipOrder
	return out
end

return Puppet

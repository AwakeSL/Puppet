--!strict
-- Reading clip data out of the engine, into the shape `Puppet` blends.
--
-- ⚠⚠ `AnimationClipProvider`, NOT `KeyframeSequenceProvider`. The latter is deprecated and does not
-- support the newer `AnimationClip` at all, so code on it is both old and quietly narrower than it
-- looks.
--
-- ⚠ This is an ADAPTER and lives apart from the core on purpose: it is the only file in the package
-- that requires an engine, so everything the core does stays provable without one.
--
-- ⚠ Yields. `GetAnimationClipAsync` is a network fetch, so a caller bakes at load and never in a
-- frame -- which is the whole reason a bake exists rather than a runtime read.

local Bake = {}

local function providerOrNil(): any
	local ok, service = pcall(function()
		return game:GetService("AnimationClipProvider")
	end)
	return if ok then service else nil
end

--- Collect `{ time -> CFrame }` per joint from a clip's keyframes.
---
--- ⚠ Poses are NESTED -- a `Pose` holds sub-poses for its children -- so this walks rather than
--- iterating one level. A flat read finds the root's immediate children and silently nothing else,
--- which produces a pose that is right at the shoulders and wrong everywhere past them.
local function collect(keyframe: Keyframe, into: { [string]: any })
	local stack: { any } = {}
	for _, child in keyframe:GetChildren() do
		if child:IsA("Pose") then
			table.insert(stack, child)
		end
	end
	while #stack > 0 do
		local pose = table.remove(stack) :: Pose
		local track = into[pose.Name]
		if track == nil then
			track = { times = {}, values = {} }
			into[pose.Name] = track
		end
		table.insert(track.times, keyframe.Time)
		table.insert(track.values, pose.CFrame)
		for _, child in pose:GetChildren() do
			if child:IsA("Pose") then
				table.insert(stack, child)
			end
		end
	end
end

--- Bake one animation into a declaration row: `{ length, markers, joints }`.
--- Returns nil plus a reason rather than throwing, so a caller baking a whole set gets every
--- failure instead of stopping at the first missing asset.
function Bake.clip(animationId: string): (any?, string?)
	local provider = providerOrNil()
	if provider == nil then
		return nil, "no AnimationClipProvider on this host"
	end
	local ok, clip = pcall(function()
		return provider:GetAnimationClipAsync(animationId)
	end)
	if not ok or clip == nil then
		return nil, ("could not fetch %s: %s"):format(animationId, tostring(clip))
	end
	if not clip:IsA("KeyframeSequence") then
		-- ⚠ Named rather than swallowed: a non-keyframe clip is a real thing and this adapter
		-- genuinely cannot read it, which a caller should be told rather than left to infer from an
		-- empty pose.
		return nil, ("%s is a %s, which this adapter cannot read"):format(animationId, clip.ClassName)
	end

	local keyframes: { Keyframe } = {}
	for _, child in clip:GetChildren() do
		if child:IsA("Keyframe") then
			table.insert(keyframes, child)
		end
	end
	-- ⚠ Sorted by time: `GetChildren` order is not keyframe order, and a track built in child order
	-- interpolates between whichever two happened to be adjacent in the datamodel.
	table.sort(keyframes, function(a, b)
		return a.Time < b.Time
	end)

	local joints: { [string]: any } = {}
	local markers: { [string]: number } = {}
	local length = 0

	for _, keyframe in keyframes do
		if keyframe.Time > length then
			length = keyframe.Time
		end
		collect(keyframe, joints)
		for _, marker in keyframe:GetMarkers() do
			-- ⚠ Marker TIMES, read here once. `GetMarkerReachedSignal` is unreachable on a side
			-- that holds no AnimationTrack, which is exactly the side that needs these.
			markers[marker.Name] = keyframe.Time
		end
	end

	if length <= 0 then
		return nil, ("%s has no keyframe past time zero"):format(animationId)
	end

	return { length = length, markers = markers, joints = joints }, nil
end

--- Bake a whole set. Returns the declarations plus a list of what failed, so a missing asset is
--- reported rather than silently absent -- the same rule the rest of this project follows.
function Bake.set(animations: { [string]: string }): ({ [string]: any }, { string })
	local out: { [string]: any } = {}
    local failures: { string } = {}
	local names: { string } = {}
	for name in animations do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		local row, why = Bake.clip(animations[name])
		if row then
			out[name] = row
		else
			table.insert(failures, ("%s: %s"):format(name, why or "unknown"))
		end
	end
	return out, failures
end

return Bake

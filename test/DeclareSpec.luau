--!strict
local Puppet = require("../src")

local function fresh(): any
	local p = Puppet.new({ ops = Puppet.Ops.scalar })
	p:mask("legs", { "LeftLeg" })
	return p
end

return function(t: any)
	t.err(function()
		fresh():define({ a = { joints = {} } })
	end, "no positive length", "a clip with no length is refused")

	t.err(function()
		fresh():define({ a = { length = -1, joints = {} } })
	end, "no positive length", "a negative length is refused")

	t.err(function()
		fresh():define({ a = { length = 1, markers = { late = 2 }, joints = {} } })
	end, "would never fire", "a marker past the clip's end is refused")

	t.err(function()
		fresh():define({ a = { length = 1, markers = { early = -0.1 }, joints = {} } })
	end, "would never fire", "and so is one before its start")

	t.err(function()
		fresh():define({ a = { length = 1, mask = "ghost", joints = {} } })
	end, "not declared", "a clip naming an undeclared mask is refused")

	t.err(function()
		Puppet.new({ ops = Puppet.Ops.scalar }):mask("empty", {})
	end, "names no joints", "a mask with no joints is refused")

	t.err(function()
		fresh():define({
			a = { length = 1, joints = {} },
			move = { from = "a", to = "ghost", fade = 0.1 },
		})
	end, "not a clip", "a transition to an undefined clip is refused")

	t.err(function()
		fresh():define({
			a = { length = 1, joints = {} },
			b = { length = 1, joints = {} },
			move = { from = "a", to = "b", fade = 0 },
		})
	end, "instant transition is no fade", "a zero fade is refused -- instant means no fade at all")

	-- ⚠ Two clips on ONE layer declaring the same marker at different times: a listener could not
	-- tell which fired.
	t.err(function()
		fresh():define({
			a = { length = 1, layer = "action", markers = { hit = 0.2 }, joints = {} },
			b = { length = 1, layer = "action", markers = { hit = 0.8 }, joints = {} },
		})
	end, "is declared on layer", "the same marker at two times on one layer is refused")

	-- Across layers it is legitimate, because the layer is what distinguishes them.
	local layered = fresh()
	layered:define({
		a = { length = 1, layer = "action", markers = { hit = 0.2 }, joints = {} },
		b = { length = 1, layer = "base", markers = { hit = 0.8 }, joints = {} },
	})
	t.eq(layered:markerAt("a", "hit"), 0.2, "the same marker on two layers keeps both times")
	t.eq(layered:markerAt("b", "hit"), 0.8, "each on its own clip")

	-- And the same marker at the SAME time on one layer is fine -- nothing is ambiguous.
	local agreed = fresh()
	agreed:define({
		a = { length = 1, layer = "action", markers = { hit = 0.2 }, joints = {} },
		b = { length = 1, layer = "action", markers = { hit = 0.2 }, joints = {} },
	})
	t.eq(agreed:markerAt("b", "hit"), 0.2, "two clips agreeing on a marker time is not a conflict")

	-- Every fault in one run.
	local ok, err = pcall(function()
		fresh():define({
			a = { joints = {} },
			b = { length = 1, markers = { late = 9 }, joints = {} },
			c = { length = 1, mask = "ghost", joints = {} },
		})
	end)
	t.ok(not ok, "a declaration with three faults is refused")
	local lines = 0
	for _ in tostring(err):gmatch("\n") do
		lines += 1
	end
	t.ok(lines >= 3, ("all three are reported (saw %d lines)"):format(lines))

	t.err(function()
		Puppet.new({ ops = Puppet.Ops.scalar }):rig("broken", {})
	end, "has no apply", "a rig adapter missing a required function is refused")

	-- Sampling: before, after and between keyframes.
	local sample = Puppet.sampleJoint
	local ops = Puppet.Ops.scalar
	local tr = { times = { 0, 1, 2 }, values = { 10, 20, 0 } }
	t.eq(sample(tr, -5, ops), 10, "before the first key clamps to it")
	t.eq(sample(tr, 9, ops), 0, "after the last key clamps to it")
	t.eq(sample(tr, 0.5, ops), 15, "and between two keys interpolates")
	t.eq(sample(tr, 1.5, ops), 10, "across the second span too")
	t.eq(sample({ times = {}, values = {} }, 0, ops), 0, "an empty track is the identity, not a crash")

	-- A looping clip's time wraps rather than clamping at the end.
	local looped = fresh()
	looped:define({
		spin = { length = 1, loops = true, joints = { J = { times = { 0, 0.5, 1 }, values = { 0, 100, 0 } } } },
	})
	t.eq(looped:pose({ { clip = "spin", time = 0.5 } }).J, 100, "mid-loop")
	t.eq(looped:pose({ { clip = "spin", time = 2.5 } }).J, 100, "and two loops later, at the same phase")

	-- A non-looping clip clamps instead.
	local once = fresh()
	once:define({ once = { length = 1, joints = { J = { times = { 0, 1 }, values = { 0, 100 } } } } })
	t.eq(once:pose({ { clip = "once", time = 5 } }).J, 100, "a non-looping clip clamps past its end")

	-- Zero and negative weights contribute nothing rather than dividing by zero.
	local zero = fresh()
	zero:define({
		a = { length = 1, joints = { J = { times = { 0, 1 }, values = { 0, 100 } } } },
		b = { length = 1, joints = { J = { times = { 0, 1 }, values = { 0, 50 } } } },
	})
	local poseOut = zero:pose({ { clip = "a", time = 1, weight = 1 }, { clip = "b", time = 1, weight = 0 } })
	t.eq(poseOut.J, 100, "a zero-weight entry contributes nothing")
	local negative = zero:pose({ { clip = "a", time = 1, weight = 1 }, { clip = "b", time = 1, weight = -3 } })
	t.eq(negative.J, 100, "and neither does a negative one")

	-- An unknown clip in an entry is skipped rather than throwing mid-frame.
	local skipped = zero:pose({ { clip = "ghost", time = 0, weight = 1 }, { clip = "a", time = 1, weight = 1 } })
	t.eq(skipped.J, 100, "an unknown clip in a pose entry is skipped, not fatal")

	-- The scratch table is reused, so a per-frame caller allocates nothing -- but a caller that
	-- wants to keep one can supply its own.
	local mine: { [string]: any } = {}
	zero:pose({ { clip = "a", time = 1 } }, mine)
	t.eq(mine.J, 100, "a supplied table is filled")
	zero:pose({ { clip = "b", time = 1 } }, mine)
	t.eq(mine.J, 50, "and cleared before being refilled rather than merged into")
end

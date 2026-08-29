--!strict
-- THE ACCEPTANCE CASE: a hand's position resolved from two blended clips WITHOUT PLAYING THEM.
--
-- ⚠ Scalar ops stand in for transforms throughout, which is the proof rather than a shortcut: an
-- authoritative side has no rig and no Animator, so a core that needed either could not be driven
-- by a table of numbers.

local Puppet = require("../src")

local function track(times: { number }, values: { number }): any
	return { times = times, values = values }
end

return function(t: any)
	local p = Puppet.new({ ops = Puppet.Ops.scalar })
	p:mask("legs", { "LeftLeg", "RightLeg" })
	p:mask("arms", { "Shoulder", "Elbow", "Hand" })

	p:define({
		-- An action clip that raises the arm: shoulder 0 -> 90 over 0.6s.
		slash = {
			layer = "action",
			length = 0.6,
			markers = { sweep = 0.18, recovery = 0.42 },
			joints = {
				Shoulder = track({ 0, 0.3, 0.6 }, { 0, 90, 30 }),
				Elbow = track({ 0, 0.6 }, { 0, 20 }),
				Hand = track({ 0, 0.6 }, { 0, 0 }),
			},
		},
		-- A looping stride that also moves the shoulder a little, plus the legs.
		stride = {
			layer = "base",
			length = 1.0,
			loops = true,
			joints = {
				Shoulder = track({ 0, 0.5, 1.0 }, { 0, 10, 0 }),
				LeftLeg = track({ 0, 0.5, 1.0 }, { 0, 40, 0 }),
				RightLeg = track({ 0, 0.5, 1.0 }, { 40, 0, 40 }),
			},
		},
		idleToRun = { from = "stride", to = "slash", fade = 0.15 },
	})

	-- ① MARKER TIMES COME FROM THE BAKE, reachable where no AnimationTrack exists.
	t.eq(p:markerAt("slash", "sweep"), 0.18, "a marker time is data, not a signal")
	t.eq(p:markerAt("slash", "nope"), nil, "an undeclared marker has no time")
	t.eq(p:markerAt("nosuchclip", "sweep"), nil, "and neither does one on an unknown clip")

	local crossed = p:markersBetween("slash", 0.1, 0.25)
	t.eq(#crossed, 1, "one marker is crossed between 0.1 and 0.25")
	t.eq(crossed[1], "sweep", "and it is the right one")
	t.eq(#p:markersBetween("slash", 0.19, 0.4), 0, "none between 0.19 and 0.4")

	-- ⚠ A LOOPING clip wrapping past its end: a naive from < at <= to misses this exactly once per
	-- loop, so it reads as an occasional dropped event rather than as a bug.
	p:define({
		loop = { length = 1.0, loops = true, markers = { tick = 0.05 }, joints = {} },
		slash = { layer = "action", length = 0.6, markers = { sweep = 0.18 }, joints = {
			Shoulder = track({ 0, 0.3, 0.6 }, { 0, 90, 30 }),
			Elbow = track({ 0, 0.6 }, { 0, 20 }),
			Hand = track({ 0, 0.6 }, { 0, 0 }),
		} },
		stride = { layer = "base", length = 1.0, loops = true, joints = {
			Shoulder = track({ 0, 0.5, 1.0 }, { 0, 10, 0 }),
			LeftLeg = track({ 0, 0.5, 1.0 }, { 0, 40, 0 }),
			RightLeg = track({ 0, 0.5, 1.0 }, { 40, 0, 40 }),
		} },
	})
	local wrapped = p:markersBetween("loop", 0.95, 0.1)
	t.eq(#wrapped, 1, "a marker just after the loop point is caught when the clip wraps")
	t.eq(wrapped[1], "tick", "and named")

	-- ② THE POSE, BLENDED, WITH NOTHING PLAYING. slash at 0.3 puts the shoulder at 90; stride at
	-- 0.5 puts it at 10. At equal weight the blend is halfway.
	local even = p:pose({
		{ clip = "slash", time = 0.3, weight = 1 },
		{ clip = "stride", time = 0.5, weight = 1 },
	})
	t.eq(even.Shoulder, 50, "two clips at equal weight blend halfway")
	t.eq(even.Elbow, 10, "a joint only one clip drives keeps that clip's value")
	t.eq(even.LeftLeg, 40, "and so does one only the other drives")

	-- ⚠ Weighted, not averaged: at 3:1 the result is three quarters of the way to the first.
	local weighted = p:pose({
		{ clip = "slash", time = 0.3, weight = 3 },
		{ clip = "stride", time = 0.5, weight = 1 },
	})
	t.eq(weighted.Shoulder, 70, "3:1 lands at 70, which is 90 and 10 weighted three to one")

	-- ⚠ And it is ORDER-INDEPENDENT, which an average of pre-scaled transforms is not.
	local reversed = p:pose({
		{ clip = "stride", time = 0.5, weight = 1 },
		{ clip = "slash", time = 0.3, weight = 3 },
	})
	t.eq(reversed.Shoulder, 70, "swapping the entries gives the same answer")

	-- ③ A MASK NARROWS WHAT A CLIP CONTRIBUTES, which is what a legs-only overlay is.
	local masked = p:pose({
		{ clip = "slash", time = 0.3, weight = 1 },
		{ clip = "stride", time = 0.5, weight = 1, mask = "legs" },
	})
	t.eq(masked.Shoulder, 90, "the masked clip does not touch the shoulder at all")
	t.eq(masked.LeftLeg, 40, "but still drives the legs")

	-- ④ THE HAND'S FRAME, by walking the skeleton. With scalar ops, `mul` is addition, so a chain
	-- of bind offsets plus animated angles adds up to a number that can be checked by hand.
	local skeleton = {
		root = "Root",
		parentOf = { Shoulder = "Root", Elbow = "Shoulder", Hand = "Elbow" },
		bindOf = { Shoulder = 1000, Elbow = 200, Hand = 30 },
	}
	local pose = p:pose({ { clip = "slash", time = 0.3, weight = 1 } })
	local hand = p:frameOf(skeleton, pose, "Hand")
	-- 1000 + 90 (shoulder) + 200 + 10 (elbow) + 30 + 0 (hand)
	t.eq(hand, 1330, "the hand's frame is the whole chain, bind and animation together")

	local elbow = p:frameOf(skeleton, pose, "Elbow")
	t.eq(elbow, 1300, "and a joint part-way up the chain stops there")
	t.eq(p:frameOf(skeleton, pose, "Root"), 0, "the root is the identity")

	-- ⚠ THE POINT OF ALL OF IT: no rig was ever touched, no Animator existed, and nothing played.
	t.eq(p:stats().frames, 3, "three frames resolved without an engine anywhere in the call")

	-- A joint with no animation still gets its bind.
	local bindOnly = p:frameOf(skeleton, {}, "Hand")
	t.eq(bindOnly, 1230, "an unanimated chain is just its bind offsets")

	-- ⑤ A cycle in an authored skeleton is refused loudly rather than hung.
	t.err(function()
		p:frameOf({ root = "Root", parentOf = { A = "B", B = "A" }, bindOf = {} }, {}, "A")
	end, "does not reach the root", "a cyclic parent chain is refused rather than looping forever")
end

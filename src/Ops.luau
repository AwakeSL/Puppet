--!strict
-- Transform algebra, injected. Puppet blends and walks a skeleton through three functions, so the
-- core holds no engine type and the whole thing is testable with numbers standing in for
-- transforms.
--
-- ⚠ THREE FUNCTIONS IS THE WHOLE REQUIREMENT, and that is not an accident: blending N poses is
-- successive weighted `lerp` rather than an average, and forward kinematics is `mul` down a parent
-- chain. Neither needs decomposition, quaternions or a matrix library.

local Ops = {}

export type Ops = {
	identity: any,
	mul: (a: any, b: any) -> any,
	lerp: (a: any, b: any, t: number) -> any,
}

--- For a host with an engine.
---
--- ⚠⚠ BUILT ONLY WHERE `CFrame` EXISTS, and that guard is the whole reason the core is testable.
--- Referencing `CFrame.identity` at load makes this module fail to load under a plain interpreter,
--- which would take the entire package down with it -- so a file whose whole purpose is to keep the
--- engine out would have been the one thing dragging it in.
Ops.cframe = if (CFrame :: any) ~= nil
	then ({
		identity = CFrame.identity,
		mul = function(a: any, b: any): any
			return (a :: CFrame) * (b :: CFrame)
		end,
		lerp = function(a: any, b: any, t: number): any
			return (a :: CFrame):Lerp(b :: CFrame, t)
		end,
	} :: any) :: Ops
	else nil :: any

--- Scalars, for tests and for a host that only needs one axis. ⚠ Shipped rather than left to every
--- test to redefine: the core's correctness should be demonstrable without an engine by anyone, not
--- only by whoever remembers how.
Ops.scalar = {
	identity = 0,
	mul = function(a: any, b: any): any
		return a + b
	end,
	lerp = function(a: any, b: any, t: number): any
		return a + (b - a) * t
	end,
} :: Ops

return Ops

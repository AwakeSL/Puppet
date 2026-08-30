# puppet

**Clips, blends and markers — and the pose a body is in without playing it.**

You declare clips with their markers, masks and blend rules. Puppet blends the clips a body is
playing into a joint pose and walks a skeleton to give you any joint's frame — using only arithmetic,
so a server with no `Animator` and no `AnimationTrack` can still answer where a hand is.

```lua
local Puppet = require(path.to.Puppet)
local Bake = require(path.to.Puppet.Bake)

local puppet = Puppet.new()          -- CFrame ops by default
puppet:mask("legs", { "LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg" })

-- Bake reads clip data through AnimationClipProvider, at load, once.
local clips, failures = Bake.set({
    slash  = "rbxassetid://1234",
    stride = "rbxassetid://5678",
})
clips.slash.layer = "action"
clips.stride.loops = true
puppet:define(clips)

-- What is this body in, right now, given what it is playing?
local pose = puppet:pose({
    { clip = "slash",  time = 0.24, weight = 1 },
    { clip = "stride", time = 0.11, weight = 0.4, mask = "legs" },
})

local skeleton = { root = "Root", parentOf = parents, bindOf = binds }
local hand = puppet:frameOf(skeleton, pose, "RightHand")   -- in root space

-- Marker times come from the bake, so they are readable where no track exists.
puppet:markerAt("slash", "sweep")              --> 0.18
puppet:markersBetween("slash", 0.10, 0.25)     --> { "sweep" }
```

- **A server holds no `AnimationTrack` for a client-played animation.** Measured: the client reports
  two playing tracks and the server reports zero, same character, same instant. The pose replicates;
  the track object does not. So an authoritative side has to compute the pose, and that is what
  `pose()` and `frameOf()` are.
- **Markers are baked data, not a runtime signal** — `GetMarkerReachedSignal` is unreachable on
  exactly the side that needs the timing, and Roblox only signals markers you ask for by name anyway.
- **Blending is successive weighted lerp**, so it is order-independent in weight and needs only three
  transform operations — which is why the algebra is injectable and the core tests with plain
  numbers.
- **`markersBetween` handles a loop wrapping past its end**, which a naive comparison misses exactly
  once per loop and therefore reads as an occasional dropped event.
- **Rig adapters are registered** — a constraint-driven rig and a `Motor6D` rig are two declarations,
  not two code paths.

`docs/Spec.md` is the build spec the implementation is held to.

## Install

```toml
[dependencies]
Puppet = "awakesl/puppet@0.1.0"
```

## Development

```
lune run scripts/headless      # the suite
selene src test scripts        # lint
```

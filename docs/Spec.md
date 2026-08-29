# Puppet — specification

Animation: clips, markers, blends, layers and masks, with full transition authoring — and the
ability to resolve **the pose a body is in without playing it**.

## The thing that makes this a package

Every item below cost real time to learn and none is discoverable from the API surface.

- **The server holds no `AnimationTrack` for a client-played animation.** Measured: a client reports
  two playing tracks and the server reports zero, for the same character at the same instant. The
  *pose* replicates; the track object does not. So `GetMarkerReachedSignal` is unreachable
  server-side, and a track sent over a remote arrives nil.
- **Therefore markers drive presentation, never simulation.** Anything simulation needs from a clip
  must come from **the bake** — times read off the clip data, not from a runtime signal.
- **Roblox only signals markers you ask for by name**, so a name outside the declared set fires
  nothing at all. It is a signal property, not a data one.
- **`KeyframeSequenceProvider` is deprecated**; `AnimationClipProvider:GetAnimationClipAsync` is the
  current door.

## Resolving a pose without playing it

⚠⚠ **THE HEADLINE CAPABILITY.** Given the clips a body is playing — which clip, at what time, at
what weight, under what mask — Puppet computes the blended joint pose and, with a skeleton, the
frame of any joint in root space.

That is what lets an authoritative side know where a hand *is* without an `Animator`, without a
rendered rig, and without trusting anything the client said. It is the same arithmetic the engine
does, done where the engine will not do it for you.

```lua
local pose = puppet:pose({
    { clip = "slash", time = 0.24, weight = 1 },
    { clip = "stride", time = 0.11, weight = 0.4, mask = "legs" },
})
local hand = puppet:frameOf(skeleton, pose, "RightHand")
```

## Declaring

```lua
puppet:mask("legs", { "LeftUpperLeg", "LeftLowerLeg", "RightUpperLeg", "RightLowerLeg" })

puppet:define({
    slash  = { layer = "action", markers = { sweep = 0.18, recovery = 0.42 }, length = 0.6 },
    stride = { layer = "base", loops = true, length = 1.0, mask = "legs" },

    -- Transitions are AUTHORED, not hardcoded: how one clip gives way to another.
    idleToRun = { from = "idle", to = "run", fade = 0.15, curve = { { 0, 0 }, { 1, 1 } } },
})
```

⚠ **Markers are declared with their times**, taken from the bake. A game that also wants the
engine's runtime signal may ask for one, but nothing in Puppet depends on it.

## What the compiler refuses

| refused | because |
|---|---|
| a clip with no length | a blend cannot normalise time against it |
| a marker outside `[0, length]` | it would never fire, and silently |
| a mask naming no joints | it would mask nothing, which is not what "mask" reads as |
| a transition whose `from` or `to` is undefined | it could never run |
| a negative or zero `fade` on a transition | an instant transition is `fade = nil`, not `fade = 0` |
| two clips declaring the same marker name at different times **on the same layer** | a listener could not tell which fired |

## Rig adapters

A rig is registered, not assumed:

```lua
puppet:rig("motor6d", { apply = ..., jointsOf = ..., bindOf = ... })
puppet:rig("constraint", { ... })
```

⚠ A constraint-driven rig and a `Motor6D` rig are two declarations rather than two code paths. On
some constraint rigs `Transform` writes are inert — the property holds and the body ignores it — so
an adapter that pretends otherwise fails silently and looks like an animation bug.

## Transform algebra is injected

Puppet does its blending and forward kinematics through an `ops` table — `identity`, `mul`, `lerp`.
The package ships `CFrame` ops for a host with an engine, and the whole core is tested with scalar
ops and no engine at all.

⚠ Blending N poses is successive weighted `lerp`, not an average: `acc = lerp(acc, next, w / (W +
w))`. It needs only `lerp`, which is why `ops` stays three functions instead of a matrix library.

# Puppet

Animation — clips, the bake, marker times, constraint rigs and blending.

## Why a package: this is expensive knowledge

Every item below cost real time to learn and none of it is discoverable from the API surface.

- **The server holds no `AnimationTrack` for a client-played animation.** Measured: the client
  reports two playing tracks, the server reports zero for the same character at the same instant. The
  *pose* replicates; the track object does not. So `GetMarkerReachedSignal` is unreachable
  server-side, and a track sent over a remote arrives nil.
- **Therefore markers drive presentation, never simulation** — and anything simulation needs from a
  clip must come from the **bake**: times read off the `KeyframeSequence` rather than from a runtime
  signal.
- **Roblox only signals markers you ask for by name**, so a name outside the declared set fires
  nothing at all. It is a signal property, not a data one.
- **Transform writes are dead on constraint-driven rigs**, and sockets on such a rig are
  additive-only.
- **`RegisterKeyframeSequence` fails silently.**

## What the game keeps

Which clips exist, what the markers mean, and when to play what.

## Development

```
lune run scripts/headless      # the suite
selene src test scripts        # lint
```

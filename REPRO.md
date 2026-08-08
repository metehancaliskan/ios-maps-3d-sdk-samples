# Repro: unbounded tile memory growth (Maps 3D SDK for iOS 0.2.1)

Fork of `googlemaps-samples/ios-maps-3d-sdk-samples` carrying a minimal
reproduction for
[issuetracker.google.com/issues/543049057](https://issuetracker.google.com/issues/543049057).

Only two files differ from upstream:

- `GoogleMaps3DDemo/GoogleMaps3DDemo/TileMemoryGrowthDemo.swift` — the repro.
- `GoogleMaps3DDemo/GoogleMaps3DDemo/GoogleMaps3DDemoApp.swift` — one
  `NavigationLink` so the repro is first in the sample list.

## What it does

Drives the camera in a straight first-person flight at 30 Hz — 1 m per frame due
north, `tilt: 72`, `range: 10`, `altitudeMode: .relativeToGround` — starting over
midtown Manhattan, and shows the process's `phys_footprint` on screen while it
runs. That is exactly what a continuous flight simulator does with the camera.

Everything is public API, and the view allocates nothing per frame except the
`Camera` value itself, which is released immediately. Anything that accumulates
accumulates inside the SDK.

## Steps

1. Add your key: `.xcconfig` with `MAPS_API_KEY`, or `Info.plist` (same as
   upstream).
2. Build in **Profile** or **Release** on a **physical device** (measured on an
   iPhone 17 Pro, iOS 26.5.2).
3. Launch, tap **⚠︎ Tile Memory Growth Repro**, tap **Start flight**.
4. Watch `FOOTPRINT` in the on-screen readout, or Xcode's Memory gauge.

## What you should see

Resident memory climbs monotonically and never plateaus. Measured upstream:
1.86 GB after ~1 min 35 s, 2.34 GB after ~3 min 50 s, then an `EXC_RESOURCE`
jetsam kill at ~2.25 GB with a debugger attached, ~3 GB without (no crash
report, consistent with jetsam rather than a crash).

Two things the buttons make easy to check:

**Nothing is reclaimed.** Tap **Pause flight** — the footprint holds at its peak
instead of dropping. Tap **Jump 4,000 km** (Manhattan → Los Angeles) — tiles for
the entire flown corridor are now far outside the frustum, and still nothing is
released; growth simply resumes from the previous peak. That is what makes this
read as an unbounded cache rather than a working set.

**Wider views are worse.** Switch the range picker to `200 m` and fly again. More
visible ground area per frame means more resident tiles, so the growth tracks
ground area covered, not elapsed time or frame count.

## Why it cannot be worked around in the app

The entire public surface of `Map` in `GoogleMaps3D.swiftinterface` (0.2.1) is
`init(initialCamera:mode:content:)`, `init(camera:mode:content:)`, `body`, and
`style(mapId:)`. There is no cache, memory, tile, LOD, purge or budget knob, and
no way to ask the SDK to drop tiles it no longer needs.

For comparison, MapKit rendering the same kind of content
(`MKImageryMapConfiguration(elevationStyle: .realistic)`) driven by the same
camera loop on the same device does not exhibit this: tiles that leave the
frustum are discarded and re-fetched when they return, and memory drops when the
map view is torn down.

Either of these would resolve it: the SDK bounding its own resident tile memory
(evicting outside the current frustum, or enforcing a budget sized to the
device's per-process limit), or exposing an API to set that budget and/or a
maximum level of detail — the equivalent of CesiumJS's `cacheBytes` /
`maximumScreenSpaceError`, or MapKit's implicit eviction.

// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Reproduction for: "Maps 3D SDK for iOS 0.2.1: unbounded tile memory growth
// during continuous camera movement leads to OS termination (no API to bound
// it)" — issuetracker.google.com/issues/543049057
//
// What it does: drives the camera in a straight first-person flight at 30 Hz,
// exactly like a continuous flight simulator would, and shows the process's
// phys_footprint on screen while it runs. Resident memory grows monotonically
// with the ground area traversed, never plateaus, and is not returned when the
// camera stops or jumps elsewhere — it ends in an EXC_RESOURCE jetsam kill
// (~2.2 GB with a debugger attached, ~3 GB without) on an iPhone 17 Pro.
//
// Everything here is public API. Nothing in this file caches, retains or
// allocates per frame apart from the Camera value itself: the only thing that
// accumulates is inside the SDK.

import SwiftUI
import GoogleMaps3D

struct TileMemoryGrowthDemo: View {
  // Midtown Manhattan — dense photorealistic 3D coverage, so tiles are as
  // heavy as they get. The bug reproduces anywhere with 3D coverage.
  private static let start = LatLngAltitude(
    latitude: 40.7580, longitude: -73.9855, altitude: 60)

  /// 30 Hz — a flight simulator's camera update rate. The growth tracks ground
  /// area covered, not frame count: a slower rate simply takes longer.
  private static let frameRate: Double = 30
  /// Metres per frame due north. 1 m at 30 Hz ≈ 30 m/s ≈ a fast consumer drone.
  private static let metresPerFrame: Double = 1
  private static let metresPerDegreeLat: Double = 111_320

  @State private var camera = Camera(
    center: Self.start, heading: 0, tilt: 72, roll: 0, range: 10,
    altitudeMode: .relativeToGround)

  @State private var flying = false
  @State private var frames = 0
  @State private var metresFlown: Double = 0
  @State private var footprintMB: Double = 0
  @State private var peakMB: Double = 0
  @State private var baselineMB: Double = 0

  /// The report notes a wider `range` makes the growth worse — more visible
  /// ground area per frame, so more tiles resident. Switchable here so the two
  /// cases can be compared on the same device without editing code.
  @State private var range: Double = 10

  private let tick = Timer.publish(
    every: 1.0 / Self.frameRate, on: .main, in: .common
  ).autoconnect()

  var body: some View {
    ZStack(alignment: .top) {
      Map(camera: $camera, mode: .hybrid)
        .ignoresSafeArea()
        .onReceive(tick) { _ in
          guard flying else { return }
          step()
        }

      readout
        .padding(.horizontal, 14)
        .padding(.top, 8)
    }
    .safeAreaInset(edge: .bottom) { controls }
    .onAppear {
      baselineMB = Self.footprintMB() ?? 0
      footprintMB = baselineMB
      peakMB = baselineMB
    }
  }

  // MARK: Camera

  /// One frame of straight-line flight. A fresh Camera value each tick is the
  /// only allocation; the previous one is released immediately.
  private func step() {
    frames += 1
    metresFlown += Self.metresPerFrame
    let dLat = Self.metresPerFrame / Self.metresPerDegreeLat
    camera = Camera(
      center: .init(
        latitude: camera.center.latitude + dLat,
        longitude: camera.center.longitude,
        altitude: 60),
      heading: 0, tilt: 72, roll: 0, range: range,
      altitudeMode: .relativeToGround)
    sampleMemory()
  }

  /// Teleport far from everything flown so far. Nothing here is reclaimed: the
  /// footprint stays at its peak and keeps climbing from there, which is why
  /// this reads as an unbounded cache rather than a working set.
  private func jumpAway() {
    camera = Camera(
      center: .init(latitude: 34.0522, longitude: -118.2437, altitude: 60),
      heading: 0, tilt: 72, roll: 0, range: range,
      altitudeMode: .relativeToGround)
    sampleMemory()
  }

  // MARK: Memory

  private func sampleMemory() {
    guard let mb = Self.footprintMB() else { return }
    footprintMB = mb
    if mb > peakMB { peakMB = mb }
  }

  /// `phys_footprint` — the number jetsam actually judges, and what Xcode's
  /// Memory gauge shows. Not `resident_size`, which undercounts compressed
  /// pages.
  private static func footprintMB() -> Double? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Double(info.phys_footprint) / (1024 * 1024)
  }

  // MARK: Chrome

  private var readout: some View {
    VStack(alignment: .leading, spacing: 4) {
      row("FOOTPRINT", String(format: "%.0f MB", footprintMB))
      row("PEAK", String(format: "%.0f MB", peakMB))
      row("SINCE START", String(format: "%+.0f MB", footprintMB - baselineMB))
      row("FLOWN", String(format: "%.2f km", metresFlown / 1000))
      row("FRAMES", "\(frames)  ·  range \(Int(range)) m")
    }
    .padding(12)
    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
    .foregroundStyle(.white)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func row(_ label: String, _ value: String) -> some View {
    HStack(spacing: 8) {
      Text(label)
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 92, alignment: .leading)
      Text(value)
        .font(.system(size: 15, weight: .bold, design: .monospaced))
    }
  }

  private var controls: some View {
    VStack(spacing: 10) {
      Picker("Camera range", selection: $range) {
        Text("range 10 m").tag(10.0)
        Text("range 200 m").tag(200.0)
      }
      .pickerStyle(.segmented)

      HStack(spacing: 10) {
        Button(flying ? "Pause flight" : "Start flight") {
          flying.toggle()
        }
        .buttonStyle(.borderedProminent)

        Button("Jump 4,000 km") { jumpAway() }
          .buttonStyle(.bordered)
      }

      Text(
        "Leave it running and watch FOOTPRINT. It climbs with ground area "
          + "covered and never plateaus; pausing or jumping away reclaims "
          + "nothing. Terminates on EXC_RESOURCE at ~2.2 GB (debugger) / ~3 GB."
      )
      .font(.system(size: 11))
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.thinMaterial)
  }
}

#Preview {
  TileMemoryGrowthDemo()
}

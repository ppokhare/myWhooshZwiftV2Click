# Zwift Click V2 for MyWhoosh on macOS

Click Bridge is a native Swift menu bar app. It connects to the right Zwift
Click V2 controller through Core Bluetooth and appears in MyWhoosh as an
OpenBikeControl controller. The bicycle icon shows the connection status
without opening the menu.

| Menu bar badge | Meaning |
| --- | --- |
| Gray dots | Waiting for both connections |
| Gray link | MyWhoosh connected, waiting for Click V2 |
| Gray antenna | Click V2 connected, waiting for MyWhoosh |
| Bike without a badge, in the system menu bar color | Click V2 and MyWhoosh connected |

Click the bicycle to see separate status rows for the Click V2 and MyWhoosh.

| Right controller button | Action |
| --- | --- |
| B | Shift up to a harder gear |
| + | Shift down to an easier gear |
| Z | Steer left while held |
| A | Steer right while held |
| Y | Unassigned |

## Build and connect

Requires macOS 13 or later and a Swift 6 toolchain from Xcode or the Xcode
Command Line Tools. From the repository folder, run:

```sh
./build-app.sh
open ".build/Click Bridge.app"
```

1. Grant Bluetooth and Local Network access if macOS prompts you.
2. Close Zwift, BikeControl, and any other bridge using the controller.
3. In MyWhoosh, click **Yes** when it asks to connect to the OpenBikeControl
   instance. Open the bicycle menu to confirm that the MyWhoosh row says
   **Connected**. Pair your trainer normally in **Connections**.
4. When you have the right controller, press a button to wake it while Click Bridge
   scans.

Bonjour is built into macOS. It lets MyWhoosh discover the bridge on the local
network automatically. Once discovered, MyWhoosh opens an OpenBikeControl
connection to receive button events.

You can run the app from `.build` while testing. For regular use, quit it and
drag **Click Bridge.app** to **Applications**, then launch that copy. When
you rebuild, replace the Applications copy to use the new version.

The bridge scans again when the controller disconnects. To use the controller
with Zwift or another app, choose **Quit Click Bridge** in the menu or press
**⌘Q** first.

### Bluetooth permission across builds

Local builds use ad hoc signing by default. macOS can ask for Bluetooth
permission again after the build changes. If you have an Apple Development
or Developer ID Application signing identity in your keychain, use the same
identity for each build so macOS can recognize the app across updates.

```sh
security find-identity -v -p codesigning
CLICK_BRIDGE_SIGN_IDENTITY="Your signing identity name" ./build-app.sh
```

## Verification

Run `swift test --disable-xctest` for the frame decoder, OpenBikeControl button
packets, and keep-awake protocol checks. A full MyWhoosh ride confirmed **B**, **+**, and normal hold and release
with only the right pod awake. After about a minute without input, the pod
went to sleep. The first press woke it and the bridge reconnected automatically.
The next press shifted. Click Bridge scans immediately after a disconnect, but
the default mode does not resolve the right pod's idle timeout. A shift can be
missed while the pod is asleep or reconnecting. The opt-in experiment below has
passed an initial B-button idle test; broader validation remains open.

See the [roadmap](ROADMAP.md) for hardware verification, security work, and notes
from the deferred Di2 and camera experiments.

- [ZwiftBoard](https://github.com/thomaschampagne/zwiftboard)
- [OpenBikeControl protocol](https://github.com/OpenBikeControl/openbikecontrol-protocol/blob/main/PROTOCOL.md)

## Experimental right-pod keep-awake (off by default)

This opt-in experiment targets a lone right Click V2 with **firmware exactly
1.2.0**, read from its Firmware Revision String (2A26). It requires the right-pod
advertisement and matching notify/write-without-response characteristics in
service FC82. It has no BikeControl runtime dependency, timed reboot, or synthetic
button/shift events. Existing RideOn, ACK, button and reconnect handling continues.

**These are firmware-update-interface writes.** BikeControl's
[implementation notes](https://github.com/OpenBikeControl/bikecontrol/commit/6610a01a08678d20d8b0ef9136a98f4c6e3bdaae)
mention a flash erase. The capture cannot establish affected flash regions,
flash wear, or long-term safety. Opt in only if you accept that uncertainty.
This is not yet validated for race use in Click Bridge.

Quit any running Click Bridge first, close BikeControl and Zwift, leave the left
pod off, then explicitly enable the experiment for this launch:

```sh
./build-app.sh
open ".build/Click Bridge.app" --args --experimental-right-keep-awake
```

Quit and launch normally without the flag to disable it. The flag is not saved.
The bridge subscribes once per connection, then runs the sequence after ordinary
handshake setup and about every 55 seconds. Each next write requires the exact
expected notification on its expected characteristic. When a cycle is due, the
bridge pauses RideOn and holds pending ACKs until the exchange ends. If Bluetooth
is busy before the first write, it waits up to two seconds for write capacity.
If capacity does not return, keep-awake is unavailable until reconnect. A timeout,
unexpected reply, lost subscription, or disconnect during an exchange disables
keep-awake until app restart. The menu shows the experiment's status and the
log reports the reason for failure. Ordinary button handling continues.

The first full race exposed this write contention after 13 successful cycles.
The previous build disabled keep-awake for the rest of the session and logged
seven subsequent Bluetooth timeouts. The change above still needs a hardware
retest. Run a bench session for at least 20 minutes before attempting a full
ride, since the earlier short idle test passed.

### Capture evidence and limits

The local BikeControl 7.5.0 capture is in `.build/ble-captures/` as
`bikecontrol-right-only-att.txt` and `bikecontrol-right-only-2026-11-14.pklg`.
`.build/` is ignored by Git; keep these traces local. Original packet bytes,
including the untruncated payload, show:

- Firmware read: `31 2E 32 2E 30` (1.2.0).
- Ordinary startup: `RideOn 02 03` on characteristic 00000003, its indication
  on 00000004 and ATT confirmation; separate `FF 04 00` writes to 00000100
  and 00000101. These startup ACKs are not replayed by the experiment.
- Notifications enabled on 00000100 and 00000102, then write commands (ATT
  opcode 52, without response): `01` to 00000102 → `01 F0 00`;
  `3D B8 F3 96 00 00 00 00 00 01 00 00 00 B0 03 00 00 00` to 00000100 → `00`;
  `03` to 00000102 → `12 00 00 00 00 00`.
- Sequence starts at 04:34:06.185, 04:35:01.476, 04:35:56.470,
  04:36:51.488, and 04:37:46.477 (capture timestamps). BikeControl repeats
  notification configuration each cycle; Core Bluetooth retains the enabled
  subscriptions here. All characteristic IDs use suffix
  `-19ca-4651-86e5-fa29dcdd09d1`; no ATT handles are hardcoded.

The recorded interval shows no disconnect. The user reported that, with the
left pod off, the first + tap after two minutes idle shifted exactly one gear
using BikeControl. That does not establish Click Bridge behavior or flash safety.

### Click Bridge validation on November 14, 2026

With the experiment enabled on the right pod, the first **B** tap after
**133.649 seconds** without button input produced exactly one press and release
in the bridge log. The rider confirmed one gear change in MyWhoosh on that tap.
The previous release was at 19:49:14.727 UTC; B went down at 19:51:28.376 and
up at 19:51:28.587. No BLE disconnect or reconnect occurred during the interval,
and four keep-awake sequences completed through 19:51:37.046 UTC.

This validates one B-button trial after more than two minutes idle in Click
Bridge. It does not yet validate **+** after idle, both buttons around the
one-minute boundary, repeated long rides, or flash safety.

The release app built successfully. All five test methods passed when run as
standalone Swift assertions. On this machine, `swift test --disable-xctest`
failed because the installed Command Line Tools could not load `TestingMacros`;
the native build-system fallback could not import `Testing`. The assertion run
covers protocol logic and button packets, not Core Bluetooth callbacks or timers.

### Remaining physical validation before race use

With Click Bridge itself and MyWhoosh connected, explicitly opt in as above.
Observe `click-bridge-idle.log` in the repository, or Console (search `ClickBridge`),
for sequence completion or failure.
Verify each test separately for **+** and **B**, starting from a gear where the
expected shift is possible:

1. Leave both buttons untouched for 55, 60, 65, and 120 seconds in separate trials.
   Tap once and confirm exactly one gear change on that first tap, in the mapped
   direction (+ easier, B harder). Do not use a second tap to hide a missed first tap.
2. Repeat across several keep-awake cycles; test near the 55-second sequence
   boundary. Check for duplicates, lost presses, disconnects and reconnections.
3. Verify normal press/hold/release and Z/A steering, then a deliberate disconnect
   and reconnect. A partial-sequence failure should leave ordinary controls working
   after reconnect and require app restart to re-enable the experiment.
4. Quit and relaunch without the flag to verify the default mode sends no
   experimental writes. Do not depend on this mode in a race until these checks pass.

Automated tests cover the exact sequence, eligibility, overlap prevention, wrong
channel/duplicate/unexpected replies and terminal failure states, plus existing
button decoding and output packets. They do not emulate Core Bluetooth or prove
physical idle behavior, reconnect timing, or flash endurance.

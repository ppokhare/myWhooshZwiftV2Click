# Zwift Click V2 bridge roadmap

## 1. Verify with a physical Click V2

The full ride used only the right pod. The left pod stayed in its box.

- [x] Verify that B and + shift in MyWhoosh during a full ride.
- [x] Verify ordinary button hold and release.
- [x] Verify wake and reconnect. The right pod slept after about 60 seconds of inactivity. The first press woke it and it reconnected automatically. The second press shifted.
- [x] Document confirmed hardware behavior in the README.
- [x] Capture a right-pod-only ride and check the available `RideOn` write modes.
- [x] Capture the BikeControl 7.5.0 keep-awake sequence on right-pod firmware 1.2.0.
- [x] Implement an experimental, explicit opt-in replay with firmware/GATT/reply guards and no BikeControl dependency.
- [x] Verify one first-tap **B** shift after more than two minutes idle in Click Bridge: one press/release, one observed gear change, no BLE reconnect.
- [ ] Verify first-tap **+** after two minutes idle, and both buttons around the one-minute mark (55, 60, and 65 seconds).
- [ ] Run a 20-minute bench session and a full ride with the write arbitration fix; verify steering, hold/release, clean reconnect, partial-sequence failure, and default-off behavior on hardware.
- [ ] Repeat the MyWhoosh restart test while the Click V2 row stays connected. The first attempt required waking the pod and reconnecting in MyWhoosh.

### Right-pod idle verification

On November 11, the rider needed multiple taps to shift after the right pod
went idle. Five of the seven BLE timeouts occurred 60.4–61.0 seconds after
the last decoded button release. The bridge submitted a `RideOn` write within
three seconds of every timeout. The pod advertised only write without response,
so the acknowledged-write comparison is unavailable on the tested unit.

Click Bridge scans immediately after a disconnect. The timed reset experiment
was removed because a tap during the reboot can be lost.

On November 14, a local BikeControl 7.5.0 capture confirmed firmware **1.2.0**
and five complete keep-awake sequences about 55 seconds apart. The user reported
one gear change on the first + tap after two minutes idle with the left pod off.
The decoded bytes now drive Click Bridge's guarded, opt-in implementation.
Capture files and ride logs remain local and ignored by Git.

The first Click Bridge hardware trial also passed: after **133.649 seconds**
since the last button release, **B** generated one press and one release, and the
rider observed exactly one gear change. There was no BLE disconnect or reconnect
in that interval. Four keep-awake sequences completed through 19:51:37.046 UTC.
This result covers B only; the requested + trial remains open.

The first race exposed a failure after 13 successful exchanges. RideOn was
submitted 1 ms before keep-awake disabled itself, followed by seven BLE
timeouts. The revised bridge waits briefly for write capacity before starting
an exchange and holds competing writes while the exchange runs. The first
race result remains unresolved until a longer bench test and full ride pass.

The mode stays **off by default**. The writes use the firmware-update interface,
and BikeControl's [public change notes](https://github.com/OpenBikeControl/bikecontrol/commit/6610a01a08678d20d8b0ef9136a98f4c6e3bdaae)
mention a flash erase. Neither the capture nor this successful shift establishes
which regions are affected, flash endurance, or long-term safety. Missing or
unexpected replies stop the experiment without stopping ordinary button handling;
a partial sequence is never retried automatically, including after reconnect.

Follow the [README's opt-in and validation instructions](README.md#experimental-right-pod-keep-awake-off-by-default).
Test **+** and **B** separately at 55, 60, 65, and 120 seconds after the last
release, away from gear limits. Confirm the first tap changes exactly one gear
in the mapped direction and match it to one press/release in the log. Repeat
through several cycles before relying on it in a race.

The app release build and a standalone assertion run of all five test methods
passed. The standard Swift Testing runner is blocked on this machine by missing
toolchain testing components; Core Bluetooth failure callbacks and timing still
need hardware validation.

## 2. Harden the Swift bridge after hardware verification

- [ ] Restrict who can connect to the OpenBikeControl listener. Test same-Mac
  discovery and reconnect before making local-only access the default. Verify
  that other LAN clients cannot receive button events, and use a generic
  connection status unless the bridge can verify the client's identity.
- [ ] Limit total and per-peer TCP connections and bound inbound work so idle
  sockets and flooding cannot disrupt the ride. Verify that MyWhoosh can still
  connect, reconnect, and receive button events under load.
- [ ] Require explicit enrollment of the right Click V2 pod and reconnect only
  to the enrolled device. Check whether the hardware supports authenticated
  bonding, and verify that a second pod cannot take over the connection.

## 3. Verify disconnect behavior

- [ ] Disconnect the pod while holding a button and verify that the action releases.

## Deferred experiments

### Shimano Di2 D-FLY

Revisit when Di2 hardware is available. The [Di2 prototype](https://github.com/ppokhare/myWhooshZwiftV2Click/pull/1)
had its Python 3.10 setup, CLI, and Click packet tests checked. The PR records
Di2 hardware testing as still pending. It provided a keyboard-only test path
to send OpenBikeControl shifts without a Di2 unit.

| Reverse-engineered BLE identifier | UUID |
| --- | --- |
| Shimano service | `000018ef-5348-494d-414e-4f5f424c4500` |
| D-FLY button characteristic | `00002ac2-5348-494d-414e-4f5f424c4500` |

The prototype expected `[counter, CH1, CH2, CH3, CH4]`. It mapped a short press
(`0x10`) on CH2 to Shift Up (`0x01`) and CH1 to Shift Down (`0x02`), skipping
channel values of `0xF0` and consecutive duplicate counters. With hardware,
capture button notifications or indications and confirm the UUIDs, packet
layout, and channel mapping for the unit's firmware.

### MyWhoosh camera view

Wait for MyWhoosh's camera-control fix before revisiting the
[camera experiment](https://github.com/ppokhare/myWhooshZwiftV2Click/pull/2).
The simulator tried binding Y to OpenBikeControl Camera View (`0x40`) with
cycle value `0x01` and experimental direct-select value `0x05`. MyWhoosh 5.7.0
advertised Camera View in App Information, and shifting changed the displayed
gear in the same session. Neither camera value visibly changed the view. Keep
Y unassigned until a MyWhoosh build with the fix responds to the standard
cycle command in the simulator.

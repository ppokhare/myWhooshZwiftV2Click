# Zwift Click V2 bridge roadmap

## 1. Verify with a physical Click V2

The full ride used only the right pod. The left pod stayed in its box.

- [x] Verify that B and + shift in MyWhoosh during a full ride.
- [x] Verify ordinary button hold and release.
- [x] Verify wake and reconnect. The right pod slept after about 60 seconds of inactivity. The first press woke it and it reconnected automatically. The second press shifted.
- [x] Document confirmed hardware behavior in the README.
- [ ] Fix the idle timeout. Verify that the right pod stays connected for at least two minutes without input and that the first press afterward shifts once. Test with the left pod off and, separately, with it awake nearby and unpaired.
- [ ] Repeat the MyWhoosh restart test while the Click V2 row stays connected. The first attempt required waking the pod and reconnecting in MyWhoosh.

BikeControl's [6.5.0 release notes](https://bikecontrol.app/changelog/) describe
an idle fix for right-side-only input. Its [public implementation notes](https://github.com/OpenBikeControl/bikecontrol/commit/1d1a0dbf72803cbc468394265338f239ab287eb5)
say the left pod must be awake and in range for that method. The BLE sequence
is in BikeControl's private package. A BLE trace of a successful keep-awake
session would provide the write sequence to test in Click Bridge.

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

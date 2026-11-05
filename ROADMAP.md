# Zwift Click V2 bridge roadmap

## 1. Verify with a physical Click V2

The first milestone for the Swift menu bar app is a full ride, an idle break
long enough for the pod to sleep, and a successful shift after waking it.

- [ ] Accept MyWhoosh’s OpenBikeControl prompt and verify that B and + move one gear per physical press.
- [ ] Let the pod sleep during a ride, wake it, and verify that shifting resumes without restarting the bridge. Record whether the left pod needs to be awake.
- [ ] Restart MyWhoosh while the pod stays connected and verify that shifting resumes after MyWhoosh reconnects.
- [ ] Disconnect the pod while holding a button and verify that the action releases.
- [ ] Verify whether MyWhoosh responds to the OpenBikeControl steering actions and whether hold and release behave as intended.
- [ ] Document confirmed hardware behavior in the README.

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

# Zwift Click V2 (right pod) -> MyWhoosh, on macOS

A lightweight Python bridge. Uses the `di2_mywhoosh_bridge.py`
OpenBikeControl server. MyWhoosh connects via OpenBikeControl and the KICKR CORE 2
connects to MyWhoosh as the trainer. Do **not** pair Click directly with MyWhoosh.

## Right Click pod mappings

| Button | MyWhoosh/OpenBikeControl action |
|---|---|
| B | Shift up / harder gear (`0x01`) |
| + | Shift down / easier gear (`0x02`) |
| Z | Steer left (`0x18`), held until physical release |
| A | Steer right (`0x19`), held until physical release |
| Y | Disabled by default |

The experimental `--camera cycle` sends OpenBikeControl value `1`, and
`--camera select5` tries the app-specific value `5`. Both produced no visible
change in MyWhoosh. The protocol does not define a universal Camera 5 value.

## Setup (Python 3.10+)

Open Terminal in the extracted folder and run:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
python click_mywhoosh_bridge.py
```

- Grant macOS Bluetooth and Local Network access if prompted.
- Close Zwift, BikeControl, and anything else that might hold the Click BLE link.
- Press a Click button to wake the right pod when it scans.
- In MyWhoosh's Connections screen, select **OpenBikeControl** then confirm
  `Click Python Bridge` if offered. The bridge stays available while it runs,
  so you can open Connections after starting it.
- For logging: `python click_mywhoosh_bridge.py --debug`
- If the right pod disconnects after ~1 minute idle, try `--idle-reset 55`
  (OFF by default because the experimental macOS port of ZwiftBoard reported
  10-minute stable idle sessions).

### Test without Click V2 or trainer

Start the simulator:

```bash
python click_mywhoosh_bridge.py --simulate
```

Select `Click Python Bridge` in MyWhoosh and wait for the simulator to log
`MyWhoosh/OpenBikeControl client connected`. Type `B`, `+`, `Z`, or `A`
followed by Enter to send a tap. Check the MyShift gear indicator during a ride
to verify that `B` and `+` shift. Test `Z` and `A` while the rider is moving.
The simulator holds steering for 2 seconds. Real buttons keep steering pressed
for as long as held.

### Check camera support reported by MyWhoosh

```bash
uv run --no-project python click_mywhoosh_bridge.py --simulate --camera cycle --debug
```

Reconnect MyWhoosh and check for an `OpenBikeControl App Information` line.
If MyWhoosh sends an explicit button list, `40` is the Camera View action.
The installed macOS app was MyWhoosh `6.2.3` (build `1245`). Its OpenBikeControl
App Information reported `5.7.0` and listed `40`. The view stayed on Camera 1
after the standard cycle command, including after the bridge began sending the
reference controller's initial ready message. In the same session, `B` shifted
the displayed gear to 30.

## What has and hasn't been tested

- Python syntax and packet-state unit tests: **passed locally**.
- MyWhoosh OpenBikeControl connection and simulated shifts in both directions:
  **confirmed**. Steering and camera selection have yet to respond in the simulator.
- Physical Zwift Click V2, MyWhoosh camera selection, reconnections and real
  races: **not yet tested**. Please report logs, especially if `Y` does not
  select camera 5 or right-pod discovery fails.
- The LEFT pod is **not** supported because its buttons require Zwift's
  time-limited unlock. You may need the left pod powered on as the pair's BLE
  anchor, but this script only connects to the right pod.
- Install `bleak` and `zeroconf` from `requirements.txt`.
- The Di2 bridge can still run separately.
  Don't run both at once unless you intentionally want two OpenBikeControl
  servers with different advertised names.

Protocol references:
- https://github.com/thomaschampagne/zwiftboard (MIT, Click BLE)
- https://github.com/OpenBikeControl/openbikecontrol-protocol/blob/main/PROTOCOL.md (MIT)

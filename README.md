# Zwift Click V2 for MyWhoosh on macOS

Use the right Zwift Click V2 pod for virtual shifting and steering in
MyWhoosh. The bridge connects to the pod over Bluetooth and appears in
MyWhoosh as an OpenBikeControl controller.

| Right pod button | Action |
| --- | --- |
| B | Shift up to a harder gear |
| + | Shift down to an easier gear |
| Z | Steer left while held |
| A | Steer right while held |
| Y | Unassigned |

## Setup with uv

Install [uv](https://docs.astral.sh/uv/getting-started/installation/), then run
these commands from the repository folder.

```bash
uv venv --python 3.10
uv pip install -r requirements.txt
uv run python click_mywhoosh_bridge.py
```

1. Grant macOS Bluetooth and Local Network access if prompted.
2. Close Zwift, BikeControl, or any other app using the pod's Bluetooth connection.
3. Press a button to wake the right pod while the bridge scans.
4. In MyWhoosh's **Connections** screen, pair your trainer normally. Select
   **OpenBikeControl** and choose **Click Python Bridge** if prompted.

The bridge supports the right pod. Some setups may need the left pod powered on
as the pair's Bluetooth anchor.

Add `--debug` to log Bluetooth frames. If the right pod disconnects after about
a minute idle, try `--idle-reset 55` to have the bridge reconnect after 55 seconds
of inactivity.

## Test without a pod or trainer

```bash
uv run python click_mywhoosh_bridge.py --simulate
```

Connect **Click Python Bridge** in MyWhoosh. Type `B`, `+`, `Z`, or `A` and
press Enter to send the action. Check the MyShift gear indicator during a ride
to verify shifting. The simulator holds steering for two seconds.

Simulated shifts in both directions were confirmed in MyWhoosh. Simulated
steering did not visibly respond. Physical pod behavior and reconnection still
need hardware testing.

Run the packet and button mapping tests with `uv run python -m unittest`.

## Protocol references

- [ZwiftBoard](https://github.com/thomaschampagne/zwiftboard)
- [OpenBikeControl protocol](https://github.com/OpenBikeControl/openbikecontrol-protocol/blob/main/PROTOCOL.md)

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
with Zwift or another app, choose **Quit Click Bridge** in the menu or press **⌘Q** first. Some setups
may require the left controller to be awake as the pair's Bluetooth anchor.

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

Run `swift test --disable-xctest` for the Click frame decoder and OpenBikeControl button packet
checks. During a ride, check the MyShift gear indicator after pressing **B**
and **+**, then verify **Z** and **A** where steering is available. Physical controller
behavior and in-ride steering still need to be verified in the Swift app.

The Python bridge remains in the repository as a protocol reference.

- [ZwiftBoard](https://github.com/thomaschampagne/zwiftboard)
- [OpenBikeControl protocol](https://github.com/OpenBikeControl/openbikecontrol-protocol/blob/main/PROTOCOL.md)

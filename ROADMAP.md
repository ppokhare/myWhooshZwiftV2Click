# Zwift Click V2 bridge roadmap

Keep the Python bridge as the reference implementation. The first milestone is a full ride, an idle break long enough for the pod to sleep, and a successful first shift after waking it without manually restarting the bridge.

## 1. Validate real rides

- [ ] Verify that both shift buttons reliably move one gear per press on the physical right pod.
- [ ] Let the pod sleep during a ride, wake it, and verify that the first intended shift works. Record whether the left pod or `--idle-reset` is needed.
- [ ] Restart MyWhoosh while the Click stays connected and verify that shifting resumes after MyWhoosh reconnects.
- [ ] Disconnect the pod while holding a button and verify that no action stays stuck.
- [ ] Verify steering in MyWhoosh with the physical pod. Confirm that holding and releasing each steering button behaves as intended before including steering in v1.
- [ ] Update the README with the hardware behavior confirmed during testing.

## 2. Harden reconnects and measure latency

- [ ] Use Bleak's disconnect callback to detect link loss promptly instead of waiting for the three-second connection check.
- [ ] End BLE discovery as soon as the target pod is found instead of waiting for the full eight-second scan.
- [ ] Put a deadline on TCP writes and remove stalled clients so they cannot indefinitely delay later button events or BLE acknowledgments.
- [ ] Add optional timing logs from BLE notification arrival to the OpenBikeControl TCP write. Use them to separate delay inside the bridge from delay elsewhere.
- [ ] Repeat the ride and reconnect checks after these changes.

## Personal use

Run the Python bridge from Terminal using the README instructions. Bleak already uses macOS Core Bluetooth, and the bridge handles small messages. Focus optimization on measured connection and I/O delays.

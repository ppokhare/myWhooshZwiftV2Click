# Zwift Click V2 bridge roadmap

The first milestone for the Swift menu bar app is a full ride, an idle break
long enough for the pod to sleep, and a successful shift after waking it.

- [ ] Accept MyWhoosh’s OpenBikeControl prompt and verify that B and + move one gear per physical press.
- [ ] Let the pod sleep during a ride, wake it, and verify that shifting resumes without restarting the bridge. Record whether the left pod needs to be awake.
- [ ] Restart MyWhoosh while the pod stays connected and verify that shifting resumes after MyWhoosh reconnects.
- [ ] Disconnect the pod while holding a button and verify that the action releases.
- [ ] Verify whether MyWhoosh responds to the OpenBikeControl steering actions and whether hold and release behave as intended.
- [ ] Document confirmed hardware behavior in the README.

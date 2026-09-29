# test-harness.sh

Enable/disable the vg-test-harness on your developer namespace without a git
commit (bypasses Flux; reverts on next reconcile).

```bash
./scripts/test-harness.sh enable  --namespace <your-ns>
./scripts/test-harness.sh disable --namespace <your-ns>
```

`enable` leaves the freeswitch image alone. It used to force an asan/debug build
for `TESTING_OVERRIDE_*`, which the chart no longer sets — a `custom:<name>`
speech credential carries its own URL, and `vgTestHarness.speechInterception:
vendor` redirects by DNS, both of which work on the production image. Pass
`--freeswitch-image` if you want a specific one anyway.

After enabling, port-forward `sip-caller` and POST a scenario from
`vg-test-harness/scenarios/`. Use Deepgram/ElevenLabs scenarios only — Azure
and other SDK vendors cannot be mocked this way.

# test-harness.sh

Enable/disable the vg-test-harness on your developer namespace without a git
commit (bypasses Flux; reverts on next reconcile).

```bash
./scripts/test-harness.sh enable  --namespace <your-ns>
./scripts/test-harness.sh disable --namespace <your-ns>
```

`enable` also forces an asan/debug freeswitch image, because the
`TESTING_OVERRIDE_*` env vars are compiled out of production FreeSWITCH builds
(vg-freeswitch PR #255). Pass `--freeswitch-image` to override the default.

After enabling, port-forward `sip-caller` and POST a scenario from
`vg-test-harness/scenarios/`. Use Deepgram/ElevenLabs scenarios only — Azure
and other SDK vendors cannot be mocked this way.

# Spec: the shared contract

Source of truth for every platform. Swift and Kotlin cores both implement it and are held to parity by the golden fixtures.

- `commands.json` — every shell command we run (id, script, timeout, distro).
- `models.schema.json` — JSON Schema for the parsed models.
- `attention-rules.json` — rules behind the needs-attention strip.
- `fixtures/<command-id>/NAME.out.txt` + `NAME.expected.json` — captured stdout and the expected parsed result. Both platforms' parsers must match.
- `features.json` — the feature parity matrix: every feature per platform (mac, android, ios, web) as done (with the tests that prove it), planned or na (with a reason). `tools/check-parity` checks the named tests against JUnit reports.
- `scenarios/*.json` — shared behaviour cases (quoting, action policy, compose commands, stream markers...) that every core's `SharedScenarioTests` runs while the scenario's feature is done there.
- `integration/checks.json` — checks every SSH transport runs against the integration lab (`test/lab`, `tools/lab up`).

See `docs/parity.md` for how these fit together.

`python3 tools/check-spec` enforces consistency.

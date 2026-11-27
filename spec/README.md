# Spec: the shared contract

Source of truth for every platform. Swift and Kotlin cores both implement it and are held to parity by the golden fixtures.

- `commands.json` — every shell command we run (id, script, timeout, distro).
- `models.schema.json` — JSON Schema for the parsed models.
- `attention-rules.json` — rules behind the needs-attention strip.
- `fixtures/<command-id>/NAME.out.txt` + `NAME.expected.json` — captured stdout and the expected parsed result. Both platforms' parsers must match.
- `features.json` — the feature parity matrix: every feature per platform (mac, android, ios, web) as done (with the tests that prove it), planned or na (with a reason). `tools/check-parity` checks the named tests against JUnit reports.
- `scenarios/*.json` — shared behaviour cases (quoting, action policy, compose commands, stream markers...) that every core's `SharedScenarioTests` runs while the scenario's feature is done there.
- `config-transfer.md`, `config-transfer.schema.json`, `config-transfer.json` — the `rackoon-config` export/import format, its shape, and the catalog of every saved setting and data file on each platform (carried or device-local with a reason). `fixtures/config/` (made by `tools/config-fixtures`) and `scenarios/config-codec.json` / `config-merge.json` are its shared cases.
- `integration/checks.json` — checks every SSH transport runs against the integration lab (`test/lab`, `tools/lab up`).

See `docs/parity.md` for how these fit together.

`python3 tools/check-spec` enforces consistency.

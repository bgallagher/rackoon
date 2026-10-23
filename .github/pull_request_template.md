## What changed


## Parity (docs/parity.md)

- [ ] `spec/` changed first if a server command, parser or shared rule changed (command, fixture, scenario)
- [ ] `spec/features.json` updated for **every** platform (mac, android, ios, web): done with tests, or planned/na with a reason
- [ ] Shared behaviour has a scenario in `spec/scenarios/`; behaviour that talks to a server has a lab check in `spec/integration/checks.json`
- [ ] `python3 tools/check-spec` passes; the `parity` CI job passes
- [ ] Nothing was run against a real server except read-only probes (writes only in the lab or throwaway `/tmp` stacks)

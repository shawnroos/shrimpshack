# Preset

The payload of one step, with a name: a tuned review or a scoped build. `/auto-preset <name> <target>` runs one preset once against a target and returns pass, fail or unverified. Status: provisional.

- **Where it lives:** `docs/contracts/preset-format.md`
- **Note:** A preset is not a loop. No flow runs around it.

---
name: retro_probe_item
description: A canonical retro item carrying a probe.
disposition: open
surface: plugin
thing: plugins/reflect/scripts/retro.py
opened: 2026-08-20
sessions: sessA
capture: live
metadata:
  type: retro
---

The list entry point returned nothing against a store that held three open items.

Cost so far: one review pass spent re-reading the store by hand.

Related: [[feedback_verify_background_work_by_effect_not_log]]

## Probe

```bash
last_used: 2020-01-01
pin: true
python3 -c 'print("RETRO-FIXED " + __import__("os").environ["RETRO_NONCE"])'
```

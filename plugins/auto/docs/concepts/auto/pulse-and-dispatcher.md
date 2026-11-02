# Pulse and dispatcher

The pulse is the self-pacing beat that moves a run forward. The dispatcher decides how many workers run in each wave, and the driving agent can resize that number during the run.

- **Where it lives:** `lib/dispatcher.py`
- **Note:** Both read the run record. Neither decides when the run is done.

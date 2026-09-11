"""One canonical JSON form, so two values compare and hash the same way everywhere."""

import json


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)

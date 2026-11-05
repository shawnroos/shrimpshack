"""The one transcript a test session has, registered the way SessionStart registers it.

Pick and prompt checks accept only the path the session registry holds for the session.
"""

import os
import pathlib


def _load(name):
    from _bootstrap import load_lib_module
    return load_lib_module(name)


def _rows(sid):
    return [r for r in _load('session_registry')._all_rows() if r.get('session_id') == sid and r.get('transcript_path')]


def register(sid, path):
    reg = _load('session_registry')
    held = _rows(sid)
    if held and max(held, key=lambda r: r['at'])['transcript_path'] == str(path):
        return pathlib.Path(path)
    # An old stamp: any real row a test writes for this session stays the one a pane or space lookup returns.
    stamp = f'2000-01-01T00:{len(held) // 60:02d}:{len(held) % 60:02d}Z'
    reg._append(reg.registry_path('default', 'fixture-transcripts'),
                {'at': stamp, 'session_id': sid, 'transcript_path': str(path), 'interactive': False,
                 'server': 'default', 'workspace': 'fixture-transcripts', 'pane_id': 'fixture:' + sid,
                 'host': _load('terminal_host').detect().name or 'herdr'})
    return pathlib.Path(path)


def transcript(sid):
    held = _rows(sid)
    if held:
        return pathlib.Path(max(held, key=lambda r: r['at'])['transcript_path'])
    folder = pathlib.Path(os.environ['CLAUDE_AUTO_DATA_DIR']).parent / 'session-transcripts'
    folder.mkdir(parents=True, exist_ok=True)
    return register(sid, folder / (sid + '.jsonl'))

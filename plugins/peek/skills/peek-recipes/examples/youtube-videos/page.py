#!/usr/bin/env python3
import json
import re
import sys
from urllib.parse import parse_qs, urlparse

link = sys.argv[-1]
url = urlparse(link)
query = parse_qs(url.query)
video = url.path.strip('/') if url.hostname == 'youtu.be' else query.get('v', [''])[0]

if not re.fullmatch(r'[A-Za-z0-9_-]{11}', video):
    print(f'no YouTube video id in {link}', file=sys.stderr)
    sys.exit(2)

start = query.get('t', [''])[0].removesuffix('s')
watch = f'https://www.youtube.com/watch?v={video}'
short = f'https://youtu.be/{video}'
details = [{'label': 'Video', 'value': video}]
if start.isdigit():
    seconds = int(start)
    watch += f'&t={seconds}s'
    short += f'?t={seconds}'
    details.append({'label': 'Starts at', 'value': f'{seconds // 60}:{seconds % 60:02d}'})

page = {
    'title': f'YouTube video {video}',
    'details': details,
    'sections': [
        {
            'heading': 'Thumbnail',
            'block': {'type': 'media', 'items': [{'url': f'https://i.ytimg.com/vi/{video}/hqdefault.jpg', 'alt': 'Video thumbnail', 'kind': 'image'}]},
        },
        {
            'heading': 'Watch',
            'block': {
                'type': 'list',
                'items': [
                    {'title': 'Watch on YouTube', 'meta': 'www.youtube.com', 'href': watch},
                    {'title': 'Embedded player, no cookies', 'meta': 'www.youtube-nocookie.com', 'href': f'https://www.youtube-nocookie.com/embed/{video}'},
                ],
            },
        },
        {
            'heading': 'Share',
            'block': {'type': 'fields', 'rows': [{'label': 'Short link', 'value': short}]},
        },
    ],
    'actions': [
        {'label': 'Open on YouTube', 'open': watch},
        {'label': 'Copy short link', 'copy': short},
    ],
}

json.dump(page, sys.stdout, indent=2)
print()

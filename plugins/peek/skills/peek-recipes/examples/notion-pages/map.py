#!/usr/bin/env python3
# Maps the Notion MCP server's notion-fetch result to a peek Page.
# examples/notion-pages.sample.json is a made-up sample in the shape that tool returns, saved as peek's map stdin.
import json
import re
import sys

source = json.load(sys.stdin)
try:
    fetched = json.loads(source['text'])
except (json.JSONDecodeError, TypeError):
    print('notion-fetch did not return JSON text; is the link a Notion page?', file=sys.stderr)
    sys.exit(3)

if fetched.get('metadata', {}).get('type') != 'page':
    print(f"not a page: notion-fetch returned a {fetched.get('metadata', {}).get('type')}", file=sys.stderr)
    sys.exit(3)

body = fetched['text']


def tag(name):
    found = re.search(rf'<{name}>\n?(.*?)\n?</{name}>', body, re.S)
    return found.group(1) if found else ''


properties = json.loads(tag('properties') or '{}')
details = [{'label': label, 'value': str(value)} for label, value in properties.items() if label != 'title' and value not in (None, '', [])]

content = tag('content')
children = [{'title': title, 'meta': 'Page', 'href': url} for url, title in re.findall(r'^<page url="([^"]+)">(.*?)</page>$', content, re.M)]
content = re.sub(r'^<page url="[^"]+">.*?</page>\n?', '', content, flags=re.M)

table = None
table_heading = 'Table'
found = re.search(r'<table[^>]*>(.*?)</table>\n?', content, re.S)
if found:
    rows = [re.findall(r'<td>(.*?)</td>', row, re.S) for row in re.findall(r'<tr>(.*?)</tr>', found.group(1), re.S)]
    if rows:
        table = {'type': 'table', 'columns': rows[0], 'rows': [{'cells': cells} for cells in rows[1:]]}
    before = content[: found.start()]
    heading = re.search(r'^#+ (.+)\n$', before, re.M)
    if heading and heading.end() == len(before):
        table_heading = heading.group(1)
        before = before[: heading.start()]
    content = before + content[found.end() :]

sections = [{'block': {'type': 'markdown', 'text': content.strip()}}]
if children:
    sections.append({'heading': 'Pages inside', 'block': {'type': 'cards', 'items': children}})
if table:
    sections.append({'heading': table_heading, 'block': table})

parent = re.search(r'<parent-page url="([^"]+)" title="([^"]*)"', body)
actions = [{'label': 'Open in Notion', 'open': fetched['url']}]
if parent:
    actions.append({'label': f'Open {parent.group(2)}', 'open': parent.group(1)})
actions.append({'label': 'Copy link', 'copy': fetched['url']})

print(json.dumps({'title': fetched['title'], 'details': details, 'sections': sections, 'actions': actions}, indent=2))

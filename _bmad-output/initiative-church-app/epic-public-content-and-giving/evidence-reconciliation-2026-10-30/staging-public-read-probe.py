"""Read-only signed-out HTTP observations; never stores keys or response text.

Usage: python3 staging-public-read-probe.py --config /private/client.json --output /path/result.json
The private JSON contains SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY. It is not evidence.
Only this explicitly identified staging project is supported by this probe.
"""
import argparse
import datetime
import json
from pathlib import Path
import urllib.error
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('--config', required=True)
parser.add_argument('--output', required=True)
args = parser.parse_args()
config = json.loads(Path(args.config).read_text())
base = config['SUPABASE_URL'].rstrip('/')
if base != 'https://tmurpotfluignacfueki.supabase.co':
    raise SystemExit('Refusing an unexpected target; review the probe for any other environment.')
headers = {'apikey': config['SUPABASE_PUBLISHABLE_KEY'], 'Content-Type': 'application/json',
           'Content-Profile': 'api', 'Accept-Profile': 'api'}
checks = []

def read(name, params, condition, summarize=lambda data: {}):
    request = urllib.request.Request(base + '/rest/v1/rpc/' + name,
                                    data=json.dumps(params).encode(), headers=headers, method='POST')
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            status, data = response.status, json.load(response)
        ok = status == 200 and bool(condition(data))
        checks.append({'rpc': name, 'http_status': status, 'status': 'run-passed' if ok else 'run-failed',
                       'observation': summarize(data)})
        return data
    except urllib.error.HTTPError as error:
        checks.append({'rpc': name, 'http_status': error.code, 'status': 'run-failed',
                       'observation': {'response_body_omitted': True}})
    except Exception as error:
        checks.append({'rpc': name, 'status': 'run-failed', 'error_type': type(error).__name__})
    return None

for rpc, key in [('content_public_events', 'events'), ('content_public_announcements', 'announcements'),
                 ('content_public_banners', 'banners'), ('content_public_giving_methods', 'methods'),
                 ('content_public_sermons', 'sermons')]:
    read(rpc, {}, lambda data, key=key: isinstance(data, dict) and isinstance(data.get(key), list),
         lambda data, key=key: {'count': len(data.get(key, [])), 'keys': sorted(data)})
read('content_public_sunday_hymns', {}, lambda data: isinstance(data, dict) and isinstance(data.get('items'), list),
     lambda data: {'item_count': len(data.get('items', [])), 'keys': sorted(data)})
unknown = '00000000-0000-4000-8000-000000000000'
for rpc, param, key in [('content_public_event', 'event_id', 'event'),
                        ('content_public_sermon', 'sermon_id', 'sermon'),
                        ('content_public_giving_method', 'method_id', 'method')]:
    read(rpc, {param: unknown}, lambda data, key=key: isinstance(data, dict) and data.get(key, 'missing') is None,
         lambda data, key=key: {'unknown_record_is_null': data.get(key, 'missing') is None})
catalog = read('content_public_bible_translations', {},
               lambda data: isinstance(data, dict) and isinstance(data.get('translations'), list),
               lambda data: {'translations': [{'code': row.get('translation_code'),
                                               'chapter_count': len(row.get('chapters', [])),
                                               'book_count': len({ch.get('book_id') for ch in row.get('chapters', [])}),
                                               'offline_allowed': row.get('offline_allowed')}
                                              for row in data.get('translations', [])]})
read('content_bible_manifest', {'translation_code': 'NOT_REGISTERED'},
     lambda data: data is None, lambda data: {'unknown_manifest_is_null': data is None})
read('content_public_bible_chapter', {'translation_id': unknown, 'book_id': 'GEN', 'chapter': 1},
     lambda data: isinstance(data, dict) and data.get('chapter', 'missing') is None,
     lambda data: {'unknown_chapter_is_null': data.get('chapter', 'missing') is None})
web = next((row for row in (catalog or {}).get('translations', []) if row.get('translation_code') == 'WEB'), None)
if web:
    for book, chapter in [('GEN', 1), ('JHN', 5), ('REV', 22)]:
        read('content_public_bible_chapter', {'translation_id': web['translation_id'], 'book_id': book, 'chapter': chapter},
             lambda data: isinstance(data, dict) and isinstance(data.get('chapter'), dict)
                          and bool(data['chapter'].get('verses')),
             lambda data, book=book, chapter=chapter: {'book_id': book, 'chapter_number': chapter,
                  'verse_count': len((data.get('chapter') or {}).get('verses', [])),
                  'offline_allowed': (data.get('chapter') or {}).get('offline_allowed'),
                  'text_omitted': True})
else:
    checks.append({'rpc': 'WEB chapter sample', 'status': 'blocked', 'reason': 'No published WEB translation observed.'})
result = {'observed_at_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'target': 'tmurpotfluignacfueki (staging)',
          'source_reference': 'c96cd562b2650c37f5d3d879cb12891419700139',
          'method': 'POST read-only RPCs with publishable key only; no Authorization header or signed-in session.',
          'limitations': ['HTTP read observations, not UI, device, rights-policy approval, whole-canon verification or source-byte parity.',
                         'No keys, UUIDs of real records, Bible text or other response content retained.'],
          'checks': checks}
Path(args.output).write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({'passed': sum(c['status'] == 'run-passed' for c in checks),
                  'failed': sum(c['status'] == 'run-failed' for c in checks),
                  'blocked': sum(c['status'] == 'blocked' for c in checks), 'output': args.output}))
raise SystemExit(1 if any(c['status'] == 'run-failed' for c in checks) else 0)

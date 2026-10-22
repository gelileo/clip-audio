#!/usr/bin/env python3
"""M0 feasibility probe: can the iOS-constrained extraction chain produce
playable AAC audio? Resolves under QuickJS-only, then verifies real bytes."""
import json, subprocess, sys, time, urllib.request, urllib.error

SELECTOR = 'bestaudio[ext=m4a][protocol^=https]/bestaudio[acodec^=mp4a]/bestaudio[ext=m4a]'
FIELDS = ['format_id', 'acodec', 'abr', 'protocol', 'url', 'http_headers']
IOS_ARGS = ['--no-js-runtimes', '--js-runtimes', 'quickjs']   # the constraint under test
TIMEOUT = 120


def classify(stderr):
    s = stderr.lower()
    for pat, stage in [
        ('requested format is not available', 'NO_COMPATIBLE_FORMAT'),
        ('po token', 'PO_TOKEN'), ('not a bot', 'BOT_CHECK'),
        ('sign in', 'AUTH_REQUIRED'), ('age', 'AGE_GATE'),
        ('private', 'UNAVAILABLE'), ('unavailable', 'UNAVAILABLE'),
        ('removed', 'UNAVAILABLE'), ('geo', 'GEO_BLOCKED'),
        ('nsig', 'JSI_FAIL'), ('jsinterp', 'JSI_FAIL'),
        ('javascript', 'JSI_FAIL'), ('challenge', 'JSI_FAIL'),
        ('members-only', 'AUTH_REQUIRED'), ('timed out', 'NETWORK'),
    ]:
        if pat in s:
            return stage
    return 'UNKNOWN'


def resolve(vid, extra):
    url = f'https://www.youtube.com/watch?v={vid}'
    cmd = ['yt-dlp', '--no-warnings', '--simulate', '-f', SELECTOR, *extra]
    for f in FIELDS:
        cmd += ['--print', f'%({f})j' if f == 'http_headers' else f'%({f})s']
    cmd.append(url)
    t0 = time.time()
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT)
    except subprocess.TimeoutExpired:
        return {'ok': False, 'stage': 'TIMEOUT', 'secs': TIMEOUT}
    secs = round(time.time() - t0, 2)
    lines = [l for l in p.stdout.strip().split('\n') if l]
    if p.returncode != 0 or len(lines) < len(FIELDS):
        return {'ok': False, 'stage': classify(p.stderr), 'secs': secs,
                'err': p.stderr.strip().split('\n')[-1][:160] if p.stderr.strip() else ''}
    d = dict(zip(FIELDS, lines))
    d.update(ok=True, secs=secs)
    return d


def verify(d):
    """Fetch a real range. A resolve that cannot serve bytes is not a success."""
    try:
        h = json.loads(d['http_headers'])
    except Exception:
        h = {}
    h['Range'] = 'bytes=0-65535'
    try:
        r = urllib.request.urlopen(urllib.request.Request(d['url'], headers=h), timeout=30)
        body = r.read()
        return {'http': r.status, 'bytes': len(body),
                'ctype': r.headers.get('Content-Type', ''),
                'brand': body[4:12].decode('ascii', 'replace') if len(body) > 12 else '',
                'playable': r.status in (200, 206) and len(body) > 1000}
    except urllib.error.HTTPError as e:
        return {'http': e.code, 'bytes': 0, 'playable': False, 'ctype': '', 'brand': ''}
    except Exception as e:
        return {'http': 0, 'bytes': 0, 'playable': False, 'ctype': type(e).__name__, 'brand': ''}


def main():
    links = json.load(open('regression_set.json'))['links']
    out = []
    print(f'{"id":<12} {"cat":<13} {"itag":<5} {"abr":>6} {"s":>6} {"http":>5} {"verdict"}')
    print('-' * 72)
    for L in links:
        r = resolve(L['id'], IOS_ARGS)
        rec = {**L, 'resolve': r}
        if r['ok']:
            v = verify(r)
            rec['verify'] = v
            verdict = 'PASS' if v['playable'] else f'DEAD_URL({v["http"]})'
            print(f'{L["id"]:<12} {L["category"]:<13} {r["format_id"]:<5} '
                  f'{r.get("abr","?")[:6]:>6} {r["secs"]:>6} {v["http"]:>5} {verdict}')
        else:
            # Failure: is it the iOS constraint, or would it fail anywhere?
            base = resolve(L['id'], [])
            rec['baseline'] = base
            tag = 'QUICKJS_ONLY' if base['ok'] else 'UNIVERSAL'
            verdict = f'FAIL:{r["stage"]}[{tag}]'
            print(f'{L["id"]:<12} {L["category"]:<13} {"-":<5} {"-":>6} '
                  f'{r["secs"]:>6} {"-":>5} {verdict}')
        out.append(rec)

    json.dump(out, open('results/m0_results.json', 'w'), indent=2)
    n = len(out)
    passed = sum(1 for r in out if r.get('verify', {}).get('playable'))
    times = [r['resolve']['secs'] for r in out if r['resolve']['ok']]
    times.sort()
    print('-' * 72)
    print(f'PASS {passed}/{n} = {100*passed/n:.1f}%   gate = 90%   '
          f'{"MET" if 100*passed/n >= 90 else "NOT MET"}')
    if times:
        print(f'resolve p50={times[len(times)//2]}s  p95={times[int(len(times)*0.95)-1]}s  max={times[-1]}s')


if __name__ == '__main__':
    main()

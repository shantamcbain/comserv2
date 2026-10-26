#!/usr/bin/env python3
"""DRY RUN: parse Square receipt emails (e.g. Monashee Community Co-op) from an mbox
(Thunderbird IMAP cache of INBOX/coop) into invoice lines. Read-only; prints a plan.
  python3 script/square_receipt_backfill_dryrun.py MBOX [MBOX...] --known-invoices F --known-items F
"""
import mailbox, re, html, sys, argparse, collections, email.utils, json

def html_text(m):
    for p in m.walk():
        if p.get_content_type() == 'text/html':
            h = p.get_payload(decode=True).decode('utf-8', 'replace')
            h = re.sub(r'(?is)<(style|script).*?</\1>', '', h)
            h = re.sub(r'(?i)<br\s*/?>|</(p|div|tr|td|th|li|h\d)>', '\n', h)
            t = html.unescape(re.sub(r'<[^>]+>', '', h))
            return [l.strip() for l in t.splitlines() if l.strip()]
    return []

MONEY = re.compile(r'^-?\$(\d+(?:,\d{3})*\.\d{2})$')
def parse(lines):
    r = {'code': None, 'items': [], 'subtotal': None, 'gst': None, 'total': None, 'kind': 'purchase'}
    codes = [l[1:] for l in lines if re.match(r'^#\w{4}$', l)]
    if not codes: return None
    r['code'] = codes[0]
    if any(re.match(r'(?i)^refund', l) for l in lines): r['kind'] = 'refund'
    # items start after the headline amount; newer receipts then repeat #code + date
    try: i = next(j for j, l in enumerate(lines) if MONEY.match(l)) + 1
    except StopIteration: return None
    if i < len(lines) and re.match(r'^#\w{4}$', lines[i]): i += 2
    items = []
    while i < len(lines):
        l = lines[i]
        if re.match(r'(?i)^((purchase )?subtotal|total)$', l): break
        cur = items[-1] if items else None
        mm = MONEY.match(l)
        if mm:
            if cur is not None and 'line_total' not in cur:
                cur['line_total'] = float(mm.group(1).replace(',', ''))
        elif re.match(r'(?i)^reg price', l):
            v = re.sub(r'[^\d.]', '', l)
            if not v and i + 1 < len(lines) and MONEY.match(lines[i + 1]):
                i += 1; v = MONEY.match(lines[i]).group(1)
            if cur is not None: cur['reg_price'] = float(v.replace(',', '')) if v else None
        elif l.startswith('Discount:'):
            if cur is not None: cur['discount'] = l[9:].strip()
        elif re.match(r'^\(-?\$[\d.,]+\)$', l):
            pass
        elif re.match(r'^([\d.]+)\s*(lb|kg|g)\s*@\s*\$([\d.]+)', l):
            w = re.match(r'^([\d.]+)\s*(lb|kg|g)\s*@\s*\$([\d.]+)', l)
            if cur is not None: cur.update(qty=float(w.group(1)), uom=w.group(2), unit_price=float(w.group(3)))
        elif re.match(r'^\(\$([\d.]+) ea\.\)$', l):
            if cur is not None: cur['unit_price'] = float(re.match(r'^\(\$([\d.]+)', l).group(1))
        elif l.startswith('('):
            w = re.match(r'^\(([\d.]+)\s*(lb|kg|g|ml|l)\b', l)
            if cur is not None:
                cur.setdefault('notes', []).append(l)
                if w and cur.get('uom') == 'each' and cur['qty'] == 1: cur['size'] = w.group(1) + w.group(2)
        else:
            mq = re.match(r'^(.*?)\s*[×x]\s*(\d+)$', l)
            items.append({'name': (mq.group(1) if mq else l).replace('  ', ' '),
                          'qty': float(mq.group(2)) if mq else 1.0, 'uom': 'each'})
        i += 1
    r['items'] = [x for x in items if 'line_total' in x]
    def after(label):
        for j, l in enumerate(lines[i - 1:], i - 1):
            if re.match(label, l, re.I) and j + 1 < len(lines) and MONEY.match(lines[j + 1]):
                return float(MONEY.match(lines[j + 1]).group(1).replace(',', ''))
    r['subtotal'], r['gst'], r['total'] = after(r'^(purchase )?subtotal$'), after(r'^GST'), after(r'^total$')
    for it in r['items']:
        if it.get('unit_price') is None:
            it['unit_price'] = round(it['line_total'] / it['qty'], 4) if it['qty'] else None
    return r

ap = argparse.ArgumentParser(); ap.add_argument('mbox', nargs='+')
ap.add_argument('--known-invoices'); ap.add_argument('--known-items'); ap.add_argument('--json')
ap.add_argument('--grep', default='cinnamon|turmeric|tumeric|pepper|chia|collagen|organika')
a = ap.parse_args()
known_inv = set(l.strip() for l in open(a.known_invoices)) if a.known_invoices else set()
known_it = set(l.strip().lower() for l in open(a.known_items)) if a.known_items else set()
seen, recs, fails = set(), [], []
for f in a.mbox:
    for m in mailbox.mbox(f):
        if 'squareup' not in str(m.get('From', '')): continue
        mid = m.get('Message-ID')
        if mid in seen: continue
        seen.add(mid)
        d = email.utils.parsedate_to_datetime(m['Date']).astimezone().strftime('%Y-%m-%d %H:%M')
        p = parse(html_text(m))
        if not p or not p['items']:
            fails.append((d, str(m['Subject'])[:60], 'no item block')); continue
        s = round(sum(x['line_total'] for x in p['items']), 2)
        p.update(date=d, sum_ok=(p['subtotal'] is None or abs(s - p['subtotal']) < 0.02), line_sum=s)
        if not p['sum_ok']: fails.append((d, p['code'], f'lines {s} != subtotal {p["subtotal"]}'))
        recs.append(p)
recs.sort(key=lambda r: r['date'])
new = [r for r in recs if 'SQ-' + r['code'] not in known_inv]
lines = [it for r in recs for it in r['items']]
names = collections.Counter(it['name'] for it in lines)
new_items = sorted(n for n in names if n.lower() not in known_it)
print(f'Square receipts: {len(seen)}  parsed: {len(recs)}  failed: {len(fails)}  '
      f'({recs[0]["date"] if recs else "-"} .. {recs[-1]["date"] if recs else "-"})')
print(f'already imported (SQ-code match): {len(recs) - len(new)}  to create: {len(new)}  '
      f'lines: {len(lines)} ({sum(len(r["items"]) for r in new)} on new receipts)  '
      f'distinct products: {len(names)}  not yet inventory items: {len(new_items)}  '
      f'spend parsed: ${sum(r["total"] or 0 for r in recs):.2f}')
for f_ in fails: print('FAIL', *f_)
print('\nNEW ITEMS:', '; '.join(new_items))
rx = re.compile(a.grep, re.I)
print('\nMATCHES for', a.grep)
for r in recs:
    for it in r['items']:
        if rx.search(it['name']): print(' ', r['date'], r['code'], it['name'], it.get('qty'), it.get('uom'), it['line_total'])
if a.json: json.dump(recs, open(a.json, 'w'), indent=1)

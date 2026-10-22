#!/usr/bin/env python3
"""Read-only RS-SDK companion portal, independent of the bot/wiki checkouts."""
import argparse
from contextlib import closing, contextmanager
from datetime import datetime, timezone
from html import escape
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import hashlib
import os
from pathlib import Path
import re
import sqlite3
import stat
import time
from typing import cast
from urllib.parse import parse_qs, quote, unquote, urlencode, urlsplit

BASE = '/rs-sdk'
STYLE = Path(__file__).with_name('theme.css').read_text()
WIKIS = {
    'rs-sdk': ('RS-SDK Wiki', 'rs-sdk-wiki.sqlite', 'Server-specific knowledge generated from RS-SDK. Search only the local game wiki.'),
    'scraped': ('Scraped Wiki', 'scraped-wiki.sqlite', 'Cached OSRS and RuneScape Wiki articles. This advice may describe later game versions, not this server.'),
}


def esc(value):
    return escape(str(value) if value is not None else '—', quote=True)


def layout(title, body, wiki=False):
    theme = 'wiki-page' if wiki else 'game-page'
    menu_title = 'Wiki navigation' if wiki else 'Game tools'
    note = 'Read-only article cache' if wiki else 'Account state is not live presence.'
    return f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(title)} · RS-SDK</title><style>{STYLE}</style></head><body class="{theme}"><div class="world"><header><nav><a class="brand" href="{BASE}/">RS-SDK / companion</a><a href="{BASE}/accounts">Accounts</a><a href="{BASE}/benchmarks">Benchmarks</a><a href="{BASE}/wiki">Wikis</a></nav></header><div class="page-layout"><aside class="tool-menu"><h2>{menu_title}</h2><a href="{BASE}/">Companion home</a><a href="{BASE}/accounts">Account Database</a><a href="{BASE}/benchmarks">Benchmarks</a><a href="{BASE}/wiki/rs-sdk">RS-SDK Wiki</a><a href="{BASE}/wiki/scraped">Scraped Wiki</a><p>{note}</p></aside><main>{body}<footer>Read-only companion · no account controls, database downloads or background polling.</footer></main></div></div></body></html>'''


@contextmanager
def read_db(path):
    db = sqlite3.connect(path.resolve().as_uri() + '?mode=ro', uri=True, timeout=0.25)
    db.row_factory = sqlite3.Row
    try:
        db.execute('PRAGMA query_only=ON')
        yield db
    finally:
        db.close()


def table(headers, rows):
    return '<div class="scroll"><table><thead><tr>' + ''.join(f'<th>{esc(h)}</th>' for h in headers) + '</tr></thead><tbody>' + ''.join('<tr>' + ''.join(f'<td>{esc(v)}</td>' for v in row) + '</tr>' for row in rows) + '</tbody></table></div>'


def render_article(text, title, source):
    lines = text.strip().splitlines()
    body = []
    headings = []
    index = 0
    while index < len(lines):
        line = lines[index].strip()
        if not line:
            index += 1
            continue
        heading = re.match(r'^(#{1,6})\s+(.+)$', line)
        if heading:
            index += 1
            if len(heading[1]) == 1 and heading[2].casefold() == title.casefold():
                continue
            level = max(2, len(heading[1]))
            anchor = f'section-{len(headings) + 1}'
            headings.append((anchor, heading[2], level))
            body.append(f'<h{level} id="{anchor}">{esc(heading[2])}</h{level}>')
            continue
        if line.startswith('|'):
            rows = []
            while index < len(lines) and lines[index].strip().startswith('|'):
                cells = [cell.strip() for cell in lines[index].strip().strip('|').split('|')]
                if not all(re.fullmatch(r':?-+:?', cell) for cell in cells):
                    rows.append(cells)
                index += 1
            if rows:
                markup = table(rows[0], rows[1:])
                if not body and source != 'rs-sdk':
                    markup = markup.replace('class="scroll"', 'class="scroll wiki-infobox"', 1)
                body.append(markup)
            continue
        if re.match(r'^[-*]\s+', line):
            items = []
            while index < len(lines):
                item = re.match(r'^\s*[-*]\s+(.+)$', lines[index])
                if not item:
                    break
                items.append(f'<li>{esc(item[1])}</li>')
                index += 1
            body.append('<ul>' + ''.join(items) + '</ul>')
            continue
        paragraph = []
        while index < len(lines):
            line = lines[index].strip()
            if not line or line.startswith('|') or re.match(r'^(#{1,6}\s+|[-*]\s+)', line):
                break
            paragraph.append(line)
            index += 1
        body.append('<p>' + esc(' '.join(paragraph)) + '</p>')
    if headings:
        contents = '<details class="wiki-toc" open><summary>Contents</summary><ol>'
        contents += ''.join(f'<li class="{"subsection" if level > 2 else "section"}"><a href="#{anchor}">{esc(label)}</a></li>' for anchor, label, level in headings)
        contents += '</ol></details>'
        first_section = next(i for i, block in enumerate(body) if re.match(r'<h[2-6] ', block))
        body.insert(first_section, contents)
    return '<article class="wiki-content">' + ''.join(body) + '</article>'


def article_href(collection, row):
    if collection == 'scraped' and row['source'] in ('osrs', 'rs3'):
        import original
        return original.page_href(row['source'], row['title'])
    return f'{BASE}/wiki/{collection}/article?id={row["id"]}'


def search_form(path, query, label=None):
    return f'<form action="{BASE}/{path}"><input type="search" name="q" aria-label="Search {esc(label or path)}" placeholder="Search {esc(label or path)}…" value="{esc(query)}"><button>Search</button></form>'


def pager(path, query, page, total):
    def link(number, label):
        return f'<a href="{BASE}/{path}?{esc(urlencode({"q": query, "page": number}))}">{label}</a>'
    links = [link(page - 1, '← Previous')] if page > 1 else []
    if page * 50 < total:
        links.append(link(page + 1, 'Next →'))
    return '<div class="pager">' + ''.join(links) + '</div>'


UPSTREAM = {'osrs': 'oldschool.runescape.wiki', 'rs3': 'runescape.wiki'}
WANTED_LIMIT = 5000


class Redirect(Exception):
    def __init__(self, location):
        super().__init__(location)
        self.location = location


class Wanted:
    """The portal's only writable state: pages and images someone asked for that
    aren't cached. The source-side sync takes them and queues them in the wiki."""
    def __init__(self, path):
        self.path = path

    def record(self, source, kind, key):
        if self.path is None or source not in UPSTREAM or kind not in ('page', 'image'):
            return False
        try:
            with closing(sqlite3.connect(self.path, timeout=0.25)) as db, db:
                db.execute('CREATE TABLE IF NOT EXISTS wanted (source TEXT NOT NULL, kind TEXT NOT NULL, key TEXT NOT NULL, requested_at INTEGER NOT NULL, PRIMARY KEY (source, kind, key))')
                if db.execute('SELECT count(*) FROM wanted').fetchone()[0] >= WANTED_LIMIT:
                    return False
                db.execute('INSERT OR IGNORE INTO wanted VALUES (?,?,?,?)', (source, kind, key, int(time.time() * 1000)))
            return True
        except (OSError, sqlite3.Error):
            return False


def split_route(path, prefix):
    """(source, decoded rest) of /prefix/<source>/<rest>, or None."""
    if not path.startswith(prefix):
        return None
    source, _, rest = path[len(prefix):].partition('/')
    if source not in UPSTREAM or not rest:
        return None
    return source, unquote(rest)


class Portal:
    def __init__(self, root, game_url, homepage_url, wanted=None):
        self.root = root
        self.game_url = game_url.rstrip('/')
        self.homepage_url = homepage_url.rstrip('/')
        self.wanted = Wanted(wanted)

    def scraped_image(self, source, rest):
        """Bytes and MIME of a cached upstream image, or None (recorded as wanted)."""
        import original
        path = original.image_path(rest)
        if path is None:
            raise ValueError('Invalid image path')
        with read_db(self.root / 'scraped-wiki.sqlite') as db:
            row = db.execute('SELECT sha256,mime,size FROM assets WHERE source=? AND url=? AND mime LIKE \'image/%\'', (source, '/images/' + path)).fetchone()
        if row is None:
            self.wanted.record(source, 'image', path)
            return None
        return self.asset(row['sha256'], row)

    def known_titles(self, db):
        pages = {(r['source'], r['title']) for r in db.execute('SELECT source,title FROM pages')}
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='redirects'").fetchone():
            pages |= {(r['source'], r['from_title']) for r in db.execute('SELECT source,from_title,to_title FROM redirects') if (r['source'], r['to_title']) in pages}
        return pages

    def find_page(self, db, source, title):
        row = db.execute('SELECT id,title FROM pages WHERE source=? AND title=?', (source, title)).fetchone()
        if row is None and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='redirects'").fetchone():
            row = db.execute('SELECT p.id,p.title FROM redirects r JOIN pages p ON p.source=r.source AND p.title=r.to_title WHERE r.source=? AND r.from_title=?', (source, title)).fetchone()
        return row

    def asset(self, digest, metadata=None):
        if not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Invalid asset')
        if metadata is None:
            with read_db(self.root / 'scraped-wiki.sqlite') as db:
                metadata = db.execute('SELECT mime,size FROM assets WHERE sha256=? AND source IN (\'osrs\',\'rs3\') LIMIT 1', (digest,)).fetchone()
        if metadata is None or metadata['mime'] not in ('image/png', 'image/jpeg', 'image/gif', 'image/webp', 'text/css'):
            raise ValueError('Missing asset')
        root_fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            directory_fd = os.open('assets', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
            try:
                fd = os.open(digest, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
            finally:
                os.close(directory_fd)
        finally:
            os.close(root_fd)
        with os.fdopen(fd, 'rb') as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= 16 * 1024 * 1024 or info.st_size != metadata['size']:
                raise ValueError('Invalid asset size')
            data = stream.read(16 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != digest:
            raise ValueError('Invalid asset digest')
        return data, metadata['mime']

    def original_document(self, article_id):
        import original
        with read_db(self.root / 'scraped-wiki.sqlite') as db:
            row = db.execute('SELECT source,raw_html,styles FROM pages WHERE id=? AND source IN (\'osrs\',\'rs3\')', (article_id,)).fetchone()
            if row is None or not row['raw_html']:
                return None
            pages = self.known_titles(db)
            assets = {(r['source'], r['url']): dict(r) for r in db.execute('SELECT source,url,sha256,mime,size FROM assets')}
        by_hash = {r['sha256']: r for r in assets.values()}
        return original.document(row['raw_html'], row['styles'], row['source'], pages, assets,
                                 lambda digest: self.asset(digest, by_hash.get(digest))[0])

    def render(self, path, params):
        try:
            status, body = self._render(path, params)
            name = {'accounts': 'accounts.sqlite', 'benchmarks': 'benchmarks.sqlite', 'benchmark': 'benchmarks.sqlite'}.get(path.rsplit('/', 1)[-1])
            if path.startswith(BASE + '/wiki/'):
                collection = path[len(BASE + '/wiki/'):].split('/')[0]
                if collection in WIKIS:
                    name = WIKIS[collection][1]
            if status == 200 and name:
                stamp = datetime.fromtimestamp((self.root / name).stat().st_mtime, timezone.utc).astimezone()
                freshness = ' · stale: workstation sync may be offline' if (datetime.now(timezone.utc) - stamp).total_seconds() > 600 else ''
                body = body.replace('<footer>', f'<footer>Snapshot exported {stamp:%Y-%m-%d %H:%M:%S %Z}{freshness}<br>')
            return status, body
        except Redirect as redirect:
            return 302, redirect.location
        except ValueError:
            return 400, layout('Invalid request', '<h1>Invalid request</h1><p>Use a positive page number.</p>')
        except sqlite3.Error:
            return 503, layout('Data unavailable', '<h1>Data temporarily unavailable</h1><p>The read-only snapshot is missing, busy or incompatible. Try again after the next sync.</p>')

    def _render(self, path, params):
        if path in ('/', BASE, BASE + '/'):
            cards = [
                ('01 / ACCOUNTS', 'Account Database', BASE + '/accounts', 'Account status, purpose, logins and recorded deaths. Credentials stay private.'),
                ('02 / PERFORMANCE', 'Benchmarks', BASE + '/benchmarks', 'Compare full runs, timings and routine versions. Inspect individual steps.'),
                ('03 / SERVER KNOWLEDGE', 'RS-SDK Wiki', BASE + '/wiki/rs-sdk', WIKIS['rs-sdk'][2]),
                ('04 / EXTERNAL KNOWLEDGE', 'Scraped Wiki', BASE + '/wiki/scraped', WIKIS['scraped'][2]),
                ('05 / GAME', 'Play', self.game_url + '/', 'Open the browser client. Your human and bot accounts share this SDK world.'),
                ('06 / RANKINGS', 'HiScores', self.game_url + '/hiscores', 'Browse the game server’s player rankings.'),
                ('07 / TRADING', 'Grand Exchange', self.game_url + '/market.html', 'Open the server’s market and trading page.'),
            ]
            body = '<div class="eyebrow">2004SCAPE / RS-SDK WORLD</div><h1>RS-SDK Companion</h1><p>Play, inspect your accounts, compare runs and explore what the bots know.</p><div class="grid">'
            body += ''.join(f'<a class="card" href="{esc(url)}"><small>{tag}</small><b>{title} ↗</b><p>{description}</p></a>' for tag, title, url, description in cards)
            body += f'</div><p class="note">Read-only snapshots from the bot workstation, refreshed every two minutes while it is online. Browsing never starts bots, refreshes the wiki or changes game state.</p><a href="{esc(self.homepage_url)}/">← Back to Homepage</a>'
            return 200, layout('Companion', body)
        if path == BASE + '/accounts':
            q = params.get('q', [''])[0][:200]
            page = int(params.get('page', ['1'])[0])
            if page < 1 or page > 1000000:
                raise ValueError('page')
            where = 'WHERE instr(lower(a.username || coalesce(a.purpose,\'\') || a.status), lower(?)) > 0'
            with read_db(self.root / 'accounts.sqlite') as db:
                total = db.execute(f'SELECT count(*) FROM accounts a {where}', (q,)).fetchone()[0]
                rows = db.execute(f'''SELECT a.username, a.status, a.purpose, a.login_count,
                    (SELECT count(*) FROM deaths d WHERE d.username=a.username),
                    a.created_at, a.first_login_at, a.last_login_at
                    FROM accounts a {where} ORDER BY a.username LIMIT 50 OFFSET ?''', (q, (page - 1) * 50)).fetchall()
            body = f'<div class="eyebrow">RS-SDK / Account registry</div><h1>Account Database</h1><p>{total} matching accounts · credentials, private notes and host details are not published.</p>'
            display_rows = [tuple(row[:5]) + tuple(value.replace('T', ' ').removesuffix('Z') if isinstance(value, str) else value for value in row[5:]) for row in rows]
            account_table = table(('Account', 'Account state', 'Purpose', 'Logins', 'Deaths', 'Created (UTC)', 'First login (UTC)', 'Last login (UTC)'), display_rows)
            body += search_form('accounts', q) + account_table.replace('class="scroll"', 'class="scroll account-table"', 1)
            body += '<p class="note">Created / active / retired describe account lifecycle, not whether the player is currently online. Live presence and current world/server are planned.</p>'
            return 200, layout('Accounts', body + pager('accounts', q, page, total))
        if path == BASE + '/benchmarks':
            q = params.get('q', [''])[0][:200]
            page = int(params.get('page', ['1'])[0])
            if not 1 <= page <= 1000000:
                raise ValueError('page')
            with read_db(self.root / 'benchmarks.sqlite') as db:
                summary = db.execute('''SELECT benchmark, count(*),
                    printf('%.1f%%',100.0*sum(success)/count(*)), min(CASE WHEN success=1 THEN total_ms END),
                    round(avg(CASE WHEN success=1 THEN total_ms END)) FROM runs
                    WHERE mode='full' GROUP BY benchmark ORDER BY benchmark''').fetchall()
                total = db.execute('SELECT count(*) FROM runs WHERE instr(lower(benchmark || username), lower(?))>0', (q,)).fetchone()[0]
                runs = db.execute('''SELECT id, benchmark, username, routine_sha, mode, started_at,
                    success, total_ms, routine_ms, ticks FROM runs
                    WHERE instr(lower(benchmark || username), lower(?))>0
                    ORDER BY id DESC LIMIT 50 OFFSET ?''', (q, (page-1)*50)).fetchall()
            body = '<h1>Benchmarks</h1><h2>Full-run summary</h2><p>Resume/dev segments are excluded. Times are milliseconds; averages and best times include successful runs only.</p>'
            body += table(('Benchmark', 'Runs', 'Success', 'Best ms', 'Average ms'), summary)
            body += f'<h2>Run history</h2><p>{total} matching runs · select a run for its step timings.</p>' + search_form('benchmarks', q)
            body += '<div class="scroll"><table><tr>' + ''.join(f'<th>{h}</th>' for h in ('Run', 'Benchmark', 'Account', 'Routine', 'Mode', 'Started (UTC)', 'Result', 'Total ms', 'Routine ms', 'Ticks')) + '</tr>'
            for row in runs:
                values = list(row)[1:]
                values[5] = 'Success' if row['success'] else 'Failed'
                body += f'<tr><td><a href="{BASE}/benchmark?id={row["id"]}">#{row["id"]}</a></td>' + ''.join(f'<td>{esc(v)}</td>' for v in values) + '</tr>'
            return 200, layout('Benchmarks', body + '</table></div>' + pager('benchmarks', q, page, total))
        if path == BASE + '/benchmark':
            run_id = int(params.get('id', ['0'])[0])
            with read_db(self.root / 'benchmarks.sqlite') as db:
                row = db.execute('SELECT benchmark, username, routine_sha, mode, started_at, finished_at, success, total_ms, routine_ms, ticks, steps FROM runs WHERE id=?', (run_id,)).fetchone()
            if row is None:
                return 404, layout('Run not found', '<h1>Run not found</h1>')
            body = f'<a href="{BASE}/benchmarks">← Benchmarks</a><h1>Run #{run_id}</h1>' + table(('Field', 'Value'), [(k, row[k]) for k in row.keys() if k != 'steps'])
            try:
                steps = json.loads(row['steps'] or '[]')
                step_rows = [(s.get('step'), s.get('ms'), s.get('ticks')) for s in steps if isinstance(s, dict)]
            except (ValueError, TypeError):
                step_rows = [('Step timings unavailable', None, None)]
            return 200, layout('Benchmark run', body + '<h2>Step timings</h2>' + table(('Step', 'ms', 'Ticks'), step_rows))
        if path == BASE + '/wiki':
            body = '<h1>Choose a wiki</h1><p>Separate pages and databases. Choose which knowledge collection you want to search.</p><div class="grid">'
            body += ''.join(f'<a class="card" href="{BASE}/wiki/{key}"><b>{title}</b><p>{description}</p></a>' for key, (title, _, description) in WIKIS.items())
            return 200, layout('Wikis', body + '</div>', wiki=True)
        wiki_path = path[len(BASE + '/wiki/'):] if path.startswith(BASE + '/wiki/') else ''
        collection = wiki_path.removesuffix('/article')
        wiki = WIKIS.get(collection)
        if wiki and wiki_path == collection:
            title, filename, description = wiki
            q = params.get('q', [''])[0][:200]
            page = int(params.get('page', ['1'])[0])
            if not 1 <= page <= 1000000:
                raise ValueError('page')
            with read_db(self.root / filename) as db:
                where = 'WHERE instr(lower(title),lower(?))>0 OR instr(lower(text),lower(?))>0'
                total = db.execute(f'SELECT count(*) FROM pages {where}', (q, q)).fetchone()[0]
                rows = db.execute(f'''SELECT id,source,title,substr(text,1,180) AS snippet FROM pages {where}
                    ORDER BY title,source,id
                    LIMIT 50 OFFSET ?''', (q, q, (page-1)*50)).fetchall()
            body = f'<h1>{title}</h1><p class="note">{description}</p><p>{total} matching cached pages in this database. Browsing never fetches or refreshes upstream pages.</p>' + search_form('wiki/' + collection, q, title)
            body += ''.join(f'<article><span class="eyebrow">{esc(r["source"])}</span><h2><a href="{esc(article_href(collection, r))}">{esc(r["title"])}</a></h2><p>{esc(r["snippet"])}</p></article>' for r in rows)
            return 200, layout(title, body + pager('wiki/' + collection, q, page, total), wiki=True)
        route = split_route(path, BASE + '/wiki/scraped/w/')
        if route:
            import original
            source, raw = route
            title = original.normalize_title(raw)
            if title is None:
                raise ValueError('title')
            with read_db(self.root / 'scraped-wiki.sqlite') as db:
                row = self.find_page(db, source, title)
            if row is not None and row['title'].replace(' ', '_') != raw:
                view = params.get('view', [''])[0]
                raise Redirect(original.page_href(source, row['title']) + ('?view=clean' if view == 'clean' else ''))
            if row is not None:
                return self.article('scraped', row['id'], params)
            return 404, self.not_scraped(source, title)
        if wiki and wiki_path == collection + '/article' and collection == 'scraped':
            import original
            with read_db(self.root / 'scraped-wiki.sqlite') as db:
                row = db.execute('SELECT source,title FROM pages WHERE id=?', (int(params.get('id', ['0'])[0]),)).fetchone()
            if row is None or row['source'] not in UPSTREAM:
                return 404, layout('Article not found', '<h1>Article not found</h1>', wiki=True)
            raise Redirect(original.page_href(row['source'], row['title']) + ('?view=clean' if params.get('view', [''])[0] == 'clean' else ''))
        if wiki and wiki_path == collection + '/article':
            return self.article(collection, int(params.get('id', ['0'])[0]), params)
        return 404, layout('Not found', '<h1>Not found</h1><p>This page does not exist.</p>')

    def not_scraped(self, source, title):
        import original
        url = f'https://{UPSTREAM[source]}/w/{quote(title.replace(" ", "_"), safe="/:(),")}'
        body = f'<a href="{BASE}/wiki/scraped">← Scraped Wiki</a><h1>{esc(title)}</h1><p>This {esc(source)} page hasn’t been scraped yet.</p>'
        if original.fetchable_title(title) and self.wanted.record(source, 'page', title):
            body += '<p>It has been requested: the workstation fetches it with its images within a few minutes while online (sync every two minutes, then at most five wiki requests a minute). Reload this page later.</p>'
        elif original.fetchable_title(title):
            body += '<p>Requests can’t be recorded right now; try again later.</p>'
        else:
            body += '<p>This kind of page (not an article) isn’t fetched on request.</p>'
        body += f'<p>Original: <a href="{esc(url)}" rel="noreferrer">{esc(url)}</a></p>'
        return layout(title, body, wiki=True)

    def article(self, collection, article_id, params):
        title, filename, _ = WIKIS[collection]
        with read_db(self.root / filename) as db:
            columns = {r[1] for r in db.execute('PRAGMA table_info(pages)')}
            raw = 'raw_html' if collection == 'scraped' and 'raw_html' in columns else 'NULL AS raw_html'
            row = db.execute(f'SELECT source,title,text,fetched_at,revid,{raw} FROM pages WHERE id=?', (article_id,)).fetchone()
        if row is None:
            return 404, layout('Article not found', '<h1>Article not found</h1>', wiki=True)
        body = f'<a href="{BASE}/wiki/{collection}">← {title}</a><h1>{esc(row["title"])}</h1><p>{title} · source: {esc(row["source"])} · revision {esc(row["revid"])}</p>'
        if row['source'] in ('osrs', 'rs3'):
            domain = 'oldschool.runescape.wiki' if row['source'] == 'osrs' else 'runescape.wiki'
            url = f'https://{domain}/w/{quote(row["title"].replace(" ", "_"), safe="")}'
            body += f'<p>Content from <a href="{esc(url)}" rel="noreferrer">{esc(domain)} · upstream article</a>, CC BY-NC-SA 3.0. Cached for personal use; uncached pages and images are requested from the workstation when opened.</p>'
        else:
            body += '<p>RS-SDK local knowledge · generated for this server. External wiki advice may describe later game versions.</p>'
        if collection == 'scraped' and row['raw_html']:
            import original
            article_url = esc(original.page_href(row['source'], row['title']))
            body += f'<p class="view-choice"><a href="{article_url}">Original view</a> · <a href="{article_url}?view=clean">Clean view</a></p>'
            if params.get('view', ['original'])[0] != 'clean':
                body += f'<iframe title="Cached original article" class="original-article" sandbox="allow-top-navigation-by-user-activation" referrerpolicy="no-referrer" src="{BASE}/wiki/scraped/document?id={article_id}"></iframe>'
                return 200, layout(row['title'], body, wiki=True)
        return 200, layout(row['title'], body + render_article(row['text'], row['title'], row['source']), wiki=True)


class PortalHTTPServer(ThreadingHTTPServer):
    portal: Portal
    assets_dir = Path(__file__).with_name('assets')


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        url = urlsplit(self.path)
        path = url.path if url.path == BASE or url.path.startswith(BASE + '/') else BASE + url.path
        portal = cast(PortalHTTPServer, self.server).portal
        document_path = BASE + '/wiki/scraped/document'
        asset_path = BASE + '/wiki/scraped/asset/'
        if path.startswith(asset_path):
            try:
                data, mime = portal.asset(path[len(asset_path):])
                if not mime.startswith('image/'):
                    raise ValueError('Not an image')
            except (OSError, ValueError, sqlite3.Error):
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'private, max-age=86400, immutable')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Content-Security-Policy', "default-src 'none'; sandbox")
            self.end_headers()
            self.wfile.write(data)
            return
        image_route = split_route(path, BASE + '/wiki/scraped/images/')
        if path.startswith(BASE + '/wiki/scraped/images/'):
            try:
                found = portal.scraped_image(*image_route) if image_route else None
                if found is None and image_route is None:
                    raise ValueError('Invalid image route')
            except (OSError, ValueError, sqlite3.Error):
                self.send_error(404)
                return
            if found is not None:
                data, mime = found
                self.send_response(200)
                self.send_header('Content-Type', mime)
                self.send_header('Content-Length', str(len(data)))
                self.send_header('Cache-Control', 'private, max-age=300')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Content-Security-Policy', "default-src 'none'; sandbox")
                self.end_headers()
                self.wfile.write(data)
                return
        if path == BASE + '/wiki/scraped/missing.svg' or path.startswith(BASE + '/wiki/scraped/images/'):
            data = b'<svg xmlns="http://www.w3.org/2000/svg" width="120" height="48" viewBox="0 0 120 48"><rect width="120" height="48" fill="#e8dfcc"/><text x="8" y="28" font-size="12" fill="#554426">Not cached</text></svg>'
            self.send_response(200)
            self.send_header('Content-Type', 'image/svg+xml')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Security-Policy', "default-src 'none'; sandbox")
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)
            return
        if path == document_path:
            try:
                body = portal.original_document(int(parse_qs(url.query).get('id', ['0'])[0]))
            except (OSError, ValueError, RecursionError, sqlite3.Error):
                body = None
            if body is None:
                self.send_error(404)
                return
            data = body.encode('utf-8')
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.send_header('Referrer-Policy', 'no-referrer')
            self.send_header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; frame-ancestors 'self'; form-action 'none'; base-uri 'none'; sandbox allow-top-navigation-by-user-activation")
            self.end_headers()
            self.wfile.write(data)
            return
        if path == BASE + '/assets/background2.jpg':
            asset = cast(PortalHTTPServer, self.server).assets_dir / 'background2.jpg'
            if not asset.is_file():
                self.send_error(404)
                return
            data = asset.read_bytes()
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.send_header('Content-Length', str(len(data)))
            self.send_header('Cache-Control', 'public, max-age=86400')
            self.send_header('X-Content-Type-Options', 'nosniff')
            self.end_headers()
            self.wfile.write(data)
            return
        status, body = cast(PortalHTTPServer, self.server).portal.render(path, parse_qs(url.query))
        if status == 302:
            self.send_response(302)
            self.send_header('Location', body)
            self.send_header('Content-Length', '0')
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            return
        data = body.encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        frame_policy = "; frame-src 'self'" if path == BASE + '/wiki/scraped/article' or path.startswith(BASE + '/wiki/scraped/w/') else ''
        self.send_header('Content-Security-Policy', "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'" + frame_policy)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).with_name('data'))
    parser.add_argument('--game-url', required=True)
    parser.add_argument('--homepage-url', required=True)
    parser.add_argument('--port', type=int, default=8098)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--wanted', type=Path, help='Writable SQLite file for requested pages and images (omit to record nothing)')
    args = parser.parse_args()
    server = PortalHTTPServer((args.host, args.port), Handler)
    server.portal = Portal(args.root.expanduser().resolve(), args.game_url, args.homepage_url,
                           args.wanted.expanduser() if args.wanted else None)
    server.serve_forever()


if __name__ == '__main__':
    main()

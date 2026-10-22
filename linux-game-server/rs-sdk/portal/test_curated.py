from contextlib import closing
from pathlib import Path
import sqlite3
import tempfile
import unittest

import server
import sync


class CuratedTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.source = self.root / 'wiki.sqlite'
        with closing(sqlite3.connect(self.source)) as db, db:
            db.execute('CREATE TABLE pages (id,source,title,text,wikitext,categories,fetched_at,revid)')
            db.executemany('INSERT INTO pages VALUES (?,?,?,?,?,?,?,?)', [
                (1, '2004scape', 'Steel axe', 'Item ID: 1353; build 289; sdk abc123',
                 '# Steel axe\n\n| Detail | |\n|---|---|\n| **Item ID** | 1353 |\n\n## Locations\nSee [Tree](wiki:Tree).\n\n## References\nServer data.', '["items"]', 0, 2),
                (2, '2004scape', 'Tree', '1281 3200,3200', '# Tree\n\nAn observed tree.', '["objects"]', 0, 2),
                (3, 'osrs', 'Later item', 'untrusted later-game advice', 'raw', '[]', 0, 99),
            ])
        sync.export_db(self.source, self.root / '2004scape-wiki.sqlite', sync.TABLES['2004scape-wiki.sqlite'], ('2004scape',))
        with closing(sqlite3.connect(self.root / 'scraped-wiki.sqlite')) as db:
            db.execute('CREATE TABLE pages (id,source,title,text,fetched_at,revid)')
        self.portal = server.Portal(self.root, 'https://game.example', 'https://home.example', self.root / 'wanted.sqlite')

    def test_projection_separates_full_article_and_compact_context(self):
        sync.check_snapshot(self.root / '2004scape-wiki.sqlite', '2004scape-wiki.sqlite')
        with closing(sqlite3.connect(self.root / '2004scape-wiki.sqlite')) as db:
            rows = db.execute('SELECT source,title,text,brief FROM pages').fetchall()
        self.assertEqual(len(rows), 2)
        self.assertTrue(rows[0][2].startswith('# Steel axe'))
        self.assertTrue(rows[0][3].startswith('Item ID:'))
        self.assertTrue(all(r[0] == '2004scape' for r in rows))

    def test_browsing_links_infobox_contents_and_wanted_article(self):
        status, body = self.portal.render('/rs-sdk/wiki/2004scape', {})
        self.assertEqual(status, 200)
        self.assertIn('/rs-sdk/wiki/2004scape/w/Steel_axe', body)
        self.assertNotIn('Later item', body)
        status, body = self.portal.render('/rs-sdk/wiki/2004scape/w/Steel_axe', {})
        self.assertEqual(status, 200)
        self.assertIn('wiki-infobox', body)
        self.assertIn('<b>Item ID</b>', body)
        self.assertIn('<summary>Contents</summary>', body)
        self.assertIn('href="/rs-sdk/wiki/2004scape/w/Tree"', body)
        self.assertIn('Compact context', body)
        with closing(sqlite3.connect(self.root / 'wanted.sqlite')) as db:
            self.assertEqual(db.execute('SELECT source,kind,key FROM wanted').fetchall(), [('osrs', 'page', 'Steel axe')])
        status, body = self.portal.render('/rs-sdk/wiki/2004scape/w/Steel_axe', {'view': ['brief']})
        self.assertEqual(status, 200)
        self.assertIn('<pre>Item ID: 1353; build 289; sdk abc123</pre>', body)
        self.assertNotIn('class="scroll wiki-infobox"', body)
        self.assertEqual(self.portal.render('/rs-sdk/wiki/2004scape/w/Unknown', {})[0], 404)

    def test_generated_markdown_never_becomes_active_html(self):
        html = server.render_article('# Bad\n\n<script>alert(1)</script> [click](javascript:alert(1)) [safe](wiki:Tree)', 'Bad', '2004scape')
        self.assertNotIn('<script>', html)
        self.assertNotIn('href="javascript:', html)
        self.assertIn('href="/rs-sdk/wiki/2004scape/w/Tree"', html)


if __name__ == '__main__':
    unittest.main()

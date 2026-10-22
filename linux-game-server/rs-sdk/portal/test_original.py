import unittest

import original


class OriginalTests(unittest.TestCase):
    def test_deeply_nested_css_is_dropped_not_fatal(self):
        html = self.render('<p style="color:red;width:' + 'calc(' * 600 + '1px' + ')' * 600 + '">x</p>')
        self.assertIn('color:red;', html)
        self.assertNotIn('calc(', html)

    def test_original_has_responsive_fallback_style_without_cached_css(self):
        html = self.render('<p>Article</p>')
        self.assertIn('name="viewport"', html)
        self.assertIn('class="mw-body-content"', html)
        self.assertIn('max-width:100%', html)

    def test_encoded_image_paths_match_decoded_cache_metadata(self):
        assets = {('osrs', '/images/Tree_(grown).png'): {'sha256': 'a' * 64, 'mime': 'image/png', 'size': 12}}
        html = self.render('<img src="/images/Tree_%28grown%29.png?abc123">', assets=assets)
        self.assertIn('src="/rs-sdk/wiki/scraped/asset/' + 'a' * 64 + '"', html)

    def test_srcset_candidates_are_rewritten_to_local_rasters(self):
        assets = {('osrs', '/images/Oak.png'): {'sha256': 'a' * 64, 'mime': 'image/png', 'size': 12}}
        html = self.render('<img src="/images/Oak.png" srcset="/images/Oak.png 1x, https://evil.test/x 2x, /images/Oak.png bad">', assets=assets)
        self.assertIn('srcset="/rs-sdk/wiki/scraped/asset/' + 'a' * 64 + ' 1x, /rs-sdk/wiki/scraped/missing.svg 2x"', html)
        self.assertNotIn('evil.test', html)
        self.assertNotIn('bad', html)

    def render(self, html, **kwargs):
        return original.document(html, kwargs.pop('styles', []), 'osrs',
                                 kwargs.pop('pages', {}), kwargs.pop('assets', {}), **kwargs)

    def test_preserves_article_structure_without_active_html(self):
        html = self.render('<h2 id="Stats">Stats</h2><table class="infobox"><tr><td>42</td></tr></table>'
                           '<script>bad()</script><form>form content</form><svg><a>svg</a></svg>'
                           '<iframe src="https://evil.test"></iframe><style>bad{}</style>'
                           '<p onclick="bad()">safe</p>')
        self.assertTrue(html.startswith('<!doctype html>'))
        self.assertIn('<h2 id="Stats">Stats</h2>', html)
        self.assertIn('class="infobox"', html)
        for forbidden in ('bad()', '<script', '<form', '<svg', '<iframe', 'onclick', 'form content'):
            self.assertNotIn(forbidden, html)

    def test_routes_links_to_cached_pages_or_local_search(self):
        html = self.render('<a href="/w/Oak_tree#Wood">Oak</a><a href="https://runescape.wiki/w/Rune">Rune</a>'
                           '<a href="/w/Unknown_title">Unknown</a><a href="#Stats">Stats</a>'
                           '<a href="https://evil.test/w/Oak_tree">External</a>'
                           '<a href="javascript:alert(1)">Bad</a><a href="//oldschool.runescape.wiki.evil.test/x">Spoof</a>',
                           pages={('osrs', 'Oak tree'): 7, ('rs3', 'Rune'): 8})
        self.assertIn('href="/rs-sdk/wiki/scraped/article?id=7#Wood" target="_top"', html)
        self.assertIn('href="/rs-sdk/wiki/scraped/article?id=8" target="_top"', html)
        self.assertIn('href="/rs-sdk/wiki/scraped?q=Unknown+title" target="_top"', html)
        self.assertIn('href="#Stats"', html)
        self.assertIn('href="https://evil.test/w/Oak_tree" target="_blank" rel="noreferrer noopener"', html)
        self.assertNotIn('javascript:', html)
        self.assertNotIn('href="//', html)

    def test_images_and_srcset_are_cached_raster_only(self):
        assets = {('osrs', 'https://oldschool.runescape.wiki/images/Oak.png'):
                  {'sha256': 'a' * 64, 'mime': 'image/png', 'size': 12}}
        html = self.render('<img src="/images/Oak.png" srcset="https://evil.test/x 2x" onerror="bad()">'
                           '<img src="https://evil.test/images/Oak.png"><img src="/images/../secret">'
                           '<img src="data:image/svg+xml,bad"><img src="/images/missing.png">', assets=assets)
        self.assertIn('src="/rs-sdk/wiki/scraped/asset/' + 'a' * 64 + '"', html)
        self.assertEqual(html.count('src="/rs-sdk/wiki/scraped/missing.svg"'), 4)
        for forbidden in ('evil.test', 'onerror', 'data:', '../secret'):
            self.assertNotIn(forbidden, html)

    def test_inline_css_ast_rewrites_urls_and_drops_dangerous_properties(self):
        html = self.render(r'''<p style="color:red; width:25px; background-image:u\72l(https://evil.test/x); behavior:url(x); -moz-binding:url(x); --x:url(x); height:expression(alert(1)); position:fixed">text</p>''')
        self.assertIn('color:red;', html)
        self.assertIn('width:25px;', html)
        self.assertIn('background-image:url(', html)
        self.assertIn('/rs-sdk/wiki/scraped/missing.svg', html)
        for forbidden in ('evil.test', 'behavior', 'binding', '--x', 'expression', 'position:fixed'):
            self.assertNotIn(forbidden, html)

    def test_cached_stylesheets_parse_media_and_rewrite_image_set_strings(self):
        css_url = 'https://oldschool.runescape.wiki/assets/wiki.css'
        assets = {('osrs', css_url): {'sha256': 'b' * 64, 'mime': 'text/css', 'size': 400},
                  ('osrs', 'https://oldschool.runescape.wiki/assets/Oak.png'):
                  {'sha256': 'a' * 64, 'mime': 'image/png', 'size': 12}}
        css = (r'@im\70ort "https://evil.test/import"; @font-face{src:url(https://evil.test/font)}'
               r'.infobox{color:red;background-image:image-set("Oak.png" 1x,u\72l("https://evil.test/img") 2x)}'
               r'@media screen and (max-width:600px){.infobox{width:90%;background:url("/images/missing.png")}}'
               r'@supports(display:grid){p{display:grid}}')
        reads = []
        def load(sha):
            reads.append(sha)
            return css.encode()
        html = self.render('<table class="infobox"></table>', styles='["' + css_url + '"]',
                           assets=assets, load_asset=load)
        self.assertEqual(reads, ['b' * 64])
        self.assertIn('<style>', html)
        self.assertIn('.infobox{color:red;', html)
        self.assertIn('@media screen and (max-width:600px)', html)
        self.assertIn('/asset/' + 'a' * 64, html)
        self.assertIn('image-set(', html)
        self.assertIn('/missing.svg', html)
        for forbidden in ('evil.test', '@import', '@font-face', '@supports', '<link'):
            self.assertNotIn(forbidden, html)

    def test_full_documents_extract_main_article_only(self):
        html = self.render('<!doctype html><html><head><title>Site title</title></head><body>'
                           '<div id="navigation">Navigation chrome</div><main id="content">'
                           '<h1>Oak</h1><div id="mw-content-text"><div class="mw-parser-output">'
                           '<h2 id="Uses">Article section</h2><p>Nested <b>text</b></p></div></div>'
                           '</main><div id="footer">Footer chrome</div></body></html>')
        self.assertIn('Article section', html)
        self.assertIn('class="mw-parser-output"', html)
        self.assertIn('<b>text</b>', html)
        for forbidden in ('Navigation chrome', 'Footer chrome', 'Site title'):
            self.assertNotIn(forbidden, html)
        fallback = self.render('<html><body><div>Unknown skin navigation</div></body></html>')
        self.assertNotIn('Unknown skin navigation', fallback)

    def test_asset_metadata_and_paths_fail_closed(self):
        bad_paths = ['../private.png', '/images/%2e%2e/private.png', 'https://oldschool.runescape.wiki.evil.test/x',
                     'https://oldschool.runescape.wiki@evil.test/x', 'https://oldschool.runescape.wiki:444/x',
                     '//evil.test/x', 'https://oldschool.runescape.wiki/images/vector.svg', '/images/bad.png']
        assets = {('osrs', 'https://oldschool.runescape.wiki/images/vector.svg'):
                  {'sha256': 'a' * 64, 'mime': 'image/svg+xml', 'size': 12},
                  ('osrs', 'https://oldschool.runescape.wiki/images/bad.png'):
                  {'sha256': '../private', 'mime': 'image/png', 'size': 12}}
        html = self.render(''.join('<img src="' + path + '">' for path in bad_paths), assets=assets)
        self.assertEqual(html.count('src="/rs-sdk/wiki/scraped/missing.svg"'), len(bad_paths))
        self.assertNotIn('/asset/', html)

    def test_missing_or_invalid_style_references_never_load(self):
        for styles in (None, '', '{bad json', '{}', '[null, 5]', ['https://evil.test/style.css']):
            with self.subTest(styles=styles):
                reads = []
                html = self.render('<p>text</p>', styles=styles, load_asset=lambda sha: reads.append(sha))
                self.assertEqual(reads, [])
                self.assertNotIn('<style>', html)
        css_url = 'https://oldschool.runescape.wiki/style.css'
        assets = {('osrs', css_url): {'sha256': 'a' * 64, 'mime': 'text/css', 'size': 10}}
        def missing(sha):
            raise FileNotFoundError('missing cached blob')
        self.assertNotIn('<style>', self.render('text', styles=[css_url], assets=assets, load_asset=missing))

    def test_css_html_breakout_and_escaped_network_syntax_are_contained(self):
        css_url = 'https://oldschool.runescape.wiki/style.css'
        assets = {('osrs', css_url): {'sha256': 'a' * 64, 'mime': 'text/css', 'size': 500}}
        css = (r'@im\70ort url(https://evil.test/import);'
               r'p{background:im\61ge-set("https://evil.test/a" 1x, u\72l("//evil.test/b") 2x);'
               r'height:expre\73sion(alert(1));color:red;}'
               r'p[title="</style><img src=https://evil.test/escape>"]{color:blue}'
               r'p{font-family:"</style><script>bad()</script>"}')
        html = self.render('<p>Safe</p>', styles=[css_url], assets=assets, load_asset=lambda sha: css.encode())
        self.assertEqual(html.count('</style>'), 2)
        self.assertNotIn('<script>', html)
        self.assertNotIn('<img src=https://evil.test', html)
        self.assertNotIn('https://evil.test/a', html)
        self.assertNotIn('https://evil.test/b', html)
        self.assertNotIn('@import', html)
        self.assertNotIn('expression', html)
        self.assertIn('color:red;', html)

    def test_article_titles_follow_mediawiki_normalization(self):
        html = self.render('<a href="/w/oak_tree">Oak</a>', pages={('osrs', 'Oak tree'): 11})
        self.assertIn('href="/rs-sdk/wiki/scraped/article?id=11"', html)

    def test_invalid_asset_mime_is_a_placeholder_not_an_exception(self):
        assets = {('osrs', 'https://oldschool.runescape.wiki/images/Oak.png'):
                  {'sha256': 'a' * 64, 'mime': None, 'size': 12}}
        self.assertIn('src="/rs-sdk/wiki/scraped/missing.svg"',
                      self.render('<img src="/images/Oak.png">', assets=assets))


if __name__ == '__main__':
    unittest.main()

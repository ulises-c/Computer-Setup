"""Offline-only original article rendering.

The caller owns CSP, iframe sandboxing, blob validation and static asset serving.
Only the source's manifest-listed raster images and text/css blobs are consumed.
"""
from html import escape
from html.parser import HTMLParser
from urllib.parse import quote, unquote, urlencode, urljoin, urlsplit

import json
import re

import nh3
import tinycss2

BASE = '/rs-sdk/wiki/scraped'
HOSTS = {'osrs': 'oldschool.runescape.wiki', 'rs3': 'runescape.wiki'}
READER_STYLE = '''
body{margin:12px;color:#25221c;background:#f8f5ee;font:14px/1.6 Arial,sans-serif;overflow-wrap:anywhere}
a{color:#315d8b}h1,h2,h3{font-family:Georgia,serif;font-weight:normal}h2{border-bottom:1px solid #aaa08e}
img{max-width:100%;height:auto}table{border-collapse:collapse;max-width:100%}td,th{padding:5px;border:1px solid #c7bba4}
.infobox{float:right;max-width:340px;margin:0 0 16px 20px;background:#eee5d1}.wikitable{background:#f2ece0}
@media(max-width:600px){.infobox{float:none;max-width:100%;margin:12px 0}body{margin:8px}table{display:block;overflow-x:auto}}
'''


def safe_url(value, base):
    if any(ord(c) < 33 for c in value) or '\\' in value:
        return None
    try:
        url = urlsplit(urljoin(base, value))
        if url.scheme != 'https' or url.username or url.password or url.port not in (None, 443):
            return None
        return url
    except ValueError:
        return None


def link(value, source, pages):
    if value.startswith('#'):
        return [('href', value)]
    url = safe_url(value, 'https://' + HOSTS.get(source, 'invalid.test') + '/w/')
    if url is None:
        return []
    upstream = next((key for key, host in HOSTS.items() if url.hostname == host), None)
    if upstream and url.path.startswith('/w/'):
        title = ' '.join(unquote(url.path[3:]).replace('_', ' ').split())
        title = title[:1].upper() + title[1:]
        page_id = pages.get((upstream, title))
        href = BASE + ('/article?' + urlencode({'id': page_id}) if page_id is not None else '?' + urlencode({'q': title}))
        if url.fragment:
            href += '#' + quote(unquote(url.fragment), safe='')
        return [('href', href), ('target', '_top')]
    return [('href', url.geturl()), ('target', '_blank'), ('rel', 'noreferrer noopener')]


MISSING = BASE + '/missing.svg'
RASTER = {'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/avif'}


def cached_asset(value, source, assets, base, mimes):
    if any(part in {'.', '..'} for part in unquote(value).replace('\\', '/').split('/')):
        return None
    url = safe_url(value, base)
    if url is None or url.hostname != HOSTS.get(source) or url.fragment:
        return None
    row = assets.get((source, url.geturl())) or assets.get((source, url.path + ('?' + url.query if url.query else '')))
    if row is None and url.path.startswith('/images/'):
        row = assets.get((source, unquote(url.path)))
    if not row or not re.fullmatch(r'[0-9a-f]{64}', str(row.get('sha256', ''))):
        return None
    mime = row.get('mime')
    if not isinstance(mime, str) or mime.split(';')[0].strip().lower() not in mimes:
        return None
    if not isinstance(row.get('size'), int) or row['size'] <= 0:
        return None
    return row


def image_url(value, source, assets, base):
    row = cached_asset(value, source, assets, base, RASTER)
    return BASE + '/asset/' + row['sha256'] if row else MISSING


def srcset(value, source, assets, base):
    candidates = []
    for candidate in value.split(',')[:32]:
        parts = candidate.split()
        if not 1 <= len(parts) <= 2:
            continue
        descriptor = parts[1] if len(parts) == 2 else ''
        if descriptor and not re.fullmatch(r'(?:[1-9][0-9]{0,5}w|(?:[1-9][0-9]{0,2}(?:\.[0-9]{1,3})?|0\.[0-9]{1,3})x)', descriptor):
            continue
        candidates.append(image_url(parts[0], source, assets, base) + (' ' + descriptor if descriptor else ''))
    return ', '.join(candidates)


PROPERTIES = set('''
    color background background-color background-image background-position
    background-size background-repeat border border-top border-right border-bottom
    border-left border-color border-width border-style border-radius border-collapse
    border-spacing box-sizing caption-side clear display empty-cells float font
    font-family font-size font-style font-variant font-weight height width min-width
    max-width min-height max-height line-height list-style list-style-type
    list-style-position list-style-image margin margin-top margin-right margin-bottom
    margin-left padding padding-top padding-right padding-bottom padding-left opacity
    overflow overflow-x overflow-y table-layout text-align text-decoration text-indent
    text-transform vertical-align white-space word-break overflow-wrap
'''.split())
FUNCTIONS = set('''
    rgb rgba hsl hsla calc min max clamp linear-gradient radial-gradient
    repeating-linear-gradient repeating-radial-gradient image-set -webkit-image-set
'''.split())


def css_values(tokens, source, assets, base, image_set=False, depth=0):
    if depth > 32:
        return None
    output = []
    for token in tokens:
        if token.type == 'comment':
            continue
        if token.type == 'url' or (token.type == 'string' and image_set):
            local = image_url(token.value, source, assets, base)
            output.extend(tinycss2.parse_component_value_list('url("' + local + '")'))
        elif token.type == 'function':
            name = token.lower_name
            if name == 'url':
                args = [arg for arg in token.arguments if arg.type not in {'whitespace', 'comment'}]
                if len(args) != 1 or args[0].type != 'string':
                    return None
                local = image_url(args[0].value, source, assets, base)
                output.extend(tinycss2.parse_component_value_list('url("' + local + '")'))
            elif name in FUNCTIONS:
                args = css_values(token.arguments, source, assets, base, name.endswith('image-set'), depth + 1)
                if args is None:
                    return None
                token.arguments = args
                output.append(token)
            else:
                return None
        elif token.type in {'() block'}:
            content = css_values(token.content, source, assets, base, image_set, depth + 1)
            if content is None:
                return None
            token.content = content
            output.append(token)
        elif token.type in {'ident', 'string', 'number', 'dimension', 'percentage', 'hash', 'literal', 'whitespace'}:
            output.append(token)
        else:
            return None
    return output


def declarations(css, source, assets, base):
    result = []
    for item in tinycss2.parse_blocks_contents(css, skip_comments=True, skip_whitespace=True):
        if item.type != 'declaration' or item.lower_name not in PROPERTIES:
            continue
        try:
            value = css_values(item.value, source, assets, base)
        except RecursionError:
            value = None
        if value is not None:
            result.append(item.lower_name + ':' + tinycss2.serialize(value).strip() + ('!important' if item.important else '') + ';')
    return ''.join(result)


def stylesheet(rules, source, assets, base):
    result = []
    for rule in rules:
        if rule.type == 'qualified-rule':
            prelude = css_values(rule.prelude, source, assets, base)
            content = declarations(rule.content, source, assets, base)
            if prelude is not None and content:
                result.append(tinycss2.serialize(prelude).strip() + '{' + content + '}')
        elif rule.type == 'at-rule' and rule.lower_at_keyword == 'media' and rule.content is not None:
            prelude = css_values(rule.prelude, source, assets, base)
            content = stylesheet(tinycss2.parse_blocks_contents(rule.content), source, assets, base)
            if prelude is not None and content:
                result.append('@media ' + tinycss2.serialize(prelude).strip() + '{' + content + '}')
    return ''.join(result)


def cached_styles(styles, source, assets, load_asset):
    if isinstance(styles, str):
        try:
            styles = json.loads(styles)
        except ValueError:
            return ''
    if not isinstance(styles, list) or load_asset is None:
        return ''
    result = []
    for value in styles:
        if not isinstance(value, str):
            continue
        base = 'https://' + HOSTS.get(source, 'invalid.test') + '/'
        row = cached_asset(value, source, assets, base, {'text/css'})
        if row is None:
            continue
        try:
            data = load_asset(row['sha256'])
        except OSError:
            continue
        rules, _ = tinycss2.parse_stylesheet_bytes(data, skip_comments=True, skip_whitespace=True)
        result.append(stylesheet(rules, source, assets, urljoin(base, value)))
    return ''.join(result).replace('<', '\\3c ')


class Article(HTMLParser):
    def __init__(self, source, pages, assets):
        super().__init__(convert_charrefs=True)
        self.source, self.pages, self.assets = source, pages, assets
        self.output = []
        self.stack = []
        self.candidates = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag not in {'img', 'br', 'hr', 'col'}:
            priority = (0 if 'mw-parser-output' in values.get('class', '').split() else
                        1 if values.get('id') == 'mw-content-text' else
                        2 if tag in {'main', 'article'} else None)
            self.stack.append((tag, len(self.output), priority))
        attrs = [(key, value) for key, value in attrs if key not in {'href', 'rel', 'target', 'style'}]
        if 'style' in values:
            style = declarations(values['style'], self.source, self.assets,
                                 'https://' + HOSTS.get(self.source, 'invalid.test') + '/')
            if style:
                attrs.append(('style', style))
        if tag == 'a' and 'href' in values:
            attrs += link(values['href'], self.source, self.pages)
        if tag == 'img':
            attrs = [(key, value) for key, value in attrs if key not in {'src', 'srcset'}]
            if 'srcset' in values:
                candidates = srcset(values['srcset'], self.source, self.assets,
                                    'https://' + HOSTS.get(self.source, 'invalid.test') + '/')
                if candidates:
                    attrs.append(('srcset', candidates))
            attrs.append(('src', image_url(values.get('src', ''), self.source, self.assets,
                                           'https://' + HOSTS.get(self.source, 'invalid.test') + '/')))
        self.output.append('<' + tag + ''.join(' ' + key + '=\"' + escape(value, quote=True) + '\"' for key, value in attrs) + '>')

    def handle_endtag(self, tag):
        self.output.append('</' + tag + '>')
        if self.stack and self.stack[-1][0] == tag:
            _, start, priority = self.stack.pop()
            if priority is not None:
                self.candidates.append((priority, start, len(self.output)))

    def handle_data(self, data):
        self.output.append(escape(data))

TAGS = set('a abbr article b blockquote br caption code col colgroup dd del details div dl dt em figcaption figure h1 h2 h3 h4 h5 h6 hr i img li main ol p pre s section small span strong sub summary sup table tbody td th thead tfoot tr u ul'.split())
DROP = set('script style form svg math iframe frame frameset object embed audio video source track base meta link template noscript'.split())
ATTRS = {'a': {'href'}, '*': {'class', 'id', 'title', 'lang', 'dir', 'style'},
         'td': {'colspan', 'rowspan'}, 'th': {'colspan', 'rowspan', 'scope'},
         'img': {'src', 'srcset', 'alt', 'width', 'height'}}


def document(raw_html, styles, source, pages, assets, load_asset=None):
    """Return standalone article HTML without fetching or writing any material.

    ``source`` is ``osrs`` or ``rs3``; ``pages[(source, title)]`` is a local id.
    ``assets[(source, url)]`` contains sha256, mime and size. ``styles`` is a
    JSON-encoded list or a list of cached stylesheet URLs, not raw CSS.
    ``load_asset(sha256)`` reads local bytes; omitted callbacks disable styles.
    Missing/unsupported images use the server-owned missing.svg placeholder.

    Original fragments are kept; full documents require a recognized article
    container. CSS uses a conservative property/function allowlist and only
    @media survives. Fonts, custom properties and active HTML are dropped.
    """
    body = nh3.clean(raw_html or '', tags=TAGS, clean_content_tags=DROP,
                     attributes=ATTRS, url_schemes={'https'}, strip_comments=True)
    parser = Article(source, pages, assets)
    parser.feed(body)
    if parser.candidates:
        _, start, end = min(parser.candidates)
        body = ''.join(parser.output[start:end])
    elif re.search(r'<(?:!doctype|html\b|body\b)', raw_html or '', re.I):
        body = '<p>Original article body unavailable.</p>'
    else:
        body = ''.join(parser.output)
    css = cached_styles(styles, source, assets, load_asset)
    head = '<style>' + css + '</style>' if css else ''
    return '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Cached article</title><style data-reader>' + READER_STYLE + '</style>' + head + '</head><body class="mediawiki skin-vector"><div class="mw-body-content">' + body + '</div></body></html>'

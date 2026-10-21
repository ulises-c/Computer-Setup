#!/usr/bin/env python3
"""Real-browser fallback checks for the grouped top bar: no JS, blocked enhancement
script, malformed native payload, and a permanently silent native request.
Requires playwright and a Homepage preview URL; makes no hardware/Glances calls.
"""
import argparse, asyncio, importlib.util, json
from pathlib import Path
from playwright.async_api import async_playwright

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('generate', ROOT / 'server-base/homepage/generate.py')
generate = importlib.util.module_from_spec(spec); spec.loader.exec_module(generate)

PROBE = """() => {
  const h=document.querySelector('#information-widgets'), n=document.querySelector('#widgets-wrap > :first-child');
  const visible=e=>{if(!e)return false;const s=getComputedStyle(e),r=e.getBoundingClientRect();return s.display!=='none'&&s.visibility!=='hidden'&&r.height>0&&r.width>0;};
  const before=h&&getComputedStyle(h,'::before');
  return {native:visible(n),shell:!!before&&before.content!=='none'&&before.content!=='normal'&&before.display!=='none',panel:!!document.querySelector('.host-monitor'),text:document.querySelector('.host-monitor')?.innerText||'',height:h?.getBoundingClientRect().height};
}"""

async def main(args):
    fleet = json.loads((ROOT / 'server-base/fleet.json').read_text())
    fleet['hosts'][args.host]['topbar']['grouped'] = True
    out = Path(args.output); out.mkdir(parents=True, exist_ok=True)
    results = {}
    async with async_playwright() as p:
        browser = await p.chromium.launch()
        async def scenario(name, *, js=True, block_script=False, native='silent', wait=14500):
            ctx = await browser.new_context(viewport={'width': 1440, 'height': 1000}, java_script_enabled=js)
            page = await ctx.new_page(); await page.bring_to_front()
            async def route(r):
                u = r.request.url
                if '/api/config/custom.js' in u:
                    return await (r.abort() if block_script else r.fulfill(body=generate.render_js(fleet, args.host), content_type='application/javascript'))
                if '/api/config/custom.css' in u:
                    return await r.fulfill(body=generate.render_css(fleet, args.host), content_type='text/css')
                if '/api/widgets/glances' in u:
                    if native == 'silent': await asyncio.sleep(60)
                    if native == 'invalid': return await r.fulfill(json={'cpu': {}, 'mem': {}, 'fs': 'bad'})
                    return await r.fulfill(status=503, json={'error': 'offline'})
                if '/api/4/' in u: return await r.fulfill(json=[], headers={'Access-Control-Allow-Origin': '*'})
                if any(s in u for s in ['/services/proxy', '/siteMonitor', '/docker/']): return await r.fulfill(json={})
                await r.continue_()
            await page.route('**/*', route)
            await page.goto(args.url, wait_until='commit')
            await page.wait_for_timeout(900)
            early = await page.evaluate(PROBE)
            await page.screenshot(path=str(out / f'{name}-early.png'))
            await page.wait_for_timeout(wait)
            late = await page.evaluate(PROBE)
            await page.screenshot(path=str(out / f'{name}-late.png'))
            results[name] = {'early': {k: v for k, v in early.items() if k != 'text'}, 'late': {k: v for k, v in late.items() if k != 'text'}, 'lateText': late['text'][:160]}
            await ctx.close()
            return early, late
        early, late = await scenario('javascript-disabled', js=False, wait=500)
        assert early['native'] and not early['shell'], ('JS disabled must show native immediately', early)
        early, late = await scenario('script-blocked', block_script=True)
        assert early['shell'] and not early['native'], ('shell reserves layout while waiting', early)
        assert late['native'] and not late['shell'] and not late['panel'], ('native fallback after 12s', late)
        early, late = await scenario('native-silent', wait=19000)  # existing 5s tick renders the age notice; no extra timer
        assert late['panel'] and not late['native'] and 'Unavailable · awaiting native data' in late['text'], ('native-silent', late)
        # Homepage's own widget error-boundary stops its SWR polling on a wrong payload; the first request can also precede custom.js.
        early, late = await scenario('native-invalid', native='invalid', wait=19000)
        assert late['panel'] and not late['native'] and 'Unavailable' in late['text'], ('native-invalid', late['text'][:300], late)
        await browser.close()
    (out / 'fallbacks.json').write_text(json.dumps(results, indent=2))
    print(json.dumps(results))

if __name__ == '__main__':
    ap = argparse.ArgumentParser(); ap.add_argument('--url', required=True); ap.add_argument('--host', default='linux-game-server'); ap.add_argument('--output', required=True)
    asyncio.run(main(ap.parse_args()))

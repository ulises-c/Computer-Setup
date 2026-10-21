#!/usr/bin/env python3
"""Optional real-Chromium regression. Install playwright separately; no hardware calls.
Run with the repository's pinned Homepage preview via --url and --host, or with
standalone representative markup (default). Captured fixtures are optional.
"""
import argparse
import asyncio
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
from playwright.async_api import async_playwright

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('generate', ROOT / 'server-base/homepage/generate.py')
generate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generate)

TRACE = """() => {
window.__monitorFrames=[]; window.__monitorCLS=[];
new PerformanceObserver(list=>window.__monitorCLS.push(...list.getEntries().filter(e=>!e.hadRecentInput).map(e=>({t:e.startTime,value:e.value,sources:(e.sources||[]).map(s=>({inTopbar:!!s.node?.closest?.('#information-widgets'),node:s.node?.id||s.node?.className||s.node?.nodeName,prev:[s.previousRect.y,s.previousRect.height],now:[s.currentRect.y,s.currentRect.height]}))})))).observe({type:'layout-shift',buffered:true});
function tick() {
 const h=document.querySelector('#information-widgets'); const n=document.querySelector('#widgets-wrap > :first-child');
 if(h) {
  const r=h.getBoundingClientRect(), p=document.querySelector('.host-monitor');
  const s=n && getComputedStyle(n); const ps=getComputedStyle(h,'::before');
  window.__monitorFrames.push({t:performance.now(),height:r.height,width:r.width,servicesTop:document.querySelector('.services-group')?.getBoundingClientRect().top??null,native:!!(n&&n.getBoundingClientRect().height&&s.display!=='none'&&s.visibility!=='hidden'),grouped:!!p,boot:ps.content!=='none'&&ps.content!=='normal'&&ps.visibility!=='hidden',text:p?.textContent||''});
 }
 if(performance.now()<45000) requestAnimationFrame(tick);
} requestAnimationFrame(tick);
}"""

async def run(args):
    fleet=json.loads((ROOT/'server-base/fleet.json').read_text())
    fleet['hosts'][args.host]['topbar']['grouped']=True
    top=fleet['hosts'][args.host]['topbar']
    config={'grouped':True,'glances':'/glances',**top}
    data={'cpu':{'total':12.3},'mem':{'percent':20,'available':32e9,'total':40e9},'load':{'min15':0.7},'fs':[],'sensors':[], 'uptime':'3 days, 12:03:42'}
    extras={'gpu':[],'wifi':[],'network':[],'smart':[],'storagepolicy':{}}
    if args.fixture:
        fixture=json.loads(Path(args.fixture).read_text()); data=fixture['native']; extras.update(fixture.get('extras',{}))
    if args.synthetic_storage:
        # Schema-shaped SYNTHETIC rows (see server-base/glances/README.md); layout/state
        # testing only, never a measurement. HDD mounts are deliberately absent.
        hdd=set(top.get('hddDisks',[]))
        data['fs']=[{'mnt_point':m,'alias':'system' if m=='/etc/hostname' else m,'percent':37.0,'free':300e9,'size':512e9,'fs_type':'ext4','collected_at':1,'collection_age_seconds':299,'collection_interval_seconds':300,'collection_status':'ok','storage_class':'solid_state','collection_source':'cached_statvfs'} for m in top['disks'] if m not in hdd]
    if args.synthetic_storage and top.get('safeSSDHealth'):
        extras['smart']=[{'DeviceName':'nvme0 Synthetic','a':{'key':'percentageUsed','value':2},'b':{'key':'criticalWarning','value':0},'c':{'key':'integrityErrors','value':0}}]
        extras['storagepolicy']={'version':1,'smart':{'enabled':True,'status':'ok','interval_seconds':600,'devices':[{'DeviceName':'nvme0 Synthetic','collected_at':1,'collection_age_seconds':120}]}}
    out=Path(args.output); out.mkdir(parents=True,exist_ok=True)
    results=[]
    async with async_playwright() as p:
        browser=await p.chromium.launch()
        for width in [1440,390]:
            context=await browser.new_context(viewport={'width':width,'height':1000},device_scale_factor=1)
            await context.add_init_script(f'({TRACE})()')
            page=await context.new_page(); await page.bring_to_front()
            state={'mode':'delayed'}; requests=[]; failures=[]
            async def route_handler(route):
                u=route.request.url
                if '/api/config/custom.js' in u or u.endswith('/custom.js'):
                    await asyncio.sleep(1.5)
                    await route.fulfill(body=generate.render_js(fleet,args.host),content_type='application/javascript')
                elif '/api/config/custom.css' in u:
                    await route.fulfill(body=generate.render_css(fleet,args.host),content_type='text/css')
                elif '/api/widgets/glances' in u:
                    requests.append('native')
                    if state['mode']=='delayed': await asyncio.sleep(args.delay)
                    if state['mode']=='failure': await route.fulfill(status=503,json={'error':'forced offline'})
                    elif state['mode']=='invalid': await route.fulfill(json={'cpu':{},'mem':{},'fs':'bad'})
                    else: await route.fulfill(json=data)
                elif '/api/4/' in u:
                    key=u.rsplit('/',1)[-1]; requests.append(key)
                    # Hardware-adjacent endpoints are forbidden unless this host explicitly opted in to SSD health.
                    forbidden=['fs','all','sensors']+([] if top.get('safeSSDHealth') else ['smart','storagepolicy'])
                    if key in forbidden: failures.append(key); return await route.fulfill(status=500,json={'forbidden':key})
                    await route.fulfill(json=extras.get(key,[]),headers={'Access-Control-Allow-Origin':'*'})
                elif args.url and '/api/' in u and '/config/' not in u:
                    # Homepage service-card APIs are outside this renderer test;
                    # never let a preview proxy access another host's devices.
                    if any(s in u for s in ['/services/proxy','/siteMonitor','/docker/']): await route.fulfill(json={})
                    else: await route.continue_()
                elif args.url: await route.continue_()
                else:
                    html=f'''<!doctype html><html><head><style>*{{box-sizing:border-box}}body{{margin:0;background:#0f172a;color:#e2e8f0;font-family:Arial,sans-serif}}#information-widgets{{margin:36px;background:#ffffff0d}}#widgets-wrap{{display:flex}}#content{{padding:24px}}{generate.render_css(fleet,args.host)}</style><script>window.__NEXT_DATA__={json.dumps({'props':{'pageProps':{'initialSettings':{'topbarExtras':config}}}})};</script></head><body><div id="information-widgets"><div id="widgets-wrap"><div class="information-widget-glances">NATIVE CPU RAM WIDGET</div><div id="information-widgets-right"><div class="information-widget-datetime">10/5/26, 10:00</div></div></div></div><div id="content">Services below</div><script src="/custom.js"></script><script>setTimeout(()=>{{fetch('/api/widgets/glances?index=0');setInterval(()=>fetch('/api/widgets/glances?index=0'),3000)}},2000);</script></body></html>'''
                    await route.fulfill(body=html,content_type='text/html')
            await page.route('**/*',route_handler)
            await page.goto(args.url or 'http://test.local/',wait_until='commit')
            await page.wait_for_timeout(1000)
            await page.screenshot(path=str(out/f'{args.host}-{width}-firstpaint.png'))
            early=await page.evaluate('window.__monitorFrames')
            assert early and not any(f['native'] for f in early),('native flash',early[:5])
            await page.wait_for_selector('.host-monitor')
            await page.locator('.monitor-header a').focus()
            await page.wait_for_function('window.__homepageGroupedTopbar?.samples.native?.at && !window.__homepageGroupedTopbar.samples.native.error',timeout=20000)
            assert await page.evaluate("document.activeElement?.matches('.monitor-header a')"),'link focus lost'
            await page.screenshot(path=str(out/f'{args.host}-{width}-ready.png'))
            state['mode']='failure'; await page.wait_for_timeout(7000)
            await page.screenshot(path=str(out/f'{args.host}-{width}-failure.png'))
            assert 'Unavailable' in await page.locator('.host-monitor').inner_text(), {'requests':requests,'text':await page.locator('.host-monitor').inner_text(),'hidden':await page.evaluate('document.hidden'),'samples':await page.evaluate('window.__homepageGroupedTopbar?.samples')}
            state['mode']='ready'; await page.wait_for_function('window.__homepageGroupedTopbar?.samples.native?.at && !window.__homepageGroupedTopbar.samples.native.error',timeout=15000)
            text=await page.locator('.host-monitor').inner_text()
            assert data['uptime'] in text
            if args.synthetic_storage:
                for mount in top.get('hddDisks',[]): assert 'Not monitored · HDD' in text, text
                assert any(f'Cached · collected {m}m ago' in text for m in (4,5)), text
                if top.get('safeSSDHealth'): assert 'Cached · collected 2m ago' in text and 'Health' in text, text
            frames=await page.evaluate('window.__monitorFrames'); cls=await page.evaluate('window.__monitorCLS')
            sizes=await page.evaluate('({viewport:document.documentElement.clientWidth,page:document.documentElement.scrollWidth,tiles:[...document.querySelectorAll(".monitor-tile")].filter(e=>e.scrollWidth>e.clientWidth).length,paint:performance.getEntriesByType("paint").map(e=>({name:e.name,t:e.startTime}))})')
            assert sizes['viewport']==sizes['page'] and sizes['tiles']==0,('overflow',sizes)
            assert not failures,('forbidden hardware request',failures)
            assert not any(f['native'] for f in frames),'native flash later'
            loading=[f for f in frames if f['grouped'] and 'Loading' in f['text']]
            ready=[f for f in frames if f['grouped'] and data['uptime'] in f['text']]
            assert ready,('native sample never observed',requests,await page.evaluate('window.__homepageGroupedTopbar?.samples'))
            assert max(f['height'] for f in frames)-min(f['height'] for f in frames)<2,('layout changed',sorted(set(f['height'] for f in frames)))
            topbar_cls=sum(e['value'] for e in cls if any(s['inTopbar'] for s in e['sources']))
            assert topbar_cls==0,('top bar caused layout shift',cls)
            grouped_start=next(i for i,f in enumerate(frames) if f['grouped'])
            tops={round(f['servicesTop']) for f in frames[grouped_start:] if f['servicesTop'] is not None}
            assert len(tops)==1,('content below moved after grouped mount',sorted(tops))
            result={'host':args.host,'width':width,'firstFrame':frames[0], 'firstGroupedMs':next(f['t'] for f in frames if f['grouped']),'firstDataMs':ready[0]['t'],'heights':sorted(set(f['height'] for f in frames)),'pageCLS':sum(e['value'] for e in cls),'topbarCLS':topbar_cls,'contentTop':sorted(tops),'layoutShifts':cls,'requests':{k:requests.count(k) for k in set(requests)},'blockedHardwareRequests':failures,'sizes':sizes}
            result['firstFrame'].pop('text',None)
            results.append(result); print(json.dumps(result),flush=True)
            await context.close()
        await browser.close()
    (out/f'{args.host}-results.json').write_text(json.dumps(results,indent=2))

if __name__=='__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--url'); parser.add_argument('--host',default='linux-game-server'); parser.add_argument('--fixture'); parser.add_argument('--synthetic-storage',action='store_true',help='inject schema-shaped synthetic fs rows (layout/state test only)'); parser.add_argument('--delay',type=float,default=6,help='seconds to hold the first native responses'); parser.add_argument('--output',default=str(Path(tempfile.gettempdir())/'grouped-firstpaint'))
    asyncio.run(run(parser.parse_args()))

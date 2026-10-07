const test = require('node:test');
const assert = require('node:assert/strict');
const api = require('../../server-base/homepage/grouped-topbar.js');

function runtime(fetch = async () => new Promise(() => {})) {
  const body = {innerHTML:''};
  const panel = {innerHTML:'',setAttribute(){},querySelector:s=>s==='.monitor-body'?body:null};
  const host = {panel:null,classes:new Set(),classList:{add(c){host.classes.add(c);}},querySelector(s){return s===':scope > .host-monitor'?this.panel:null;},prepend(p){this.panel=p;}};
  const document = {hidden:true,querySelector:s=>s==='#information-widgets'?host:null,createElement:()=>panel,addEventListener(){},removeEventListener(){}};
  const timers=[];
  const root={document,location:{origin:'https://example.test'},fetch,setInterval(fn,ms){timers.push([fn,ms]);return 1;},clearInterval(){},addEventListener(){},AbortSignal};
  return {root,host,panel,body,timers};
}

test('mounts grouped loading dashes synchronously before a native response', () => {
  const {root,host,body}=runtime();
  const control=api.start(root,{label:'NAS',net:'eth0',disks:['/etc/hostname']});
  assert.ok(host.panel,'grouped shell mounted without data');
  assert.ok(host.classes.has('host-monitor-ready'));
  for(const text of ['Compute','Storage','Connectivity','System','Loading','—']) assert.ok(body.innerHTML.includes(text),text);
  assert.ok(!body.innerHTML.includes('0%'),'unknown is not zero');
  control.stop();
});

test('normal cache ages are calm; stale, unknown and failed states remain warnings', () => {
  const html = api.markup([{title:'Storage',tiles:[
    {label:'a',rows:[],state:'Cached · collected 5s ago'},
    {label:'b',rows:[],state:'Stale · collected 25m ago'},
    {label:'c',rows:[],state:'Cached · age unknown'},
    {label:'d',rows:[],state:'Collection error · last value, 3m old'},
    {label:'e',rows:[],state:''},
  ]}]);
  const tile = label => html.split('<article ').find(part => part.includes(`<h3>${label}</h3>`));
  assert.match(tile('a'), /^class="monitor-tile"/, 'a healthy cache is not a warning tile');
  assert.match(tile('a'), /<p class="monitor-state is-calm">Cached · collected 5s ago<\/p>/);
  for (const label of ['b','c','d']) {
    assert.match(tile(label), /^class="monitor-tile has-warning"/, label);
    assert.doesNotMatch(tile(label), /monitor-state is-calm/, label);
  }
  assert.match(tile('e'), /<p class="monitor-state is-calm"><\/p>/, 'empty state reserves space without a warning');
});

test('normal informational notice is calm; outages and stale native data stay warnings', () => {
  assert.equal(api.noticeLevel('Core metrics update automatically · filesystem and health values are cached snapshots'), 'calm');
  assert.equal(api.noticeLevel('Loading host metrics'), 'calm');
  assert.equal(api.noticeLevel('Unavailable · awaiting native data'), 'warn');
  assert.equal(api.noticeLevel('Extras unavailable: GPU'), 'warn');
  assert.equal(api.noticeLevel('Stale · last value'), 'warn');
});

module.exports={runtime};

test('native failure is not double-reported as a filesystem extras failure, and hidden tabs do not claim outage', async () => {
  const response={ok:false,clone:()=>({json:async()=>({error:'down'})})};
  const r=runtime(async()=>response); const control=api.start(r.root,{disks:['/etc/hostname']});
  await r.root.fetch('/api/widgets/glances?index=0'); await new Promise(resolve=>setImmediate(resolve));
  assert.ok(r.body.innerHTML.includes('Unavailable'));
  assert.ok(!r.body.innerHTML.includes('Extras unavailable: FILESYSTEM'),r.body.innerHTML);
  control.stop();
  const realNow=Date.now; let now=realNow(); Date.now=()=>now;
  try {
    const hidden=runtime(); const c2=api.start(hidden.root,{}); now+=13000; await hidden.timers[0][0]();
    assert.ok(!hidden.body.innerHTML.includes('awaiting native data'),'hidden tab is not an outage');
    hidden.root.document.hidden=false; await hidden.timers[0][0]();
    assert.ok(hidden.body.innerHTML.includes('Unavailable · awaiting native data'));
    c2.stop();
  } finally { Date.now=realNow; }
});

test('wrong numeric payload shapes stay unavailable while original native response is untouched', async () => {
  const response={ok:true,clone:()=>({json:async()=>({cpu:{},mem:{},fs:[]})})};
  const r=runtime(async()=>response); const control=api.start(r.root,{disks:['/etc/hostname']});
  assert.equal(await r.root.fetch('/api/widgets/glances?index=0'),response);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(control.samples.native.error,true);
  assert.equal(control.samples.native.at,undefined);
  assert.ok(r.body.innerHTML.includes('Unavailable'));
  control.stop();
});

test('per-host GPU fields omit unsupported shared-memory gauges without inventing VRAM', () => {
  const groups=api.model({gpu:{data:[{gpu_id:'intel0',proc:0,name:'Intel GPU'}],at:1000}}, {gpuTypes:{intel0:'iGPU'},gpuFields:{intel0:['Usage']}},1000,'');
  assert.deepEqual(groups[0].tiles.find(t=>t.label==='iGPU').rows,[['Usage','0%']]);
});

test('SSD health is disabled by default, opt-in uses a conservative configurable cadence', async () => {
  const calls=[]; const r=runtime(async url=>{calls.push(url);return {ok:true,json:async()=>[]};});
  r.root.document.hidden=false;
  let control=api.start(r.root,{glances:'/glances',net:'eth0'});
  await new Promise(resolve=>setImmediate(resolve));
  assert.ok(!calls.some(u=>String(u).includes('/smart')),'default must not probe drives');
  control.stop(); calls.length=0; r.host.panel=null;
  control=api.start(r.root,{glances:'/glances',safeSSDHealth:true,smartIntervalMs:900000});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(calls.filter(u=>String(u).includes('/smart')).length,1);
  await r.timers.at(-1)[0]();
  assert.equal(calls.filter(u=>String(u).includes('/smart')).length,1);
  assert.ok(r.panel.innerHTML.includes('health 15m'));
  control.stop();
});

test('configured GPU and thermal slots keep the same row geometry before data', () => {
  const config={disks:['/etc/hostname','/mnt/photos'],diskLabels:{'/mnt/photos':'Photos SSD'},gpuTypes:{nvidia0:'dGPU'},temperatureLabels:['NVMe'],wifi:true,net:'wlan0'};
  const native={cpu:{total:0},mem:{percent:0},fs:[],sensors:[{label:'CPU',type:'temperature_core',value:30,warning:80},{label:'NVMe',type:'temperature_core',value:32,warning:74}]};
  const skeleton=api.model({},config,1000,'');
  const ready=api.model({native:{data:native,at:1000},gpu:{data:[{gpu_id:'nvidia0',proc:0,temperature:31,memory_used:0,memory_total:8192,mem:0,fan_speed:0}],at:1000},wifi:{data:[{quality_link:80,quality_level:-55}],at:1000}},config,1000,'now');
  const geometry=groups=>groups.map(g=>g.tiles.map(t=>[t.label,t.rows.map(r=>r[0])]));
  assert.deepEqual(geometry(skeleton),geometry(ready));
  assert.equal(skeleton[1].tiles.find(t=>t.label==='Photos SSD').rows[0][1],'—');
  assert.ok(!JSON.stringify(api.model({},{gpu:false,wifi:false,disks:[]},1000,'')).includes('GPU'));
});

// Storage contract: server/glances/README.md ("API contract / truthful cache age").
const fsRow=(extra={})=>({mnt_point:'/etc/hostname',percent:10,free:5e9,size:10e9,collected_at:1000,collection_age_seconds:299,collection_interval_seconds:300,collection_status:'ok',...extra});
const nativeWith=(fs,at=1000)=>({data:{cpu:{total:1},mem:{percent:5},fs,sensors:[{label:'NVMe',type:'temperature_core',value:30,warning:74}]},at});
const disk=(groups,label='System disk')=>groups[1].tiles.find(t=>t.label===label);

test('filesystem age comes from the collector and advances with the browser clock, not the HTTP response', () => {
  const sample=nativeWith([fsRow()]);
  assert.equal(disk(api.model({native:sample},{disks:['/etc/hostname']},1000,'')).state,'Cached · collected 4m ago');
  assert.equal(disk(api.model({native:sample},{disks:['/etc/hostname']},6000,'')).state,'Cached · collected 5m ago');
});

test('filesystem rows past twice their collection interval are stale and errors keep the last real value', () => {
  assert.equal(disk(api.model({native:nativeWith([fsRow({collection_age_seconds:700})])},{disks:['/etc/hostname']},1000,'')).state,'Stale · collected 11m ago');
  const failed=disk(api.model({native:nativeWith([fsRow({collection_status:'error'})])},{disks:['/etc/hostname']},1000,''));
  assert.equal(failed.state,'Collection error · last value, 4m old');
  assert.deepEqual(failed.rows.map(r=>r[0]),['Used','Free','Total']);
  assert.equal(failed.rows[0][1],'10%');
  const never=disk(api.model({native:nativeWith([fsRow({collection_status:'never',collected_at:null,collection_age_seconds:null,percent:null,free:null,size:null})])},{disks:['/etc/hostname']},1000,''));
  assert.equal(never.state,'Waiting for first collection');
  assert.equal(never.rows[0][1],'—');
});

test('rows from an older backend without collector metadata are never dated as fresh', () => {
  const row={mnt_point:'/etc/hostname',percent:10,free:1,size:2};
  assert.equal(disk(api.model({native:nativeWith([row])},{disks:['/etc/hostname']},1000,'')).state,'Cached · age unknown');
});

test('configured HDDs are never monitored: no values, no loading, no unavailable claim, even if a row leaks through', () => {
  const config={disks:['/etc/hostname','/mnt/das'],diskLabels:{'/mnt/das':'DAS 4 TB'},hddDisks:['/mnt/das']};
  for (const samples of [{}, {native:nativeWith([fsRow(),fsRow({mnt_point:'/mnt/das',percent:50,size:4e12})])}]) {
    const hdd=disk(api.model(samples,config,1000,''),'DAS 4 TB');
    assert.equal(hdd.state,'Not monitored · HDD');
    assert.deepEqual(hdd.rows,[['Used','—'],['Free','—'],['Total','—']]);
    assert.equal(hdd.usage,undefined);
  }
});

test('activity-gated HDD rows show their values with the date they were read', () => {
  const config={disks:['/etc/hostname','/mnt/das'],diskLabels:{'/mnt/das':'DAS 4 TB'},hddDisks:['/mnt/das'],hddActivityStats:true};
  const row=fsRow({mnt_point:'/mnt/das',percent:50,free:2e12,size:4e12,fs_type:'ext4',collection_source:'activity_gated_statvfs',collected_at:Date.UTC(2026,9,5,22,4)/1000});
  const hdd=disk(api.model({native:nativeWith([fsRow(),row])},config,Date.UTC(2026,9,6),''),'DAS 4 TB');
  assert.deepEqual(hdd.rows,[['Used','50%'],['Free','2 TB'],['Total','4 TB']]);
  assert.equal(hdd.usage,50);
  assert.match(hdd.state,/^Last read Oct \d+, \d+:04\s?(AM|PM)$/);
  assert.equal(api.readDate(Date.UTC(2025,0,2,12)/1000,Date.UTC(2026,9,6)).includes('2025'),true,'a different year is spelled out');
  assert.ok(api.markup(api.model({native:nativeWith([fsRow(),row])},config,Date.UTC(2026,9,6),'')).includes('monitor-state is-calm'));
});

test('HDD without an activity-gated row says it waits for activity, never zero or unavailable', () => {
  const config={disks:['/mnt/das'],diskLabels:{'/mnt/das':'DAS'},hddDisks:['/mnt/das'],hddActivityStats:true};
  const unmarked=fsRow({mnt_point:'/mnt/das',percent:50,size:4e12});
  for (const fs of [[],[unmarked]]) {
    const hdd=disk(api.model({native:nativeWith(fs)},config,1000,''),'DAS');
    assert.equal(hdd.state,'Not read yet · waits for drive activity');
    assert.deepEqual(hdd.rows,[['Used','—'],['Free','—'],['Total','—']]);
    assert.equal(hdd.usage,undefined);
  }
  assert.equal(disk(api.model({},config,1000,''),'DAS').state,'Loading');
});

test('NVMe health age is matched by device name from the storage policy and policy outages stay explicit', () => {
  const device={DeviceName:'nvme0 Example',a:{key:'percentageUsed',value:2},b:{key:'criticalWarning',value:0},c:{key:'integrityErrors',value:0}};
  const policy=(age)=>({data:{smart:{enabled:true,status:'ok',devices:[{DeviceName:'nvme0 Example',collected_at:1,collection_age_seconds:age}]}},at:1000});
  const cfg={disks:[],safeSSDHealth:true,temperatureLabels:['NVMe']};
  const tile=samples=>api.model({native:nativeWith([]),smart:{data:[device],at:1000},...samples},cfg,1000,'')[1].tiles.find(t=>t.label==='NVMe');
  assert.equal(tile({storagepolicy:policy(120)}).state,'Cached · collected 2m ago');
  assert.equal(tile({storagepolicy:policy(1300)}).state,'Stale · collected 21m ago');
  assert.equal(tile({}).state,'Cached · age unknown');
  assert.equal(tile({storagepolicy:{data:{smart:{enabled:false,status:'never',devices:[]}},at:1000}}).state,'Health disabled by host policy');
});

test('storage thermal rows are labelled cached even before health is opted in', () => {
  const tile=api.model({native:nativeWith([])},{disks:[],temperatureLabels:['NVMe']},1000,'')[1].tiles.find(t=>t.label==='NVMe');
  assert.equal(tile.state,'Cached · age unknown');
});

test('storage requests: nothing by default; opt-in asks smart and storagepolicy once per conservative interval', async () => {
  const calls=[]; const r=runtime(async url=>{calls.push(String(url));return {ok:true,json:async()=>[]};}); r.root.document.hidden=false;
  let c=api.start(r.root,{glances:'/glances'}); await new Promise(x=>setImmediate(x));
  assert.deepEqual(calls.filter(u=>/smart|storagepolicy|\/fs|\/all/.test(u)),[]); c.stop(); calls.length=0; r.host.panel=null;
  c=api.start(r.root,{glances:'/glances',safeSSDHealth:true,smartIntervalMs:1000}); await new Promise(x=>setImmediate(x));
  assert.equal(calls.filter(u=>u.endsWith('/api/4/smart')).length,1);
  assert.equal(calls.filter(u=>u.endsWith('/api/4/storagepolicy')).length,1);
  await r.timers.at(-1)[0](); // interval below the 10 minute floor is clamped
  assert.equal(calls.filter(u=>u.endsWith('/api/4/smart')).length,1);
  assert.ok(r.panel.innerHTML.includes('health 10m'),r.panel.innerHTML);
  c.stop();
});

test('storagepolicy object payload is accepted but never required by core metrics', async () => {
  const policy={version:1,smart:{enabled:true,devices:[]}};
  const r=runtime(async url=>({ok:true,json:async()=>String(url).endsWith('/storagepolicy')?policy:[]})); r.root.document.hidden=false;
  const c=api.start(r.root,{glances:'/glances',safeSSDHealth:true}); await new Promise(x=>setImmediate(x));
  assert.deepEqual(c.samples.storagepolicy.data,policy);
  assert.equal(c.samples.storagepolicy.error,false);
  c.stop();
});

test('opted-in SSD health reserves Health and Wear rows before data and fills the same rows after', () => {
  const config={disks:[],safeSSDHealth:true,temperatureLabels:['NVMe']};
  const device={DeviceName:'nvme0 Example',a:{key:'percentageUsed',value:2},b:{key:'criticalWarning',value:0},c:{key:'integrityErrors',value:0}};
  const before=api.model({},config,1000,'')[1].tiles;
  const after=api.model({native:nativeWith([]),smart:{data:[device],at:1000}},config,1000,'')[1].tiles;
  assert.deepEqual(before.map(t=>[t.label,t.rows.map(r=>r[0])]),after.map(t=>[t.label,t.rows.map(r=>r[0])]));
  assert.deepEqual(before[0].rows.map(r=>r[0]),['Temp','Warn','Health','Wear']);
  assert.equal(before[0].rows[2][1],'—');
  assert.equal(after[0].rows[2][1],'OK');
  const standalone=api.model({},{disks:[],safeSSDHealth:true},1000,'')[1].tiles;
  assert.deepEqual(standalone.map(t=>[t.label,t.rows.map(r=>r[0])]),[['NVMe health',['Health','Wear']]]);
  assert.deepEqual(api.model({},{disks:[],temperatureLabels:['NVMe']},1000,'')[1].tiles[0].rows.map(r=>r[0]),['Temp','Warn']);
});

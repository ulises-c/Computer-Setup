const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = path.join(__dirname, '../../server-base/homepage/grouped-topbar.js');
test('game host has an opt-in renderer without native polling', () => {
  assert.ok(fs.existsSync(source), 'grouped renderer exists');
  const api = require(source);
  assert.equal(api.isNativeRequest('/api/widgets/glances?index=0', 'https://example.test'), true);
  assert.equal(api.isNativeRequest('/api/services/proxy?index=0', 'https://example.test'), false);
  assert.equal(api.isNativeRequest('https://other.test/api/widgets/glances?index=0', 'https://example.test'), false);
  assert.equal(api.isNativeRequest('/api/widgets/glances?index=1', 'https://example.test'), false);
});
const api = () => require(source);
const native = {cpu:{total:12.3}, load:{min15:0.4}, mem:{total:32e9,available:28e9,percent:12.5}, fs:[{mnt_point:'/etc/hostname',alias:'system',free:450e9,size:500e9,used:25e9,percent:5}], sensors:[{type:'temperature_core',label:'CPU',value:33,warning:84},{type:'temperature_core',label:'NVMe',value:30,warning:74}],uptime:'4 days, 13:02:20'};
const sample = (data) => ({data,at:1000,error:false});
test('groups preserve real native and available extras, including zero GPU readings', () => {
  const groups = api().model({native:sample(native),gpu:sample([{name:'GTX 1070',proc:0,temperature:37,fan_speed:0,mem:1.4}]),network:sample([{interface_name:'eth0',bytes_sent_rate_per_sec:200,bytes_recv_rate_per_sec:300}]),wifi:sample([]),smart:sample([])}, {net:'eth0',disks:['/etc/hostname']}, 1000, '10/5/26, 10:00');
  assert.deepEqual(groups.map(g=>g.title), ['Compute','Storage','Connectivity','System']);
  const text = JSON.stringify(groups);
  for (const label of ['CPU','RAM','Temp','GPU','VRAM','Fan','System disk','NVMe','eth0','Upload','Download','Uptime','Clock','Warn']) assert.ok(text.includes(label),label);
  assert.ok(text.includes('0%'));
  assert.ok(text.includes('Used'));
  assert.ok(text.includes('Free'));
  assert.ok(text.includes('Total'));
  assert.ok(text.includes('4 days, 13:02:20'));
});
test('failure and age retain values but never claim they are live', () => {
  assert.equal(api().status(undefined,1000),'Loading');
  assert.equal(api().status({error:true},1000),'Unavailable');
  assert.equal(api().status({...sample({}),error:true},1000),'Unavailable · last value');
  assert.equal(api().status(sample({}),16000),'');
  assert.equal(api().status(sample({}),16001),'Stale · last value');
  const groups=api().model({native:sample(native),gpu:sample([])}, {disks:['missing']},1000,'');
  assert.equal(groups[0].tiles.some(t=>t.label==='GPU'),false);
  assert.deepEqual(groups[1].tiles.find(t=>t.label==='missing').rows,[['Used','—'],['Free','—'],['Total','—']]);
});
test('renderer escapes API text, clamps usage, and rejects credential-bearing links', () => {
  const html=api().markup([{title:'Compute',tiles:[{label:'<script>',rows:[['Usage','<img onerror=x>']],usage:200,state:'Stale · last value',detail:'a&b'}]}]);
  assert.ok(html.includes('&lt;script&gt;'));
  assert.ok(html.includes('&lt;img onerror=x&gt;'));
  assert.ok(html.includes('width:100%'));
  assert.ok(html.includes('Stale · last value'));
  assert.equal(api().publicUrl('https://user:password@example.test/glances','https://example.test'),null);
  assert.equal(api().publicUrl('javascript:alert(1)','https://example.test'),null);
  assert.equal(api().publicUrl('/glances','https://example.test'),'https://example.test/glances');
});
test('runtime uses one extras timer, no sensor/native polling, and preserves native responses', async () => {
  const calls=[]; const timers=[]; const listeners={};
  const response={ok:true,clone:()=>({json:async()=>native}),json:async()=>[]};
  const root={location:{origin:'https://example.test'},document:{hidden:false,querySelector:()=>null,addEventListener:(key,fn)=>{listeners[key]=fn;},removeEventListener:()=>{}},fetch:async(url,options)=>{calls.push([url,options]);return response;},setInterval:(fn,ms)=>{timers.push([fn,ms]);return 1;},clearInterval:()=>{},addEventListener:()=>{},AbortSignal};
  const control=api().start(root,{glances:'https://example.test/glances',net:'eth0',disks:[]});
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(timers.length,1);assert.equal(timers[0][1],5000);
  assert.deepEqual(calls.map(c=>new URL(c[0]).pathname).sort(),['/glances/api/4/gpu','/glances/api/4/network','/glances/api/4/wifi']);
  assert.ok(calls.every(c=>c[1].credentials==='omit'));
  const actual=await root.fetch('/api/widgets/glances?index=0');
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(actual,response);assert.deepEqual(control.samples.native.data,native);
  root.document.hidden=true;await timers[0][0]();assert.equal(calls.length,4);
  control.stop();
});
test('compact compute folds CPU temperature into CPU, and host clock into uptime', () => {
  const groups=api().model({native:sample(native),gpu:sample([{proc:0}])},{},1000,'date');
  assert.equal(groups[0].tiles.length,3);
  assert.ok(groups[0].tiles.find(t=>t.label==='CPU').rows.some(r=>r[1]==='33°C'));
  assert.equal(groups[3].tiles.length,1);
  assert.ok(groups[3].tiles[0].rows.some(r=>r[0]==='Clock'));
});
test('NVMe thermal and health rows form one compact tile with conservative freshness', () => {
  const smart=[{DeviceName:'NVMe',a:{key:'percentageUsed',value:2},b:{key:'criticalWarning',value:0},c:{key:'integrityErrors',value:0}}];
  const groups=api().model({native:sample(native),smart:{...sample(smart),error:true}},{disks:['/etc/hostname']},1000,'');
  assert.equal(groups[1].tiles.length,2);
  const nvme=groups[1].tiles.find(t=>t.label==='NVMe');
  assert.ok(nvme.rows.some(r=>r[0]==='Temp'));
  assert.ok(nvme.rows.some(r=>r[0]==='Health' && r[1]==='OK'));
  assert.equal(nvme.state,'Unavailable · last value');
});
test('native HTTP failures and clone failures preserve SWR response and mark last data unavailable', async () => {
  let response={ok:true,clone:()=>({json:async()=>native}),json:async()=>[]};
  const root={location:{origin:'https://example.test'},document:{hidden:true,querySelector:()=>null,addEventListener:()=>{},removeEventListener:()=>{}},fetch:async()=>response,setInterval:()=>1,clearInterval:()=>{},addEventListener:()=>{},AbortSignal};
  const control=api().start(root,{});
  await root.fetch('/api/widgets/glances?index=0');await new Promise(r=>setImmediate(r));
  response={ok:false,clone:()=>({json:async()=>({error:'upstream failure'})})};
  assert.equal(await root.fetch('/api/widgets/glances?index=0'),response);await new Promise(r=>setImmediate(r));
  assert.equal(control.samples.native.error,true);assert.deepEqual(control.samples.native.data,native);
  response={ok:true,clone:()=>{throw new Error('cannot clone');}};
  assert.equal(await root.fetch('/api/widgets/glances?index=0'),response);await new Promise(r=>setImmediate(r));
  control.stop();
});


test('GPU identifies configured dGPU/iGPU and reports byte gauges without deriving them from percent', () => {
  const groups=api().model({native:sample(native),gpu:sample([
    {gpu_id:'nvidia0',name:'NVIDIA GeForce GTX 1070',mem:12.5,memory_used:1073741824,memory_total:8589934592},
    {gpu_id:'intel0',name:'Intel graphics',mem:20},
    {gpu_id:'other0',name:'Unclassified',mem:20}
  ])},{gpuTypes:{nvidia0:'dGPU',intel0:'iGPU'}},1000,'');
  const gpu=groups[0].tiles.find(t=>t.label==='dGPU');
  assert.ok(gpu, 'explicit dGPU designation');
  assert.ok(gpu.detail.includes('NVIDIA GeForce GTX 1070'));
  assert.ok(gpu.rows.some(r=>r[0]==='VRAM' && r[1]==='1 GiB / 8 GiB'));
  const igpu=groups[0].tiles.find(t=>t.label==='iGPU');
  assert.ok(igpu.rows.some(r=>r[0]==='Memory' && r[1]==='— / —'));
  assert.ok(groups[0].tiles.find(t=>t.detail?.includes('Unclassified')).detail.includes('type unknown'));
});

test('top bar has no RGB tile and makes no RGB request, even if a stale sample or setting is supplied', async () => {
  const groups=api().model({native:sample(native),rgb:sample({updated:1,devices:[{name:'Omen',mode:'Static'}]})},{rgb:'/host-status/rgb.json'},1000,'clock');
  const text=JSON.stringify(groups);
  assert.ok(!/rgb|Omen|Static/i.test(text), text);
  const calls=[];
  const root={location:{origin:'https://example.test'},document:{hidden:false,querySelector:()=>null,addEventListener:()=>{},removeEventListener:()=>{}},fetch:async(url)=>{calls.push(String(url));return {ok:true,json:async()=>[]};},setInterval:()=>1,clearInterval:()=>{},addEventListener:()=>{},AbortSignal};
  const control=api().start(root,{glances:'https://example.test/glances',rgb:'/host-status/rgb.json'});
  await new Promise(r=>setImmediate(r));
  assert.ok(calls.length>0);
  assert.ok(calls.every(url=>!/rgb|host-status/i.test(url)), calls.join());
  assert.equal(control.samples.rgb,undefined);
  control.stop();
});

test('System group is the host tile with uptime and clock, and the panel keeps the Open Glances link', async () => {
  const groups=api().model({native:sample(native)},{},1000,'10/5/26, 10:00');
  assert.equal(groups[3].title,'System');
  assert.deepEqual(groups[3].tiles.map(t=>t.label),['Host']);
  assert.deepEqual(groups[3].tiles[0].rows,[['Uptime','4 days, 13:02:20'],['Clock','10/5/26, 10:00']]);
  const body={innerHTML:''};
  const panel={className:'',innerHTML:'',setAttribute(){},querySelector:(sel)=>sel==='.monitor-body'?body:null};
  const host={classList:{add(){}},panel:null,querySelector(sel){return sel===':scope > .host-monitor'?this.panel:null;},prepend(el){this.panel=el;}};
  const document={hidden:true,querySelector:(sel)=>sel==='#information-widgets'?host:sel==='.information-widget-datetime'?{textContent:' 10/5/26, 10:00 '}:null,createElement:()=>panel,addEventListener(){},removeEventListener(){}};
  const root={location:{origin:'https://example.test'},document,fetch:async()=>({ok:true,clone:()=>({json:async()=>native}),json:async()=>[]}),setInterval:()=>1,clearInterval:()=>{},addEventListener:()=>{},AbortSignal};
  const control=api().start(root,{glances:'https://example.test/glances',label:'game server'});
  await root.fetch('/api/widgets/glances?index=0');await new Promise(r=>setImmediate(r));
  assert.match(panel.innerHTML,/href="https:\/\/example\.test\/glances"[^>]*>Open Glances/);
  assert.ok(body.innerHTML.includes('System'));
  assert.ok(body.innerHTML.includes('4 days, 13:02:20'));
  assert.ok(body.innerHTML.includes('10/5/26, 10:00'));
  assert.ok(!/rgb/i.test(panel.innerHTML+body.innerHTML));
  control.stop();
});

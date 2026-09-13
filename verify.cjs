// Development verification only. Not shipped in the ZIP; no real credentials.
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const assert = require('node:assert/strict');
const { createRequire } = require('node:module');
const req = createRequire(path.join(__dirname, 'src/apps/desktop/package.json'));
const { _electron } = req('playwright');
// Reuse Playwright's bundled ws; no extra install and no production dependency.
const { wsServer: WebSocketServer } = req(path.join(path.dirname(req.resolve('playwright-core/package.json')),'lib/utilsBundle.js'));
const exe = process.argv[2] || 'C:\\Apps\\HermesThin\\current\\Hermes.exe';
const root = path.join(__dirname, 'logs', 'smoke-' + Date.now());
fs.mkdirSync(root, {recursive:true});
const report = {exe, root, httpRequests:[], wsConnections:0, phases:[]};
const server = http.createServer((request,response) => {
  const url = new URL(request.url, 'http://localhost');
  report.httpRequests.push(url.pathname);
  response.setHeader('Content-Type','application/json');
  if (url.pathname === '/api/status') response.end(JSON.stringify({status:'ok',version:'thin-client-test',authenticated:true,auth_required:false}));
  else if(url.pathname === '/api/auth/providers') response.end(JSON.stringify({providers:[]}));
  else if(url.pathname === '/api/health') response.end(JSON.stringify({status:'ok'}));
  else response.end(JSON.stringify({ok:true,profiles:[],sessions:[],providers:[],models:[]}));
});
const wss = new WebSocketServer({server});
wss.on('connection', socket => {
  report.wsConnections++;
  socket.on('message', raw => {
    try {
      const message = JSON.parse(String(raw));
      if (message.id != null) socket.send(JSON.stringify({jsonrpc:'2.0',id:message.id,result:{profiles:[],sessions:[],models:[],providers:[],connected:true}}));
    } catch {}
  });
});
let app;
const env = {...process.env};
for (const key of Object.keys(env)) if (/^(HERMES|PYTHON|VIRTUAL_ENV|CONDA|NODE_OPTIONS|ELECTRON_RUN_AS_NODE)/i.test(key)) delete env[key];
env.PATH = `${env.SystemRoot}\\System32;${env.SystemRoot}`;
env.HERMES_DESKTOP_USER_DATA_DIR = path.join(root,'userdata');
env.HERMES_HOME = path.join(root,'hermes-home');
env.HERMES_DESKTOP_IGNORE_EXISTING = '1';
env.LOCALAPPDATA = path.join(root,'local');
fs.mkdirSync(env.LOCALAPPDATA,{recursive:true});
function noRuntime() {
  for(const base of [env.HERMES_HOME,path.join(env.LOCALAPPDATA,'hermes')]) {
    for(const name of ['hermes-agent','venv','.venv','python','uv','git','node','PortableGit']) {
      assert.equal(fs.existsSync(path.join(base,name)),false,`Unexpected local runtime ${base}/${name}`);
    }
  }
}
async function launch() {
  app = await _electron.launch({executablePath:exe,env,timeout:30000});
  const page = await app.firstWindow();
  await page.waitForFunction(() => Boolean(window.hermesDesktop),null,{timeout:30000});
  return page;
}
async function close() { if(app) { await app.close(); app=null; } }
(async()=>{
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url = `http://127.0.0.1:${server.address().port}`;
  let page = await launch();
  await page.waitForFunction(async()=>Boolean((await window.hermesDesktop.getBootstrapState()).setupChoice),null,{timeout:30000});
  const first = await page.evaluate(()=>window.hermesDesktop.getBootstrapState());
  assert.equal(first.active,false); assert.equal(first.startedAt,null);
  await page.screenshot({path:path.join(root,'first-run.png')});
  report.firstRun = first;
  noRuntime();
  if (process.argv.includes('--slow-first-run')) {
    await page.waitForTimeout(47000);
    report.slowFirstRun = {timedOut:await page.getByText('Timed out connecting to Hermes backend',{exact:false}).count()>0};
  }
  const payload = {mode:'remote',remoteUrl:url,remoteToken:'thin-client-test-not-a-real-secret',remoteAuthMode:'token'};
  report.connectionTest = await page.evaluate(p=>window.hermesDesktop.testConnectionConfig(p),payload);
  assert.equal(report.connectionTest.ok,true);
  await page.evaluate(p=>window.hermesDesktop.applyConnectionConfig(p),payload);
  const remote = await page.evaluate(()=>window.hermesDesktop.getConnection());
  assert.equal(remote.mode,'remote'); assert.equal(remote.baseUrl,url);
  const applied = await page.evaluate(()=>window.hermesDesktop.getBootstrapState());
  assert.equal(applied.active,false); assert.equal(applied.startedAt,null); assert.equal(applied.manifest,null);
  report.applied = {mode:remote.mode,baseUrl:remote.baseUrl,bootstrap:applied};
  if (process.argv.includes('--slow-first-run')) {
    await page.waitForTimeout(2000);
    report.slowFirstRun.afterApplyProgress=await page.evaluate(()=>window.hermesDesktop.getBootProgress());
    report.slowFirstRun.staleFailureVisible=await page.getByText('Timed out connecting to Hermes backend',{exact:false}).count()>0;
    await page.screenshot({path:path.join(root,'slow-apply.png')});
  }
  const versions = await app.evaluate(()=>process.versions);
  report.versions = versions;
  report.paths = await app.evaluate(({app})=>({userData:app.getPath('userData'),exe:app.getPath('exe')}));
  await page.evaluate(()=>localStorage.setItem('thin-client-upgrade-test','preserved'));
  noRuntime();
  await close();
  page = await launch();
  const restored = await page.evaluate(()=>window.hermesDesktop.getConnection());
  assert.equal(restored.mode,'remote'); assert.equal(restored.baseUrl,url);
  assert.equal(await page.evaluate(()=>localStorage.getItem('thin-client-upgrade-test')),'preserved');
  const savedBoot = await page.evaluate(()=>window.hermesDesktop.getBootstrapState());
  assert.equal(savedBoot.active,false); assert.equal(savedBoot.startedAt,null); assert.equal(savedBoot.setupChoice,null);
  report.restarted = {mode:restored.mode,bootstrap:savedBoot,uiSettingPreserved:true};
  report.updater = await page.evaluate(()=>window.hermesDesktop.updates.check());
  assert.equal(report.updater.supported,false);
  assert.equal(report.updater.reason,'not-a-git-checkout');
  noRuntime();
  assert.ok(report.wsConnections>=2,'Real WebSocket handshake missing');
  report.ok = true;
})().catch(error=>{report.ok=false;report.error=error.stack;process.exitCode=1;}).finally(async()=>{
  try { await close(); } catch {}
  for(const socket of wss.clients) socket.terminate();
  wss.close();server.close();
  fs.writeFileSync(path.join(root,'result.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify({ok:report.ok,root,error:report.error,httpRequests:report.httpRequests.length,wsConnections:report.wsConnections},null,2));
});

import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createCatalogServer } from '../src/server.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../public');
const names = { io: 'Io', callisto: 'Callisto', europa: 'Europa', ganymede: 'Ganymede' };
const fixture = () => ({ generatedAt: new Date().toISOString(), token: 'private-secret', bots: Object.entries(names).map(([id,name]) =>
  ({ id,name,version:'1.0',level:8,style:'tempo',activity:'playing',player_id:123,match_id:'private-match',
    rank:{bracket:0,inLegend:false,legendRating:0,lp:34,rating:1000} })) });

test('public bot status proxy projects only four identities and rejects unavailable or malformed data', async t => {
  let mode = 'ok', calls = 0;
  const upstream = http.createServer((req,res) => {
    calls++; assert.equal(req.url, '/data/bots/status.json');
    if (mode === 'timeout') return;
    if (mode === 'redirect') { res.writeHead(302, {Location:'/private'}).end(); return; }
    if (mode === 'status') { res.writeHead(500).end('private diagnostic'); return; }
    if (mode === 'large') { res.end(' '.repeat(32769)); return; }
    const data = fixture();
    if (mode === 'duplicate') data.bots[1] = data.bots[0];
    if (mode === 'human') data.bots[0].name = 'Private Human';
    if (mode === 'unknown') data.bots[0].id = 'someone_else';
    if (mode === 'rank') data.bots[0].rank.bracket = 21;
    if (mode === 'lp') data.bots[0].rank.lp = 100;
    if (mode === 'activity') data.bots[0].activity = 'winning';
    if (mode === 'missing') data.bots.pop();
    if (mode === 'null_rank') data.bots[0].rank = null;
    if (mode === 'not_started') { data.bots[0].activity = 'not_started'; data.bots[0].rank = null; }
    res.end(JSON.stringify(data));
  });
  await new Promise(r=>upstream.listen(0,'127.0.0.1',r));
  const proxy = createCatalogServer(root,{statsOrigin:`http://127.0.0.1:${upstream.address().port}`,statsTimeoutMs:100});
  await new Promise(r=>proxy.listen(0,'127.0.0.1',r));
  t.after(async()=>{ for(const s of [upstream,proxy]) {s.closeAllConnections();await new Promise(r=>s.close(r));} });
  const url = `http://127.0.0.1:${proxy.address().port}/data/bots/status.json`;
  const response = await fetch(url); assert.equal(response.status,200); assert.equal(response.headers.get('cache-control'),'no-store');
  const text = await response.text(), data = JSON.parse(text);
  assert.deepEqual(data.bots.map(b=>b.id),Object.keys(names));
  assert.equal(data.bots[0].rank.lp,34);
  for(const secret of ['token','player_id','match_id','private','rating"']) assert.ok(!text.includes(secret),secret);
  const before = calls;
  assert.equal((await fetch(url+'?username=human')).status,400); assert.equal(calls,before);
  assert.equal((await fetch(url,{method:'POST'})).status,405);
  assert.equal((await fetch(url,{method:'OPTIONS'})).status,204);
  assert.equal(await (await fetch(url,{method:'HEAD'})).text(),'');
  mode='not_started'; assert.equal((await (await fetch(url)).json()).bots[0].rank,null);
  for(mode of ['duplicate','human','unknown','rank','lp','activity','missing','null_rank','status','redirect','large','timeout']) {
    const failed=await fetch(url); assert.equal(failed.status,503,mode);
    assert.deepEqual(await failed.json(),{error:'bot status unavailable'});
  }
  mode='ok'; assert.equal((await fetch(url)).status,200,'failure never poisons recovery');
});

'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs/promises');
const os=require('node:os');
const path=require('node:path');
const {parseArgs,runBalance}=require('../second_player_balance');
const {validateDeck,loadCards}=require('../authoritative/decks');
const cards=loadCards();

test('balance options reject invalid bounds and require an explicit report destination',()=>{
  for(const args of [[],['--output=x','--level=0'],['--output=x','--pairs=0'],['--output=x','--pairs=251'],
    ['--output=x','--seed=-1'],['--output=x','--level=5','--level=6'],['--output=x','--unknown=1']]) assert.throws(()=>parseArgs(args));
});

test('actual opening experiment preserves rules in search copies, runs a paired block and reports caps as failures',{
  skip:!process.env.GODOT_BIN?'requires GODOT_BIN':false,timeout:180000,
},async t=>{
  const dir=await fs.mkdtemp(path.join(os.tmpdir(),'cardgame-opening-proof-'));
  t.after(async()=>{
    assert.equal(path.dirname(dir),path.resolve(os.tmpdir()));assert.ok(path.basename(dir).startsWith('cardgame-opening-proof-'));
    await fs.rm(dir,{recursive:true,force:true});
  });
  const options=(file,extra=[])=>parseArgs(['--pairs=1','--level=1',`--output=${path.join(dir,file)}`,...extra]);
  const run=cfg=>runBalance(cfg,{signal:t.signal,log:()=>{}});
  const checked=await run(options('checks.json',['--checks-only']));
  assert.deepEqual(checked.failures,[]);assert.ok(checked.checks>0);assert.equal(checked.requestedGames,0);
  const report=await run(options('games.json'));
  assert.equal(report.games.length,4);assert.equal(report.blocks.length,1);assert.deepEqual(report.failures,[]);
  const first=report.games[0];
  for(const game of report.games){
    assert.equal(game.completed,true);assert.ok(game.actions>0);assert.ok(game.turns>0);
    assert.deepEqual(game.deckA,first.deckA);assert.deepEqual(game.deckB,first.deckB);assert.equal(game.seed,first.seed);
    assert.equal(validateDeck(game.deckA,game.factionA,cards).ok,true);assert.equal(game.deckA.length,40);
    assert.equal(validateDeck(game.deckB,game.factionB,cards).ok,true);assert.equal(game.deckB.length,40);
    assert.deepEqual(game.openingHands,{first:3,second:game.condition==='baseline'?4:3});
  }
  for(const condition of ['baseline','experiment']){
    assert.deepEqual(report.games.filter(g=>g.condition===condition).map(g=>g.first),['host','guest']);
    const sum=report.summary[condition];assert.equal(sum.completed,2);assert.equal(sum.firstWins+sum.secondWins+sum.draws,2);
  }
  await assert.rejects(run(options('capped.json',['--max-actions=1'])),/experiment failed/);
  const partial=JSON.parse(await fs.readFile(path.join(dir,'capped.json'),'utf8'));
  assert.equal(partial.games[0].completed,false);assert.ok(partial.failures.includes('game_cap'));
  assert.ok(Object.values(partial.summary).every(s=>s.completed===0&&s.draws===0));
  await assert.rejects(run(options('games.json')),/Output already exists/);
});

import test from 'node:test';
import assert from 'node:assert/strict';
import { BOT_NAMES, validStatus, rankDisplay } from '../bots-core.mjs';

test('bot page displays visible divisions, LP and all three Legend bands',()=>{
  assert.deepEqual(rankDisplay({bracket:0,inLegend:false,legendRating:0,lp:34}),
    {name:'Orbital III',progress:'34 / 100 LP',icon:'01-orbital'});
  assert.equal(rankDisplay({bracket:20,inLegend:false,legendRating:0,lp:99}).name,'Cosmic I');
  for(const [rating,name,icon] of [[0,'Superluminal','08-superluminal'],[499,'Superluminal','08-superluminal'],
    [500,'Celestial','09-celestial'],[999,'Celestial','09-celestial'],[1000,'Universal','10-universal']]) {
    const rank=rankDisplay({bracket:20,inLegend:true,legendRating:rating,lp:0});
    assert.equal(rank.name,name);assert.equal(rank.icon,icon);
  }
  assert.equal(rankDisplay(null).name,'Not ranked yet');
});
test('bot page refuses missing identities and invented activity or rank',()=>{
  const data={generatedAt:new Date().toISOString(),bots:Object.entries(BOT_NAMES).map(([id,name])=>
    ({id,name,version:'1.0',level:8,style:'tempo',activity:'not_started',rank:null}))};
  assert.ok(validStatus(data));
  for(const mutate of [d=>d.bots.pop(),d=>{d.bots[1]=d.bots[0];},d=>{d.bots[0].activity='thinking_about_secrets';},
    d=>{d.bots[0].name='Someone else';},d=>{d.generatedAt='yesterday';},
    d=>{d.bots[0].activity='playing';}]) {
    const bad=structuredClone(data);mutate(bad);assert.equal(validStatus(bad),false);
  }
});

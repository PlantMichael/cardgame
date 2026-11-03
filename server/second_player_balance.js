'use strict';
const { spawn } = require('node:child_process');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { killTree } = require('./bot_worker');
const ROOT = path.resolve(__dirname, '..');

function parseArgs(args) {
  const config = { pairs:25, level:5, seed:42, maxActions:1000, checksOnly:false };
  const seen = new Set();
  for (const arg of args) {
    const match = /^--(pairs|level|seed|max-actions|output)=(.+)$/.exec(arg);
    const key = match?.[1] ?? (arg === '--checks-only' ? 'checks-only' : null);
    if (!key || seen.has(key)) throw new Error('Unknown or duplicate balance option');
    seen.add(key);
    if (key === 'checks-only') config.checksOnly = true;
    else if (key === 'output') config.output = path.resolve(match[2]);
    else {
      if (!/^\d+$/.test(match[2])) throw new Error(`Invalid ${key}`);
      config[key === 'max-actions' ? 'maxActions' : key] = Number(match[2]);
    }
  }
  for (const [key,min,max] of [['pairs',1,250],['level',1,10],['seed',0,2147483000],['maxActions',1,10000]]) {
    if (!Number.isSafeInteger(config[key]) || config[key] < min || config[key] > max) throw new Error(`Invalid ${key}`);
  }
  if (!config.output) throw new Error('--output=PATH is required');
  return config;
}

async function runBalance(config, { godotBin = process.env.GODOT_BIN, signal = new AbortController().signal, log = console.log } = {}) {
  if (!godotBin) throw new Error('GODOT_BIN is required');
  if (typeof config.output!=='string' || !config.output.trim()) throw new Error('--output=PATH is required');
  // Reuse the public parser's bounds for programmatic callers too.
  config = parseArgs([`--pairs=${config.pairs}`,`--level=${config.level}`,`--seed=${config.seed}`,
    `--max-actions=${config.maxActions}`,`--output=${config.output}`,...(config.checksOnly ? ['--checks-only'] : [])]);
  try { await fs.access(config.output); throw new Error('Output already exists; choose a new filename'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  const directory = await fs.mkdtemp(path.join(os.tmpdir(),'cardgame-opening-balance-'));
  const resultPath = path.join(directory,'result.json');
  let child, timer, aborted = signal.aborted;
  const stop = () => { aborted = true; killTree(child); };
  signal.addEventListener('abort',stop,{once:true});
  try {
    let diagnostic = '', lines = '';
    const code = await new Promise((resolve,reject) => {
      child = spawn(godotBin,['--headless','--path',ROOT,'res://server/test/fixtures/second_player_balance.tscn','--',
        `--balance-pairs=${config.pairs}`,`--balance-level=${config.level}`,`--balance-seed=${config.seed}`,
        `--balance-max-actions=${config.maxActions}`,`--balance-output=${resultPath}`,...(config.checksOnly ? ['--balance-checks-only'] : [])],
      {env:{...process.env,APPDATA:directory,XDG_DATA_HOME:directory,DATABASE_URL:'',RANKED_BOT_SESSIONS:''},windowsHide:true,stdio:['ignore','pipe','pipe']});
      timer = setTimeout(stop,config.checksOnly ? 60000 : config.pairs*4*600000+60000);
      child.stdout.on('data',data => {
        diagnostic = (diagnostic+data).slice(-8192); lines += data;
        let newline;
        while ((newline=lines.indexOf('\n'))>=0) {
          const line=lines.slice(0,newline).trim(); lines=lines.slice(newline+1);
          if (line.startsWith('BALANCE_PROGRESS ')) log(line);
        }
        if (lines.length>8192) lines=lines.slice(-8192);
      });
      child.stderr.on('data',data => {
        diagnostic=(diagnostic+data).slice(-8192);
        if (/SCRIPT ERROR|Parse Error/.test(diagnostic)) killTree(child);
      });
      child.once('error',reject); child.once('close',resolve);
      if (aborted) stop();
    });
    if (aborted) throw new Error('Balance experiment stopped; incomplete games are not results');
    let report;
    try { report=JSON.parse(await fs.readFile(resultPath,'utf8')); }
    catch { throw new Error(`Balance process failed (${code}): ${diagnostic}`); }
    const completed=Object.values(report.summary).reduce((n,s)=>n+s.completed,0);
    report.completedSuccessfully=code===0 && !report.failures.length && !/SCRIPT ERROR|Parse Error/.test(diagnostic) &&
      completed===report.requestedGames && report.games.length===report.requestedGames;
    await fs.mkdir(path.dirname(config.output),{recursive:true});
    await fs.writeFile(config.output,JSON.stringify(report,null,2)+'\n',{flag:'wx'});
    if (code!==0 || report.failures.length || /SCRIPT ERROR|Parse Error/.test(diagnostic)) throw new Error(`Balance experiment failed; partial report: ${config.output}\n${diagnostic}`);
    if (completed!==report.requestedGames || report.games.length!==report.requestedGames) throw new Error('Incomplete balance sample');
    return report;
  } finally {
    clearTimeout(timer); signal.removeEventListener('abort',stop); killTree(child);
    if (path.dirname(directory)!==path.resolve(os.tmpdir()) || !path.basename(directory).startsWith('cardgame-opening-balance-')) throw new Error('Unsafe harness cleanup path');
    await fs.rm(directory,{recursive:true,force:true});
  }
}

module.exports={parseArgs,runBalance};
if (require.main===module) {
  const controller=new AbortController();
  process.once('SIGINT',()=>controller.abort()); process.once('SIGTERM',()=>controller.abort());
  Promise.resolve().then(()=>runBalance(parseArgs(process.argv.slice(2)),{signal:controller.signal}))
    .then(report=>console.log(JSON.stringify({checks:report.checks,requestedGames:report.requestedGames,summary:report.summary})))
    .catch(error=>{console.error(error.message);process.exitCode=1;});
}

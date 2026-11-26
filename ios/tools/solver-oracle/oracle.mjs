// The challenge solver bundle in Node (V8, Android's engine): reads player.js from the fixture
// directory, solves fixed n and sig challenges with jsc(), and writes expected.json for
// ChallengeSolverTests to compare JavaScriptCore against. Usage: node oracle.mjs <bundle dir> <fixture dir>
import fs from 'node:fs';
import vm from 'node:vm';
import path from 'node:path';

const [bundle, fixtures] = process.argv.slice(2);
const sandbox = {};
vm.createContext(sandbox);
for (const name of ['polyfill.js', 'meriyah-6.1.4.min.js', 'astring-1.9.0.min.js', 'yt.solver.core.js']) {
  vm.runInContext(fs.readFileSync(path.join(bundle, name), 'utf8'), sandbox, { filename: name });
}
// Deterministic challenge strings shaped like YouTube's (n: 16 chars; s: 104 chars of the URL-safe alphabet).
const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
let seed = 20261125;
// xorshift32, kept in 32 bits (a multiplying LCG overflows a double's 53 bits).
const next = () => { seed ^= seed << 13; seed >>>= 0; seed ^= seed >>> 17; seed ^= seed << 5; seed >>>= 0; return seed; };
const make = (length) => Array.from({ length }, () => alphabet[next() % alphabet.length]).join('');
const n = Array.from({ length: 6 }, () => make(16));
const sig = Array.from({ length: 4 }, () => make(104));
const player = fs.readFileSync(path.join(fixtures, 'player.js'), 'utf8');
sandbox.__input = { type: 'player', player, requests: [{ type: 'n', challenges: n }, { type: 'sig', challenges: sig }] };
const started = Date.now();
const output = JSON.parse(vm.runInContext('JSON.stringify(jsc(__input))', sandbox));
const ms = Date.now() - started;
if (output.type !== 'result') throw new Error('solver error: ' + JSON.stringify(output).slice(0, 500));
const [nOut, sigOut] = output.responses;
if (nOut.type !== 'result' || sigOut.type !== 'result') throw new Error('request failed: ' + JSON.stringify(output.responses).slice(0, 500));
fs.writeFileSync(path.join(fixtures, 'expected.json'), JSON.stringify({ engine: 'node ' + process.version, ms, n: nOut.data, sig: sigOut.data }, null, 2));
console.log(`node solved ${Object.keys(nOut.data).length} n and ${Object.keys(sigOut.data).length} sig in ${ms} ms`);

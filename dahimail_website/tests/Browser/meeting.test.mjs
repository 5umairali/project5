import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
const source = readFileSync(new URL('../../public/js/meeting.js', import.meta.url), 'utf8')
  .replace('  bind();\n  initPre();', '  window.mediaTest = { acquire: acquire, showEnd: showEnd, leave: leave, poll: poll, endForAll: endForAll, queueSignal: queueSignal };');
const flush = () => new Promise(resolve => setImmediate(resolve));
function room(search, recordingDone = Promise.resolve(), mediaDevices, fetch = async () => ({ status: 200, json: async () => ({}) })) {
  const elements = new Map(), redirects = [], events = new Map();
  const element = id => {
    if (!elements.has(id)) elements.set(id, { classList: { toggle() {} }, appendChild() {}, style: {},
      getAttribute: key => ({ 'data-code': 'test', 'data-kind': 'call', 'data-user': 'null' })[key] });
    return elements.get(id);
  };
  class Stream { getTracks() { return []; } addTrack() {} }
  const window = { addEventListener(name, fn) { events.set(name, fn); }, DahiRec: { init() {}, stop: () => recordingDone } };
  const document = { getElementById: element, addEventListener() {}, querySelector: element, createElement: element };
  const location = { origin: 'https://mail.example', search, assign: url => redirects.push(url) };
  vm.runInNewContext(source, { window, document, navigator: { mediaDevices }, location, MediaStream: Stream,
    fetch, URL, URLSearchParams, Promise, Date, Set, clearTimeout() {}, setInterval() {}, clearInterval() {}, setTimeout() {} });
  return { api: window.mediaTest, state: window.__meeting.S, events, redirects, elements };
}
test('ending a call waits for recording delivery and returns to the exact source thread', async () => {
  let deliver;
  const done = new Promise(resolve => { deliver = resolve; });
  const r = room('?return_to=' + encodeURIComponent('/friends/chat/42?tab=media#latest'), done);
  r.api.showEnd('Ended', false);
  await flush();
  assert.equal(r.redirects.length, 0);
  deliver();
  await flush();
  assert.deepEqual(r.redirects, ['/friends/chat/42?tab=media#latest']);
});
test('return destination cannot redirect to an external origin', async () => {
  const r = room('?return_to=' + encodeURIComponent('https://untrusted.example/friends/chat/42'));
  r.api.showEnd('Ended', false);
  await flush();
  assert.deepEqual(r.redirects, ['/friends']);
});
test('audio calls never ask for a camera, including microphone failure fallback', async () => {
  const constraints = [];
  const r = room('?audio=1', Promise.resolve(), {
    getUserMedia: async c => { constraints.push(c); throw new Error('Microphone denied'); },
    enumerateDevices: async () => [],
  });
  await r.api.acquire();
  assert.equal(constraints.some(c => c.video && c.video !== false), false);
  assert.match(r.elements.get('mt-pre-msg').textContent, /permissions/);
});

test('hangup stops locally before acknowledgement, and navigation waits for delivery', async () => {
  let deliver; const requests = [];
  const r = room('', Promise.resolve(), null, (url, options) => {
    requests.push({ url, options });
    return new Promise(resolve => { deliver = resolve; });
  });
  r.state.pid = 7; r.state.status = 'joined';
  r.api.leave(); await flush();
  assert.equal(r.state.status, 'idle');
  assert.equal(r.redirects.length, 0);
  assert.equal(requests[0].options.keepalive, true);
  r.events.get('dahi:sync')({ detail: { type: 'meeting_ended', code: 'test' } });
  await flush(); assert.equal(r.redirects.length, 0);
  deliver({ status: 200, json: async () => ({}) }); await flush();
  assert.ok(r.redirects.every(url => url === '/friends')); assert.ok(r.redirects.length > 0);
});

test('a stale poll cannot restore state after a terminal socket event', async () => {
  let respond;
  const r = room('', Promise.resolve(), null, () => new Promise(resolve => { respond = resolve; }));
  r.state.pid = 7; r.state.status = 'joined'; r.api.poll();
  r.events.get('dahi:sync')({ detail: { type: 'meeting_ended', code: 'test' } });
  respond({ status: 200, json: async () => ({ data: { meeting: { title: 'stale' }, me: { status: 'joined' } } }) });
  await flush();
  assert.equal(r.state.status, 'idle'); assert.equal(r.state.meeting, null);
});

test('socket invalidation during a poll schedules an immediate follow-up', async () => {
  const responses = [];
  const r = room('', Promise.resolve(), null, () => new Promise(resolve => responses.push(resolve)));
  r.state.pid = 7; r.state.status = 'waiting'; r.api.poll();
  r.events.get('dahi:sync')({ detail: { type: 'meeting_changed', code: 'test' } });
  assert.equal(responses.length, 1);
  responses[0]({ status: 200, json: async () => ({ data: { me: { status: 'waiting' } } }) });
  await flush(); assert.equal(responses.length, 2);
});

test('host end releases media immediately while the server response is pending', async () => {
  const r = room('', Promise.resolve(), null, () => new Promise(() => {}));
  r.state.pid = 7; r.state.status = 'joined';
  let stopped = 0; r.state.local = { getTracks: () => [{ stop: () => stopped++ }] };
  r.api.endForAll();
  assert.equal(stopped, 1); assert.equal(r.state.status, 'idle');
  await flush(); assert.equal(r.redirects.length, 0);
});

test('socket ICE is consumed without a REST round trip and replay is deduplicated', async () => {
  let polls = 0, candidates = 0;
  const r = room('', Promise.resolve(), null, async () => { polls++; return { status: 200, json: async () => ({}) }; });
  r.state.pid = 7; r.state.status = 'joined'; r.state.parts = [{ pid: 8 }];
  r.state.peers[8] = { remoteSet: true, pc: { addIceCandidate: async () => { candidates++; } } };
  const signal = { id: 12, from: 8, type: 'ice', payload: '{"candidate":"test"}' };
  r.events.get('dahi:sync')({ detail: { type: 'meeting_signal', code: 'test', to: 7, signal } });
  await flush(); r.api.queueSignal(signal); await flush();
  assert.equal(candidates, 1); assert.equal(polls, 0); assert.equal(r.state.sigLast, 0);
});

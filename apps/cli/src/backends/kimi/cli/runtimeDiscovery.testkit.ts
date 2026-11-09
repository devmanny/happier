import { chmodSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { writeAcpTestAgentScript } from '@/agent/acp/testkit/subprocessHarness';

/** Vendor process boundary fixture; Happier discovery and ACP logic remain real. */
export function writeKimiFixture(dir: string, kind: 'current' | 'legacy' | 'malformed', options?: { autonomousTurns?: boolean; thinkingEfforts?: boolean }): string {
  const initialize = JSON.parse(readFileSync(fileURLToPath(new URL(`./__fixtures__/${kind}.initialize.ndjson`, import.meta.url)), 'utf8')).result;
  if (options?.autonomousTurns) initialize.agentCapabilities = { ...initialize.agentCapabilities, _meta: { 'kimi/autonomous-turns': true } };
  const path = writeAcpTestAgentScript({ dir, fileName: 'kimi', source: `#!${process.execPath}
const { createInterface } = require('node:readline');
const { appendFileSync } = require('node:fs');
const initialize = ${JSON.stringify(initialize)};
let autonomousTurns = false;
// Kimi Code's acp-server shape: a thinking model's effort is the \`thinking\` select (category thought_level).
let thinking = ${options?.thinkingEfforts ? "'high'" : 'null'};
const configOptions = () => [
  { id: 'mode', name: 'Mode', category: 'mode', type: 'select', currentValue: 'default', options: [{ value: 'auto', name: 'Auto' }] },
  { id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: 'kimi-for-coding', options: [{ value: 'kimi-for-coding', name: 'Kimi for Coding' }] },
  ...(thinking === null ? [] : [{ id: 'thinking', name: 'Thinking', category: 'thought_level', type: 'select', currentValue: thinking,
    options: ['low', 'high', 'max'].map(value => ({ value, name: 'Thinking ' + value.charAt(0).toUpperCase() + value.slice(1) })) }]),
];
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
const record = ${JSON.stringify(join(dir, 'requests.ndjson'))};
createInterface({ input: process.stdin }).on('line', (line) => {
  const request = JSON.parse(line);
  appendFileSync(record, JSON.stringify({ method: request.method, params: request.params, cwd: process.cwd(), args: process.argv.slice(2) }) + '\\n');
  if (request.id === undefined) return;
  let result = {};
  if (request.method === 'initialize') { result = initialize; autonomousTurns = request.params.clientCapabilities?._meta?.['kimi/autonomous-turns'] === true; }
  if (request.method === '_test/autonomous-turn' && autonomousTurns) {
    const emit = (event, fields = {}) => send({ jsonrpc: '2.0', method: '_kimi/autonomous_turn', params: { sessionId: 'kimi-fixture-session', turnId: 17, event, ...fields } });
    emit('started');
    emit('update', { update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'factory background result' } } });
    emit('ended', { stopReason: 'end_turn' });
  }
  if (['session/new', 'session/load', 'session/fork'].includes(request.method)) result = {
    sessionId: request.method === 'session/fork' ? 'kimi-fixture-fork' : request.params.sessionId || 'kimi-fixture-session',
    modes: { currentModeId: 'default', availableModes: [{ id: 'default', name: 'Default' }, { id: 'auto', name: 'Auto' }] },
    configOptions: configOptions(),
  };
  if (request.method === 'session/set_config_option' && thinking !== null) {
    // Kimi rejects config ids it does not advertise.
    if (request.params.configId !== 'thinking') {
      process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, error: { code: -32602, message: 'Unknown config option: ' + request.params.configId } }) + '\\n');
      return;
    }
    thinking = request.params.value;
    result = { configOptions: configOptions() };
  }
  if (request.method === 'session/prompt') result = { stopReason: 'end_turn' };
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: request.id, result }) + '\\n');
});
` });
  chmodSync(path, 0o755);
  return path;
}

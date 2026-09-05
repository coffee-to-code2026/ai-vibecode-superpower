import assert from 'node:assert/strict';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { promisify } from 'node:util';

const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const opencodeDriver = path.join(repository, 'opencode-global-config', 'skills', 'agent-toolchain', 'scripts', 'agent-toolchain.sh');
const run = promisify(execFile);

async function runResult(command, args, options) {
  try {
    const result = await run(command, args, { windowsHide: true, maxBuffer: 8 * 1024 * 1024, env: { ...process.env, PYTHONIOENCODING: 'utf-8' }, ...options });
    return { code: 0, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
  } catch (error) {
    return { code: typeof error.code === 'number' ? error.code : 1, stdout: error.stdout ?? '', stderr: error.stderr ?? '', error };
  }
}

async function assertOpenCodeCodegraphJson(config, project) {
  const parsed = JSON.parse(await readFile(config, 'utf8'));
  const server = parsed.mcp?.codegraph;
  assert.ok(server, 'mcp.codegraph missing');
  assert.equal(server.type, 'local');
  assert.deepEqual(server.command, ['codegraph', 'serve', '--mcp']);
  assert.equal(server.enabled, true);
  assert.equal(server.environment?.CODEGRAPH_TELEMETRY, '0');
  assert.equal(server.environment?.CODEGRAPH_NO_UPDATE_CHECK, '1');
  assert.equal(server.environment?.DO_NOT_TRACK, '1');
  assert.match(await readFile(path.join(project, 'AGENTS.md'), 'utf8'), /## CodeGraph 与 RTK/);
  assert.match(await readFile(path.join(project, '.gitignore'), 'utf8'), /^\/\.codegraph\/$/m);
}

test('opencode driver configure wires opencode.json and stays idempotent (POSIX)', { skip: process.platform === 'win32' }, async (t) => {
  const root = await mkdtemp(path.join(repository, '.oc-atc-config-'));
  const project = path.join(root, 'project');
  try {
    await mkdir(project, { recursive: true });
    const first = await runResult('sh', [opencodeDriver, 'configure', '--project', project, '--config', 'opencode'], {});
    assert.equal(first.code, 0, `${first.stdout}\n${first.stderr}`);
    await assertOpenCodeCodegraphJson(path.join(project, 'opencode.json'), project);
    const snapshot = await readFile(path.join(project, 'opencode.json'), 'utf8');
    const second = await runResult('sh', [opencodeDriver, 'configure', '--project', project, '--config', 'opencode'], {});
    assert.equal(second.code, 0, `${second.stdout}\n${second.stderr}`);
    assert.equal(await readFile(path.join(project, 'opencode.json'), 'utf8'), snapshot);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('opencode driver configure preserves unrelated json keys while merging the codegraph block (POSIX)', { skip: process.platform === 'win32' }, async (t) => {
  const root = await mkdtemp(path.join(repository, '.oc-atc-merge-'));
  const project = path.join(root, 'project');
  try {
    await mkdir(project, { recursive: true });
    await writeFile(path.join(project, 'opencode.json'), '{"model": "merge-ai/deepseek-v4-flash", "clean": true}\n');
    const result = await runResult('sh', [opencodeDriver, 'configure', '--project', project, '--config', 'opencode'], {});
    assert.equal(result.code, 0, `${result.stdout}\n${result.stderr}`);
    const parsed = JSON.parse(await readFile(path.join(project, 'opencode.json'), 'utf8'));
    assert.equal(parsed.model, 'merge-ai/deepseek-v4-flash');
    assert.equal(parsed.clean, true);
    assert.ok(parsed.mcp?.codegraph, 'mcp.codegraph missing after merge');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('opencode driver configure refuses a conflicting codegraph block (POSIX)', { skip: process.platform === 'win32' }, async (t) => {
  const root = await mkdtemp(path.join(repository, '.oc-atc-conflict-'));
  const project = path.join(root, 'project');
  try {
    await mkdir(project, { recursive: true });
    await writeFile(path.join(project, 'opencode.json'), '{"mcp": {"codegraph": {"type": "remote", "url": "http://evil"}}}\n');
    const result = await runResult('sh', [opencodeDriver, 'configure', '--project', project, '--config', 'opencode'], {});
    assert.notEqual(result.code, 0, result.stdout);
    assert.match(result.stdout + '\n' + result.stderr, /存在非受管的 codegraph 配置/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('opencode driver reports usage and rejects unknown config targets (POSIX)', { skip: process.platform === 'win32' }, async (t) => {
  const root = await mkdtemp(path.join(repository, '.oc-atc-usage-'));
  const project = path.join(root, 'project');
  try {
    const result = await runResult('sh', [opencodeDriver, 'configure', '--project', project, '--config', 'bogus'], {});
    assert.notEqual(result.code, 0, result.stdout);
    assert.match(result.stdout + '\n' + result.stderr, /--config 仅支持 opencode/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
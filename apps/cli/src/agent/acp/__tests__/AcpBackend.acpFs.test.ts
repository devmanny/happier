import { describe, expect, it, afterEach } from 'vitest';

import { writeFileSync, readFileSync, existsSync, mkdirSync, symlinkSync } from 'node:fs';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

import { AcpBackend, buildInitializeRequest, createAcpClientFsMethods } from '../AcpBackend';
import type { AcpPermissionHandler } from '../AcpBackend';
import { writeAcpTestAgentScript } from '../testkit/subprocessHarness';
import { createEnvKeyScope } from '@/testkit/env/envScope';
import { withTempDir } from '@/testkit/fs/tempDir';

const envScope = createEnvKeyScope(['HAPPIER_ACP_FS', 'HAPPIER_MACHINE_RPC_WORKING_DIRECTORY']);

describe('AcpBackend ACP FS capability experiment', () => {
  afterEach(() => {
    envScope.restore();
  });

  it('exposes buildInitializeRequest to allow ACP capabilities to be unit-tested', () => {
    expect(typeof buildInitializeRequest).toBe('function');
  });

  it('advertises fs.readTextFile/fs.writeTextFile when HAPPIER_ACP_FS is enabled', () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    const req = buildInitializeRequest({ clientName: 'test', clientVersion: '0.0.0' });
    expect(req.clientCapabilities?.fs?.readTextFile).toBe(true);
    expect(req.clientCapabilities?.fs?.writeTextFile).toBe(true);
  });

  it('advertises ACP fs capabilities by default', () => {
    envScope.patch({ HAPPIER_ACP_FS: undefined });

    const req = buildInitializeRequest({ clientName: 'test', clientVersion: '0.0.0' });
    expect(req.clientCapabilities?.fs?.readTextFile).toBe(true);
    expect(req.clientCapabilities?.fs?.writeTextFile).toBe(true);
  });

  it('advertises the SDK plan lifecycle capability only when its canonical publisher is active', () => {
    const withoutPublisher = buildInitializeRequest({
      clientName: 'test',
      clientVersion: '0.0.0',
      planUpdates: false,
    });
    const withPublisher = buildInitializeRequest({
      clientName: 'test',
      clientVersion: '0.0.0',
      planUpdates: true,
    });
    expect(withoutPublisher.clientCapabilities?.plan).toBeUndefined();
    expect(withPublisher.clientCapabilities?.plan).toEqual({});
  });

  it('writeTextFile is permission-gated when ACP fs is enabled', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-', async (workspace) => {
      const targetPath = join(workspace, 'a.txt');
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
        permissionHandler: {
          async handleToolCall() {
            return { decision: 'denied' };
          },
        } satisfies AcpPermissionHandler,
      });

      await expect(
        clientFs.writeTextFile!({ sessionId: 's', path: targetPath, content: 'hi' })
      ).rejects.toThrow(/denied/i);

      expect(existsSync(targetPath)).toBe(false);
    });
  });

  it('readTextFile reads file content when ACP fs is enabled', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-', async (workspace) => {
      const targetPath = join(workspace, 'b.txt');
      writeFileSync(targetPath, 'line1\nline2\nline3\n', 'utf8');
      const clientFs = createAcpClientFsMethods({ cwd: workspace });

      const res = await clientFs.readTextFile!({ sessionId: 's', path: targetPath, line: 2, limit: 1 });
      expect(res.content).toBe('line2');
      expect(readFileSync(targetPath, 'utf8')).toContain('line3');
    });
  });

  it('uses OS-user access by default for files outside cwd and still checks write approval', async () => {
    envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: undefined });

    await withTempDir('happier-acp-fs-', async (root) => {
      const workspace = join(root, 'workspace');
      const plan = join(root, 'session', 'plans', 'active.md');
      mkdirSync(workspace);
      mkdirSync(join(root, 'session', 'plans'), { recursive: true });
      writeFileSync(plan, 'original', 'utf8');
      let approved = false;
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
        permissionHandler: {
          async handleToolCall() {
            return { decision: approved ? 'approved' : 'denied' };
          },
        },
      });

      await expect(clientFs.readTextFile!({ sessionId: 's', path: plan })).resolves.toEqual({ content: 'original' });
      const newFile = join(root, 'session', 'new-directory', 'new.md');
      await expect(clientFs.writeTextFile!({ sessionId: 's', path: newFile, content: 'updated' })).rejects.toThrow(/denied/i);
      expect(existsSync(join(root, 'session', 'new-directory'))).toBe(false);

      approved = true;
      await clientFs.writeTextFile!({ sessionId: 's', path: newFile, content: 'updated' });
      expect(readFileSync(newFile, 'utf8')).toBe('updated');
      await expect(clientFs.readTextFile!({ sessionId: 's', path: '../session/new-directory/new.md' }))
        .resolves.toEqual({ content: 'updated' });
    });
  });

  it('honors configured roots without changing cwd as the base for relative paths', async () => {
    await withTempDir('happier-acp-fs-', async (root) => {
      const firstRoot = join(root, 'first');
      const workspace = join(root, 'workspace');
      const outside = join(root, 'outside.md');
      mkdirSync(firstRoot);
      mkdirSync(workspace);
      writeFileSync(join(firstRoot, 'same.md'), 'first root', 'utf8');
      writeFileSync(join(workspace, 'same.md'), 'workspace', 'utf8');
      writeFileSync(outside, 'outside', 'utf8');
      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: `${firstRoot},${workspace}` });
      const clientFs = createAcpClientFsMethods({ cwd: workspace });

      await expect(clientFs.readTextFile!({ sessionId: 's', path: 'same.md' })).resolves.toEqual({ content: 'workspace' });
      await expect(clientFs.readTextFile!({ sessionId: 's', path: join(firstRoot, 'same.md') }))
        .resolves.toEqual({ content: 'first root' });
      await expect(clientFs.readTextFile!({ sessionId: 's', path: outside })).rejects.toThrow(/denied/i);
    });
  });

  it('fails closed for an invalid configured filesystem policy', async () => {
    envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: 'relative/root' });
    await withTempDir('happier-acp-fs-', async (workspace) => {
      expect(() => createAcpClientFsMethods({ cwd: workspace })).toThrow(/absolute directories/i);
    });
  });

  it.each([
    { policy: 'OS-user', restricted: false, approved: true },
    { policy: 'restricted roots', restricted: true, approved: true },
    { policy: 'write denied', restricted: false, approved: false },
  ])('enforces $policy through the spawned ACP process', async ({ restricted, approved }) => {
    await withTempDir('happier-acp-fs-process-', async (root) => {
      const workspace = join(root, 'workspace');
      const plan = join(root, 'session', 'plans', 'active.md');
      const missing = join(root, 'session', 'plans', 'missing.md');
      const newFile = join(root, 'session', 'new-directory', 'new.md');
      const resultFile = join(root, 'responses.json');
      mkdirSync(workspace);
      mkdirSync(join(root, 'session', 'plans'), { recursive: true });
      writeFileSync(plan, 'existing plan', 'utf8');
      envScope.patch({
        HAPPIER_ACP_FS: '1',
        HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: restricted ? workspace : undefined,
      });
      const sdkUrl = pathToFileURL(createRequire(import.meta.url).resolve('@agentclientprotocol/sdk')).href;
      const scriptPath = writeAcpTestAgentScript({
        dir: root,
        fileName: 'filesystem-agent.mjs',
        source: `
          import { agent, ndJsonStream } from ${JSON.stringify(sdkUrl)};
          import { Readable, Writable } from 'node:stream';
          import { writeFile } from 'node:fs/promises';
          const app = agent({ name: 'filesystem-process-contract' })
            .onRequest('initialize', () => ({ protocolVersion: 1, agentCapabilities: {}, authMethods: [] }))
            .onRequest('session/new', () => ({ sessionId: 'filesystem-session' }))
            .onRequest('session/prompt', async (context) => {
              const responses = [];
              const requests = [
                ['fs/read_text_file', { path: ${JSON.stringify(plan)} }],
                ['fs/read_text_file', { path: ${JSON.stringify(missing)} }],
                ['fs/write_text_file', { path: ${JSON.stringify(newFile)}, content: 'new plan' }],
              ];
              for (const [method, params] of requests) {
                try {
                  const result = await context.client.request(method, { sessionId: 'filesystem-session', ...params });
                  responses.push({ result });
                } catch (error) {
                  responses.push({ error: { code: error.code, message: error.message, data: error.data } });
                }
              }
              await writeFile(${JSON.stringify(resultFile)}, JSON.stringify(responses));
              return { stopReason: 'end_turn' };
            });
          const connection = app.connect(ndJsonStream(Writable.toWeb(process.stdout), Readable.toWeb(process.stdin)));
          await connection.closed;
        `,
      });
      const backend = new AcpBackend({
        agentName: 'filesystem-process-contract',
        cwd: workspace,
        command: process.execPath,
        args: [scriptPath],
        // A provider's environment cannot relax the host's restricted roots.
        env: { HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: '' },
        permissionHandler: { async handleToolCall() { return { decision: approved ? 'approved' : 'denied' }; } },
      });
      try {
        const { sessionId } = await backend.startSession();
        await backend.sendPrompt(sessionId, 'exercise filesystem');
        await backend.waitForResponseComplete();
        const responses: unknown = JSON.parse(readFileSync(resultFile, 'utf8'));
        if (restricted) {
          expect(responses).toEqual([
            expect.objectContaining({ error: expect.objectContaining({ code: -32603, data: { code: 'EACCES', path: plan } }) }),
            expect.objectContaining({ error: expect.objectContaining({ code: -32603, data: { code: 'EACCES', path: missing } }) }),
            expect.objectContaining({ error: expect.objectContaining({ code: -32603, data: { code: 'EACCES', path: newFile } }) }),
          ]);
        } else {
          expect(responses).toEqual([
            { result: { content: 'existing plan' } },
            { error: expect.objectContaining({ code: -32002 }) },
            approved ? { result: {} } : { error: expect.objectContaining({ data: { code: 'EACCES', path: newFile } }) },
          ]);
        }
        expect(existsSync(join(root, 'session', 'new-directory'))).toBe(!restricted && approved);
        if (!restricted && approved) expect(readFileSync(newFile, 'utf8')).toBe('new plan');
        expect(readFileSync(plan, 'utf8')).toBe('existing plan');
      } finally {
        await backend.dispose();
      }
    });
  });

  it('reports missing files under a symlinked cwd as ACP resource-not-found', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-root-', async (root) => {
      const workspaceReal = join(root, 'workspace-real');
      const workspaceLink = join(root, 'workspace-link');
      mkdirSync(workspaceReal, { recursive: true });
      symlinkSync(workspaceReal, workspaceLink);

      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: workspaceLink });
      const clientFs = createAcpClientFsMethods({ cwd: workspaceLink });
      const missing = join(workspaceLink, 'missing.txt');

      await expect(clientFs.readTextFile!({ sessionId: 's', path: missing })).rejects.toMatchObject({ code: -32002 });
    });
  });

  it('readTextFile rejects paths outside configured roots', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-root-', async (root) => {
      const workspace = join(root, 'workspace');
      const outside = join(root, 'outside');
      const outsideFile = join(outside, 'outside.txt');
      // Prepare test files.
      mkdirSync(workspace, { recursive: true });
      mkdirSync(outside, { recursive: true });
      writeFileSync(outsideFile, 'nope', 'utf8');

      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: workspace });
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
      });
      await expect(clientFs.readTextFile!({ sessionId: 's', path: outsideFile })).rejects.toThrow(/permission denied|traversal/i);
      await expect(clientFs.readTextFile!({ sessionId: 's', path: '../outside/outside.txt' })).rejects.toThrow(/permission denied|traversal/i);
    });
  });

  it('writeTextFile rejects paths outside configured roots even when approved', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-root-', async (root) => {
      const workspace = join(root, 'workspace');
      const outside = join(root, 'outside');
      const outsideFile = join(outside, 'outside.txt');
      mkdirSync(workspace, { recursive: true });
      mkdirSync(outside, { recursive: true });

      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: workspace });
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
        permissionHandler: {
          async handleToolCall() {
            return { decision: 'approved' };
          },
        } satisfies AcpPermissionHandler,
      });

      await expect(clientFs.writeTextFile!({ sessionId: 's', path: outsideFile, content: 'nope' })).rejects.toThrow(/permission denied|traversal/i);
      await expect(clientFs.writeTextFile!({ sessionId: 's', path: '../outside/outside.txt', content: 'nope' })).rejects.toThrow(/permission denied|traversal/i);

      expect(existsSync(outsideFile)).toBe(false);
    });
  });

  it.each([true, false])('writeTextFile rejects writes through symlinks outside configured roots (target exists=%s)', async (targetExists) => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-root-', async (root) => {
      const workspace = join(root, 'workspace');
      const outside = join(root, 'outside');
      const outsideFile = join(outside, 'outside.txt');
      const linkPath = join(workspace, 'link.txt');
      mkdirSync(workspace, { recursive: true });
      mkdirSync(outside, { recursive: true });
      if (targetExists) writeFileSync(outsideFile, 'original', 'utf8');
      symlinkSync(outsideFile, linkPath);

      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: workspace });
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
        permissionHandler: {
          async handleToolCall() {
            return { decision: 'approved' };
          },
        } satisfies AcpPermissionHandler,
      });

      await expect(clientFs.writeTextFile!({ sessionId: 's', path: linkPath, content: 'nope' })).rejects.toThrow(/permission denied|traversal/i);
      expect(existsSync(outsideFile)).toBe(targetExists);
      if (targetExists) expect(readFileSync(outsideFile, 'utf8')).toBe('original');
    });
  });

  it('writeTextFile rejects writes when a missing child is nested under a symlinked ancestor outside cwd', async () => {
    envScope.patch({ HAPPIER_ACP_FS: '1' });

    await withTempDir('happier-acp-fs-root-', async (root) => {
      const workspace = join(root, 'workspace');
      const outside = join(root, 'outside');
      const linkDir = join(workspace, 'linkdir');
      const escapedFile = join(outside, 'nested', 'via-symlink.txt');
      mkdirSync(workspace, { recursive: true });
      mkdirSync(outside, { recursive: true });
      symlinkSync(outside, linkDir);

      envScope.patch({ HAPPIER_MACHINE_RPC_WORKING_DIRECTORY: workspace });
      const clientFs = createAcpClientFsMethods({
        cwd: workspace,
        permissionHandler: {
          async handleToolCall() {
            return { decision: 'approved' };
          },
        } satisfies AcpPermissionHandler,
      });

      await expect(
        clientFs.writeTextFile!({
          sessionId: 's',
          path: join(linkDir, 'nested', 'via-symlink.txt'),
          content: 'nope',
        })
      ).rejects.toThrow(/permission denied|traversal/i);
      expect(existsSync(escapedFile)).toBe(false);
    });
  });
});

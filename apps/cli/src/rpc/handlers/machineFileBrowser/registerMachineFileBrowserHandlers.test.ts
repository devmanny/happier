import { mkdtempSync, mkdirSync, writeFileSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { afterEach, describe, expect, it } from 'vitest';

import type { RpcHandlerRegistrar } from '@/api/rpc/types';
import { RPC_METHODS } from '@happier-dev/protocol/rpc';

import { registerMachineFileBrowserHandlers } from './registerMachineFileBrowserHandlers';

type Handler = (data: unknown) => Promise<unknown> | unknown;

const tempDirectories: string[] = [];

function createTempDirectory(): string {
  const directory = mkdtempSync(join(tmpdir(), 'happier-machine-browser-'));
  tempDirectories.push(directory);
  return directory;
}

function createRegistrar(): { handlers: Map<string, Handler>; registrar: RpcHandlerRegistrar } {
  const handlers = new Map<string, Handler>();
  return {
    handlers,
    registrar: {
      registerHandler(method, handler) {
        handlers.set(method, handler as Handler);
      },
    },
  };
}

async function withMachineWorkingDirectoryEnv<T>(value: string, run: () => Promise<T>): Promise<T> {
  const previous = process.env.HAPPIER_MACHINE_RPC_WORKING_DIRECTORY;
  process.env.HAPPIER_MACHINE_RPC_WORKING_DIRECTORY = value;
  try {
    return await run();
  } finally {
    if (previous === undefined) {
      delete process.env.HAPPIER_MACHINE_RPC_WORKING_DIRECTORY;
    } else {
      process.env.HAPPIER_MACHINE_RPC_WORKING_DIRECTORY = previous;
    }
  }
}

afterEach(() => {
  while (tempDirectories.length > 0) {
    const directory = tempDirectories.pop();
    if (!directory) continue;
    rmSync(directory, { recursive: true, force: true });
  }
});

describe('registerMachineFileBrowserHandlers', () => {
  it('registers machine-root browse handlers and lists directories lazily', async () => {
    const root = createTempDirectory();
    mkdirSync(join(root, 'folder'));
    writeFileSync(join(root, 'notes.txt'), 'hello');
    const resolvedRoot = realpathSync(root);
    const { handlers, registrar } = createRegistrar();

    registerMachineFileBrowserHandlers({
      rpcHandlerManager: registrar,
      deps: {
        resolveRoots: async () => [{ id: root, label: root, path: root }],
        maxEntries: 200,
        statConcurrency: 4,
        platform: 'darwin',
      },
    });

    expect(handlers.has(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS)).toBe(true);
    expect(handlers.has(RPC_METHODS.DAEMON_FILESYSTEM_LIST_DIRECTORY)).toBe(true);

    const listRoots = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS);
    const listDirectory = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_DIRECTORY);
    if (!listRoots || !listDirectory) {
      throw new Error('expected machine file browser handlers to be registered');
    }

    await expect(listRoots({})).resolves.toEqual({
      ok: true,
      roots: [{ id: root, label: root, path: root }],
    });

    await expect(listDirectory({ path: root, includeFiles: false })).resolves.toEqual({
      ok: true,
      path: resolvedRoot,
      entries: [
        {
          name: 'folder',
          path: join(resolvedRoot, 'folder'),
          type: 'directory',
          size: expect.any(Number),
          modified: expect.any(Number),
        },
      ],
      truncated: false,
    });
  });

  it('searches every folder by name, including ones past the entry limit', async () => {
    const root = createTempDirectory();
    for (const name of ['alpha', 'beta', 'gamma', 'delta', 'sukarro', 'sukarro-video']) {
      mkdirSync(join(root, name));
    }
    writeFileSync(join(root, 'sukarro-notes.txt'), 'file, not a folder');
    const { handlers, registrar } = createRegistrar();
    registerMachineFileBrowserHandlers({
      rpcHandlerManager: registrar,
      deps: {
        resolveRoots: async () => [{ id: root, label: root, path: root }],
        maxEntries: 3,
        statConcurrency: 4,
        platform: 'darwin',
      },
    });
    const listDirectory = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_DIRECTORY);
    if (!listDirectory) throw new Error('expected the list directory handler to be registered');

    const all = await listDirectory({ path: root, includeFiles: false }) as { entries: Array<{ name: string }>; truncated: boolean };
    expect(all.truncated).toBe(true);
    expect(all.entries.map((entry) => entry.name)).not.toContain('sukarro');

    const found = await listDirectory({ path: root, includeFiles: false, query: 'SUKAR' }) as { entries: Array<{ name: string }>; truncated: boolean };
    expect(found.entries.map((entry) => entry.name)).toEqual(['sukarro', 'sukarro-video']);
    expect(found.truncated).toBe(false);
  });

  it('uses the injected platform consistently for both roots and directory browsing', async () => {
    const { handlers, registrar } = createRegistrar();
    const seenPlatforms: Array<NodeJS.Platform | undefined> = [];

    registerMachineFileBrowserHandlers({
      rpcHandlerManager: registrar,
      deps: {
        resolveRoots: async (input) => {
          seenPlatforms.push(input?.platform);
          return [{ id: '/', label: '/', path: '/' }];
        },
        maxEntries: 200,
        statConcurrency: 4,
        platform: 'win32',
      },
    });

    const listRoots = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS);
    const listDirectory = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_DIRECTORY);
    if (!listRoots || !listDirectory) {
      throw new Error('expected machine file browser handlers to be registered');
    }

    await listRoots({});
    await listDirectory({ path: '/', includeFiles: false });

    expect(seenPlatforms).toEqual(['win32', 'win32']);
  });

  it('lists configured restricted roots and rejects browsing outside every restricted root', async () => {
    const rootA = createTempDirectory();
    const rootB = createTempDirectory();
    const outside = createTempDirectory();
    const resolvedRootA = realpathSync(rootA);
    const resolvedRootB = realpathSync(rootB);
    const { handlers, registrar } = createRegistrar();

    registerMachineFileBrowserHandlers({
      rpcHandlerManager: registrar,
      accessPolicy: {
        kind: 'restrictedRoots',
        roots: [rootA, rootB],
      },
      deps: {
        maxEntries: 200,
        statConcurrency: 4,
        platform: 'darwin',
      },
    });

    const listRoots = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS);
    const listDirectory = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_DIRECTORY);
    if (!listRoots || !listDirectory) {
      throw new Error('expected machine file browser handlers to be registered');
    }

    await expect(listRoots({})).resolves.toEqual({
      ok: true,
      roots: [
        { id: resolvedRootA, label: resolvedRootA, path: resolvedRootA },
        { id: resolvedRootB, label: resolvedRootB, path: resolvedRootB },
      ],
    });

    await expect(listDirectory({ path: outside, includeFiles: false })).resolves.toMatchObject({
      ok: false,
      errorCode: 'invalid_path',
    });
  });

  it('canonicalizes injected Windows restricted roots with Windows path semantics', async () => {
    const { handlers, registrar } = createRegistrar();

    registerMachineFileBrowserHandlers({
      rpcHandlerManager: registrar,
      accessPolicy: {
        kind: 'restrictedRoots',
        roots: ['C:\\Users\\alice\\workspace'],
      },
      deps: {
        maxEntries: 200,
        statConcurrency: 4,
        platform: 'win32',
      },
    });

    const listRoots = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS);
    if (!listRoots) {
      throw new Error('expected machine file browser root handler to be registered');
    }

    await expect(listRoots({})).resolves.toEqual({
      ok: true,
      roots: [
        {
          id: 'C:\\Users\\alice\\workspace',
          label: 'C:\\Users\\alice\\workspace',
          path: 'C:\\Users\\alice\\workspace',
        },
      ],
    });
  });

  it('derives restricted roots from comma-delimited HAPPIER_MACHINE_RPC_WORKING_DIRECTORY when no policy is injected', async () => {
    const rootA = createTempDirectory();
    const rootB = createTempDirectory();
    const resolvedRootA = realpathSync(rootA);
    const resolvedRootB = realpathSync(rootB);
    const { handlers, registrar } = createRegistrar();

    await withMachineWorkingDirectoryEnv(` ${rootA},, ${rootB} `, async () => {
      registerMachineFileBrowserHandlers({
        rpcHandlerManager: registrar,
        deps: {
          maxEntries: 200,
          statConcurrency: 4,
          platform: 'darwin',
        },
      });

      const listRoots = handlers.get(RPC_METHODS.DAEMON_FILESYSTEM_LIST_ROOTS);
      if (!listRoots) {
        throw new Error('expected machine file browser root handler to be registered');
      }

      await expect(listRoots({})).resolves.toEqual({
        ok: true,
        roots: [
          { id: resolvedRootA, label: resolvedRootA, path: resolvedRootA },
          { id: resolvedRootB, label: resolvedRootB, path: resolvedRootB },
        ],
      });
    });
  });
});

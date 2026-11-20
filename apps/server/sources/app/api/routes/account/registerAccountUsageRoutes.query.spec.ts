import { beforeEach, describe, expect, it, vi } from "vitest";
import { createAuthenticatedTestApp } from "../../testkit/sqliteFastify";

const findMany = vi.hoisted(() => vi.fn());
vi.mock("@/storage/db", () => ({ db: {
    session: { findFirst: vi.fn(async () => ({ id: "s1" })) },
    usageReport: { findMany },
} }));
vi.mock("@/app/events/eventRouter", () => ({ eventRouter: {}, buildUsageEphemeral: vi.fn() }));
vi.mock("@/utils/logging/log", () => ({ log: vi.fn() }));

const report = (key: string, total: number, cost = 0, sessionId = "s1") => ({
    key, sessionId, createdAt: new Date("2026-01-01T00:00:00Z"),
    data: { tokens: { total }, cost: { total: cost } },
});

async function query(payload: Record<string, unknown> = { sessionId: "s1" }) {
    const { registerAccountUsageRoutes } = await import("./registerAccountUsageRoutes");
    const app = createAuthenticatedTestApp();
    registerAccountUsageRoutes(app as any);
    try {
        const response = await app.inject({ method: "POST", url: "/v1/usage/query",
            headers: { "x-test-user-id": "u1" }, payload });
        expect(response.statusCode).toBe(200);
        return response.json();
    } finally { await app.close(); }
}

describe("recorded usage aggregation", () => {
    beforeEach(() => findMany.mockReset());

    it("excludes overlapping legacy snapshots only for sessions with response reports", async () => {
        const modern = [report("claude-response:r1", 30, 0.3), report("acp-prompt-usage:p1", 20)];
        findMany.mockResolvedValueOnce([
            report("claude-session", 30, 0.3), report("acp-prompt-usage", 20, 0.2),
            ...modern, report("claude-session", 12, 0.1, "other-session"),
        ]).mockResolvedValueOnce(modern);
        const result = await query({});
        expect(result.usage[0].tokens.total).toBe(62);
        // A provider that did not supply response costs must not erase its recorded legacy cost.
        expect(result.usage[0].cost.total).toBeCloseTo(0.6);
        expect(findMany.mock.calls[1][0].where.accountId).toBe("u1");
    });

    it("does not revive a legacy snapshot when response reports fall outside the requested dates", async () => {
        findMany.mockResolvedValueOnce([report("claude-session", 30, 0.3)])
            .mockResolvedValueOnce([report("claude-response:r1", 30, 0.3)]);
        const result = await query({ sessionId: "s1", startTime: 1, endTime: 2 });
        expect(result.usage[0].tokens).toEqual({});
        expect(findMany.mock.calls[1][0].where.createdAt).toBeUndefined();
    });

    it("preserves legacy-only consumption but excludes historical context occupancy", async () => {
        const context = report("acp-usage-update", 500, 0.5);
        Object.assign(context.data.tokens, { used: 500, size: 1000 });
        findMany.mockResolvedValueOnce([report("claude-session", 30, 0.3), context])
            .mockResolvedValueOnce([]);
        const result = await query();
        expect(result.usage[0].tokens.total).toBe(30);
        expect(result.usage[0].cost.total).toBeCloseTo(0.8);
    });
});

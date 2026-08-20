import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../../server/auth-middleware'
import { requireJsonContentType, safeErrorMessage } from '../../../server/rate-limit'
import { normalizeTestResult } from '../../../server/mcp-normalize'
import { runHermesMcpTest } from '../../../server/mcp-cli-bridge'
import { setProbe } from '../../../server/mcp-tools-cache'

const TEST_TIMEOUT_MS = 30_000

export const Route = createFileRoute('/api/mcp/test')({
  server: {
    handlers: {
      // Stage4: POST /api/mcp/test — test an existing server by name via
      // `hermes mcp test <name>` (local fallback, no gateway/dashboard proxy).
      POST: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        try {
          const raw = (await request.json()) as Record<string, unknown>
          const name = typeof raw.name === 'string' ? raw.name : null
          if (!name) {
            return json(
              {
                ok: false,
                status: 'unknown',
                discoveredTools: [],
                error: 'Local fallback only supports testing existing servers by name.',
              },
              { status: 400 },
            )
          }
          const result = await runHermesMcpTest(name, { timeoutMs: TEST_TIMEOUT_MS })
          setProbe(name, {
            status: result.status,
            toolCount: result.discoveredTools.length,
            toolNames: result.discoveredTools.map((t) => t.name),
            latencyMs: result.latencyMs,
            error: result.error,
          })
          return json(result)
        } catch (err) {
          return json(
            {
              ok: false,
              status: 'failed',
              discoveredTools: [],
              error: safeErrorMessage(err),
            },
            { status: 500 },
          )
        }
      },
    },
  },
})

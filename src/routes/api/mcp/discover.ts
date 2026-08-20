import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../../server/auth-middleware'
import { requireJsonContentType, safeErrorMessage } from '../../../server/rate-limit'
import { runHermesMcpTest } from '../../../server/mcp-cli-bridge'

const DISCOVER_TIMEOUT_MS = 30_000

export const Route = createFileRoute('/api/mcp/discover')({
  server: {
    handlers: {
      // Stage4: POST /api/mcp/discover — discover tools for an existing server
      // by name via `hermes mcp test <name>` (local fallback, no gateway proxy).
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
              { ok: false, tools: [], error: 'Server name is required for discovery.' },
              { status: 400 },
            )
          }
          const result = await runHermesMcpTest(name, { timeoutMs: DISCOVER_TIMEOUT_MS })
          return json({ ok: result.status === 'connected', tools: result.discoveredTools, error: result.error })
        } catch (err) {
          return json({ ok: false, tools: [], error: safeErrorMessage(err) }, { status: 500 })
        }
      },
    },
  },
})

import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../../../server/auth-middleware'
import {
  CLAUDE_UPGRADE_INSTRUCTIONS,
  ensureGatewayProbed,
} from '../../../../server/gateway-capabilities'
import { requireJsonContentType, safeErrorMessage } from '../../../../server/rate-limit'
import { createCapabilityUnavailablePayload } from '@/lib/feature-gates'
import { readMcpServersCli, writeMcpServersCli } from '../../../../server/mcp-config-cli'

export const Route = createFileRoute('/api/mcp/servers/$name')({
  server: {
    handlers: {
      DELETE: async ({ request, params }) => {
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        // DELETE has no body, so requireJsonContentType allows it through.
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        const capabilities = await ensureGatewayProbed()
        if (!capabilities.mcp && !capabilities.mcpFallback) {
          return json(
            createCapabilityUnavailablePayload('mcp', {
              error: `Gateway does not support /api/mcp. ${CLAUDE_UPGRADE_INSTRUCTIONS}`,
            }),
            { status: 503 },
          )
        }
        const name = (params as { name?: string }).name?.trim() || ''
        if (!name) {
          return json({ ok: false, error: 'Missing server name' }, { status: 400 })
        }
        try {
          const cfg = readMcpServersCli()
          const servers =
            cfg && typeof cfg === 'object'
              ? { ...(cfg as Record<string, unknown>) }
              : {}
          if (!(name in servers)) {
            return json({ ok: false, error: 'Server not found' }, { status: 404 })
          }
          delete servers[name]
          writeMcpServersCli(servers)
          return json({ ok: true, name })
        } catch (err) {
          return json({ ok: false, error: safeErrorMessage(err) }, { status: 500 })
        }
      },
    },
  },
})

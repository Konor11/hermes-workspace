import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../../server/auth-middleware'
import { requireJsonContentType, safeErrorMessage } from '../../../server/rate-limit'
import {
  maskSecretsInPlace,
  normalizeMcpServerFromConfig,
} from '../../../server/mcp-normalize'
import { readMcpServersCli, writeMcpServersCli } from '../../../server/mcp-config-cli'

function readConfigure(raw: unknown): {
  name: string
  enabled?: boolean
  toolMode?: string
  includeTools?: string[]
  excludeTools?: string[]
} | null {
  if (!raw || typeof raw !== 'object') return null
  const r = raw as Record<string, unknown>
  const name = typeof r.name === 'string' ? r.name.trim() : ''
  if (!name) return null
  const out: {
    name: string
    enabled?: boolean
    toolMode?: string
    includeTools?: string[]
    excludeTools?: string[]
  } = { name }
  if (typeof r.enabled === 'boolean') out.enabled = r.enabled
  if (r.toolMode === 'all' || r.toolMode === 'include' || r.toolMode === 'exclude') {
    out.toolMode = r.toolMode
  }
  if (Array.isArray(r.includeTools)) {
    out.includeTools = (r.includeTools as Array<unknown>).map((t) => String(t))
  }
  if (Array.isArray(r.excludeTools)) {
    out.excludeTools = (r.excludeTools as Array<unknown>).map((t) => String(t))
  }
  return out
}

export const Route = createFileRoute('/api/mcp/configure')({
  server: {
    handlers: {
      // Stage4: PUT /api/mcp/configure — toggle/save server config via `hermes config` CLI.
      // We do NOT proxy to the dashboard (9119); we patch the local `mcp_servers`
      // entry in ~/.hermes/config.yaml directly.
      PUT: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        try {
          const raw = (await request.json()) as unknown
          const input = readConfigure(raw)
          if (!input) {
            return json({ ok: false, error: 'Invalid configure payload' }, { status: 400 })
          }
          const cfg = readMcpServersCli()
          const servers =
            cfg && typeof cfg === 'object' && !Array.isArray(cfg)
              ? { ...(cfg as Record<string, unknown>) }
              : {}
          const existing = servers[input.name]
          if (!existing || typeof existing !== 'object' || Array.isArray(existing)) {
            return json({ ok: false, error: `MCP server not found: ${input.name}` }, { status: 404 })
          }
          const next: Record<string, unknown> = { ...(existing as Record<string, unknown>) }
          if (typeof input.enabled === 'boolean') next.enabled = input.enabled
          if (input.toolMode) next.tool_mode = input.toolMode
          if (Array.isArray(input.includeTools)) next.include_tools = input.includeTools
          if (Array.isArray(input.excludeTools)) next.exclude_tools = input.excludeTools
          servers[input.name] = next
          writeMcpServersCli(servers)
          const written = normalizeMcpServerFromConfig(input.name, next)
          if (!written) {
            return json({ ok: false, error: 'MCP configure failed (config write)' }, { status: 500 })
          }
          return json({ ok: true, server: maskSecretsInPlace(written) })
        } catch (err) {
          return json({ ok: false, error: safeErrorMessage(err) }, { status: 500 })
        }
      },
    },
  },
})

import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../../server/auth-middleware'
import * as fs from 'node:fs'
import {
  BEARER_TOKEN,
  CLAUDE_API,
  CLAUDE_UPGRADE_INSTRUCTIONS,
  dashboardFetch,
  ensureGatewayProbed,
  getCapabilities,
} from '../../../server/gateway-capabilities'
import { requireJsonContentType, safeErrorMessage } from '../../../server/rate-limit'
import {
  maskSecretsInPlace,
  normalizeMcpList,
  normalizeMcpListFromConfig,
  normalizeMcpServer,
  normalizeMcpServerFromConfig,
} from '../../../server/mcp-normalize'
import { getConfig, saveConfig } from '../../../server/claude-dashboard-api'
import type { McpServerInput } from '../../../types/mcp-input'
import { parseMcpServerInput } from '../../../server/mcp-input-validate'
import { createCapabilityUnavailablePayload } from '@/lib/feature-gates'
import { getProbe } from '../../../server/mcp-tools-cache'
import { readMcpServersCli, writeMcpServersCli } from '../../../server/mcp-config-cli'

const KNOWN_CATEGORIES = ['All', 'Connected', 'Failed', 'Disabled'] as const
const REQUEST_TIMEOUT_MS = 30_000

async function mcpFetch(path: string, init: RequestInit = {}): Promise<Response> {
  const capabilities = getCapabilities()
  if (capabilities.dashboard.available) {
    return dashboardFetch(path, init)
  }
  const headers = new Headers(init.headers)
  if (BEARER_TOKEN && !headers.has('Authorization')) {
    headers.set('Authorization', `Bearer ${BEARER_TOKEN}`)
  }
  return fetch(`${CLAUDE_API}${path}`, { ...init, headers })
}

function unavailableListPayload() {
  return {
    ...createCapabilityUnavailablePayload('mcp'),
    servers: [],
    total: 0,
    categories: [...KNOWN_CATEGORIES],
  }
}

/**
 * Phase 1.5 fallback: convert the runtime `McpServerInput` write shape into
 * the dashboard config-yaml entry shape stored under `config.mcp_servers[name]`.
 * Only stable, top-level keys are emitted; secret bodies (`bearerToken`,
 * `oauth.clientSecret`) are persisted under `auth.token` / `auth.oauth.*`
 * for the agent to pick up later. Empty fields are omitted to keep the YAML
 * minimal.
 */
function toConfigEntry(input: McpServerInput): Record<string, unknown> {
  const out: Record<string, unknown> = {
    transport: input.transportType,
  }
  if (typeof input.enabled === 'boolean') out.enabled = input.enabled
  if (input.url) out.url = input.url
  if (input.command) out.command = input.command
  if (input.args && input.args.length > 0) out.args = input.args
  if (input.env && Object.keys(input.env).length > 0) out.env = input.env
  if (input.headers && Object.keys(input.headers).length > 0) out.headers = input.headers
  if (input.toolMode && input.toolMode !== 'all') out.tool_mode = input.toolMode
  if (input.includeTools && input.includeTools.length > 0) out.include_tools = input.includeTools
  if (input.excludeTools && input.excludeTools.length > 0) out.exclude_tools = input.excludeTools
  if (input.authType && input.authType !== 'none') {
    const auth: Record<string, unknown> = { type: input.authType }
    if (input.bearerToken) auth.token = input.bearerToken
    if (input.oauth) auth.oauth = { ...input.oauth }
    out.auth = auth
  } else if (input.bearerToken || input.oauth) {
    const auth: Record<string, unknown> = {}
    if (input.bearerToken) auth.token = input.bearerToken
    if (input.oauth) auth.oauth = { ...input.oauth }
    out.auth = auth
  }
  return out
}

/**
 * Read the current `config.mcp_servers` map from the dashboard config payload.
 * Always returns a fresh object (never the live reference). Empty when missing.
 */
async function readConfigServersMap(): Promise<{
  config: Record<string, unknown>
  servers: Record<string, unknown>
}> {
  const cfg = await getConfig()
  const root: Record<string, unknown> =
    'config' in cfg && cfg.config && typeof cfg.config === 'object'
      ? (cfg.config as Record<string, unknown>)
      : cfg
  const raw = root.mcp_servers
  const servers =
    raw && typeof raw === 'object' && !Array.isArray(raw)
      ? { ...(raw as Record<string, unknown>) }
      : {}
  return { config: root, servers }
}

export { parseMcpServerInput, unavailableListPayload, toConfigEntry }

export const Route = createFileRoute('/api/mcp/')({
  server: {
    handlers: {
      GET: async ({ request }) => {
        fs.appendFileSync('/tmp/ws-mcp-debug.log', `[GET /api/mcp/servers] start url=${request.url}\n`)
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        // Stage4: read config locally via `hermes config` CLI — no gateway/dashboard
        // capability probe needed (probeMcp hits dashboard 9119 which 401s and can
        // cause the handler to hang/500 in the browser context).
        try {
          const url = new URL(request.url)
          const search = (url.searchParams.get('search') || '').trim().toLowerCase()
          const category = (url.searchParams.get('category') || 'All').trim()

          let servers: ReturnType<typeof normalizeMcpList>
          // Stage4: read via `hermes config` CLI (no dashboard dependency)
          const cfg = readMcpServersCli()
          servers = normalizeMcpListFromConfig({ mcp_servers: cfg })
            .map((s) => maskSecretsInPlace(s))
            .map((s) => {
              const probe = getProbe(s.name)
              if (!probe) return s
              return {
                ...s,
                status: probe.status,
                discoveredToolsCount: probe.toolCount,
                lastError: probe.error || s.lastError,
              }
            })

          const filtered = servers.filter((s) => {
            if (search) {
              const hay = [s.name, s.url || '', s.command || '', ...s.args]
                .join('\n')
                .toLowerCase()
              if (!hay.includes(search)) return false
            }
            if (category === 'Connected' && s.status !== 'connected') return false
            if (category === 'Failed' && s.status !== 'failed') return false
            if (category === 'Disabled' && s.enabled) return false
            return true
          })

          return json({
            ok: true,
            servers: filtered,
            total: filtered.length,
            categories: [...KNOWN_CATEGORIES],
          })
        } catch (err) {
          fs.appendFileSync('/tmp/ws-mcp-debug.log', `[GET /api/mcp/servers] ERROR: ${err instanceof Error ? err.stack || err.message : String(err)}\n`)
          return json(
            { ok: false, error: safeErrorMessage(err), servers: [], total: 0, categories: [...KNOWN_CATEGORIES] },
            { status: 500 },
          )
        }
      },
      POST: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        // Stage4: write config locally via `hermes config` CLI — no capability probe.
        try {
          const raw = (await request.json()) as unknown
          const parsed = parseMcpServerInput(raw)
          if (!parsed.ok) {
            return json(
              { ok: false, error: 'Invalid MCP server payload', errors: parsed.errors },
              { status: 400 },
            )
          }
          const input = parsed.value
          // Stage4: write via `hermes config` CLI
          const cfg = readMcpServersCli()
          const servers =
            cfg && typeof cfg === 'object'
              ? { ...(cfg as Record<string, unknown>) }
              : {}
          servers[input.name] = toConfigEntry(input)
          writeMcpServersCli(servers)
          const written = normalizeMcpServerFromConfig(
            input.name,
            servers[input.name],
          )
          if (!written) {
            return json({ ok: false, error: 'MCP create failed (config write)' }, { status: 500 })
          }
          return json({ ok: true, server: maskSecretsInPlace(written as NonNullable<typeof written>) })
        } catch (err) {
          return json({ ok: false, error: safeErrorMessage(err) }, { status: 500 })
        }
      },
      // Stage4: DELETE /api/mcp/{name} — remove server via `hermes config` CLI.
      // (Kept here instead of mcp/$name.ts because the dynamic $name route
      // shadows static sub-routes like /api/mcp/test and /api/mcp/discover,
      // causing them to 405. DELETE has no body, so we parse the name from the URL.)
      DELETE: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return json({ ok: false, error: 'Unauthorized' }, { status: 401 })
        }
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        try {
          const url = new URL(request.url)
          const name = url.pathname.split('/').pop() || ''
          if (!name) {
            return json({ ok: false, error: 'Missing server name' }, { status: 400 })
          }
          const cfg = readMcpServersCli()
          const servers =
            cfg && typeof cfg === 'object' ? { ...(cfg as Record<string, unknown>) } : {}
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

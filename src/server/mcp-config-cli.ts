// Stage4 (DKTunnel 2026-08-19): MCP server config access via the `hermes config`
// CLI so the Workspace UI can manage servers without the dashboard's
// /api/mcp endpoints (which the user's hermes-agent build does not expose as JSON).
//
// Lives under src/server/ (server-only) so `node:child_process` is allowed here,
// keeping the route file (src/routes/api/mcp.ts) free of node: imports that
// break TanStack Start server-handler registration.
import { execSync } from 'node:child_process'

export function readMcpServersCli(): Record<string, unknown> {
  try {
    const out = execSync('hermes config get mcp_servers --json 2>/dev/null', {
      timeout: 15000,
      encoding: 'utf8',
    })
    const parsed = JSON.parse(out)
    return parsed && typeof parsed === 'object' ? parsed : {}
  } catch {
    return {}
  }
}

export function writeMcpServersCli(servers: Record<string, unknown>): void {
  for (const [name, entry] of Object.entries(servers)) {
    const e = entry as Record<string, unknown>
    execSync(
      `hermes config set mcp_servers.${name}.enabled ${e.enabled === false ? 'false' : 'true'} 2>/dev/null`,
      { timeout: 15000 },
    )
    if (e.command) {
      execSync(
        `hermes config set mcp_servers.${name}.command ${JSON.stringify(e.command)} 2>/dev/null`,
        { timeout: 15000 },
      )
    }
    if (Array.isArray(e.args)) {
      execSync(
        `hermes config set mcp_servers.${name}.args ${JSON.stringify(JSON.stringify(e.args))} 2>/dev/null`,
        { timeout: 15000 },
      )
    }
  }
  const current = readMcpServersCli()
  for (const name of Object.keys(current)) {
    if (!(name in servers)) {
      execSync(`hermes config unset mcp_servers.${name} 2>/dev/null`, { timeout: 15000 })
    }
  }
}

import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/**
 * Per-profile gateway resolution for Workspace.
 *
 * Each Hermes profile may run its own gateway process on a dedicated port
 * (see `gateway.port` in the profile's config.yaml and `API_SERVER_PORT` in
 * its `.env`). This module maps a profile name to the gateway base URL and
 * auth key so the Workspace chat UI can route a conversation to the correct
 * gateway without modifying hermes-agent itself.
 */

const DEFAULT_PORT = 8642

function getHermesRoot(): string {
  return (
    process.env.HERMES_HOME ??
    process.env.CLAUDE_HOME ??
    path.join(os.homedir(), '.hermes')
  )
}

function getProfilesRoot(): string {
  return path.join(getHermesRoot(), 'profiles')
}

function readEnvFile(envPath: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (!fs.existsSync(envPath)) return out
  try {
    const text = fs.readFileSync(envPath, 'utf-8')
    for (const raw of text.split('\n')) {
      const line = raw.trim()
      if (!line || line.startsWith('#')) continue
      const eq = line.indexOf('=')
      if (eq === -1) continue
      const key = line.slice(0, eq).trim()
      let val = line.slice(eq + 1).trim()
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1)
      }
      if (key) out[key] = val
    }
  } catch {
    // ignore unreadable env
  }
  return out
}

function readYamlPort(configPath: string): number | undefined {
  if (!fs.existsSync(configPath)) return undefined
  try {
    // Lightweight YAML scan for `gateway: { port: N }` — avoids a yaml dep import here.
    const text = fs.readFileSync(configPath, 'utf-8')
    const m = text.match(/gateway:\s*\n[^]*?port:\s*(\d{2,5})/)
    if (m) {
      const port = Number(m[1])
      if (port > 0 && port <= 65535) return port
    }
  } catch {
    // ignore
  }
  return undefined
}

export type ProfileGateway = {
  profile: string
  baseUrl: string
  apiKey: string
  port: number
}

/**
 * Resolve the gateway connection details for a profile.
 *
 * - `default` (or empty) → root `.hermes/.env` (port 8642 by default).
 * - any other profile → its own `profiles/<id>/.env` (API_SERVER_PORT + API_SERVER_KEY),
 *   falling back to `config.yaml` `gateway.port` and the root API key.
 */
export function resolveProfileGateway(profile: string): ProfileGateway {
  const name = (profile || 'default').trim()
  const root = getHermesRoot()
  const rootEnv = readEnvFile(path.join(root, '.env'))

  if (name === 'default' || name === 'Workspace') {
    const port = Number(rootEnv.API_SERVER_PORT) || DEFAULT_PORT
    return {
      profile: 'default',
      baseUrl: `http://127.0.0.1:${port}`,
      apiKey: rootEnv.API_SERVER_KEY || '',
      port,
    }
  }

  const profileDir = path.join(getProfilesRoot(), name)
  const env = readEnvFile(path.join(profileDir, '.env'))
  const yamlPort = readYamlPort(path.join(profileDir, 'config.yaml'))
  const port =
    Number(env.API_SERVER_PORT) || yamlPort || DEFAULT_PORT
  const apiKey = env.API_SERVER_KEY || rootEnv.API_SERVER_KEY || ''

  return {
    profile: name,
    baseUrl: `http://127.0.0.1:${port}`,
    apiKey,
    port,
  }
}

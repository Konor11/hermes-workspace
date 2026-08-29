/**
 * Per-profile gateway proxy.
 *
 * Forwards Workspace chat requests to the gateway that belongs to a specific
 * Hermes profile. The chat UI sends `POST /api/gateway/<profile>/sessions/...`
 * (and reads SSE from the same prefix) and this route proxies it to
 * `http://127.0.0.1:<profilePort>/...` with that profile's API_SERVER_KEY.
 *
 * This keeps hermes-agent untouched — Workspace just routes by profile.
 */
import { createFileRoute } from '@tanstack/react-router'
import { isAuthenticated } from '../../../../server/auth-middleware'
import { resolveProfileGateway } from '../../../../server/profile-gateways'

function buildTarget(profile: string, rest: string[]): {
  url: string
  key: string
} | null {
  const gw = resolveProfileGateway(profile)
  const suffix = rest.filter(Boolean).join('/')
  const url = `${gw.baseUrl}/${suffix}`.replace(/([^:]\/)\/+/g, '$1')
  return { url, key: gw.apiKey }
}

async function proxy(request: Request, profile: string, rest: string[]) {
  if (!isAuthenticated(request)) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const target = buildTarget(profile, rest)
  if (!target) {
    return new Response(JSON.stringify({ error: 'Unknown profile' }), {
      status: 404,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  const headers = new Headers()
  // Forward content-type and any client authorization, but enforce the
  // profile's own gateway key for the upstream call.
  const contentType = request.headers.get('content-type')
  if (contentType) headers.set('content-type', contentType)
  if (target.key) headers.set('Authorization', `Bearer ${target.key}`)

  const init: RequestInit = {
    method: request.method,
    headers,
  }
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    init.body = request.body
    // @ts-expect-error stream body is allowed at runtime
    init.duplex = 'half'
  }

  let upstream: Response
  try {
    upstream = await fetch(target.url, init)
  } catch (err) {
    const msg = err instanceof Error ? err.message : 'gateway unreachable'
    return new Response(JSON.stringify({ error: `Gateway proxy failed: ${msg}` }), {
      status: 502,
      headers: { 'Content-Type': 'application/json' },
    })
  }

  // Stream the response back verbatim, preserving SSE/content-type.
  const responseHeaders = new Headers()
  const passThrough = [
    'content-type',
    'cache-control',
    'connection',
    'transfer-encoding',
  ]
  for (const h of passThrough) {
    const v = upstream.headers.get(h)
    if (v) responseHeaders.set(h, v)
  }

  return new Response(upstream.body, {
    status: upstream.status,
    statusText: upstream.statusText,
    headers: responseHeaders,
  })
}

export const Route = createFileRoute('/api/gateway/$profile/[./path]')({
  server: {
    handlers: {
      GET: async ({ request, params }) => {
        const rest = Array.isArray(params._splat)
          ? params._splat
          : (params._splat ? [params._splat] : [])
        return proxy(request, params.profile, rest)
      },
      POST: async ({ request, params }) => {
        const rest = Array.isArray(params._splat)
          ? params._splat
          : (params._splat ? [params._splat] : [])
        return proxy(request, params.profile, rest)
      },
    },
  },
})

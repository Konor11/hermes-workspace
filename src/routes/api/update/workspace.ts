import { createFileRoute } from '@tanstack/react-router'
import { spawn } from 'node:child_process'
import { isAuthenticated } from '../../../server/auth-middleware'
import {
  getClientIp,
  rateLimit,
  rateLimitResponse,
  requireJsonContentType,
} from '../../../server/rate-limit'
import { applyWorkspaceUpdate, type UpdateStage } from '../../../server/update-system'

export const Route = createFileRoute('/api/update/workspace')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return new Response(
            JSON.stringify({ ok: false, error: 'Unauthorized' }),
            { status: 401, headers: { 'Content-Type': 'application/json' } },
          )
        }
        const csrfCheck = requireJsonContentType(request)
        if (csrfCheck) return csrfCheck
        if (!rateLimit(`update-workspace:${getClientIp(request)}`, 3, 60_000)) {
          return rateLimitResponse()
        }

        let force = false
        try {
          const body = (await request.json()) as { force?: boolean }
          force = Boolean(body?.force)
        } catch {
          // no body / invalid JSON → treat as non-force
        }

        const encoder = new TextEncoder()
        const stream = new ReadableStream({
          start(controller) {
            const send = (event: string, data: unknown) => {
              controller.enqueue(
                encoder.encode(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`),
              )
            }
            let result: Awaited<ReturnType<typeof applyWorkspaceUpdate>> | null =
              null
            try {
              result = applyWorkspaceUpdate(
                (stage: UpdateStage, message: string) => {
                  send('stage', { stage, message })
                },
                force,
              )
              send('stage', {
                stage: result.ok ? 'done' : 'error',
                message: result.ok
                  ? result.status.reason ?? 'Update complete.'
                  : result.error ?? 'Update failed.',
              })
              send('result', result)
            } catch (err) {
              send('stage', {
                stage: 'error',
                message: err instanceof Error ? err.message : String(err),
              })
              send('result', {
                ok: false,
                error: err instanceof Error ? err.message : String(err),
              })
            } finally {
              controller.close()
            }
            // Restart via a detached setsid process with a short delay, so the
            // SSE 'done' event is flushed to the client before this process is
            // killed. Using setsid ensures the restart survives the death of
            // the current workspace process.
            if (result?.restartRequired) {
              try {
                spawn(
                  'setsid',
                  [
                    'bash',
                    '-c',
                    'sleep 2; systemctl restart hermes-workspace.service',
                  ],
                  { detached: true, stdio: 'ignore' },
                ).unref()
              } catch {
                // ignore — client will reload manually
              }
            }
          },
        })

        return new Response(stream, {
          headers: {
            'Content-Type': 'text/event-stream; charset=utf-8',
            'Cache-Control': 'no-cache, no-transform',
            'X-Accel-Buffering': 'no',
            Connection: 'keep-alive',
          },
        })
      },
    },
  },
})

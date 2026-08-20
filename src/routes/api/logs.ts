import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import { isAuthenticated } from '../../server/auth-middleware'
import { execSync } from 'node:child_process'

// Local replacement for the dashboard's /api/logs proxy. The Workspace shell
// previously had no handler for /api/logs, so it fell through to the SPA and
// the dashboard "log error in tail" banner false-matched console.error() in
// the bootstrap script. We read the real agent log from journald instead.
//
// We only surface genuine ERROR/FATAL lines (not INFO/WARNING lines that merely
// contain the word "error" in their message), so the banner reflects real
// problems, not noisy tool-executor notices.
export const Route = createFileRoute('/api/logs')({
  server: {
    handlers: {
      GET: async ({ request }) => {
        if (!isAuthenticated(request)) {
          return json({ error: 'unauthorized' }, { status: 401 })
        }
        const url = new URL(request.url)
        const lines = Math.min(Math.max(parseInt(url.searchParams.get('lines') || '200', 10) || 200, 10), 2000)
        let raw = ''
        try {
          raw = execSync(
            `journalctl -u hermes-gateway -n ${lines} -o short --no-pager 2>/dev/null`,
            { encoding: 'utf-8', timeout: 8000 },
          )
        } catch {
          raw = ''
        }
        const realErrors = raw
          .split('\n')
          .map((l) => l.trim())
          .filter((l) => l.length > 0)
          // Match on the actual log LEVEL token (e.g. "...,201 ERROR" / "FATAL"),
          // not on the word "error" appearing inside an INFO/WARNING message.
          .filter((l) => /\b(ERROR|FATAL|CRITICAL|TRACEBACK)\b\s/.test(l) ||
                          /\b(ERROR|FATAL|CRITICAL|TRACEBACK)\b$/.test(l))
          .slice(-lines)
        return json({
          file: 'hermes-gateway (journald)',
          lines: realErrors,
        })
      },
    },
  },
})

import { createFileRoute } from '@tanstack/react-router'
import { json } from '@tanstack/react-start'
import {
  createExpiredSessionCookie,
  getSessionTokenFromCookie,
  revokeSessionToken,
} from '../../server/auth-middleware'

export const Route = createFileRoute('/api/auth/logout')({
  server: {
    handlers: {
      POST: async ({ request }) => {
        const token = getSessionTokenFromCookie(request.headers.get('cookie'))
        if (token) revokeSessionToken(token)
        return json(
          { ok: true },
          { headers: { 'Set-Cookie': createExpiredSessionCookie() } },
        )
      },
    },
  },
})

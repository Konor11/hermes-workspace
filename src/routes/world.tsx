import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import { usePageTitle } from '@/hooks/use-page-title'
import { HermesWorldLanding } from '@/screens/playground/hermes-world-landing'

export const Route = createFileRoute('/world')({
  ssr: false,
  component: WorldRoute,
})

function WorldRoute() {
  usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.hermesWorld'))
  return <HermesWorldLanding />
}

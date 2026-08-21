import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import { usePageTitle } from '@/hooks/use-page-title'
import { HermesWorldLanding } from '@/screens/playground/hermes-world-landing'

export const Route = createFileRoute('/hermes-world')({
  ssr: false,
  component: HermesWorldRoute,
})

function HermesWorldRoute() {
  usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.hermesWorld'))
  return <HermesWorldLanding />
}

import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import { usePageTitle } from '@/hooks/use-page-title'
import { DashboardScreen } from '@/screens/dashboard/dashboard-screen'

export const Route = createFileRoute('/dashboard')({
  ssr: false,
  component: DashboardRoute,
})

function DashboardRoute() {
  usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.dashboard'))
  return <DashboardScreen />
}

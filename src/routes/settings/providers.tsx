import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import { usePageTitle } from '@/hooks/use-page-title'
import { ProvidersScreen } from '@/screens/settings/providers-screen'

export const Route = createFileRoute('/settings/providers')({
  ssr: false,
  component: function SettingsProvidersRoute() {
    usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.providerSetup'))
    return <ProvidersScreen />
  },
})

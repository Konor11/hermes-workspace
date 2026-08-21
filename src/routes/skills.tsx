import { createFileRoute } from '@tanstack/react-router'
import { __hermesT } from '@/lib/i18n'
import BackendUnavailableState from '@/components/backend-unavailable-state'
import { usePageTitle } from '@/hooks/use-page-title'
import { getUnavailableReason } from '@/lib/feature-gates'
import { useFeatureAvailable } from '@/hooks/use-feature-available'
import { SkillsScreen } from '@/screens/skills/skills-screen'

export const Route = createFileRoute('/skills')({
  ssr: false,
  component: SkillsRoute,
})

function SkillsRoute() {
  usePageTitle((__hermesT || (globalThis as any).__hermesT)('page.skills'))
  if (!useFeatureAvailable('skills')) {
    return (
      <BackendUnavailableState
        feature="Skills"
        description={getUnavailableReason('Skills')}
      />
    )
  }
  return <SkillsScreen />
}

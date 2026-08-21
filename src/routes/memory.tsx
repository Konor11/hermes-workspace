import { Suspense, lazy, useState } from 'react'
import { createFileRoute } from '@tanstack/react-router'
import BackendUnavailableState from '@/components/backend-unavailable-state'
import { Tabs, TabsList, TabsPanel, TabsTab } from '@/components/ui/tabs'
import { useFeatureAvailable } from '@/hooks/use-feature-available'
import { usePageTitle } from '@/hooks/use-page-title'
import { getUnavailableReason } from '@/lib/feature-gates'
import { __hermesT } from '@/lib/i18n'

const MemoryBrowserScreen = lazy(async () => {
  const module = await import('@/screens/memory/memory-browser-screen')
  return { default: module.MemoryBrowserScreen }
})

const KnowledgeBrowserScreen = lazy(async () => {
  const module = await import('@/screens/memory/knowledge-browser-screen')
  return { default: module.KnowledgeBrowserScreen }
})

const ExternalMemoryBrowserScreen = lazy(async () => {
  const module = await import('@/screens/memory/external-memory-browser-screen')
  return { default: module.ExternalMemoryBrowserScreen }
})

export const Route = createFileRoute('/memory')({
  ssr: false,
  component: function MemoryRoute() {
    const [tab, setTab] = useState<'memory' | 'knowledge' | 'external'>(
      'memory',
    )
    const memoryAvailable = useFeatureAvailable('memory')

    usePageTitle((__hermesT || (globalThis as any).__hermesT)('memory.title'))

    return (
      <div className="flex h-full min-h-0 flex-col">
        <Tabs
          value={tab}
          onValueChange={(value) =>
            setTab(value as 'memory' | 'knowledge' | 'external')
          }
          className="h-full min-h-0 gap-0"
        >
          <div className="border-b border-primary-200 px-3 pt-3 dark:border-neutral-800 md:px-4 md:pt-4">
            <TabsList
              variant="underline"
              className="w-full justify-start gap-1"
            >
              <TabsTab value="memory">{(__hermesT || (globalThis as any).__hermesT)('memory.tabMemory')}</TabsTab>
              <TabsTab value="knowledge">{(__hermesT || (globalThis as any).__hermesT)('memory.tabKnowledge')}</TabsTab>
              <TabsTab value="external">{(__hermesT || (globalThis as any).__hermesT)('memory.tabExternal')}</TabsTab>
            </TabsList>
          </div>

          <TabsPanel value="memory" className="min-h-0 flex-1">
            {tab === 'memory' ? (
              <Suspense
                fallback={
                  <RouteLoadingState label={(__hermesT || (globalThis as any).__hermesT)('memory.loadingBrowser')} />
                }
              >
                {memoryAvailable ? (
                  <MemoryBrowserScreen />
                ) : (
                  <BackendUnavailableState
                    feature={(__hermesT || (globalThis as any).__hermesT)('memory.feature')}
                    description={getUnavailableReason('Memory')}
                  />
                )}
              </Suspense>
            ) : null}
          </TabsPanel>

          <TabsPanel value="knowledge" className="min-h-0 flex-1">
            {tab === 'knowledge' ? (
              <Suspense
                fallback={
                  <RouteLoadingState label={(__hermesT || (globalThis as any).__hermesT)('memory.loadingKnowledge')} />
                }
              >
                <KnowledgeBrowserScreen />
              </Suspense>
            ) : null}
          </TabsPanel>

          <TabsPanel value="external" className="min-h-0 flex-1">
            {tab === 'external' ? (
              <Suspense
                fallback={
                  <RouteLoadingState label={(__hermesT || (globalThis as any).__hermesT)('memory.loadingExternal')} />
                }
              >
                <ExternalMemoryBrowserScreen />
              </Suspense>
            ) : null}
          </TabsPanel>
        </Tabs>
      </div>
    )
  },
})

function RouteLoadingState({ label }: { label: string }) {
  return (
    <div className="flex h-full min-h-[240px] items-center justify-center px-4 text-sm text-primary-500 dark:text-neutral-400">
      {label}
    </div>
  )
}

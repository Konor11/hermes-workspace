'use client'

import { useState } from 'react'
import {
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogRoot,
  DialogTitle,
} from '@/components/ui/dialog'
import { Button } from '@/components/ui/button'
import { __hermesT } from '@/lib/i18n'

type SessionRenameDialogProps = {
  open: boolean
  onOpenChange: (open: boolean) => void
  sessionTitle: string
  onSave: (newTitle: string) => void
  onCancel: () => void
}

export function SessionRenameDialog({
  open,
  onOpenChange,
  sessionTitle,
  onSave,
  onCancel,
}: SessionRenameDialogProps) {
  const [renameValue, setRenameValue] = useState(sessionTitle)

  // Keep controlled value in sync when the dialog opens with a new session
  function handleOpenChange(nextOpen: boolean) {
    if (nextOpen) setRenameValue(sessionTitle)
    onOpenChange(nextOpen)
  }

  return (
    <DialogRoot open={open} onOpenChange={handleOpenChange}>
      <DialogContent>
        <div className="p-4">
          <DialogTitle className="mb-1">{(__hermesT || (globalThis as any).__hermesT)('chat.rename')}</DialogTitle>
          <DialogDescription className="mb-4">
            Enter a new name for this session.
          </DialogDescription>
          <input
            type="text"
            value={renameValue}
            onChange={(e) => setRenameValue(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === 'Enter' && !e.nativeEvent.isComposing) {
                e.preventDefault()
                onSave(renameValue)
              }
            }}
            className="w-full rounded-lg border border-primary-200 bg-primary-50 px-3 py-2 text-sm text-primary-900 outline-none focus:border-primary-400"
            placeholder={(__hermesT || (globalThis as any).__hermesT)('chat.sessionName')}
            autoFocus
          />
          <div className="mt-4 flex justify-end gap-2">
            <DialogClose onClick={onCancel}>{(__hermesT || (globalThis as any).__hermesT)('chat.cancel')}</DialogClose>
            <Button onClick={() => onSave(renameValue)}>{(__hermesT || (globalThis as any).__hermesT)('chat.save')}</Button>
          </div>
        </div>
      </DialogContent>
    </DialogRoot>
  )
}

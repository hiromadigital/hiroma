'use client'
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import SecurityPinModal from '@/app/components/ui/SecurityPinModal'

export default function UnilevelSettings({ currentLevels }: { currentLevels: number }) {
  const router = useRouter()
  const [levels, setLevels] = useState(String(currentLevels))
  const [confirming, setConfirming] = useState(false)
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')
  const count = Number(levels)
  const valid = Number.isInteger(count) && count >= 1 && count <= 10
  async function save(securityPin: string): Promise<string | null> {
    setSaving(true)
    try {
      const response = await fetch('/api/admin/settings/unilevel', {
        method: 'PATCH', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ levels: count, securityPin }),
      })
      const result = await response.json()
      if (!response.ok) return result.error || 'Unable to save Unilevel settings.'
      setConfirming(false)
      setMessage('Unilevel settings saved.')
      router.refresh()
      return null
    } catch {
      return 'Unable to save Unilevel settings. Please try again.'
    } finally { setSaving(false) }
  }
  return <section className="rounded-xl border border-slate-200 bg-white p-5 space-y-3">
    <h2 className="font-semibold">Unilevel configuration</h2>
    <p className="text-sm text-slate-600">Each level receives up to PHP 1 per eligible bottle. New stock receipts reserve PHP 1 times the configured number of levels per bottle. Changes apply to future stock receipts and order allocations.</p>
    <form onSubmit={event => { event.preventDefault(); setConfirming(true) }} className="flex flex-wrap items-end gap-3">
      <label className="text-sm">Number of levels
        <input type="number" required min={1} max={10} step={1} value={levels} disabled={saving}
          onChange={event => setLevels(event.target.value)} className="mt-1 block rounded border border-slate-300 p-2" />
      </label>
      <p className="py-2 text-sm">New allocation per bottle <strong>{valid ? 'PHP ' + count.toFixed(2) : '—'}</strong></p>
      <button disabled={saving || !valid || count === currentLevels} className="rounded bg-[#0D1B3E] px-4 py-2 text-sm text-white disabled:opacity-40">Save configuration</button>
    </form>
    <p className="text-sm text-slate-600">Existing stock keeps its original funding. If an order uses stock funded for fewer levels, its traced funding is divided across its recorded levels, up to PHP 1 per level per bottle. Ineligible levels keep their position and their share is retained for Hiroma.</p>
    {message && <p role="status" className="text-sm">{message}</p>}
    {confirming && <SecurityPinModal title="Confirm Unilevel configuration" description="Authorize the level count and funding for future transactions."
      confirmLabel="Save configuration" loading={saving} onClose={() => setConfirming(false)} onConfirm={save} />}
  </section>
}

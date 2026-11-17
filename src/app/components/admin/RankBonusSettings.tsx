'use client'

import { useEffect, useState, type FormEvent } from 'react'
import type { RankBonus } from '@/app/lib/rankBonuses'

const endpoint = '/api/admin/rank-bonuses'

export default function RankBonusSettings() {
  const [quarter, setQuarter] = useState('')
  const [quarters, setQuarters] = useState<string[]>([])
  const [editable, setEditable] = useState(false)
  const [funded, setFunded] = useState(0)
  const [credited, setCredited] = useState(0)
  const [fundingAmount, setFundingAmount] = useState('')
  const [reference, setReference] = useState('')
  const [loading, setLoading] = useState(true)
  const [bonuses, setBonuses] = useState<RankBonus[]>([])
  const [saved, setSaved] = useState<RankBonus[]>([])
  const [pin, setPin] = useState('')
  const [message, setMessage] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    void load()
  }, [])

  async function load(period?: string) {
    setLoading(true)
    setMessage('')
    setFundingAmount('')
    setReference('')
    setPin('')
    try {
      const response = await fetch(period ? `${endpoint}?quarter=${encodeURIComponent(period)}` : endpoint)
      const data = await response.json()
      if (!response.ok) throw new Error(data.error)
      setQuarter(data.quarter)
      setBonuses(data.bonuses)
      setSaved(data.bonuses)
      setQuarters(data.quarters)
      setEditable(data.editable)
      setFunded(data.funded)
      setCredited(data.credited)
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Unable to load milestones.')
    } finally {
      setLoading(false)
    }
  }

  function edit(index: number, change: Partial<RankBonus>) {
    setBonuses(rows => rows.map((row, i) => i === index ? { ...row, ...change } : row))
  }

  async function save(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setSaving(true)
    setMessage('')
    try {
      const response = await fetch(endpoint, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          quarter, bonuses, securityPin: pin,
          funding: addingFunding ? { amount: Number(fundingAmount), reference } : undefined,
        }),
      })
      const data = await response.json()
      if (!response.ok) throw new Error(data.error)
      setBonuses(data.bonuses)
      setSaved(data.bonuses)
      setFunded(data.funded)
      setCredited(data.credited)
      setFundingAmount('')
      setReference('')
      setPin('')
      setMessage(addingFunding ? 'Funding recorded. Qualifying bonuses will be processed on the daily run.' : 'Milestones saved.')
    } catch (error) {
      setMessage(error instanceof Error ? error.message : 'Unable to save milestones.')
    } finally {
      setSaving(false)
    }
  }

  const changed = JSON.stringify(bonuses) !== JSON.stringify(saved)
  const addingFunding = Boolean(fundingAmount || reference)
  const canEdit = editable && funded === 0
  const canSave = (changed || addingFunding) && /^\d{6}$/.test(pin)
    && (!addingFunding || (Number(fundingAmount) > 0 && reference.trim().length > 0 && bonuses.length > 0))
  const money = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' })
  const input = 'mt-1 block w-full rounded border border-slate-300 p-2'
  return <section className="mb-5 rounded-xl border border-slate-200 bg-white p-5">
    <h2 className="font-semibold text-[#0D1B3E]">Quarterly Rank Advancement bonuses</h2>
    <p className="mt-1 text-sm text-gray-600">Set company-funded milestones for all packages. Each completed milestone can earn one wallet credit per quarter. Funding locks the milestone rules for that quarter.</p>
    {quarter && <label className="mt-3 block max-w-xs text-sm">Quarter
      <select className={input} value={quarter} disabled={loading || saving} onChange={event => void load(event.target.value)}>
        {quarters.map(period => <option key={period}>{period}</option>)}
      </select>
    </label>}
    {quarter && <form onSubmit={save} className="mt-4">
      <fieldset disabled={saving || loading} className="space-y-3">
        <fieldset disabled={!canEdit} className="space-y-3">
        {bonuses.map((bonus, index) => <fieldset key={index} className="grid gap-2 rounded-lg border border-slate-200 p-3 text-sm sm:grid-cols-2">
          <legend className="px-1">Milestone {index + 1}</legend>
          <label>Name<input className={input} required maxLength={60} value={bonus.name} onChange={event => edit(index, { name: event.target.value })} /></label>
          <label>Repeat-order bottles<input className={input} type="number" required min={1} max={1000000} value={bonus.bottles || ''} onChange={event => edit(index, { bottles: Number(event.target.value) })} /></label>
          <label>Paid direct referrals<input className={input} type="number" required min={0} max={1000000} value={bonus.referrals} onChange={event => edit(index, { referrals: Number(event.target.value) })} /></label>
          <label>Additional bonus (₱)<input className={input} type="number" required min={0.01} max={1000000} step={0.01} value={bonus.amount || ''} onChange={event => edit(index, { amount: Number(event.target.value) })} /></label>
          <button type="button" className="justify-self-start text-red-700" onClick={() => setBonuses(rows => rows.filter((_, i) => i !== index))}>Remove milestone</button>
        </fieldset>)}
        {canEdit && <button type="button" className="rounded border border-slate-300 px-3 py-2 text-sm disabled:opacity-50" disabled={bonuses.length >= 20} onClick={() => setBonuses(rows => [...rows, { name: '', bottles: 0, referrals: 0, amount: 0 }])}>Add milestone</button>}
        </fieldset>
        <dl className="grid gap-2 rounded-lg bg-slate-50 p-3 text-sm sm:grid-cols-3">
          <div><dt>Recorded funding</dt><dd className="font-semibold">{money.format(funded)}</dd></div>
          <div><dt>Wallet credits</dt><dd className="font-semibold">{money.format(credited)}</dd></div>
          <div><dt>Available for new credits</dt><dd className="font-semibold">{money.format(funded - credited)}</dd></div>
        </dl>
        {(canEdit || funded > 0) && bonuses.length > 0 && <div className="grid gap-2 text-sm sm:grid-cols-2">
          <label>Additional funding set aside (₱)<input className={input} type="number" min={0.01} max={1000000} step={0.01} value={fundingAmount} onChange={event => setFundingAmount(event.target.value)} /></label>
          <label>Unique funding reference<input className={input} maxLength={120} value={reference} onChange={event => setReference(event.target.value)} /></label>
          <p className="text-gray-600 sm:col-span-2">Record only funds Hiroma has already set aside for these bonuses.</p>
        </div>}
        {(changed || addingFunding) && <label className="block max-w-xs text-sm">Admin Security PIN<input className={input} type="password" autoComplete="off" inputMode="numeric" maxLength={6} value={pin} onChange={event => setPin(event.target.value.replace(/\D/g, ''))} /></label>}
        <button disabled={!canSave} className="block rounded bg-[#0D1B3E] px-4 py-2 text-sm text-white disabled:opacity-40">{saving ? 'Saving…' : addingFunding ? 'Record funding' : 'Save milestones'}</button>
      </fieldset>
    </form>}
    <p role="status" className="mt-2 text-sm">{message}</p>
  </section>
}

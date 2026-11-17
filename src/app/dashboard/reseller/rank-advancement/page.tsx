'use client'

import { useEffect, useState } from 'react'
import Link from 'next/link'
import type { RankBonus } from '@/app/lib/rankBonuses'

type Progress = {
  quarter: { label: string; start: string; endExclusive: string }
  bottles: number
  referrals: number
  bonuses: RankBonus[]
  funded: boolean
  awards: { milestone: string; creditedAt: string }[]
}

const money = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' })
const date = new Intl.DateTimeFormat('en-PH', { timeZone: 'Asia/Manila', dateStyle: 'medium' })

export default function RankAdvancementPage() {
  const [progress, setProgress] = useState<Progress>()
  const [error, setError] = useState('')

  useEffect(() => {
    fetch('/api/reseller/rank-bonuses').then(async response => {
      const data = await response.json()
      if (!response.ok) throw new Error(data.error || 'Unable to load your milestones.')
      setProgress(data)
    }).catch(() => setError('Unable to load your milestones. Please try again.'))
  }, [])

  return <main className="mx-auto max-w-4xl space-y-5 pb-10">
    <header className="flex flex-wrap items-center justify-between gap-3">
      <div>
        <h1 className="text-2xl font-bold text-[#0D1B3E]">Rank Advancement</h1>
        <p className="text-sm text-gray-600">Earn quarterly milestones through eligible repeat purchases and paid direct referrals.</p>
      </div>
      <Link href="/dashboard/reseller/orders#place-order" className="rounded-lg bg-[#0D1B3E] px-4 py-2 text-sm font-semibold text-white">Place an order</Link>
    </header>
    {error && <p role="alert" className="text-red-700">{error}</p>}
    {!progress && !error && <p role="status">Loading milestones…</p>}
    {progress && <>
      <section className="rounded-xl bg-[#0D1B3E] p-5 text-white">
        <h2 className="font-semibold">{progress.quarter.label}</h2>
        <p className="text-sm text-white/80">{date.format(new Date(progress.quarter.start))} – {date.format(new Date(Date.parse(progress.quarter.endExclusive) - 1))} · Philippine time</p>
        <dl className="mt-4 grid grid-cols-2 gap-4">
          <div><dt className="text-sm text-white/80">Eligible bottles</dt><dd className="text-xl font-bold">{progress.bottles.toLocaleString()}</dd></div>
          <div><dt className="text-sm text-white/80">Paid direct referrals</dt><dd className="text-xl font-bold">{progress.referrals.toLocaleString()}</dd></div>
        </dl>
      </section>
      <section className="rounded-xl border border-slate-200 bg-white p-5">
        <h2 className="font-semibold text-[#0D1B3E]">Quarterly milestones</h2>
        {progress.bonuses.length === 0 ? <p className="mt-2 text-sm text-gray-600">No milestones are configured for this quarter.</p> :
          <ul className="mt-3 divide-y divide-slate-200">
            {progress.bonuses.map(bonus => {
              const award = progress.awards.find(item => item.milestone === bonus.name)
              const bottles = Math.max(0, bonus.bottles - progress.bottles)
              const referrals = Math.max(0, bonus.referrals - progress.referrals)
              return <li key={bonus.name} className="flex flex-wrap justify-between gap-2 py-3">
                <div>
                  <h3 className="font-semibold">{bonus.name}</h3>
                  <p className="text-sm text-gray-600">{bonus.bottles.toLocaleString()} bottles{bonus.referrals > 0 && ` and ${bonus.referrals} paid direct referrals`}</p>
                  <p className="text-sm text-gray-600">{award ? `Credited ${date.format(new Date(award.creditedAt))}` : bottles || referrals ? [bottles > 0 && `${bottles.toLocaleString()} bottles to go`, referrals > 0 && `${referrals} paid direct referral(s) to go`].filter(Boolean).join(' · ') : progress.funded ? 'Requirements met · awaiting wallet credit' : 'Requirements met · awaiting program funding'}</p>
                </div>
                <span className="font-semibold">{money.format(bonus.amount)}</span>
              </li>
            })}
          </ul>}
        <p className="mt-4 text-sm text-gray-600">Hiroma funds these milestones separately from the weekly Product Binary pool. Qualifying bonuses are credited on the daily run as funding allows.</p>
      </section>
    </>}
  </main>
}

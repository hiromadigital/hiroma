'use client'

import { useEffect, useState } from 'react'

type Report = {
  quarter: string
  totals: Record<string, string>
  count: number
  movements: {
    kind: string; date: string; reference: string; award: string | null
    member: string; accountId: string; milestone: string | null; amount: string
    status: string; externalReference: string | null
  }[]
}

const endpoint = '/api/admin/rank-bonuses/reconciliation'
const money = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' })
const date = new Intl.DateTimeFormat('en-PH', { dateStyle: 'medium', timeStyle: 'short', timeZone: 'Asia/Manila' })
const totals = [
  ['funded', 'Recorded funding'], ['credited', 'Wallet credits'], ['available', 'Available for new credits'],
  ['walletPayable', 'Wallet payable'], ['approved', 'Approved, awaiting release'], ['released', 'Released withdrawals'],
  ['retained', 'Retained on deactivation'], ['difference', 'Reconciliation difference'],
]

export default function RankBonusReconciliation() {
  const [open, setOpen] = useState(false)
  const [month, setMonth] = useState('')
  const [report, setReport] = useState<Report>()
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [refresh, setRefresh] = useState(0)
  const query = new URLSearchParams(month ? { month } : {}).toString()

  useEffect(() => {
    if (!open) return
    const controller = new AbortController()
    fetch(`${endpoint}?${query}`, { signal: controller.signal }).then(async response => {
      const data = await response.json()
      if (!response.ok) throw new Error(data.error)
      setReport(data)
    }).catch(error => {
      if (!controller.signal.aborted) setError(error.message || 'Unable to load reconciliation.')
    }).finally(() => {
      if (!controller.signal.aborted) setLoading(false)
    })
    return () => controller.abort()
  }, [open, query, refresh])

  function reload() {
    setLoading(true)
    setError('')
    setReport(undefined)
    setRefresh(value => value + 1)
  }

  return <details className="mb-5 rounded-xl border border-slate-200 bg-white p-5" onToggle={event => {
    const expanded = event.currentTarget.open
    setOpen(expanded)
    if (expanded) reload()
  }}>
    <summary className="cursor-pointer font-semibold text-[#0D1B3E]">Rank bonus reconciliation</summary>
    {open && <div className="mt-4 space-y-4 text-sm">
      <div className="flex flex-wrap items-end gap-3">
        <label>Month in quarter<input type="month" min="2000-01" max="2099-12" value={month} onChange={event => {
          setMonth(event.target.value)
          reload()
        }} className="mt-1 block rounded border border-slate-300 p-2" /></label>
        <button type="button" onClick={reload} className="rounded border border-slate-300 px-3 py-2">Refresh</button>
        {report && <a className="rounded bg-[#0D1B3E] px-3 py-2 text-white" href={`${endpoint}?${query ? query + '&' : ''}format=csv`}>Download full CSV</a>}
      </div>
      {loading && <p role="status">Loading reconciliation…</p>}
      {error && <p role="alert" className="text-red-700">{error}</p>}
      {report && <>
        <h3 className="font-semibold">{report.quarter} reconciliation</h3>
        <dl className="grid grid-cols-2 gap-2 sm:grid-cols-4">
          {totals.map(([key, label]) => <div key={key} className={`rounded-lg p-3 ${key === 'difference' && Number(report.totals[key]) !== 0 ? 'bg-red-50 text-red-800' : 'bg-slate-50'}`}>
            <dt className="text-xs">{label}</dt><dd className="font-semibold">{money.format(Number(report.totals[key]))}</dd>
          </div>)}
        </dl>
        <p className="text-slate-600">Wallet credits reconcile to wallet payable, approved withdrawals, released withdrawals, and retention. Use the award ID to match each credit to its withdrawals or retention. Funding references reconcile against the quarter’s pooled budget.</p>
        {report.count === 0 ? <p>No funding or wallet activity for this quarter.</p> : <>
          <p className="text-slate-600">Showing {report.movements.length} of {report.count} movements · Philippine time</p>
          <div className="max-h-96 overflow-auto rounded border border-slate-200">
            <table className="w-full min-w-[800px] text-left">
              <thead className="sticky top-0 bg-slate-50"><tr>
                {['Date', 'Movement', 'Account', 'Milestone', 'Amount', 'Status', 'References'].map(label => <th key={label} scope="col" className="p-2">{label}</th>)}
              </tr></thead>
              <tbody className="divide-y divide-slate-200">
                {report.movements.map((row, index) => <tr key={index}>
                  <td className="p-2">{date.format(new Date(row.date))}</td>
                  <td className="p-2">{row.kind}</td>
                  <td className="p-2">{row.member}</td>
                  <td className="p-2">{row.milestone ?? '—'}</td>
                  <td className="p-2">{money.format(Number(row.amount))}</td>
                  <td className="p-2 capitalize">{row.status}</td>
                  <td className="break-all p-2 text-xs">{row.reference}{row.award && <div>Award {row.award}</div>}{row.externalReference && <div>External {row.externalReference}</div>}</td>
                </tr>)}
              </tbody>
            </table>
          </div>
        </>}
      </>}
    </div>}
  </details>
}

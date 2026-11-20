import Link from 'next/link'
import { Prisma } from '@prisma/client'
import { redirect } from 'next/navigation'
import { getCurrentUser } from '@/app/lib/auth'
import prisma from '@/app/lib/prisma'
import UnilevelSettings from './UnilevelSettings'

const pesos = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP' })
const reasons: Record<string, string> = {
  qualified: 'Qualified',
  no_sponsor: 'No sponsor at this level',
  inactive_account: 'Inactive or ineligible account',
  monthly_purchase_required: 'Monthly purchase requirement not met',
  recipient_unavailable_at_credit: 'Account unavailable when credit was processed',
  credited: 'Credited to wallet',
  unfunded: 'Settled — no funded amount for this level',
}

export default async function UnilevelBonusesPage({ searchParams }: {
  searchParams: Promise<{ month?: string; page?: string }>
}) {
  const user = await getCurrentUser()
  if (!user || user.role !== 'admin' || user.is_staff) redirect('/dashboard')

  const query = await searchParams
  const currentMonth = new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit',
  }).format(new Date())
  const month = query.month && /^20\d{2}-(0[1-9]|1[0-2])$/.test(query.month) ? query.month : currentMonth
  const requestedPage = Number(query.page)
  const page = Number.isSafeInteger(requestedPage) && requestedPage > 0 && requestedPage <= 100000 ? requestedPage : 1
  const [schema] = await prisma.$queryRaw<{ ready: boolean; retry_ready: boolean }[]>`
    SELECT to_regclass('public.unilevel_order_settlements') IS NOT NULL AS ready,
      to_regclass('public.unilevel_settlement_jobs') IS NOT NULL AS retry_ready
  `
  if (!schema.ready) return <main className="mx-auto max-w-5xl space-y-4 p-4">
    <Link href="/dashboard/admin/bonuses" className="underline">Back to Bonuses</Link>
    <h1 className="text-xl font-semibold">Unilevel</h1>
    <p>Unilevel tracking becomes available after the database migration.</p>
  </main>

  const { rows, policy, summary, inventory, retries } = await prisma.$transaction(async tx => {
    const rows = await tx.$queryRaw<{
      order_id: string; level: number; username: string | null; bottle_count: number
      disposition: string; funded_units: number; credited: string; retained: string; outcome: string | null
    }[]>`
      SELECT event.order_id, allocation.level, member.username, allocation.bottle_count,
             allocation.disposition, COALESCE(funding.funded_units, 0) AS funded_units,
             COALESCE(lot.original_amount,0)::text AS credited,COALESCE(retention.amount,0)::text AS retained,
             CASE WHEN lot.id IS NOT NULL THEN 'credited' WHEN retention.reason IS NOT NULL THEN retention.reason
               WHEN settlement.order_event_id IS NOT NULL THEN 'unfunded' END AS outcome
      FROM public.unilevel_order_allocations allocation
      JOIN public.product_binary_order_events event ON event.id = allocation.order_event_id
      JOIN public.product_binary_settlement_jobs job ON job.id = event.settlement_job_id
      LEFT JOIN public.unilevel_order_funding funding ON funding.order_event_id = event.id
      LEFT JOIN public.unilevel_payable_lots lot ON lot.order_event_id=event.id AND lot.level=allocation.level
      LEFT JOIN public.unilevel_retention_entries retention ON retention.order_event_id=event.id AND retention.level=allocation.level
      LEFT JOIN public.unilevel_order_settlements settlement ON settlement.order_event_id=event.id
      LEFT JOIN public.users member ON member.id = allocation.user_id
      WHERE job.qualified_at >= (${month + '-01'}::date::timestamp AT TIME ZONE 'Asia/Manila')
        AND job.qualified_at < ((${month + '-01'}::date + interval '1 month') AT TIME ZONE 'Asia/Manila')
      ORDER BY job.qualified_at DESC, event.id, allocation.level
      LIMIT 51 OFFSET ${(page - 1) * 50}
    `

    const [policy] = await tx.$queryRaw<{ levels: number }[]>`SELECT public.unilevel_level_count() AS levels`
    const [summary] = await tx.$queryRaw<{ budget: string; unfunded: string; credited: string; actual_retained: string; pending: string }[]>`
      WITH orders AS (
        SELECT event.id, COALESCE(funding.funded_amount,0) AS budget, COUNT(*) AS slots,
          MAX(allocation.bottle_count) AS bottles, COALESCE(settlement.credited_amount,0) AS credited,
          COALESCE(settlement.retained_amount,0) AS actual_retained
        FROM public.unilevel_order_allocations allocation
        JOIN public.product_binary_order_events event ON event.id=allocation.order_event_id
        JOIN public.product_binary_settlement_jobs job ON job.id=event.settlement_job_id
        LEFT JOIN public.unilevel_order_funding funding ON funding.order_event_id=event.id
        LEFT JOIN public.unilevel_order_settlements settlement ON settlement.order_event_id=event.id
        WHERE job.qualified_at >= (${month + '-01'}::date::timestamp AT TIME ZONE 'Asia/Manila')
          AND job.qualified_at < ((${month + '-01'}::date + interval '1 month') AT TIME ZONE 'Asia/Manila')
        GROUP BY event.id,funding.funded_amount,settlement.credited_amount,settlement.retained_amount
      )
      SELECT COALESCE(SUM(budget),0)::text AS budget,
        COALESCE(SUM(GREATEST(bottles*slots-budget,0)),0)::text AS unfunded,
        COALESCE(SUM(credited),0)::text AS credited,COALESCE(SUM(actual_retained),0)::text AS actual_retained,
        COALESCE(SUM(budget-credited-actual_retained),0)::text AS pending FROM orders
    `
    const [inventory] = await tx.$queryRaw<{ original: string; remaining: string; transferred: string; released: string }[]>`
      WITH stocks AS (
        SELECT earmark.amount, reserve.remaining_units::numeric * earmark.levels AS remaining,
          COALESCE((SELECT SUM(movement.units::numeric * earmark.levels)
            FROM public.product_binary_inventory_reserve_transfers movement
            WHERE movement.source_order_item_id=earmark.source_order_item_id),0) AS transferred
        FROM public.unilevel_inventory_earmarks earmark
        JOIN public.product_binary_inventory_reserves reserve USING(source_order_item_id)
      )
      SELECT COALESCE(SUM(amount),0)::text AS original, COALESCE(SUM(remaining),0)::text AS remaining,
        COALESCE(SUM(transferred),0)::text AS transferred,
        COALESCE(SUM(amount-remaining-transferred),0)::text AS released FROM stocks
    `

    const retries = schema.retry_ready ? await tx.$queryRaw<{
      order_id: string; status: string; attempts: number; last_error: string | null
    }[]>`
      SELECT job.order_id,settlement.status,settlement.attempts,settlement.last_error
      FROM public.unilevel_settlement_jobs settlement
      JOIN public.product_binary_settlement_jobs job ON job.id=settlement.settlement_job_id
      WHERE settlement.status<>'settled'
        AND job.qualified_at >= (${month + '-01'}::date::timestamp AT TIME ZONE 'Asia/Manila')
        AND job.qualified_at < ((${month + '-01'}::date + interval '1 month') AT TIME ZONE 'Asia/Manila')
      ORDER BY settlement.next_attempt_at,settlement.settlement_job_id LIMIT 21
    ` : []
    return { rows, policy, summary, inventory, retries }
  }, { isolationLevel: Prisma.TransactionIsolationLevel.RepeatableRead, timeout: 15000 })

  const pageLink = (number: number) => `?month=${month}&page=${number}`

  return <main className="mx-auto max-w-5xl space-y-4 p-4 text-[#0D1B3E]">
    <Link href="/dashboard/admin/bonuses" className="text-sm underline">Back to Bonuses</Link>
    <h1 className="text-xl font-semibold">Unilevel</h1>
    <p className="text-sm text-slate-600">Order-funded Unilevel commissions and retention. Qualification is recorded at paid delivery.</p>
    <UnilevelSettings currentLevels={policy.levels} />
    <section className="rounded-xl border border-slate-200 bg-white p-5 space-y-3">
      <h2 className="font-semibold">Current inventory funding</h2>
      <p className="text-sm text-slate-600">Overall balances across City Distributors and branches, across all months. Funding follows each stock receipt.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        {[['Total inventory earmarked', inventory.original], ['Remaining inventory reserve', inventory.remaining],
          ['Transferred through eligible sales', inventory.transferred], ['Released from inventory for other uses', inventory.released]].map(([label, amount]) =>
          <div key={label} className="rounded-lg bg-slate-50 p-3"><p className="text-sm text-slate-600">{label}</p><strong>{pesos.format(Number(amount))}</strong></div>)}
      </div>
    </section>
    <form className="flex items-end gap-3">
      <label className="text-sm">Order month (Philippine time)
        <input type="month" name="month" defaultValue={month} className="mt-1 block rounded border border-slate-300 p-2" required />
      </label>
      <button className="rounded bg-[#0D1B3E] px-4 py-2 text-sm text-white">Apply filter</button>
    </form>
    <section className="rounded-xl border border-slate-200 bg-white p-5 space-y-3">
      <h2 className="font-semibold">Unilevel funding for {month}</h2>
      <p className="text-sm text-slate-600">Selected order month. Credits and retention are recorded settlements. Each stock receipt funds its original levels; increasing the depth does not reduce those PHP 1 shares or top up older stock.</p>
      <div className="grid gap-3 sm:grid-cols-2">
        {[['Funding assigned to orders', summary.budget], ['Wallet commissions credited', summary.credited],
          ['Retained by Hiroma', summary.actual_retained], ['Funding awaiting settlement', summary.pending], ['Unfunded allocation capacity', summary.unfunded]].map(([label, amount]) =>
          <div key={label} className="rounded-lg bg-slate-50 p-3"><p className="text-sm text-slate-600">{label}</p><strong>{pesos.format(Number(amount))}</strong></div>)}
      </div>
    </section>
    {schema.retry_ready && <section className="rounded-xl border border-slate-200 bg-white p-5 space-y-3">
      <h2 className="font-semibold">Unilevel orders awaiting settlement</h2>
      <p className="text-sm text-slate-600">Selected order month. These orders retry independently of Product Binary matching. Completed Unilevel credits are not repeated.</p>
      {retries.length === 0 ? <p className="text-sm">No pending Unilevel settlement jobs for this month.</p> :
        <ul className="divide-y divide-slate-200">{retries.slice(0, 20).map(job => <li key={job.order_id} className="py-2 text-sm">
          <p className="break-all font-medium">Order {job.order_id}</p>
          <p>{job.status === 'failed' ? 'Retry pending' : 'Queued'} · {job.attempts} attempt(s)</p>
          {job.last_error && <p className="break-words text-slate-600">{job.last_error.slice(0, 300)}</p>}
        </li>)}</ul>}
      {retries.length > 20 && <p className="text-sm text-slate-600">Showing the first 20 pending orders. More orders remain in the retry queue.</p>}
    </section>}
    {rows.length === 0 ? <p className="text-sm">No Unilevel allocations recorded for this page.</p> :
      <div className="overflow-x-auto rounded-xl border border-slate-200 bg-white">
        <table className="w-full text-left text-sm">
          <thead className="bg-slate-50"><tr>
            {['Order', 'Level', 'Sponsor', 'Eligible bottles', 'Funded bottles', 'Wallet credit', 'Retained', 'Status / qualification'].map(label =>
              <th key={label} scope="col" className="px-3 py-2">{label}</th>)}
          </tr></thead>
          <tbody className="divide-y divide-slate-200">
            {rows.slice(0, 50).map(row => <tr key={`${row.order_id}-${row.level}`}>
              <td className="break-all px-3 py-2">{row.order_id}</td><td className="px-3 py-2">{row.level}</td>
              <td className="px-3 py-2">{row.username ? `@${row.username}` : '—'}</td>
              <td className="px-3 py-2">{row.bottle_count}</td><td className="px-3 py-2">{row.funded_units}</td>
              <td className="px-3 py-2">{pesos.format(Number(row.credited))}</td>
              <td className="px-3 py-2">{pesos.format(Number(row.retained))}</td>
              <td className="px-3 py-2">{row.outcome ? reasons[row.outcome] : `Pending settlement — ${reasons[row.disposition]}`}</td>
            </tr>)}
          </tbody>
        </table>
      </div>}
    <nav aria-label="Unilevel result pages" className="flex gap-4 text-sm">
      {page > 1 && <Link href={pageLink(page - 1)} className="underline">Previous</Link>}
      {rows.length > 50 && <Link href={pageLink(page + 1)} className="underline">Next</Link>}
    </nav>
  </main>
}

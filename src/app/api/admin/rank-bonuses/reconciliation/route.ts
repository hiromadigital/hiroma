import { NextRequest, NextResponse } from 'next/server'
import { getCurrentUser } from '@/app/lib/auth'
import prisma from '@/app/lib/prisma'
import { getManilaQuarter } from '@/app/lib/productBinaryQuarter'
import { rankBonusStorageReady } from '@/app/lib/rankBonuses'

type Movement = {
  kind: string; date: string; reference: string; award: string | null
  member: string; accountId: string; milestone: string | null; amount: string
  status: string; externalReference: string | null; bottles: number | null; referrals: number | null
}
type Report = { totals: Record<string, string>; movements: Movement[]; count: number }

function csvCell(value: unknown) {
  const raw = String(value ?? '')
  const safe = /^[\s\uFEFF]*[=+\-@]|^[\t\r\n]/.test(raw) ? "'" + raw : raw
  return '"' + safe.replaceAll('"', '""') + '"'
}

export async function GET(req: NextRequest) {
  const user = await getCurrentUser()
  if (user?.role !== 'admin' || user.is_staff) return NextResponse.json({ error: 'Admin owner access is required.' }, { status: 403 })
  if (!await rankBonusStorageReady()) return NextResponse.json({ error: 'Rank Advancement storage is unavailable.' }, { status: 503 })

  const month = req.nextUrl.searchParams.get('month')
  if (month && !/^20\d{2}-(0[1-9]|1[0-2])$/.test(month)) {
    return NextResponse.json({ error: 'Choose a valid month.' }, { status: 400 })
  }
  const quarter = getManilaQuarter(month ? new Date(month + '-01T00:00:00+08:00') : undefined)
  const download = req.nextUrl.searchParams.get('format') === 'csv'
  const [report] = await prisma.$queryRaw<Report[]>`
    WITH funding AS (
      SELECT * FROM rank_bonus_funding WHERE quarter_start = ${quarter.start}::timestamptz
    ), awards AS (
      SELECT * FROM rank_bonus_awards WHERE quarter_start = ${quarter.start}::timestamptz
    ), withdrawals AS (
      SELECT c.award_id, c.amount, p.id, p.status, p.transaction_number, p.external_reference,
             COALESCE(p.released_at, p.processed_at AT TIME ZONE 'UTC', p.requested_at AT TIME ZONE 'UTC') AS event_at
      FROM rank_bonus_payout_consumptions c JOIN awards a ON a.id = c.award_id
      JOIN payouts p ON p.id = c.payout_id
    ), forfeitures AS (
      SELECT f.* FROM payable_lot_forfeitures f JOIN awards a ON a.id = f.rank_bonus_lot_id
    ), movements AS (
      SELECT 'Funding' AS kind, f.created_at AS date, f.reference, NULL::text AS award,
             u.full_name AS member, u.id AS "accountId", NULL::text AS milestone, f.amount,
             'Recorded' AS status, NULL::text AS "externalReference", NULL::integer AS bottles, NULL::integer AS referrals
      FROM funding f JOIN users u ON u.id = f.funded_by
      UNION ALL
      SELECT 'Wallet credit', a.allocated_at, a.commission_id, a.id::text, u.full_name, u.id, a.milestone,
             a.original_amount, 'Credited', NULL, a.bottles, a.referrals
      FROM awards a JOIN users u ON u.id = a.user_id
      UNION ALL
      SELECT 'Withdrawal', w.event_at, COALESCE(w.transaction_number, w.id), a.id::text, u.full_name, u.id, a.milestone,
             w.amount, w.status::text, w.external_reference, NULL, NULL
      FROM withdrawals w JOIN awards a ON a.id = w.award_id JOIN users u ON u.id = a.user_id
      UNION ALL
      SELECT 'Deactivation retention', f.created_at, f.deactivation_event_id, a.id::text, u.full_name, u.id, a.milestone,
             f.amount, 'Retained', NULL, NULL, NULL
      FROM forfeitures f JOIN awards a ON a.id = f.rank_bonus_lot_id JOIN users u ON u.id = a.user_id
    ), sums AS (
      SELECT COALESCE((SELECT SUM(amount) FROM funding), 0) AS funded,
             COALESCE((SELECT SUM(original_amount) FROM awards), 0) AS credited,
             COALESCE((SELECT SUM(remaining_amount) FROM awards), 0) AS unallocated,
             COALESCE((SELECT SUM(amount) FROM withdrawals WHERE status = 'approved'), 0) AS approved,
             COALESCE((SELECT SUM(amount) FROM withdrawals WHERE status = 'released'), 0) AS released,
             COALESCE((SELECT SUM(amount) FROM forfeitures), 0) AS retained
    )
    SELECT jsonb_build_object(
      'funded', funded::text, 'credited', credited::text, 'available', (funded - credited)::text,
      'walletPayable', unallocated::text, 'approved', approved::text, 'released', released::text,
      'retained', retained::text, 'difference', (credited - unallocated - approved - released - retained)::text
    ) AS totals,
    (SELECT COUNT(*)::int FROM movements) AS count,
    COALESCE((
      SELECT jsonb_agg(to_jsonb(row) || jsonb_build_object('amount', row.amount::text)
                       ORDER BY row.date DESC, row.kind, row.reference, row.award)
      FROM (SELECT * FROM movements ORDER BY date DESC, kind, reference, award LIMIT ${download ? null : 50}::integer) row
    ), '[]'::jsonb) AS movements
    FROM sums
  `

  const headers = { 'Cache-Control': 'no-store' }
  if (!download) return NextResponse.json({ quarter: quarter.label, ...report }, { headers })
  const rows = [
    ['Quarter', quarter.label],
    ['Recorded funding', report.totals.funded],
    ['Wallet credits', report.totals.credited],
    ['Available for new credits', report.totals.available],
    ['Wallet payable', report.totals.walletPayable],
    ['Approved withdrawals awaiting release', report.totals.approved],
    ['Released withdrawals', report.totals.released],
    ['Deactivation retention', report.totals.retained],
    ['Reconciliation difference', report.totals.difference],
    [],
    ['Movement', 'Date (UTC)', 'Reference', 'Award ID', 'Account name', 'Account ID', 'Milestone', 'Amount (PHP)', 'Status', 'External reference', 'Eligible bottles', 'Paid direct referrals'],
    ...report.movements.map(row => [
      row.kind, row.date, row.reference, row.award, row.member, row.accountId, row.milestone,
      row.amount, row.status, row.externalReference, row.bottles, row.referrals,
    ]),
  ]
  return new Response(rows.map(row => row.map(csvCell).join(',')).join('\r\n'), {
    headers: {
      ...headers,
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': `attachment; filename="rank-bonus-${quarter.year}-q${quarter.quarter}.csv"`,
    },
  })
}

import { NextRequest, NextResponse } from 'next/server'
import { getCurrentUser } from '@/app/lib/auth'
import { createRequiredAuditLog, getClientInfo } from '@/app/lib/auditLog'
import prisma from '@/app/lib/prisma'
import { getManilaQuarter } from '@/app/lib/productBinaryQuarter'
import { rankBonusStorageReady, getRankBonuses, parseRankBonuses, rankBonusKey, validRankBonusAmount } from '@/app/lib/rankBonuses'
import { getSensitiveResellerPinFailure, isSensitiveResellerPinAccepted, verifyResellerSecurityPin } from '@/app/lib/resellerSecurityPin'

function availableQuarters() {
  const current = getManilaQuarter()
  return [current, getManilaQuarter(new Date(current.start.getTime() - 1))]
}

export async function GET(req: NextRequest) {
  const user = await getCurrentUser()
  if (user?.role !== 'admin' || user.is_staff) return NextResponse.json({ error: 'Admin owner access is required.' }, { status: 403 })
  if (!await rankBonusStorageReady()) return NextResponse.json({ error: 'Apply the Rank Advancement wallet migration first.' }, { status: 503 })
  const quarters = availableQuarters()
  const quarter = quarters.find(period => period.label === req.nextUrl.searchParams.get('quarter')) ?? quarters[0]
  return NextResponse.json({
    quarter: quarter.label,
    quarters: quarters.map(period => period.label),
    editable: quarter === quarters[0],
    ...await getRankBonuses(quarter),
  })
}

export async function PATCH(req: NextRequest) {
  const user = await getCurrentUser()
  if (user?.role !== 'admin' || user.is_staff || req.headers.get('origin') !== req.nextUrl.origin) {
    return NextResponse.json({ error: 'Admin owner access and a valid request origin are required.' }, { status: 403 })
  }

  const body = await req.json().catch(() => null)
  const bonuses = parseRankBonuses(body?.bonuses)
  if (!bonuses) return NextResponse.json({ error: 'Enter valid milestone names, bottle counts, referral counts, and bonus amounts.' }, { status: 400 })
  if (!await rankBonusStorageReady()) return NextResponse.json({ error: 'Apply the Rank Advancement wallet migration first.' }, { status: 503 })
  const quarters = availableQuarters()
  const quarter = quarters.find(period => period.label === body.quarter)
  if (!quarter) return NextResponse.json({ error: 'The quarter changed. Reload before saving.' }, { status: 409 })
  const funding = body.funding
  const reference = typeof funding?.reference === 'string' ? funding.reference.trim() : ''
  if (funding && (!validRankBonusAmount(funding.amount) || !reference || reference.length > 120)) {
    return NextResponse.json({ error: 'Enter the amount already set aside by Hiroma and its unique funding reference.' }, { status: 400 })
  }

  const pin = await verifyResellerSecurityPin(user.id, body.securityPin)
  if (!isSensitiveResellerPinAccepted(pin)) {
    const failure = getSensitiveResellerPinFailure(pin)
    return NextResponse.json({ error: failure.error, status: failure.status }, { status: failure.status })
  }

  const key = rankBonusKey(quarter)
  const value = JSON.stringify(bonuses)
  const conflict = await prisma.$transaction(async tx => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${key}))`
    const [program] = await tx.$queryRaw<{ milestones: unknown }[]>`
      SELECT milestones FROM rank_bonus_programs WHERE quarter_start = ${quarter.start}::timestamptz
    `
    if (program && JSON.stringify(parseRankBonuses(program.milestones)) !== value) {
      return 'Funded milestones are locked for this quarter.'
    }
    if (!program && quarter !== quarters[0]) return 'Only an existing funded program can be topped up for the previous quarter.'
    if (funding && bonuses.length === 0) return 'Add at least one milestone before funding the program.'

    if (funding) {
      await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${'rank-bonus-funding:' + reference}))`
      const [existing] = await tx.$queryRaw<{ same: boolean }[]>`
        SELECT quarter_start = ${quarter.start}::timestamptz AND amount = ${funding.amount}::numeric AS same
        FROM rank_bonus_funding WHERE reference = ${reference}
      `
      if (existing) return existing.same ? null : 'That funding reference has already been used.'
      if (!program) {
        await tx.$executeRaw`
          INSERT INTO rank_bonus_programs(quarter_start, quarter_end, milestones)
          VALUES (${quarter.start}::timestamptz, ${quarter.endExclusive}::timestamptz, ${value}::jsonb)
        `
      }
      await tx.$executeRaw`
        INSERT INTO rank_bonus_funding(reference, quarter_start, amount, funded_by)
        VALUES (${reference}, ${quarter.start}::timestamptz, ${funding.amount}::numeric, ${user.id})
      `
    }

    const previous = await tx.systemSetting.findUnique({ where: { key } })
    if (!funding && (previous?.value ?? '[]') === value) return null
    await tx.systemSetting.upsert({
      where: { key },
      create: { key, value, updated_by: user.id },
      update: { value, updated_by: user.id },
    })
    await createRequiredAuditLog(tx, {
      user_id: user.id,
      user_name: user.full_name,
      user_role: 'admin',
      activity_type: funding ? 'rank_bonus_funded' : 'rank_bonus_milestones_changed',
      category: 'commission',
      description: funding ? `Recorded PHP ${funding.amount} in Hiroma funding for ${quarter.label}.` : `Updated Rank Advancement milestones for ${quarter.label}.`,
      metadata: { quarter: quarter.label, previous: previous?.value, bonuses, funding: funding ? { amount: funding.amount, reference } : undefined },
      risk_level: 'high',
      status: 'completed',
      ...getClientInfo(req),
    })
    return null
  })
  if (conflict) return NextResponse.json({ error: conflict }, { status: 409 })
  return NextResponse.json({ quarter: quarter.label, ...await getRankBonuses(quarter) })
}

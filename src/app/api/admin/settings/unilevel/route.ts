import { NextRequest, NextResponse } from 'next/server'
import { getCurrentUser } from '@/app/lib/auth'
import { createRequiredAuditLog, getClientInfo } from '@/app/lib/auditLog'
import prisma from '@/app/lib/prisma'
import { getSensitiveResellerPinFailure, isSensitiveResellerPinAccepted, verifyResellerSecurityPin } from '@/app/lib/resellerSecurityPin'

const settingKey = 'unilevel_levels'
async function getLevels() {
  const [row] = await prisma.$queryRaw<{ levels: number }[]>`SELECT public.unilevel_level_count() AS levels`
  return row.levels
}

async function getOwner() {
  const user = await getCurrentUser()
  return user?.role === 'admin' && user.is_staff !== true ? user : null
}

export async function GET() {
  if (!await getOwner()) return NextResponse.json({ error: 'Admin owner access is required.' }, { status: 403 })
  return NextResponse.json({ levels: await getLevels() }, {
    headers: { 'Cache-Control': 'no-store' },
  })
}

export async function PATCH(req: NextRequest) {
  const user = await getOwner()
  if (!user || req.headers.get('origin') !== req.nextUrl.origin) {
    return NextResponse.json({ error: 'Admin owner access and a valid request origin are required.' }, { status: 403 })
  }

  const body = await req.json().catch(() => null)
  const levels: unknown = body?.levels
  if (typeof levels !== 'number' || !Number.isInteger(levels) || levels < 1 || levels > 10) {
    return NextResponse.json({ error: 'Enter a whole number from 1 to 10 levels.' }, { status: 400 })
  }
  const pin = await verifyResellerSecurityPin(user.id, body.securityPin)
  if (!isSensitiveResellerPinAccepted(pin)) {
    const failure = getSensitiveResellerPinFailure(pin)
    return NextResponse.json({ error: failure.error }, { status: failure.status })
  }

  await prisma.$transaction(async tx => {
    await tx.$executeRaw`SELECT pg_advisory_xact_lock(hashtext(${settingKey}))`
    const previous = await tx.systemSetting.findUnique({ where: { key: settingKey } })
    if (Number(previous?.value ?? 5) === levels) return
    await tx.systemSetting.upsert({
      where: { key: settingKey },
      create: { key: settingKey, value: String(levels), updated_by: user.id },
      update: { value: String(levels), updated_by: user.id },
    })
    await createRequiredAuditLog(tx, {
      user_id: user.id,
      user_name: user.full_name,
      user_role: 'admin',
      activity_type: 'unilevel_policy_changed',
      category: 'commission',
      description: `Set Unilevel to ${levels} levels at PHP 1 per level.`,
      metadata: { previous: Number(previous?.value ?? 5), levels, amountPerLevel: 1 },
      risk_level: 'high',
      status: 'completed',
      ...getClientInfo(req),
    })
  })
  return NextResponse.json({ levels })
}

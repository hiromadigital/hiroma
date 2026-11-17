import { NextResponse } from 'next/server'
import { getCurrentUser } from '@/app/lib/auth'
import { getManilaQuarter } from '@/app/lib/productBinaryQuarter'
import { rankBonusStorageReady, getRankBonuses, getRankBonusProgress } from '@/app/lib/rankBonuses'

export async function GET() {
  const user = await getCurrentUser()
  if (user?.role !== 'reseller') return NextResponse.json({ error: 'Reseller access is required.' }, { status: 403 })
  if (!await rankBonusStorageReady()) return NextResponse.json({ error: 'Apply the Rank Advancement wallet migration first.' }, { status: 503 })
  const quarter = getManilaQuarter()
  const [program, progress] = await Promise.all([getRankBonuses(quarter), getRankBonusProgress(user.id, quarter)])
  return NextResponse.json({ quarter, bonuses: program.bonuses, funded: program.funded > 0, ...progress })
}

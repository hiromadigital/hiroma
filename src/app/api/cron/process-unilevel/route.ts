import { NextRequest, NextResponse } from 'next/server'
import { settlePendingUnilevelOrders } from '@/app/lib/unilevelSettlement'

export const maxDuration = 60

export async function GET(req: NextRequest) {
  const secret = process.env.CRON_SECRET
  if (!secret || req.headers.get('authorization') !== `Bearer ${secret}`) {
    return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
  }
  try {
    const result = await settlePendingUnilevelOrders(Date.now() + 45_000)
    return NextResponse.json({ success: !result.held && result.failed === 0, ...result }, {
      status: result.held ? 503 : 200,
    })
  } catch (error) {
    console.error('[UNILEVEL RETRY WORKER]', error)
    return NextResponse.json({ error: 'Unilevel retry worker failed.' }, { status: 500 })
  }
}

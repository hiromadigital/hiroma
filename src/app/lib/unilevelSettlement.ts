import { isProductBinaryReleaseApproved } from '@/app/lib/productBinaryReleaseGate'
import prisma from '@/app/lib/prisma'

type SettlementStatus = 'settled' | 'already_settled' | 'not_eligible'

export async function processDeliveredUnilevelOrder(orderId: string) {
  const [schema] = await prisma.$queryRaw<{ ready: boolean }[]>`
    SELECT to_regprocedure('public.process_unilevel_order(text)') IS NOT NULL AS ready
  `
  if (!schema.ready) return { processed: false, reason: 'migration_required' as const }
  if (!await isProductBinaryReleaseApproved(prisma)) {
    return { processed: false, reason: 'release_approval_pending' as const }
  }
  try {
    const [result] = await prisma.$transaction(async tx => {
      await tx.$queryRaw`SELECT set_config('statement_timeout','9000',true)`
      return tx.$queryRaw<{ status: SettlementStatus }[]>`
        SELECT public.process_unilevel_order(${orderId}::text) AS status
      `
    }, { maxWait: 1000, timeout: 10_000 })
    return { processed: result.status === 'settled', reason: result.status }
  } catch (error) {
    // Retry metadata is committed independently from a rolled-back settlement.
    try {
      const failure = error instanceof Error ? error.message : 'Unilevel settlement failed'
      await prisma.$executeRaw`SELECT public.record_unilevel_retry(${orderId}::text,${failure.slice(0, 2000)}::text)`
    } catch (retryError) {
      console.error('[UNILEVEL RETRY RECORD]', retryError)
    }
    throw error
  }
}

export async function settlePendingUnilevelOrders(deadline = Date.now() + 45_000) {
  const [schema] = await prisma.$queryRaw<{ ready: boolean }[]>`
    SELECT to_regprocedure('public.claim_pending_unilevel_orders(integer)') IS NOT NULL AS ready
  `
  if (!schema.ready) return { attempted: 0, settled: 0, failed: 0, held: true, reason: 'migration_required' }
  if (!await isProductBinaryReleaseApproved(prisma)) {
    return { attempted: 0, settled: 0, failed: 0, held: true, reason: 'release_approval_pending' }
  }
  let attempted = 0
  let settled = 0
  let failed = 0
  while (deadline - Date.now() >= 12_000) {
    // Lease only the order this invocation has time to attempt. An interrupted
    // worker leaves a durable job that becomes claimable after the short lease.
    const orders = await prisma.$queryRaw<{ order_id: string }[]>`
      SELECT * FROM public.claim_pending_unilevel_orders(1)
    `
    if (!orders.length) break
    attempted++
    try {
      const result = await processDeliveredUnilevelOrder(orders[0].order_id)
      if (result.reason === 'migration_required' || result.reason === 'release_approval_pending') {
        return { attempted, settled, failed, held: true, reason: result.reason }
      }
      if (result.reason === 'settled' || result.reason === 'already_settled') settled++
    } catch (error) {
      failed++
      console.error('[UNILEVEL SETTLEMENT]', { orderId: orders[0].order_id, error })
    }
  }
  return { attempted, settled, failed, held: false }
}

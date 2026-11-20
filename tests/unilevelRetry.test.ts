import assert from 'node:assert/strict'
import test from 'node:test'
import type { PrismaClient } from '@prisma/client'
import type { NextRequest } from 'next/server'

test('Unilevel retry isolates a failed order and retries it without duplicating a completed order', async () => {
  const original = globalThis.prisma
  const originalError = console.error
  let pending = ['failure', 'healthy']
  const settled = new Set<string>()
  const failures: string[] = []
  let shouldFail = true
  const fake = {
    async $queryRaw(sql: TemplateStringsArray) {
      const query = sql.join('?')
      if (query.includes('to_regprocedure')) return [{ ready: true }]
      if (query.includes('claim_pending_unilevel_orders')) {
        const order = pending.shift()
        return order ? [{ order_id: order }] : []
      }
      assert.fail(`Unexpected query: ${query}`)
    },
    async $executeRaw(sql: TemplateStringsArray, order: string) {
      assert.match(sql.join('?'), /record_unilevel_retry/)
      failures.push(order)
    },
    async $transaction(run: (tx: unknown) => Promise<unknown>) {
      return run({ async $queryRaw(sql: TemplateStringsArray, order: string) {
        const query = sql.join('?')
        if (query.includes('set_config')) return []
        assert.match(query, /process_unilevel_order/)
        if (order === 'failure' && shouldFail) throw new Error('temporary database failure')
        const status = settled.has(order) ? 'already_settled' : 'settled'
        settled.add(order)
        return [{ status }]
      } })
    },
  }
  globalThis.prisma = fake as unknown as PrismaClient
  console.error = () => {}
  try {
    const { settlePendingUnilevelOrders } = await import('../src/app/lib/unilevelSettlement')
    assert.deepEqual(await settlePendingUnilevelOrders(), { attempted: 2, settled: 1, failed: 1, held: false })
    assert.deepEqual([...settled], ['healthy'])
    assert.deepEqual(failures, ['failure'])
    shouldFail = false
    pending = ['failure', 'healthy']
    assert.deepEqual(await settlePendingUnilevelOrders(), { attempted: 2, settled: 2, failed: 0, held: false })
    assert.equal(settled.size, 2)
    assert.deepEqual(await settlePendingUnilevelOrders(Date.now()), { attempted: 0, settled: 0, failed: 0, held: false })
  } finally {
    globalThis.prisma = original
    console.error = originalError
  }
})

test('independent Unilevel cron rejects missing or incorrect authentication', async () => {
  const previous = process.env.CRON_SECRET
  process.env.CRON_SECRET = 'isolated-unilevel-worker-secret'
  try {
    const { GET } = await import('../src/app/api/cron/process-unilevel/route')
    for (const authorization of [undefined, 'Bearer incorrect']) {
      const request = new Request('http://localhost/api/cron/process-unilevel', {
        headers: authorization ? { authorization } : {},
      })
      assert.equal((await GET(request as NextRequest)).status, 401)
    }
  } finally {
    if (previous === undefined) delete process.env.CRON_SECRET
    else process.env.CRON_SECRET = previous
  }
})

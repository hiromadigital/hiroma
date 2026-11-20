import assert from 'node:assert/strict'
import test from 'node:test'
import { createUnilevelDatabase } from './fixtures/unilevelFixture'
import { PrismaClient } from '@prisma/client'
import { PrismaPg } from '@prisma/adapter-pg'
import { randomUUID } from 'node:crypto'
import { Client } from 'pg'

const connection = process.env.UNILEVEL_INTEGRATION_DATABASE_URL

test('Unilevel funded settlement and retry boundaries', { skip: !connection }, async t => {
  const fixture = await createUnilevelDatabase(connection!)
  const previousUrl = process.env.DATABASE_URL
  process.env.DATABASE_URL = fixture.runtimeUrl
  const originalPrisma = globalThis.prisma
  const prisma = new PrismaClient({ adapter: new PrismaPg({ connectionString: fixture.runtimeUrl, max: 4 }) })
  globalThis.prisma = prisma
  const { processDeliveredUnilevelOrder } = await import('../src/app/lib/unilevelSettlement')
  const { processDeliveredProductBinaryOrder } = await import('../src/app/lib/productBinary')
  const settle = async (order: string) => {
    const result = await processDeliveredUnilevelOrder(order)
    assert.equal(result.reason, 'settled')
  }
  const totals = async (order: string) => (await fixture.runtime.query(`
    SELECT settlement.funded_amount::float funded,settlement.credited_amount::float credited,
      settlement.retained_amount::float retained
    FROM unilevel_order_settlements settlement JOIN product_binary_order_events event ON event.id=settlement.order_event_id
    WHERE event.order_id=$1`, [order])).rows[0]
  try {
    await t.test('pays all five qualified fixed sponsor positions before binary matching completes', async () => {
      const f = await fixture.memberFixture()
      await f.stock(100)
      for (let i = 1; i <= 5; i++) await f.qualifySponsor(i)
      const sale = await f.order(f.members[0], 10)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 50, credited: 50, retained: 0 })
      assert.equal((await fixture.runtime.query('SELECT status FROM product_binary_settlement_jobs WHERE order_id=$1', [sale])).rows[0].status, 'pending')
      const credits = await fixture.runtime.query(`SELECT lot.level,lot.original_amount::float amount,commission.rule_version
        FROM unilevel_payable_lots lot JOIN commissions commission ON commission.id=lot.commission_id
        JOIN product_binary_order_events event ON event.id=lot.order_event_id WHERE event.order_id=$1 ORDER BY lot.level`, [sale])
      assert.deepEqual(credits.rows.map(row => row.amount), [10, 10, 10, 10, 10])
      assert.ok(credits.rows.every(row => row.rule_version === 'unilevel-v2'))
      const before = (await fixture.runtime.query('SELECT count(*)::int n FROM product_binary_inventory_reserve_transfers')).rows[0].n
      assert.equal((await processDeliveredProductBinaryOrder(sale)).processed, true)
      assert.equal((await fixture.runtime.query('SELECT count(*)::int n FROM product_binary_inventory_reserve_transfers')).rows[0].n, before)
      assert.equal((await processDeliveredUnilevelOrder(sale)).reason, 'already_settled')
      assert.equal((await processDeliveredProductBinaryOrder(sale)).reason, 'already_processed')
      assert.equal((await fixture.runtime.query('SELECT total_pu FROM reseller_profiles WHERE user_id=$1', [f.members[0]])).rows[0].total_pu, 10)
    })

    await t.test('Branch accepted stock funds the same PHP1-per-level credits', async () => {
      const f = await fixture.memberFixture(5, true)
      await f.stock(20)
      await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
    })

    await t.test('an unqualified level retains its share without compression to level six', async () => {
      const f = await fixture.memberFixture(6)
      await fixture.owner.query("UPDATE system_settings SET value='5' WHERE key='unilevel_levels'")
      await f.stock(30)
      await f.qualifySponsor(1); await f.qualifySponsor(3); await f.qualifySponsor(6)
      const sale = await f.order(f.members[0], 3)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 15, credited: 6, retained: 9 })
      assert.equal((await fixture.runtime.query(`SELECT count(*)::int n FROM unilevel_payable_lots lot
        JOIN product_binary_order_events e ON e.id=lot.order_event_id WHERE e.order_id=$1 AND lot.user_id=$2`, [sale, f.members[6]])).rows[0].n, 0)
    })

    await t.test('previous Manila-month purchase does not qualify the current sale', async () => {
      const f = await fixture.memberFixture()
      await f.stock(20)
      await f.qualifySponsor(1, true)
      const sale = await f.order(f.members[0], 2)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 0, retained: 10 })
      const reason = await fixture.runtime.query(`SELECT a.disposition FROM unilevel_order_allocations a
        JOIN product_binary_order_events e ON e.id=a.order_event_id WHERE e.order_id=$1 AND a.level=1`, [sale])
      assert.equal(reason.rows[0].disposition, 'monthly_purchase_required')
    })

    await t.test('later monthly qualification cannot rewrite an earlier purchase snapshot', async () => {
      const f = await fixture.memberFixture()
      await f.stock(20)
      const sale = await f.order(f.members[0], 2)
      await f.qualifySponsor(1)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 0, retained: 10 })
    })

    await t.test('old five-level stock pays full original slots after depth increases to ten', async () => {
      const f = await fixture.memberFixture(10)
      await fixture.owner.query("UPDATE system_settings SET value='5' WHERE key='unilevel_levels'")
      await f.stock(10)
      await fixture.owner.query("UPDATE system_settings SET value='10' WHERE key='unilevel_levels'")
      await f.stock(30)
      for (let i = 1; i <= 10; i++) await f.qualifySponsor(i)
      const sale = await f.order(f.members[0], 12)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 70, credited: 70, retained: 0 })
      const rows = await fixture.runtime.query(`SELECT lot.level,lot.original_amount::float amount FROM unilevel_payable_lots lot
        JOIN product_binary_order_events e ON e.id=lot.order_event_id WHERE e.order_id=$1 ORDER BY lot.level`, [sale])
      assert.deepEqual(rows.rows.map(row => row.amount), [12, 12, 12, 12, 12, 2, 2, 2, 2, 2])
    })

    await t.test('concurrent retries credit and transfer stock only once', async () => {
      const f = await fixture.memberFixture()
      await f.stock(20); await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      const results = await Promise.all(Array.from({ length: 4 }, () => processDeliveredUnilevelOrder(sale)))
      assert.equal(results.filter(result => result.processed).length, 1)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
      const count = await fixture.runtime.query(`SELECT count(*)::int n FROM commissions c
        JOIN unilevel_payable_lots lot ON lot.commission_id=c.id JOIN product_binary_order_events e ON e.id=lot.order_event_id WHERE e.order_id=$1`, [sale])
      assert.equal(count.rows[0].n, 1)
    })

    await t.test('reducing the current depth preserves the original ten funded levels on older stock', async () => {
      const f = await fixture.memberFixture(10)
      await f.stock(10)
      await fixture.owner.query("UPDATE system_settings SET value='5' WHERE key='unilevel_levels'")
      await f.stock(30)
      for (let i = 1; i <= 10; i++) await f.qualifySponsor(i)
      const sale = await f.order(f.members[0], 12)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 110, credited: 110, retained: 0 })
      const rows = await fixture.runtime.query(`SELECT lot.level,lot.original_amount::float amount FROM unilevel_payable_lots lot
        JOIN product_binary_order_events e ON e.id=lot.order_event_id WHERE e.order_id=$1 ORDER BY lot.level`, [sale])
      assert.deepEqual(rows.rows.map(row => row.amount), [12, 12, 12, 12, 12, 10, 10, 10, 10, 10])
    })

    await t.test('delivered but unpaid orders create no credits', async () => {
      const f = await fixture.memberFixture()
      await f.stock(20)
      const sale = await f.order(f.members[0], 2, false)
      assert.equal((await processDeliveredUnilevelOrder(sale)).reason, 'not_eligible')
      assert.equal(await totals(sale), undefined)
    })

    await t.test('one unavailable recipient is retained without blocking other levels', async () => {
      const f = await fixture.memberFixture()
      await f.stock(30); await f.qualifySponsor(1); await f.qualifySponsor(2)
      const sale = await f.order(f.members[0], 2)
      // Owner-only setup of the post-qualification status transition.
      await fixture.owner.query('BEGIN; SET LOCAL session_replication_role=replica')
      await fixture.owner.query("UPDATE users SET status='suspended' WHERE id=$1", [f.members[1]])
      await fixture.owner.query('COMMIT')
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
    })

    await t.test('binary completion cannot be forged for a prepared order with a missing ancestor', async () => {
      const f = await fixture.memberFixture(5, false, true)
      await f.stock(20); await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      await settle(sale)
      await assert.rejects(fixture.runtime.query("UPDATE product_binary_settlement_jobs SET status='completed',completed_at=now() WHERE order_id=$1", [sale]), /every eligible ancestor/)
      assert.equal((await fixture.runtime.query('SELECT status FROM product_binary_settlement_jobs WHERE order_id=$1', [sale])).rows[0].status, 'pending')
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
      assert.equal((await processDeliveredProductBinaryOrder(sale)).processed, true)
    })

    await t.test('binary matching failure preserves the separately committed Unilevel credit', async () => {
      const f = await fixture.memberFixture(5, false, true)
      await f.stock(20); await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      // Fault injection is limited to this disposable database and recipient.
      await fixture.owner.query(`CREATE FUNCTION public.unilevel_test_matching_failure() RETURNS trigger
        LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated matching failure'; END $$;
        REVOKE ALL ON FUNCTION public.unilevel_test_matching_failure() FROM PUBLIC;
        CREATE TRIGGER unilevel_test_matching_failure BEFORE INSERT ON public.product_binary_pair_events
        FOR EACH ROW WHEN (NEW.source_user_id='${f.members[0]}') EXECUTE FUNCTION public.unilevel_test_matching_failure()`)
      try {
        await assert.rejects(processDeliveredProductBinaryOrder(sale), /simulated matching failure/)
        assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
        assert.equal((await fixture.runtime.query('SELECT status FROM product_binary_settlement_jobs WHERE order_id=$1', [sale])).rows[0].status, 'failed')
      } finally {
        await fixture.owner.query('DROP TRIGGER unilevel_test_matching_failure ON public.product_binary_pair_events; DROP FUNCTION public.unilevel_test_matching_failure()')
      }
      assert.equal((await processDeliveredProductBinaryOrder(sale)).processed, true)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
    })

    await t.test('weekly preparation waits for matching on a funded source and resumes after matching completes', async () => {
      const f = await fixture.memberFixture(5, false, true)
      await f.stock(20); await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      await settle(sale)
      // Move this disposable fixture's source to a past week to simulate the
      // Sunday cutoff. Production history remains immutable to the runtime.
      await fixture.owner.query("INSERT INTO product_binary_pool_weeks(week_start,max_rate_centavos) VALUES('2020-08-03',500)")
      await fixture.owner.query('BEGIN; SET LOCAL session_replication_role=replica')
      await fixture.owner.query(`UPDATE product_binary_pool_orders source SET week_start='2020-08-03'
        FROM product_binary_order_events event WHERE source.order_event_id=event.id AND event.order_id=$1`, [sale])
      await fixture.owner.query('COMMIT')
      assert.equal((await fixture.runtime.query("SELECT (close_product_binary_pool_week('2020-08-03')).closed_at IS NOT NULL closed")).rows[0].closed, false)
      assert.equal((await fixture.runtime.query("SELECT count(*)::int n FROM product_binary_week_preparation WHERE week_start='2020-08-03'")).rows[0].n, 0)
      assert.equal((await processDeliveredProductBinaryOrder(sale)).processed, true)
      let closed = false
      for (let attempt = 0; attempt < 10 && !closed; attempt++) {
        closed = (await fixture.runtime.query("SELECT (close_product_binary_pool_week('2020-08-03')).closed_at IS NOT NULL closed")).rows[0].closed
      }
      assert.equal(closed, true)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
    })

    await t.test('a failed Unilevel wallet credit cannot roll back binary matching', async () => {
      const f = await fixture.memberFixture(5, false, true)
      await f.stock(20); await f.qualifySponsor(1)
      const sale = await f.order(f.members[0], 2)
      await fixture.owner.query(`CREATE FUNCTION public.unilevel_test_wallet_failure() RETURNS trigger
        LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'simulated Unilevel wallet failure'; END $$;
        REVOKE ALL ON FUNCTION public.unilevel_test_wallet_failure() FROM PUBLIC;
        CREATE TRIGGER unilevel_test_wallet_failure BEFORE INSERT ON public.commissions
        FOR EACH ROW WHEN (NEW.type='multilevel' AND NEW.source_user_id='${f.members[0]}')
        EXECUTE FUNCTION public.unilevel_test_wallet_failure()`)
      const originalError = console.error
      console.error = () => {}
      try {
        assert.equal((await processDeliveredProductBinaryOrder(sale)).processed, true)
        assert.equal(await totals(sale), undefined)
        assert.equal((await fixture.runtime.query('SELECT status FROM product_binary_settlement_jobs WHERE order_id=$1', [sale])).rows[0].status, 'completed')
        assert.equal((await fixture.runtime.query(`SELECT settlement.status FROM unilevel_settlement_jobs settlement
          JOIN product_binary_settlement_jobs job ON job.id=settlement.settlement_job_id WHERE job.order_id=$1`, [sale])).rows[0].status, 'failed')
      } finally {
        console.error = originalError
        await fixture.owner.query('DROP TRIGGER unilevel_test_wallet_failure ON public.commissions; DROP FUNCTION public.unilevel_test_wallet_failure()')
      }
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 2, retained: 8 })
    })

    await t.test('insufficient stock funding rolls back all credits and recovers after a funded receipt', async () => {
      const f = await fixture.memberFixture()
      await f.stock(1)
      const sale = await f.order(f.members[0], 2)
      await assert.rejects(processDeliveredUnilevelOrder(sale), /reserve funding/)
      assert.equal(await totals(sale), undefined)
      assert.equal((await fixture.runtime.query('SELECT count(*)::int n FROM product_binary_order_events WHERE order_id=$1', [sale])).rows[0].n, 0)
      assert.equal((await fixture.runtime.query('SELECT remaining_units FROM product_binary_inventory_reserves WHERE distributor_id=$1', [f.seller])).rows[0].remaining_units, 1)
      await f.stock(2)
      await settle(sale)
      assert.deepEqual(await totals(sale), { funded: 10, credited: 0, retained: 10 })
    })

    await t.test('runtime cannot edit financial records, bypass triggers, or call private credit helpers', async () => {
      for (const statement of [
        'UPDATE wallets SET balance=balance WHERE false',
        'UPDATE unilevel_settlement_jobs SET status=status WHERE false',
        'DELETE FROM unilevel_product_order_preparations WHERE false',
        "SELECT settle_funded_unilevel_order('00000000-0000-0000-0000-000000000000')",
        "SET session_replication_role='replica'",
      ]) await assert.rejects(fixture.runtime.query(statement), (error: { code: string }) => error.code === '42501')
      assert.equal((await fixture.runtime.query('SELECT count(*)::int n FROM wallet_funding_reconciliation WHERE abs(unreconciled_balance)>0.01')).rows[0].n, 0)
    })
  } finally {
    await prisma.$disconnect()
    globalThis.prisma = originalPrisma
    process.env.DATABASE_URL = previousUrl
    await fixture.close()
  }
})

test('upgrade preserves a previously credited v1 award and never credits it a second time', { skip: !connection }, async () => {
  const fixture = await createUnilevelDatabase(connection!, false)
  try {
    const f = await fixture.memberFixture(10)
    await fixture.owner.query("UPDATE system_settings SET value='5' WHERE key='unilevel_levels'")
    await f.stock(30)
    await fixture.owner.query("UPDATE system_settings SET value='10' WHERE key='unilevel_levels'")
    await f.qualifySponsor(1)
    const sale = await f.order(f.members[0], 2)
    const event = randomUUID()
    await fixture.runtime.query('BEGIN')
    try {
      await fixture.runtime.query(`INSERT INTO product_binary_order_events(id,order_id,buyer_user_id,eligible_units,total_pu,recorded_gross_margin,settlement_job_id)
        SELECT $1,order_id,buyer_user_id,eligible_units_snapshot,total_pu_snapshot,gross_margin_snapshot,id
        FROM product_binary_settlement_jobs WHERE order_id=$2`, [event, sale])
      await fixture.runtime.query('SELECT queue_product_binary_pool_order($1,transaction_timestamp(),500)', [event])
      await fixture.runtime.query("UPDATE product_binary_settlement_jobs SET status='completed',completed_at=now() WHERE order_id=$1", [sale])
      await fixture.runtime.query('SET CONSTRAINTS ALL IMMEDIATE; COMMIT')
    } catch (error) { await fixture.runtime.query('ROLLBACK'); throw error }
    const old = (await fixture.runtime.query("SELECT id,amount::float amount,rule_version FROM commissions WHERE source_user_id=$1 AND type='multilevel'", [f.members[0]])).rows
    assert.equal(old.length, 1)
    assert.equal(old[0].amount, 1)
    assert.equal(old[0].rule_version, 'unilevel-v1')
    await fixture.upgrade()
    assert.equal((await fixture.runtime.query('SELECT process_unilevel_order($1) result', [sale])).rows[0].result, 'already_settled')
    const after = (await fixture.runtime.query("SELECT id,amount::float amount,rule_version FROM commissions WHERE source_user_id=$1 AND type='multilevel'", [f.members[0]])).rows
    assert.deepEqual(after, old)
    const fresh = await f.order(f.members[0], 2)
    assert.equal((await fixture.runtime.query('SELECT process_unilevel_order($1) result', [fresh])).rows[0].result, 'settled')
    assert.equal((await fixture.runtime.query('SELECT balance::float balance FROM wallets WHERE user_id=$1', [f.members[1]])).rows[0].balance, 3)
    assert.equal((await fixture.runtime.query('SELECT unreconciled_balance::float difference FROM wallet_funding_reconciliation WHERE user_id=$1', [f.members[1]])).rows[0].difference, 0)
  } finally { await fixture.close() }
})

test('retry leases exclude overlapping workers and recover after interruption and backoff', { skip: !connection }, async () => {
  const fixture = await createUnilevelDatabase(connection!)
  const second = new Client({ connectionString: fixture.runtimeUrl })
  await second.connect()
  try {
    const f = await fixture.memberFixture()
    await f.stock(5)
    const sale = await f.order(f.members[0], 1)
    const claimed = await Promise.all([
      fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)'),
      second.query('SELECT * FROM claim_pending_unilevel_orders(1)'),
    ])
    assert.equal(claimed.reduce((total, result) => total + result.rowCount!, 0), 1)
    assert.equal(claimed.flatMap(result => result.rows)[0].order_id, sale)
    assert.equal((await fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)')).rowCount, 0)
    const expireLease = () => fixture.owner.query(`UPDATE unilevel_settlement_jobs settlement SET next_attempt_at=now()-interval '1 second'
      FROM product_binary_settlement_jobs job WHERE job.id=settlement.settlement_job_id AND job.order_id=$1`, [sale])
    await expireLease()
    assert.equal((await fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)')).rows[0].order_id, sale)
    await fixture.runtime.query("SELECT record_unilevel_retry($1,'simulated retry failure')", [sale])
    assert.equal((await fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)')).rowCount, 0)
    await expireLease()
    assert.equal((await fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)')).rows[0].order_id, sale)
    assert.equal((await fixture.runtime.query('SELECT process_unilevel_order($1) result', [sale])).rows[0].result, 'settled')
    assert.equal((await fixture.runtime.query('SELECT * FROM claim_pending_unilevel_orders(1)')).rowCount, 0)
  } finally { await second.end(); await fixture.close() }
})

import { randomBytes, randomUUID } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { gunzipSync } from 'node:zlib'
import { Client } from 'pg'

export async function createUnilevelDatabase(connection: string, applyMigration = true) {
  const target = new URL(connection)
  if (!['127.0.0.1', 'localhost'].includes(target.hostname)) {
    throw new Error('Unilevel integration tests require an explicit local PostgreSQL service.')
  }
  const name = `unilevel_ci_${randomUUID().replaceAll('-', '')}`
  const role = `unilevel_ci_${randomUUID().replaceAll('-', '')}`
  const password = randomBytes(32).toString('hex')
  const admin = new Client({ connectionString: connection })
  await admin.connect()
  await admin.query(`CREATE DATABASE "${name}"`)
  target.pathname = `/${name}`
  const ownerUrl = target.href
  const owner = new Client({ connectionString: ownerUrl })
  await owner.connect()
  try {
    await owner.query(gunzipSync(readFileSync(new URL('./unilevelFinancialBaseline.sql.gz', import.meta.url))).toString())
    await owner.query('SET search_path=public')
    await owner.query(`REVOKE CREATE,TEMP ON DATABASE "${name}" FROM PUBLIC; REVOKE CREATE ON SCHEMA public FROM PUBLIC`)
    if (applyMigration) await owner.query(readFileSync('prisma/migrations/20261119010000_independent_unilevel_settlement/migration.sql', 'utf8'))
    await admin.query(`CREATE ROLE "${role}" LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`)
    await owner.query('SELECT configure_financial_runtime_role($1)', [role])
  } catch (error) {
    await owner.end()
    await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`)
    await admin.query(`DROP ROLE IF EXISTS "${role}"`)
    await admin.end()
    throw error
  }
  target.username = role
  target.password = password
  const runtimeUrl = target.href
  const runtime = new Client({ connectionString: runtimeUrl })
  await runtime.connect()
  let sequence = 0
  let scenario = 0

  async function memberFixture(depth = 5, branch = false, binaryParent = false) {
    scenario++
    const id = () => randomUUID()
    const adminId = id(), seller = id(), product = id(), packageId = id()
    const members = Array.from({ length: depth + 1 }, id)
    // Historical account setup only. Financial operations below run with all
    // triggers enabled using the restricted application role.
    await owner.query('BEGIN; SET LOCAL session_replication_role=replica')
    try {
      for (const [userId, userRole] of [[adminId, 'admin'], [seller, 'city'], ...members.map(key => [key, 'reseller'])]) {
        const memberId = `HRM-2080-${String(++sequence).padStart(6, '0')}`
        await owner.query("INSERT INTO member_id_issuances(member_id,year,sequence,evidence_source) VALUES($1,'2080',$2,'runtime_allocation')", [memberId, sequence])
        await owner.query(`INSERT INTO users(id,member_id,username,full_name,first_name,last_name,mobile,password_hash,role,status,
          identity_document_type,identity_document_hash,birthday)
          VALUES($1,$2,$1,$1,'Fixture',$1,'09000000000','not-a-login',$3,'active','Passport',md5($1),date '1990-01-01')`, [userId, memberId, userRole])
      }
      await owner.query(`INSERT INTO distributor_profiles(id,user_id,dist_level,coverage_area,region_code,province_code,city_muni_code)
        VALUES($1,$1,$2,'Fixture','07','0722',$3)`, [seller, branch ? 'branch' : 'city', `0722${String(scenario).padStart(2, '0')}`])
      await owner.query("INSERT INTO packages(id,name,price,direct_referral_bonus,pairing_bonus_value,point_php_value) VALUES($1,'Starter',660,300,600,10)", [packageId])
      await owner.query("INSERT INTO products(id,name,type,price,cost_price,reseller_price,city_price,pu_value) VALUES($1,'Fixture bottle','physical',249,110,183,163,1)", [product])
      for (const index of [...members.keys()].reverse()) {
        const key = members[index], pin = id()
        await owner.query("INSERT INTO pins(id,pin_code,package_id,city_dist_id,generated_by,status,used_by) VALUES($1,$1,$2,$3,$4,'used',$5)", [pin, packageId, seller, adminId, key])
        await owner.query('INSERT INTO reseller_profiles(id,user_id,package_id,city_dist_id,pin_id) VALUES($1,$1,$2,$3,$4)', [key, packageId, seller, pin])
        await owner.query('INSERT INTO binary_tree_nodes(id,user_id,sponsor_id,parent_id,position) VALUES($1,$1,$2,$3,$4)',
          [key, members[index + 1] ?? null, binaryParent && index === 0 ? members[1] : null, binaryParent && index === 0 ? 'left' : null])
        await owner.query('INSERT INTO wallets(id,user_id,updated_at) VALUES($1,$1,now())', [key])
      }
      for (const [key, value] of Object.entries({ unilevel_levels: String(depth), product_binary_weekly_cutover: '2020-01-06', product_binary_pair_amount: '5' })) {
        await owner.query('INSERT INTO system_settings(id,key,value,updated_at) VALUES($1,$2,$3,now()) ON CONFLICT(key) DO UPDATE SET value=EXCLUDED.value', [id(), key, value])
      }
      await owner.query('SET LOCAL session_replication_role=origin; COMMIT')
    } catch (error) { await owner.query('ROLLBACK'); throw error }

    async function order(buyer: string, quantity: number, paid = true, source = seller) {
      const key = id()
      await runtime.query('BEGIN')
      try {
        await runtime.query("INSERT INTO orders(id,buyer_id,seller_id,order_type,total_amount,pickup_scheduled_at,pickup_schedule_timezone) VALUES($1,$2,$3,'online',$4,now()+interval '1 day','Asia/Manila')", [key, buyer, source, quantity * 183])
        await runtime.query('INSERT INTO order_items(id,order_id,product_id,quantity,unit_price,subtotal) VALUES($1,$2,$3,$4,183,$5)', [id(), key, product, quantity, quantity * 183])
        await runtime.query("UPDATE orders SET status='delivered',payment_status=$2::text,paid_at=CASE WHEN $2='paid' THEN now() END,delivered_at=now() WHERE id=$1", [key, paid ? 'paid' : 'unpaid'])
        await runtime.query('COMMIT')
      } catch (error) { await runtime.query('ROLLBACK'); throw error }
      return key
    }
    async function stock(quantity: number) {
      if (!branch) return order(seller, quantity, true, adminId)
      const transfer = id(), movement = id()
      await runtime.query('BEGIN')
      try {
        await runtime.query("INSERT INTO inventory_transfers(id,reference_number,admin_id,recipient_id,dispatched_by_actor_id,reference_value,updated_at) VALUES($1::uuid,$1::text,$2::text,$3::text,$2::uuid,$4,now())", [transfer, adminId, seller, quantity * 110])
        await runtime.query(`INSERT INTO inventory_movements(id,transfer_id,admin_id,recipient_id,product_id,quantity,unit_cost,unit_price,reference_value,sale_value,admin_profit,is_sale,admin_stock_before,admin_stock_after,recipient_stock_before,recipient_stock_after)
          VALUES($1,$2,$3,$4,$5,$6,110,110,$7,0,0,false,1000,1000-$6,0,0)`, [movement, transfer, adminId, seller, product, quantity, quantity * 110])
        await runtime.query("UPDATE inventory_transfers SET status='receiving' WHERE id=$1", [transfer])
        await runtime.query('UPDATE inventory_movements SET accepted_quantity=$2,damaged_quantity=0,missing_quantity=0,recipient_stock_after=$2,received_at=now() WHERE id=$1', [movement, quantity])
        await runtime.query("UPDATE inventory_transfers SET status='received_full',received_at=now(),received_by=$2::text,received_by_actor_id=$2::uuid WHERE id=$1::uuid", [transfer, seller])
        await runtime.query('COMMIT')
      } catch (error) { await runtime.query('ROLLBACK'); throw error }
      return transfer
    }
    async function qualifySponsor(index: number, previousMonth = false) {
      const qualifying = await order(members[index], 1)
      if (previousMonth) {
        // Simulate historical qualification time in the disposable fixture.
        await owner.query('BEGIN; SET LOCAL session_replication_role=replica')
        await owner.query("UPDATE product_binary_settlement_jobs SET qualified_at=(date_trunc('month',now() AT TIME ZONE 'Asia/Manila') AT TIME ZONE 'Asia/Manila')-interval '1 millisecond' WHERE order_id=$1", [qualifying])
        await owner.query('COMMIT')
      }
      return qualifying
    }
    return { adminId, seller, product, members, order, stock, qualifySponsor }
  }
  return {
    owner, runtime, runtimeUrl, memberFixture,
    async upgrade() {
      await owner.query(readFileSync('prisma/migrations/20261119010000_independent_unilevel_settlement/migration.sql', 'utf8'))
    },
    async close() {
      await runtime.end(); await owner.end()
      await admin.query(`DROP DATABASE "${name}" WITH (FORCE)`)
      await admin.query(`DROP ROLE "${role}"`)
      await admin.end()
    },
  }
}

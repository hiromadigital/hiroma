# Unilevel runtime validation — 19 November 2026

## Verified behavior

The default funding policy allocates a separate ₱5 per eligible bottle for
Unilevel (five fixed sponsor positions at ₱1 each). Product Binary funding is
separate. A paid stock receipt earmarks inventory funding; an eligible paid,
delivered repeat order consumes the corresponding FIFO stock funding. Missing
or unqualified sponsor positions are retained, without compression.

An isolated database with synthetic accounts passed the following tests using
the restricted application role for database operations:

- City stock receipt: 30 bottles created ₱150 in Unilevel inventory earmarks.
- Branch accepted stock transfer: 30 bottles created a separate ₱150 earmark.
- Eligible City sale: 10 bottles transferred ₱50 of recorded funding.
- Mixed historical Branch inventory: only eight funded bottles transferred
  ₱40; no funding was invented for pre-migration stock.
- Two qualified purchases credited ₱18 to the sponsor's wallet, with a zero
  difference in the funding reconciliation.
- Four concurrent retries produced no additional allocations or credits.
- Delivered but unpaid orders produced no Unilevel allocations.
- Withdrawal reservation, source-lot allocation, simulated disbursement and
  deactivation forfeiture reconciled correctly. Test payout/deactivation
  transactions were rolled back.
- Qualification stayed frozen at paid delivery; a sponsor suspended before
  credit had a recorded retention reason.
- Inventory funding reconciled as original earmarks = remaining + transferred.

The actual registration API also passed under the restricted role: two funded
PIN registrations produced ₱600 Direct Referral and ₱300 Package Binary,
released stock once, recovered identical retries, and rejected changed retries.
Registration fixtures and payout-provider evidence were synthetic.

Repository validation: 674 tests, 673 passed, zero failed, one skipped.
The final production build, including TypeScript validation, passed. ESLint on
the runtime provisioning and verification scripts also passed.

## Shared database and runtime configuration

Migration `20261119000000_prepare_financial_runtime_boundary` is applied.
All 171 migrations are applied. The dedicated `hiroma_app_runtime` role passed
`verify:financial-runtime-role` against the shared PostgreSQL 17 database:
145 protected tables, zero disabled protected triggers, no trigger bypass.

No-op mutation probes confirmed permission denial for direct Unilevel and
wallet edits, direct Product Binary credit, runtime role escalation and replica
mode. These probes wrote no financial records to the shared database.

The migration separates owner-executed, source-validated ledger callbacks from
application privileges. Restricted callers can submit normal business events
but cannot edit generated financial lots, credits or retention evidence. The
owner-only configuration function grants approved entry points explicitly.

For repeatable provisioning, supply `FINANCIAL_OWNER_DATABASE_URL` and
`FINANCIAL_RUNTIME_DATABASE_URL` securely, then run:

```sh
npm run configure:financial-runtime-role
npm run verify:financial-runtime-role
```

The configuration script supports Supabase pooler role/project usernames and
never prints credentials. Migration credentials remain separate from the
application connection. Re-run permission configuration and verification after
future migrations add financial objects or change function ACLs.

Vercel's sensitive `DATABASE_URL` variable for production and preview now points
to the verified restricted role for subsequent deployments. The existing running
deployment does not change until redeployment. Local Next.js uses the runtime
connection in ignored `.env.local`; Prisma migrations retain the owner
connection in ignored `.env`.

## Release work still separate

This validation does not publish a deployment, merge a PR, approve a dirty
working tree, or set `PRODUCT_BINARY_APPROVED_RELEASE_SHA`. The tested source
must be deployed and approved using its exact release commit before live gated
processing is enabled. Existing daily Hobby cron scheduling is unchanged.
These are deployment/activation steps; passing isolated tests alone is not a
claim that public live payouts are already enabled.

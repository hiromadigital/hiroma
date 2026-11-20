# Unilevel financial integration baseline

`unilevelFinancialBaseline.sql.gz` is a schema-only PostgreSQL dump of the
financial schema immediately before `20261119010000_independent_unilevel_settlement`.
It includes the existing ledger validators and triggers, without table records,
ownership statements, ACLs, connection strings or login credentials.

The repository's oldest migrations assume an original application schema that
predates the tracked migration history. They cannot currently initialize an
empty database (`pins` is missing during the registration-financials migration).
This fixture makes the Unilevel change reproducible against the existing
financial boundary without changing that historical migration chain or replacing
the wallet validators with test stubs.

The integration fixture restores the baseline into a uniquely named disposable
database on an explicitly supplied **local** PostgreSQL service, applies the new
migration, provisions a restricted runtime role and deletes both after testing.
Historical member/profile setup uses the owner role; subsequent stock, order,
settlement and credit operations use the restricted role with triggers enabled.

Run with a local database administrator connection that can create disposable
databases and roles:

```powershell
$env:UNILEVEL_INTEGRATION_DATABASE_URL = 'postgresql://postgres@127.0.0.1:5432/postgres'
npm run test:unilevel-integration
```

The GitHub quality workflow supplies its disposable PostgreSQL service URL.
The normal test suite skips this integration test when the explicit variable is
absent; the separate CI step always runs it.

The baseline was exported using `pg_dump --schema-only --no-owner --no-acl`.
Client-only backslash commands and PostgreSQL 18's `transaction_timeout` setting
were removed so the SQL can also be restored through `pg` on CI PostgreSQL 16.
Uncompressed SHA-256:
`bafa16a5e370dd3255ea2b84aad1b484d5ceedc554907765eeaa3617ad9c9bda`.

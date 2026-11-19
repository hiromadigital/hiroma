import "dotenv/config";
import { Client } from "pg";

// Use the owner connection only for provisioning. Neither URL is printed.
async function main() {
  const ownerUrl = process.env.FINANCIAL_OWNER_DATABASE_URL?.trim();
  const runtimeUrl = process.env.FINANCIAL_RUNTIME_DATABASE_URL?.trim();
  if (!ownerUrl || !runtimeUrl) {
    throw new Error("FINANCIAL_OWNER_DATABASE_URL and FINANCIAL_RUNTIME_DATABASE_URL are required.");
  }
  const ownerTarget = new URL(ownerUrl);
  const runtimeTarget = new URL(runtimeUrl);
  if (ownerTarget.hostname !== runtimeTarget.hostname || ownerTarget.pathname !== runtimeTarget.pathname) {
    throw new Error("Owner and runtime connections must target the same host and database.");
  }
  const runtimeUsername = decodeURIComponent(runtimeTarget.username);
  const ownerUsername = decodeURIComponent(ownerTarget.username);
  // Supabase pooler authentication uses role.projectRef, while PostgreSQL
  // permissions use the role alone. Require the same project suffix.
  const pooler = runtimeTarget.hostname.endsWith(".pooler.supabase.com");
  const [role, projectRef] = pooler ? runtimeUsername.split(".") : [runtimeUsername];
  if (pooler && (!projectRef || projectRef !== ownerUsername.split(".")[1] || runtimeUsername.split(".").length !== 2)) {
    throw new Error("Owner and runtime pooler connections must use the same project.");
  }
  const password = decodeURIComponent(runtimeTarget.password);
  if (!/^[a-z][a-z0-9_]{0,62}$/.test(role) || !password || ownerTarget.username === runtimeTarget.username) {
    throw new Error("Use a distinct runtime role with a password and a valid lowercase role name.");
  }
  const owner = new Client({ connectionString: ownerUrl });
  await owner.connect();
  try {
    await owner.query("BEGIN");
    await owner.query("SET LOCAL standard_conforming_strings=on");
    if (!(await owner.query("SELECT 1 FROM pg_roles WHERE rolname=$1", [role])).rowCount) {
      // PostgreSQL does not accept parameters in CREATE ROLE. The identifier is
      // strictly validated above; quote the password as a SQL literal.
      await owner.query(`CREATE ROLE "${role}" LOGIN PASSWORD '${password.replaceAll("'", "''")}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS`);
    }
    await owner.query("SELECT public.configure_financial_runtime_role($1)", [role]);
    await owner.query("COMMIT");
    const runtime = new Client({ connectionString: runtimeUrl });
    await runtime.connect();
    try {
      const identity = await runtime.query<{ role: string; database: string }>(
        "SELECT current_user AS role,current_database() AS database",
      );
      if (identity.rows[0].role !== role) throw new Error("Runtime connection did not select the provisioned role.");
      console.log(JSON.stringify({ ok: true, ...identity.rows[0], next: "Run verify:financial-runtime-role before deployment." }));
    } finally {
      await runtime.end();
    }
  } catch (error) {
    await owner.query("ROLLBACK");
    throw error;
  } finally {
    await owner.end();
  }
}

main().catch(() => {
  // Connection/SQL errors can contain credentials. Keep operational output safe.
  console.error("Financial runtime configuration failed. Verify credentials, target, role attributes and the required migration.");
  process.exitCode = 1;
});

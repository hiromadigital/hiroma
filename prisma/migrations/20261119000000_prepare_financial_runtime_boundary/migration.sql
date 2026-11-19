BEGIN;

-- Internal ledger writes run with the table owner's authority. Runtime calls
-- remain limited to existing source-validated business entry points.
DO $$
DECLARE signature text; procedure_id regprocedure;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
      'public.track_product_binary_account_hold()',
      'public.apply_product_binary_expired_window(date,text)',
      'public.require_fully_funded_product_binary_pool_order()',
      'public.sync_open_product_binary_week_rate()',
      'public.verify_legacy_product_binary_week_readiness(date)',
      'public.seal_closed_product_binary_allocation()',
      'public.enforce_lifetime_person_accounts()',
      'public.accumulate_binary_daily_cap_usage()',
      'public.initialize_package_binary_carryover()',
      'public.reserve_combined_order_replacement()',
      'public.settle_combined_order_replacements()',
      'public.seed_reward_stock_unit()',
      'public.validate_reward_stock_dispatch()',
      'public.fulfill_reward_stock_dispatch()',
      'public.receive_reward_stock_dispatch()',
      'public.release_product_reward_claim()',
      'public.fulfill_product_reward_claim()',
      'public.credit_package_binary_product_reward()',
      'public.apply_wallet_ledger_entry()',
      'public.allocate_approved_direct_referral_payout()',
      'public.allocate_approved_binary_payout()',
      'public.allocate_approved_product_binary_payout()',
      'public.allocate_rank_bonus_payout()',
      'public.fund_product_binary_commission()',
      'public.qualify_product_binary_order_trigger()',
      'public.maintain_binary_tree_ancestor_counts()',
      'public.allocate_direct_referral_payout(text,text,numeric,timestamp without time zone)',
      'public.allocate_binary_payout(text,text,numeric,timestamp with time zone)',
      'public.allocate_product_binary_payout(text,text,numeric,timestamp with time zone)',
      'public.consume_product_binary_funding(text,numeric,timestamp with time zone)',
      'public.qualify_product_binary_order(text)',
      'public.create_binary_reserve_lot_for_registration()',
      'public.create_binary_reserve_lot_for_upgrade()',
      'public.consume_binary_reserve()',
      'public.create_binary_payable_lot()',
      'public.create_direct_referral_reserve_lot()',
      'public.create_product_binary_payable_lot()',
      'public.validate_product_binary_pair_event_entitlement()',
      'public.validate_exact_commission_entitlement()',
      'public.validate_binary_pair_event_entitlement()',
      'public.validate_binary_settlement_source_entitlement()',
      'public.validate_direct_referral_settlement_insert()',
      'public.enforce_payout_identity_and_status_transition()'
  ] LOOP
    procedure_id := to_regprocedure(signature);
    IF procedure_id IS NULL THEN
      RAISE EXCEPTION 'Required financial boundary is missing: %', signature;
    END IF;
    EXECUTE format('ALTER FUNCTION %s SECURITY DEFINER',procedure_id);
    EXECUTE format('ALTER FUNCTION %s SET search_path TO pg_catalog, public, pg_temp',procedure_id);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',procedure_id);
  END LOOP;
  EXECUTE format('REVOKE CREATE, TEMP ON DATABASE %I FROM PUBLIC',current_database());
  REVOKE CREATE ON SCHEMA public FROM PUBLIC;
END;
$$;

-- Passwords and connection settings are supplied by the owner provisioning
-- script. The database migration contains no login credentials.
CREATE FUNCTION public.configure_financial_runtime_role(runtime_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
  owner_id oid;
  role_id oid;
  role_risk boolean;
  object_name text;
  signature text;
  procedure_id regprocedure;
  protected_function record;
BEGIN
  SELECT proowner INTO owner_id FROM pg_proc
  WHERE oid='public.configure_financial_runtime_role(text)'::regprocedure;
  IF NOT pg_has_role(session_user,owner_id,'MEMBER') THEN
    RAISE EXCEPTION 'Only the migration owner can configure the financial runtime role.' USING ERRCODE='42501';
  END IF;
  IF runtime_name !~ '^[a-z][a-z0-9_]{0,62}$' THEN
    RAISE EXCEPTION 'Invalid runtime role name.';
  END IF;
  SELECT oid INTO role_id FROM pg_roles WHERE rolname=runtime_name;
  IF role_id IS NULL THEN RAISE EXCEPTION 'Runtime role does not exist.'; END IF;
  WITH RECURSIVE reachable(id) AS (
    SELECT role_id
    UNION
    SELECT membership.roleid FROM pg_auth_members membership
    JOIN reachable ON reachable.id=membership.member
  )
  SELECT EXISTS(
    SELECT 1 FROM reachable JOIN pg_roles role ON role.oid=reachable.id
    WHERE role.rolsuper OR role.rolcreaterole OR role.rolcreatedb
      OR role.rolreplication OR role.rolbypassrls
  ) INTO role_risk;
  IF role_risk OR pg_has_role(role_id,owner_id,'MEMBER') THEN
    RAISE EXCEPTION 'Runtime role has owner or administrative privileges.';
  END IF;
  IF EXISTS(SELECT 1 FROM pg_database WHERE datname=current_database() AND pg_has_role(role_id,datdba,'MEMBER'))
     OR EXISTS(SELECT 1 FROM pg_class class JOIN pg_namespace namespace ON namespace.oid=class.relnamespace
       WHERE namespace.nspname='public' AND pg_has_role(role_id,class.relowner,'MEMBER')) THEN
    RAISE EXCEPTION 'Runtime role owns application objects.';
  END IF;

  EXECUTE format('GRANT CONNECT ON DATABASE %I TO %I',current_database(),runtime_name);
  EXECUTE format('REVOKE CREATE, TEMP ON DATABASE %I FROM %I',current_database(),runtime_name);
  EXECUTE format('GRANT USAGE ON SCHEMA public TO %I',runtime_name);
  EXECUTE format('REVOKE CREATE ON SCHEMA public FROM %I',runtime_name);
  EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA public FROM %I',runtime_name);
  EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO %I',runtime_name);
  EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM %I',runtime_name);
  EXECUTE format('GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO %I',runtime_name);

  FOREACH object_name IN ARRAY ARRAY[
      'person_account_totals',
      'person_account_memberships',
      'person_account_documents',
      'binary_daily_cap_usage',
      'binary_reserve_lots',
      'binary_reserve_consumptions',
      'binary_payable_lots',
      'binary_payout_consumptions',
      'direct_referral_reserve_lots',
      'direct_referral_payout_consumptions',
      'product_binary_funding_lots',
      'product_binary_funding_consumptions',
      'product_binary_payable_lots',
      'product_binary_payout_consumptions',
      'product_binary_inventory_reserves',
      'product_binary_inventory_reserve_transfers',
      'product_binary_non_member_reserve_releases',
      'product_binary_non_member_reserve_restorations',
      'product_binary_replacement_reserve_releases',
      'product_binary_package_reserve_releases',
      'product_binary_pool_weeks',
      'product_binary_pool_orders',
      'product_binary_pool_pairs',
      'product_binary_pool_allocations',
      'product_binary_week_preparation',
      'product_binary_account_holds',
      'product_binary_prepared_recipients',
      'rank_bonus_awards',
      'rank_bonus_payout_consumptions',
      'payable_lot_forfeitures',
      'unilevel_inventory_earmarks',
      'unilevel_order_allocations',
      'unilevel_qualified_orders',
      'unilevel_qualified_recipients',
      'unilevel_order_settlements',
      'unilevel_payable_lots',
      'unilevel_retention_entries',
      'unilevel_payout_consumptions',
      '_prisma_migrations'
  ] LOOP
    IF to_regclass('public.'||object_name) IS NOT NULL THEN
      EXECUTE format('REVOKE INSERT, UPDATE, DELETE ON TABLE public.%I FROM %I',object_name,runtime_name);
    END IF;
  END LOOP;
  FOREACH object_name IN ARRAY ARRAY[
      'commissions',
      'wallet_ledger_entries',
      'wallets',
      'audit_logs',
      'registration_financials',
      'upgrade_financials',
      'direct_referral_settlement_events',
      'binary_settlement_events',
      'binary_pair_events',
      'product_binary_order_events',
      'product_binary_pair_events',
      'binary_point_consumptions',
      'binary_point_expirations',
      'financial_operation_receipts',
      'request_receipts',
      'rank_bonus_programs',
      'rank_bonus_funding'
  ] LOOP
    EXECUTE format('REVOKE UPDATE, DELETE ON TABLE public.%I FROM %I',object_name,runtime_name);
  END LOOP;
  REVOKE ALL ON FUNCTION public.configure_financial_runtime_role(text) FROM PUBLIC;
  EXECUTE format('REVOKE INSERT, DELETE ON TABLE public.product_binary_settlement_jobs FROM %I',runtime_name);
  EXECUTE format('REVOKE DELETE ON TABLE public.product_binary_positions,public.product_binary_pu_lots,public.binary_point_lots FROM %I',runtime_name);

  -- Trigger functions cannot be attached to a shadow table. SECURITY DEFINER
  -- helpers use explicit grants, including the synchronized release functions.
  EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM %I',runtime_name);
  FOR protected_function IN
    SELECT procedure.oid::regprocedure AS signature
    FROM pg_proc procedure JOIN pg_namespace namespace ON namespace.oid=procedure.pronamespace
    WHERE namespace.nspname='public'
      AND (procedure.prosecdef OR procedure.prorettype='trigger'::regtype)
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',protected_function.signature);
  END LOOP;
  FOREACH signature IN ARRAY ARRAY[
      'public.close_product_binary_pool_week(date)',
      'public.expire_deferred_product_binary_credits()',
      'public.process_rank_bonus_awards(timestamp with time zone,integer)',
      'public.product_binary_surviving_pairs(date,text)',
      'public.product_binary_weekly_pair_eligible(text)',
      'public.queue_product_binary_pool_order(uuid,timestamp with time zone,integer)',
      'public.release_product_binary_pool_week(date)',
      'public.retry_deferred_product_binary_credit(date,text)',
      'public.verify_product_binary_week_readiness(date)',
      'public.rank_bonus_progress(text,timestamp with time zone,timestamp with time zone)'
  ] LOOP
    procedure_id:=to_regprocedure(signature);
    IF procedure_id IS NULL THEN RAISE EXCEPTION 'Required runtime entry point is missing: %',signature; END IF;
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO %I',procedure_id,runtime_name);
  END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.configure_financial_runtime_role(text) FROM PUBLIC;
COMMIT;

BEGIN;

CREATE TABLE public.rank_bonus_programs (
  quarter_start timestamptz PRIMARY KEY,
  quarter_end timestamptz NOT NULL CHECK (quarter_end > quarter_start),
  milestones jsonb NOT NULL CHECK (jsonb_typeof(milestones) = 'array' AND jsonb_array_length(milestones) > 0)
);

CREATE TABLE public.rank_bonus_funding (
  reference text PRIMARY KEY CHECK (length(btrim(reference)) BETWEEN 1 AND 120),
  quarter_start timestamptz NOT NULL REFERENCES public.rank_bonus_programs(quarter_start),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  funded_by text NOT NULL REFERENCES public.users(id),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
CREATE INDEX rank_bonus_funding_quarter_idx ON public.rank_bonus_funding(quarter_start);

CREATE TABLE public.rank_bonus_awards (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  quarter_start timestamptz NOT NULL REFERENCES public.rank_bonus_programs(quarter_start),
  user_id text NOT NULL REFERENCES public.users(id),
  milestone text NOT NULL,
  bottles integer NOT NULL,
  referrals integer NOT NULL,
  original_amount numeric(12,2) NOT NULL CHECK (original_amount > 0),
  remaining_amount numeric(12,2) NOT NULL CHECK (remaining_amount BETWEEN 0 AND original_amount),
  commission_id text NOT NULL UNIQUE REFERENCES public.commissions(id) DEFERRABLE INITIALLY DEFERRED,
  allocated_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  UNIQUE (quarter_start, user_id, milestone)
);
CREATE INDEX rank_bonus_awards_user_idx ON public.rank_bonus_awards(user_id, allocated_at, id)
  WHERE remaining_amount > 0;

CREATE TABLE public.rank_bonus_payout_consumptions (
  payout_id text NOT NULL REFERENCES public.payouts(id),
  award_id uuid NOT NULL REFERENCES public.rank_bonus_awards(id),
  amount numeric(12,2) NOT NULL CHECK (amount > 0),
  PRIMARY KEY (payout_id, award_id)
);

REVOKE ALL ON public.rank_bonus_programs, public.rank_bonus_funding, public.rank_bonus_awards,
  public.rank_bonus_payout_consumptions FROM PUBLIC;

CREATE TRIGGER rank_bonus_programs_append_only BEFORE UPDATE OR DELETE ON public.rank_bonus_programs
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();
CREATE TRIGGER rank_bonus_funding_append_only BEFORE UPDATE OR DELETE ON public.rank_bonus_funding
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();
CREATE TRIGGER rank_bonus_awards_protected_update BEFORE UPDATE OR DELETE ON public.rank_bonus_awards
FOR EACH ROW EXECUTE FUNCTION public.require_internal_financial_ledger_write();

CREATE TRIGGER rank_bonus_consumptions_append_only BEFORE UPDATE OR DELETE ON public.rank_bonus_payout_consumptions
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();

ALTER TABLE public.payable_lot_forfeitures
  ADD COLUMN rank_bonus_lot_id uuid UNIQUE REFERENCES public.rank_bonus_awards(id),
  DROP CONSTRAINT payable_lot_forfeitures_exact_source_check,
  ADD CONSTRAINT payable_lot_forfeitures_exact_source_check CHECK (
    num_nonnulls(direct_lot_id, binary_lot_id, product_binary_lot_id, rank_bonus_lot_id) = 1
    AND ((source_type = 'direct_referral' AND direct_lot_id IS NOT NULL)
      OR (source_type = 'binary' AND binary_lot_id IS NOT NULL)
      OR (source_type = 'product_binary' AND product_binary_lot_id IS NOT NULL)
      OR (source_type = 'rank_bonus' AND rank_bonus_lot_id IS NOT NULL))
  );

CREATE FUNCTION public.rank_bonus_progress(member_id text, starts_at timestamptz, ends_at timestamptz)
RETURNS TABLE(bottles integer, referrals integer)
LANGUAGE sql STABLE SET search_path = pg_catalog, public, pg_temp AS $$
  SELECT
    COALESCE((
      SELECT SUM(job.eligible_units_snapshot)
      FROM product_binary_settlement_jobs job
      JOIN orders ON orders.id = job.order_id
      WHERE job.buyer_user_id = member_id AND orders.buyer_id = member_id
        AND job.qualification_status = 'qualified_paid_delivery'
        AND orders.status = 'delivered' AND orders.payment_status = 'paid'
        AND orders.financial_purpose = 'commerce' AND NOT orders.is_non_member_sale
        AND job.qualified_at >= starts_at AND job.qualified_at < ends_at
    ), 0)::int,
    (
      SELECT COUNT(DISTINCT event.referred_user_id)
      FROM direct_referral_settlement_events event
      JOIN registration_financials registration ON registration.id = event.registration_financial_id
      WHERE event.sponsor_user_id = member_id AND event.referred_user_id <> member_id
        AND registration.payment_status = 'paid'
        AND (COALESCE(registration.paid_at, registration.created_at) AT TIME ZONE 'UTC') >= starts_at
        AND (COALESCE(registration.paid_at, registration.created_at) AT TIME ZONE 'UTC') < ends_at
    )::int;
$$;

CREATE INDEX rank_bonus_qualified_orders_idx
  ON public.product_binary_settlement_jobs (buyer_user_id, qualified_at)
  WHERE qualification_status = 'qualified_paid_delivery';
CREATE INDEX rank_bonus_referral_sponsor_idx ON public.direct_referral_settlement_events(sponsor_user_id);
CREATE INDEX rank_bonus_quarter_orders_idx
  ON public.product_binary_settlement_jobs (qualified_at, buyer_user_id)
  WHERE qualification_status = 'qualified_paid_delivery';

CREATE FUNCTION public.process_rank_bonus_awards(target_quarter timestamptz, batch_size integer DEFAULT 50)
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  program rank_bonus_programs;
  available numeric;
  candidate record;
  award_id uuid;
  credit_id text;
  credited integer := 0;
BEGIN
  SELECT * INTO program FROM rank_bonus_programs
  WHERE quarter_start = target_quarter AND quarter_start <= transaction_timestamp()
  FOR UPDATE;
  IF NOT FOUND THEN RETURN 0; END IF;

  SELECT COALESCE((SELECT SUM(amount) FROM rank_bonus_funding WHERE quarter_start = target_quarter), 0)
       - COALESCE((SELECT SUM(original_amount) FROM rank_bonus_awards WHERE quarter_start = target_quarter), 0)
  INTO available;

  FOR candidate IN
    WITH buyers AS (
      SELECT DISTINCT job.buyer_user_id AS user_id
      FROM product_binary_settlement_jobs job
      WHERE job.qualification_status = 'qualified_paid_delivery'
        AND job.qualified_at >= program.quarter_start AND job.qualified_at < program.quarter_end
    )
    SELECT buyer.user_id, milestone.name, milestone.amount, progress.bottles, progress.referrals
    FROM buyers buyer
    JOIN users member ON member.id = buyer.user_id AND member.status = 'active' AND member.role = 'reseller'
    JOIN reseller_profiles profile ON profile.user_id = member.id AND profile.is_active
    CROSS JOIN LATERAL rank_bonus_progress(buyer.user_id, program.quarter_start, program.quarter_end) progress
    CROSS JOIN jsonb_to_recordset(program.milestones) AS milestone(name text, bottles int, referrals int, amount numeric(12,2))
    WHERE progress.bottles >= milestone.bottles AND progress.referrals >= milestone.referrals
      AND milestone.amount > 0 AND milestone.amount <= available
      AND NOT EXISTS (
        SELECT 1 FROM rank_bonus_awards award
        WHERE award.quarter_start = target_quarter AND award.user_id = buyer.user_id AND award.milestone = milestone.name
      )
    ORDER BY buyer.user_id, milestone.bottles, milestone.referrals, milestone.name
    LIMIT LEAST(GREATEST(batch_size, 1), 100)
  LOOP
    EXIT WHEN candidate.amount > available;
    PERFORM pg_advisory_xact_lock(hashtext('financial-user:' || candidate.user_id));
    PERFORM 1 FROM users WHERE id = candidate.user_id AND status = 'active' AND role = 'reseller' FOR SHARE;
    IF NOT FOUND THEN CONTINUE; END IF;

    award_id := gen_random_uuid();
    credit_id := gen_random_uuid()::text;
    INSERT INTO rank_bonus_awards (
      id, quarter_start, user_id, milestone, bottles, referrals, original_amount, remaining_amount, commission_id
    ) VALUES (
      award_id, target_quarter, candidate.user_id, candidate.name, candidate.bottles,
      candidate.referrals, candidate.amount, candidate.amount, credit_id
    );

    INSERT INTO commissions (id, event_key, source_event_kind, source_event_id, rule_version, user_id, type, amount)
    VALUES (credit_id, 'rank-bonus:' || award_id, 'rank_bonus', award_id::text, 'rank-bonus-v1',
      candidate.user_id, 'rank_bonus', candidate.amount);

    available := available - candidate.amount;
    credited := credited + 1;
  END LOOP;
  RETURN credited;
END;
$$;

REVOKE ALL ON FUNCTION public.process_rank_bonus_awards(timestamptz, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rank_bonus_progress(text, timestamptz, timestamptz) FROM PUBLIC;


CREATE OR REPLACE FUNCTION "validate_new_commission_provenance"()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW."event_key" IS NULL OR length(btrim(NEW."event_key")) = 0 THEN
    RAISE EXCEPTION 'Every commission requires an idempotent event key.' USING ERRCODE = '23514';
  END IF;
  IF NEW."source_event_kind" IS NULL OR length(btrim(NEW."source_event_kind")) = 0
     OR NEW."source_event_id" IS NULL OR length(btrim(NEW."source_event_id")) = 0
     OR NEW."rule_version" IS NULL OR length(btrim(NEW."rule_version")) = 0 THEN
    RAISE EXCEPTION 'Every commission requires immutable source provenance and a rule version.' USING ERRCODE = '23514';
  END IF;
  IF NEW."amount" <= 0 THEN
    RAISE EXCEPTION 'Commission amount must be positive.' USING ERRCODE = '23514';
  END IF;
  IF NEW."is_pair_overflow" = false
     AND NEW."type" NOT IN (
       'direct_referral'::"CommissionType",
       'binary_pairing'::"CommissionType",
       'sponsor_point'::"CommissionType",
       'rank_bonus'::"CommissionType"
     ) THEN
    RAISE EXCEPTION 'Unsupported commission type cannot become spendable.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "validate_exact_commission_entitlement"()
RETURNS TRIGGER AS $$
DECLARE
  direct_source_user_id TEXT;
  direct_sponsor_user_id TEXT;
  direct_source_allocation DECIMAL(12,2);
  direct_entitled_amount DECIMAL(12,2);
  direct_paid_count INTEGER;
  direct_retained_count INTEGER;
  direct_paid_amount DECIMAL(12,2);
  direct_retained_amount DECIMAL(12,2);
  exact_match_count INTEGER;
BEGIN
  IF NEW."type" = 'direct_referral'::"CommissionType" THEN
    SELECT rf."reseller_id", source_node."sponsor_id", rf."direct_referral_allocation",
           LEAST(sponsor_package."direct_referral_bonus", rf."direct_referral_allocation")::DECIMAL(12,2)
    INTO direct_source_user_id, direct_sponsor_user_id,
         direct_source_allocation, direct_entitled_amount
    FROM "registration_financials" rf
    JOIN "binary_tree_nodes" source_node ON source_node."user_id" = rf."reseller_id"
    JOIN "reseller_profiles" sponsor_profile ON sponsor_profile."user_id" = source_node."sponsor_id"
    JOIN "packages" sponsor_package ON sponsor_package."id" = sponsor_profile."package_id"
    WHERE rf."pin_id" = NEW."source_event_id"
      AND rf."payment_status" = 'paid'
    FOR SHARE OF rf, source_node, sponsor_profile, sponsor_package;

    IF direct_source_user_id IS NULL
       OR NEW."rule_version" IS DISTINCT FROM 'registration-direct-v1'
       OR NEW."source_event_kind" IS DISTINCT FROM 'registration'
       OR NEW."source_user_id" IS DISTINCT FROM direct_source_user_id THEN
      RAISE EXCEPTION 'Direct referral commission does not match the registered member and exact sponsor entitlement.' USING ERRCODE = '23514';
    END IF;

    IF NEW."is_pair_overflow" = false THEN
      IF NEW."user_id" IS DISTINCT FROM direct_sponsor_user_id
         OR NEW."amount" IS DISTINCT FROM direct_entitled_amount THEN
        RAISE EXCEPTION 'Direct referral commission does not match the registered member and exact sponsor entitlement.' USING ERRCODE = '23514';
      END IF;
    ELSE
      -- Retained direct-referral evidence is non-spendable. Its exact daily-cap
      -- decision cannot be reconstructed without a dedicated immutable event,
      -- but it may never name another source, exceed the sealed allocation, or
      -- be retained by an account other than the Hiroma system account.
      IF NEW."amount" <= 0
         OR NEW."amount" > direct_source_allocation
         OR NEW."overflow_to" IS DISTINCT FROM NEW."user_id"
         OR NOT EXISTS (
              SELECT 1 FROM "users" hiroma
              WHERE hiroma."id" = NEW."user_id"
                AND hiroma."username" = 'hiroma'
                AND hiroma."role" = 'admin'::"Role"
            ) THEN
        RAISE EXCEPTION 'Retained direct referral evidence exceeds its sealed registration source or is not assigned to Hiroma.' USING ERRCODE = '23514';
      END IF;
    END IF;

    SELECT
      COUNT(*) FILTER (WHERE commission."is_pair_overflow" = false)::INTEGER,
      COUNT(*) FILTER (WHERE commission."is_pair_overflow" = true)::INTEGER,
      COALESCE(SUM(commission."amount") FILTER (WHERE commission."is_pair_overflow" = false), 0)::DECIMAL(12,2),
      COALESCE(SUM(commission."amount") FILTER (WHERE commission."is_pair_overflow" = true), 0)::DECIMAL(12,2)
    INTO direct_paid_count, direct_retained_count,
         direct_paid_amount, direct_retained_amount
    FROM "commissions" commission
    WHERE commission."type" = 'direct_referral'::"CommissionType"
      AND commission."rule_version" = 'registration-direct-v1'
      AND commission."source_event_kind" = 'registration'
      AND commission."source_event_id" = NEW."source_event_id";

    IF direct_paid_count > 1 OR direct_retained_count > 1
       OR direct_paid_amount NOT IN (0, direct_entitled_amount)
       OR direct_retained_amount IS DISTINCT FROM direct_source_allocation - direct_paid_amount THEN
      RAISE EXCEPTION 'Direct referral paid and retained evidence does not exactly exhaust one sealed allocation.' USING ERRCODE = '23514';
    END IF;

  ELSIF NEW."type" = 'binary_pairing'::"CommissionType" THEN
    IF NEW."rule_version" IS DISTINCT FROM 'package-binary-v1' THEN
      RAISE EXCEPTION 'Package Binary commission uses an unsupported rule version.' USING ERRCODE = '23514';
    END IF;

    IF NEW."is_pair_overflow" = false THEN
      SELECT COUNT(*)::INTEGER
      INTO exact_match_count
      FROM "binary_pair_events" event
      WHERE event."normal_commission_id" = NEW."id"
        AND event."recipient_user_id" = NEW."user_id"
        AND event."source_user_id" = NEW."source_user_id"
        AND event."source_kind" = NEW."source_event_kind"
        AND event."source_event_id" = NEW."source_event_id"
        AND event."payable_amount" = NEW."amount"
        AND NEW."points" IS NOT NULL
        AND NEW."points"::NUMERIC = (event."payable_pairs" - event."product_reward_pairs") * event."points_per_pair";

      IF exact_match_count <> 1 THEN
        RAISE EXCEPTION 'Package Binary commission has no exact immutable pair entitlement.' USING ERRCODE = '23514';
      END IF;
    ELSE
      SELECT COUNT(*)::INTEGER
      INTO exact_match_count
      FROM "binary_pair_events" event
      WHERE event."flashout_commission_id" = NEW."id"
        AND event."source_user_id" = NEW."source_user_id"
        AND event."source_kind" = NEW."source_event_kind"
        AND event."source_event_id" = NEW."source_event_id"
        AND event."flashout_amount" = NEW."amount"
        AND NEW."points" IS NOT NULL
        AND NEW."points"::NUMERIC =
            (event."cap_flashout_pairs" + event."inactive_flashout_pairs") * event."points_per_pair"
        AND NEW."overflow_to" = NEW."user_id"
        AND EXISTS (
          SELECT 1 FROM "users" hiroma
          WHERE hiroma."id" = NEW."user_id"
            AND hiroma."username" = 'hiroma'
            AND hiroma."role" = 'admin'::"Role"
        );

      IF exact_match_count <> 1 THEN
        RAISE EXCEPTION 'Retained Package Binary commission has no exact immutable pair entitlement.' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF NEW."type" = 'sponsor_point'::"CommissionType" THEN
    IF NEW.rule_version = 'product-binary-weekly-v1' THEN
      IF NEW.is_pair_overflow OR NEW.source_event_kind IS DISTINCT FROM 'product_binary_week'
         OR NEW.source_user_id IS NOT NULL OR NEW.points IS NOT NULL
         OR NOT EXISTS (
           SELECT 1 FROM product_binary_pool_allocations a
           JOIN product_binary_pool_weeks w USING (week_start)
           WHERE w.closed_at IS NOT NULL AND a.commission_id = NEW.id
             AND a.recipient_user_id = NEW.user_id
             AND to_char(a.week_start, 'YYYY-MM-DD') = NEW.source_event_id
             AND a.amount_centavos::numeric = NEW.amount * 100
         ) THEN
        RAISE EXCEPTION 'Product Binary commission has no exact weekly allocation.' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END IF;
    IF NEW."rule_version" IS DISTINCT FROM 'product-binary-v1' THEN
      RAISE EXCEPTION 'Product Binary commission uses an unsupported rule version.' USING ERRCODE = '23514';
    END IF;

    IF NEW."is_pair_overflow" = false THEN
      SELECT COUNT(*)::INTEGER
      INTO exact_match_count
      FROM "product_binary_pair_events" pair_event
      JOIN "product_binary_order_events" order_event
        ON order_event."id" = pair_event."order_event_id"
      WHERE pair_event."normal_commission_id" = NEW."id"
        AND pair_event."recipient_user_id" = NEW."user_id"
        AND pair_event."source_user_id" = NEW."source_user_id"
        AND NEW."source_event_kind" = 'product_order'
        AND order_event."order_id" = NEW."source_event_id"
        AND pair_event."payable_amount" = NEW."amount"
        AND NEW."points" IS NOT NULL
        AND NEW."points"::NUMERIC = pair_event."payable_pairs" * pair_event."pair_rate_points";

      IF exact_match_count <> 1 THEN
        RAISE EXCEPTION 'Product Binary commission has no exact immutable pair entitlement.' USING ERRCODE = '23514';
      END IF;
    ELSE
      SELECT COUNT(*)::INTEGER
      INTO exact_match_count
      FROM "product_binary_pair_events" pair_event
      JOIN "product_binary_order_events" order_event
        ON order_event."id" = pair_event."order_event_id"
      WHERE pair_event."flashout_commission_id" = NEW."id"
        AND pair_event."source_user_id" = NEW."source_user_id"
        AND NEW."source_event_kind" = 'product_order'
        AND order_event."order_id" = NEW."source_event_id"
        AND pair_event."flashout_amount" = NEW."amount"
        AND NEW."points" IS NOT NULL
        AND NEW."points"::NUMERIC =
            (pair_event."cap_flashout_pairs" + pair_event."inactive_flashout_pairs") * pair_event."pair_rate_points"
        AND NEW."overflow_to" = NEW."user_id"
        AND EXISTS (
          SELECT 1 FROM "users" hiroma
          WHERE hiroma."id" = NEW."user_id"
            AND hiroma."username" = 'hiroma'
            AND hiroma."role" = 'admin'::"Role"
        );

      IF exact_match_count <> 1 THEN
        RAISE EXCEPTION 'Retained Product Binary commission has no exact immutable pair entitlement.' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF NEW."type" = 'deactivation_wallet_transfer'::"CommissionType"
        AND NEW."is_pair_overflow" = true THEN
    -- Migration 1450 proves that the complete liquidation occurred. This
    -- complementary check binds its one retained commission to the same
    -- reseller, exact wallet value, rule version, and Hiroma account.
    SELECT COUNT(*)::INTEGER
    INTO exact_match_count
    FROM "reseller_deactivation_events" event
    WHERE event."id" = NEW."source_event_id"
      AND NEW."source_event_kind" = 'deactivation'
      AND NEW."rule_version" = 'reseller-deactivation-v1'
      AND event."reseller_id" = NEW."source_user_id"
      AND event."wallet_value" = NEW."amount"
      AND NEW."overflow_to" = NEW."user_id"
      AND EXISTS (
        SELECT 1 FROM "users" hiroma
        WHERE hiroma."id" = NEW."user_id"
          AND hiroma."username" = 'hiroma'
          AND hiroma."role" = 'admin'::"Role"
      );

    IF exact_match_count <> 1 THEN
      RAISE EXCEPTION 'Retained deactivation transfer has no exact immutable liquidation entitlement.' USING ERRCODE = '23514';
    END IF;

  ELSIF NEW."type" = 'rank_bonus'::"CommissionType" THEN
    IF NEW."source_event_kind" IS DISTINCT FROM 'rank_bonus'
       OR NEW."rule_version" IS DISTINCT FROM 'rank-bonus-v1'
       OR NEW."is_pair_overflow" OR NEW."points" IS NOT NULL OR NEW."source_user_id" IS NOT NULL
       OR NOT EXISTS (
         SELECT 1 FROM public.rank_bonus_awards award
         WHERE award.id::text = NEW."source_event_id"
           AND award.commission_id = NEW."id" AND award.user_id = NEW."user_id"
           AND award.original_amount = NEW."amount"
       ) THEN
      RAISE EXCEPTION 'Rank bonus commission has no exact funded award.' USING ERRCODE = '23514';
    END IF;
  ELSE
    RAISE EXCEPTION 'Spendable commission type has no exact entitlement rule.' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "apply_wallet_ledger_entry"()
RETURNS TRIGGER AS $$
DECLARE
  commission_row "commissions"%ROWTYPE;
  payout_row "payouts"%ROWTYPE;
  recipient_role TEXT;
  recipient_status TEXT;
  funded_amount DECIMAL(12,2) := 0;
  unfunded_amount DECIMAL(12,2) := 0;
  source_available DECIMAL(12,2) := 0;
  earlier_pending DECIMAL(12,2) := 0;
  deactivation_amount DECIMAL(12,2) := 0;
  changed INTEGER := 0;
  reservation_exists BOOLEAN := false;
  reservation_release_exists BOOLEAN := false;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('financial-user:' || NEW."user_id"));

  SELECT u."role"::text, u."status"::text
  INTO recipient_role, recipient_status
  FROM "users" u
  WHERE u."id" = NEW."user_id"
  FOR SHARE;

  IF recipient_role IS NULL THEN
    RAISE EXCEPTION 'Wallet ledger recipient does not exist.' USING ERRCODE = '23503';
  END IF;

  IF NEW."entry_type" = 'commission_credit' THEN
    IF NEW."commission_id" IS NULL OR NEW."payout_id" IS NOT NULL THEN
      RAISE EXCEPTION 'Commission credit requires one commission and no payout.' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO commission_row FROM "commissions" WHERE "id" = NEW."commission_id" FOR SHARE;
    IF NOT FOUND OR commission_row."user_id" <> NEW."user_id"
       OR commission_row."is_pair_overflow" = true
       OR recipient_role <> 'reseller' OR recipient_status <> 'active'
       OR NEW."balance_delta" <> commission_row."amount"
       OR NEW."total_earned_delta" <> commission_row."amount"
       OR NEW."reserved_delta" <> 0 OR NEW."total_withdrawn_delta" <> 0
       OR NEW."source_kind" <> commission_row."source_event_kind"
       OR NEW."source_event_id" <> commission_row."source_event_id" THEN
      RAISE EXCEPTION 'Commission wallet credit does not match an active reseller commission.' USING ERRCODE = '23514';
    END IF;

    IF commission_row."type" = 'direct_referral'::"CommissionType" THEN
      SELECT rf."direct_referral_allocation" INTO funded_amount
      FROM "registration_financials" rf
      WHERE rf."pin_id" = commission_row."source_event_id"
        AND rf."payment_status" = 'paid'
      FOR SHARE;
      IF funded_amount IS NULL OR commission_row."source_event_kind" <> 'registration'
         OR commission_row."amount" > funded_amount THEN
        RAISE EXCEPTION 'Direct referral commission is not funded by its registration snapshot.' USING ERRCODE = '23514';
      END IF;
    ELSIF commission_row."type" = 'binary_pairing'::"CommissionType" THEN
      SELECT
        COALESCE(SUM(c."amount") FILTER (WHERE c."is_unfunded" = false), 0),
        COALESCE(SUM(c."amount") FILTER (WHERE c."is_unfunded" = true), 0)
      INTO funded_amount, unfunded_amount
      FROM "binary_reserve_consumptions" c
      WHERE c."commission_id" = commission_row."id";
      IF funded_amount + unfunded_amount <> commission_row."amount" THEN
        RAISE EXCEPTION 'Package Binary funding position is not fully accounted.' USING ERRCODE = '23514';
      END IF;
    ELSIF commission_row."type" = 'sponsor_point'::"CommissionType" THEN
      SELECT
        COALESCE(SUM(c."amount") FILTER (WHERE c."is_unfunded" = false), 0),
        COALESCE(SUM(c."amount") FILTER (WHERE c."is_unfunded" = true), 0)
      INTO funded_amount, unfunded_amount
      FROM "product_binary_funding_consumptions" c
      WHERE c."commission_id" = commission_row."id";
      IF funded_amount <> commission_row."amount" OR unfunded_amount <> 0 THEN
        RAISE EXCEPTION 'Product Binary commission is not fully funded.' USING ERRCODE = '23514';
      END IF;
    ELSIF commission_row."type" = 'rank_bonus'::"CommissionType" THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.rank_bonus_awards award
        WHERE award.commission_id = commission_row."id"
          AND award.original_amount = commission_row."amount"
          AND award.remaining_amount = commission_row."amount"
      ) THEN
        RAISE EXCEPTION 'Rank bonus wallet credit requires its funded award.' USING ERRCODE = '23514';
      END IF;
    ELSE
      RAISE EXCEPTION 'Unsupported commission cannot be credited.' USING ERRCODE = '23514';
    END IF;

  ELSIF NEW."entry_type" IN ('payout_reservation', 'payout_reservation_release', 'payout_disbursement') THEN
    IF NEW."payout_id" IS NULL OR NEW."commission_id" IS NOT NULL OR recipient_role <> 'reseller'
       OR NEW."source_kind" <> 'payout' OR NEW."source_event_id" <> NEW."payout_id" THEN
      RAISE EXCEPTION 'Payout ledger entry is invalid.' USING ERRCODE = '23514';
    END IF;
    SELECT * INTO payout_row FROM "payouts" WHERE "id" = NEW."payout_id" FOR SHARE;
    IF NOT FOUND OR payout_row."user_id" <> NEW."user_id" THEN
      RAISE EXCEPTION 'Payout ledger entry does not match its payout.' USING ERRCODE = '23514';
    END IF;

    IF NEW."entry_type" = 'payout_reservation' THEN
      SELECT
        COALESCE((SELECT SUM("remaining_amount") FROM "direct_referral_reserve_lots" WHERE "user_id" = NEW."user_id"), 0)
        + COALESCE((SELECT SUM("remaining_amount") FROM "binary_payable_lots" WHERE "user_id" = NEW."user_id"), 0)
        + COALESCE((SELECT SUM("remaining_amount") FROM "product_binary_payable_lots" WHERE "user_id" = NEW."user_id"), 0)
        + COALESCE((SELECT SUM("remaining_amount") FROM "rank_bonus_awards" WHERE "user_id" = NEW."user_id"), 0)
      INTO source_available;
      SELECT COALESCE(SUM("amount"), 0) INTO earlier_pending
      FROM "payouts"
      WHERE "user_id" = NEW."user_id" AND "status" = 'pending'::"PayoutStatus" AND "id" <> NEW."payout_id";
      IF payout_row."status" <> 'pending'::"PayoutStatus"
         OR NEW."reserved_delta" <> payout_row."amount"
         OR NEW."balance_delta" <> 0 OR NEW."total_earned_delta" <> 0 OR NEW."total_withdrawn_delta" <> 0
         OR source_available - earlier_pending < payout_row."amount" THEN
        RAISE EXCEPTION 'Payout reservation exceeds source-backed withdrawable funds.' USING ERRCODE = '23514';
      END IF;
    ELSIF NEW."entry_type" = 'payout_reservation_release' THEN
      SELECT EXISTS (
        SELECT 1 FROM "wallet_ledger_entries"
        WHERE "payout_id" = NEW."payout_id" AND "entry_type" = 'payout_reservation'
      ) INTO reservation_exists;
      IF payout_row."status" <> 'rejected'::"PayoutStatus"
         OR reservation_exists = false
         OR NEW."reserved_delta" <> -payout_row."amount"
         OR NEW."balance_delta" <> 0 OR NEW."total_earned_delta" <> 0 OR NEW."total_withdrawn_delta" <> 0 THEN
        RAISE EXCEPTION 'Payout reservation release is invalid.' USING ERRCODE = '23514';
      END IF;
    ELSE
      SELECT EXISTS (
        SELECT 1 FROM "wallet_ledger_entries"
        WHERE "payout_id" = NEW."payout_id" AND "entry_type" = 'payout_reservation'
      ), EXISTS (
        SELECT 1 FROM "wallet_ledger_entries"
        WHERE "payout_id" = NEW."payout_id" AND "entry_type" = 'payout_reservation_release'
      ) INTO reservation_exists, reservation_release_exists;
      IF payout_row."status" <> 'released'::"PayoutStatus"
         OR reservation_exists = false OR reservation_release_exists = true
         OR NEW."balance_delta" <> -payout_row."amount"
         OR NEW."reserved_delta" <> -payout_row."amount"
         OR NEW."total_earned_delta" <> 0
         OR NEW."total_withdrawn_delta" <> payout_row."amount" THEN
        RAISE EXCEPTION 'Payout disbursement is invalid.' USING ERRCODE = '23514';
      END IF;
    END IF;

  ELSIF NEW."entry_type" = 'deactivation_forfeit' THEN
    SELECT e."wallet_value" INTO deactivation_amount
    FROM "reseller_deactivation_events" e
    WHERE e."id" = NEW."source_event_id" AND e."reseller_id" = NEW."user_id"
    FOR SHARE;
    IF deactivation_amount IS NULL OR recipient_role <> 'reseller' OR recipient_status <> 'inactive'
       OR NEW."balance_delta" <> -deactivation_amount
       OR NEW."reserved_delta" <> 0 OR NEW."total_earned_delta" <> 0 OR NEW."total_withdrawn_delta" <> 0 THEN
      RAISE EXCEPTION 'Deactivation wallet forfeiture is invalid.' USING ERRCODE = '23514';
    END IF;
  ELSE
    RAISE EXCEPTION 'Unsupported wallet ledger entry type.' USING ERRCODE = '23514';
  END IF;

  UPDATE "wallets"
  SET "balance" = "balance" + NEW."balance_delta",
      "reserved_balance" = "reserved_balance" + NEW."reserved_delta",
      "total_earned" = "total_earned" + NEW."total_earned_delta",
      "total_withdrawn" = "total_withdrawn" + NEW."total_withdrawn_delta",
      "updated_at" = CURRENT_TIMESTAMP
  WHERE "user_id" = NEW."user_id"
    AND "balance" + NEW."balance_delta" >= 0
    AND "reserved_balance" + NEW."reserved_delta" >= 0
    AND "balance" + NEW."balance_delta" >= "reserved_balance" + NEW."reserved_delta"
    AND "total_earned" + NEW."total_earned_delta" >= 0
    AND "total_withdrawn" + NEW."total_withdrawn_delta" >= 0;
  GET DIAGNOSTICS changed = ROW_COUNT;

  IF changed <> 1 THEN
    RAISE EXCEPTION 'Wallet ledger delta violates wallet balance invariants.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- processed_at is stored as a UTC timestamp without a time zone, as is
-- the direct-referral allocator's fourth argument.
CREATE OR REPLACE FUNCTION public.allocate_approved_direct_referral_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  IF NEW.status = 'approved' AND (TG_OP = 'INSERT' OR OLD.status <> 'approved') THEN
    PERFORM allocate_direct_referral_payout(
      NEW.id, NEW.user_id, NEW.amount, COALESCE(NEW.processed_at, CURRENT_TIMESTAMP AT TIME ZONE 'UTC')
    );
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION public.allocate_approved_direct_referral_payout() FROM PUBLIC;

CREATE FUNCTION public.allocate_rank_bonus_payout()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  available numeric;
  remaining numeric;
  lot record;
  consumed numeric;
BEGIN
  IF NEW.status <> 'approved' OR (TG_OP = 'UPDATE' AND OLD.status = NEW.status) THEN RETURN NEW; END IF;

  SELECT COALESCE(SUM(amount), 0) INTO available FROM (
    SELECT amount FROM direct_referral_payout_consumptions WHERE payout_id = NEW.id
    UNION ALL SELECT amount FROM binary_payout_consumptions WHERE payout_id = NEW.id
    UNION ALL SELECT amount FROM product_binary_payout_consumptions WHERE payout_id = NEW.id
    UNION ALL SELECT amount FROM rank_bonus_payout_consumptions WHERE payout_id = NEW.id
  ) existing;

  remaining := NEW.amount - available;
  IF remaining <= 0 THEN RETURN NEW; END IF;

  FOR lot IN
    SELECT award.id, award.remaining_amount FROM rank_bonus_awards award
    WHERE award.user_id = NEW.user_id AND award.remaining_amount > 0
    ORDER BY award.allocated_at, award.id
    FOR UPDATE
  LOOP
    consumed := LEAST(remaining, lot.remaining_amount);
    INSERT INTO rank_bonus_payout_consumptions (payout_id, award_id, amount) VALUES (NEW.id, lot.id, consumed);
    UPDATE rank_bonus_awards SET remaining_amount = remaining_amount - consumed WHERE id = lot.id;
    remaining := remaining - consumed;
    EXIT WHEN remaining = 0;
  END LOOP;
  RETURN NEW;
END;
$$;

CREATE TRIGGER zzz_payouts_allocate_rank_bonus
AFTER INSERT OR UPDATE OF status ON public.payouts
FOR EACH ROW EXECUTE FUNCTION public.allocate_rank_bonus_payout();
REVOKE ALL ON FUNCTION public.allocate_rank_bonus_payout() FROM PUBLIC;


CREATE OR REPLACE FUNCTION "require_fully_allocated_approved_payout"()
RETURNS TRIGGER AS $$
DECLARE
  allocated DECIMAL(12,2);
BEGIN
  IF NEW."status" IN ('approved', 'released')
     AND (
       TG_OP = 'INSERT'
       OR OLD."status" IS DISTINCT FROM NEW."status"
     ) THEN
    SELECT COALESCE(SUM(x."amount"), 0)
    INTO allocated
    FROM (
      SELECT c."amount"
      FROM "direct_referral_payout_consumptions" c
      WHERE c."payout_id" = NEW."id"
      UNION ALL
      SELECT c."amount"
      FROM "binary_payout_consumptions" c
      WHERE c."payout_id" = NEW."id"
      UNION ALL
      SELECT c."amount"
      FROM "product_binary_payout_consumptions" c
      WHERE c."payout_id" = NEW."id"
      UNION ALL
      SELECT c."amount" FROM "rank_bonus_payout_consumptions" c WHERE c."payout_id" = NEW."id"
    ) x;

    IF allocated <> NEW."amount" THEN
      RAISE EXCEPTION USING
        ERRCODE = 'P0001',
        MESSAGE = 'Payout is not fully backed by payable commission lots.',
        DETAIL = format(
          'payout_id=%s required=%s allocated=%s',
          NEW."id",
          NEW."amount",
          allocated
        );
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "require_complete_payout_ledger_state"()
RETURNS TRIGGER AS $$
DECLARE
  reservation_count INTEGER;
  reservation_amount DECIMAL(12,2);
  release_count INTEGER;
  release_amount DECIMAL(12,2);
  disbursement_count INTEGER;
  disbursement_amount DECIMAL(12,2);
  allocation_amount DECIMAL(12,2);
BEGIN
  SELECT
    COUNT(*) FILTER (WHERE "entry_type" = 'payout_reservation')::INTEGER,
    COALESCE(SUM("reserved_delta") FILTER (WHERE "entry_type" = 'payout_reservation'), 0),
    COUNT(*) FILTER (WHERE "entry_type" = 'payout_reservation_release')::INTEGER,
    COALESCE(SUM("reserved_delta") FILTER (WHERE "entry_type" = 'payout_reservation_release'), 0),
    COUNT(*) FILTER (WHERE "entry_type" = 'payout_disbursement')::INTEGER,
    COALESCE(SUM(-"balance_delta") FILTER (WHERE "entry_type" = 'payout_disbursement'), 0)
  INTO reservation_count, reservation_amount, release_count, release_amount,
       disbursement_count, disbursement_amount
  FROM "wallet_ledger_entries"
  WHERE "payout_id" = NEW."id";

  SELECT COALESCE(SUM(x."amount"), 0)
  INTO allocation_amount
  FROM (
    SELECT "amount" FROM "direct_referral_payout_consumptions" WHERE "payout_id" = NEW."id"
    UNION ALL
    SELECT "amount" FROM "binary_payout_consumptions" WHERE "payout_id" = NEW."id"
    UNION ALL
    SELECT "amount" FROM "product_binary_payout_consumptions" WHERE "payout_id" = NEW."id"
    UNION ALL
    SELECT "amount" FROM "rank_bonus_payout_consumptions" WHERE "payout_id" = NEW."id"
  ) x;

  IF reservation_count <> 1 OR reservation_amount <> NEW."amount" THEN
    RAISE EXCEPTION 'Payout does not have exactly one matching wallet reservation.' USING ERRCODE = '23514';
  END IF;

  IF NEW."status" = 'pending'::"PayoutStatus" THEN
    IF release_count <> 0 OR disbursement_count <> 0 OR allocation_amount <> 0 THEN
      RAISE EXCEPTION 'Pending payout has premature release, disbursement, or source allocation.' USING ERRCODE = '23514';
    END IF;
  ELSIF NEW."status" = 'rejected'::"PayoutStatus" THEN
    IF release_count <> 1 OR release_amount <> -NEW."amount"
       OR disbursement_count <> 0 OR allocation_amount <> 0 THEN
      RAISE EXCEPTION 'Rejected payout does not have one exact reservation release.' USING ERRCODE = '23514';
    END IF;
  ELSIF NEW."status" = 'approved'::"PayoutStatus" THEN
    IF release_count <> 0 OR disbursement_count <> 0 OR allocation_amount <> NEW."amount" THEN
      RAISE EXCEPTION 'Approved payout is not fully allocated and still reserved.' USING ERRCODE = '23514';
    END IF;
  ELSIF NEW."status" = 'released'::"PayoutStatus" THEN
    IF release_count <> 0 OR disbursement_count <> 1
       OR disbursement_amount <> NEW."amount" OR allocation_amount <> NEW."amount" THEN
      RAISE EXCEPTION 'Released payout lacks one exact funded wallet disbursement.' USING ERRCODE = '23514';
    END IF;
  ELSE
    RAISE EXCEPTION 'Payout has an unsupported lifecycle state.' USING ERRCODE = '23514';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "liquidate_deactivation_payable_lots"()
RETURNS TRIGGER AS $$
DECLARE
  reseller_role TEXT;
  reseller_status TEXT;
  processor_role TEXT;
  processor_status TEXT;
  wallet_balance DECIMAL(12,2);
  wallet_reserved DECIMAL(12,2);
  payable_total DECIMAL(12,2) := 0;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('financial-user:' || NEW."reseller_id"));

  SELECT u."role"::text, u."status"::text
  INTO reseller_role, reseller_status
  FROM "users" u
  WHERE u."id" = NEW."reseller_id"
  FOR SHARE;

  SELECT u."role"::text, u."status"::text
  INTO processor_role, processor_status
  FROM "users" u
  WHERE u."id" = NEW."processed_by"
  FOR SHARE;

  IF reseller_role <> 'reseller' OR reseller_status <> 'inactive'
     OR processor_role <> 'admin' OR processor_status <> 'active' THEN
    RAISE EXCEPTION 'A sealed deactivation requires an inactive reseller and an active Admin processor.' USING ERRCODE = '23514';
  END IF;

  SELECT w."balance", w."reserved_balance"
  INTO wallet_balance, wallet_reserved
  FROM "wallets" w
  WHERE w."user_id" = NEW."reseller_id"
  FOR UPDATE;

  IF wallet_balance IS NULL OR wallet_reserved <> 0
     OR wallet_balance <> NEW."wallet_value" OR NEW."points_value" <> 0
     OR NEW."total_flushed" <> NEW."wallet_value" + NEW."points_value" THEN
    RAISE EXCEPTION 'Deactivation values do not match the unlocked member wallet and zero-value carryover policy.' USING ERRCODE = '23514';
  END IF;

  IF EXISTS (
    SELECT 1 FROM "payouts" p
    WHERE p."user_id" = NEW."reseller_id"
      AND p."status" IN ('pending'::"PayoutStatus", 'approved'::"PayoutStatus")
  ) THEN
    RAISE EXCEPTION 'Resolve pending or approved payouts before deactivation.' USING ERRCODE = '23514';
  END IF;

  PERFORM l."id" FROM "direct_referral_reserve_lots" l
    WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0 FOR UPDATE;
  PERFORM l."id" FROM "binary_payable_lots" l
    WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0 FOR UPDATE;
  PERFORM l."id" FROM "product_binary_payable_lots" l
    WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0 FOR UPDATE;

  SELECT
    COALESCE((SELECT SUM("remaining_amount") FROM "direct_referral_reserve_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "binary_payable_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "product_binary_payable_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "rank_bonus_awards" WHERE "user_id" = NEW."reseller_id"), 0)
  INTO payable_total;

  IF payable_total <> NEW."wallet_value" THEN
    RAISE EXCEPTION 'Wallet and payable liabilities do not reconcile; deactivation is blocked.' USING ERRCODE = '23514';
  END IF;

  INSERT INTO "payable_lot_forfeitures" (
    "deactivation_event_id", "source_type", "direct_lot_id", "amount", "created_at"
  )
  SELECT NEW."id", 'direct_referral', l."id", l."remaining_amount", NEW."created_at"
  FROM "direct_referral_reserve_lots" l
  WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0;

  INSERT INTO "payable_lot_forfeitures" (
    "deactivation_event_id", "source_type", "binary_lot_id", "amount", "created_at"
  )
  SELECT NEW."id", 'binary', l."id", l."remaining_amount", NEW."created_at"
  FROM "binary_payable_lots" l
  WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0;

  INSERT INTO "payable_lot_forfeitures" (
    "deactivation_event_id", "source_type", "product_binary_lot_id", "amount", "created_at"
  )
  SELECT NEW."id", 'product_binary', l."id", l."remaining_amount", NEW."created_at"
  FROM "product_binary_payable_lots" l
  WHERE l."user_id" = NEW."reseller_id" AND l."remaining_amount" > 0;

  INSERT INTO "payable_lot_forfeitures" (
    "deactivation_event_id", "source_type", "rank_bonus_lot_id", "amount", "created_at"
  )
  SELECT NEW."id", 'rank_bonus', award.id, award.remaining_amount, NEW."created_at"
  FROM public.rank_bonus_awards award
  WHERE award.user_id = NEW."reseller_id" AND award.remaining_amount > 0;

  UPDATE public.rank_bonus_awards SET remaining_amount = 0
  WHERE user_id = NEW."reseller_id" AND remaining_amount > 0;

  UPDATE "direct_referral_reserve_lots"
  SET "remaining_amount" = 0
  WHERE "user_id" = NEW."reseller_id" AND "remaining_amount" > 0;

  UPDATE "binary_payable_lots"
  SET "remaining_amount" = 0
  WHERE "user_id" = NEW."reseller_id" AND "remaining_amount" > 0;

  UPDATE "product_binary_payable_lots"
  SET "remaining_amount" = 0
  WHERE "user_id" = NEW."reseller_id" AND "remaining_amount" > 0;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "verify_deactivation_financial_liquidation"()
RETURNS TRIGGER AS $$
DECLARE
  ledger_count BIGINT := 0;
  ledger_amount DECIMAL(12,2) := 0;
  forfeiture_total DECIMAL(12,2) := 0;
  remaining_total DECIMAL(12,2) := 0;
  transfer_count BIGINT := 0;
  exact_transfer_count BIGINT := 0;
  audit_count BIGINT := 0;
  current_wallet_balance DECIMAL(12,2);
  current_wallet_reserved DECIMAL(12,2);
  profile_left INTEGER;
  profile_right INTEGER;
  profile_active BOOLEAN;
  current_status TEXT;
BEGIN
  IF NEW."liability_liquidation_version" IS DISTINCT FROM 'deactivation-liability-v1' THEN
    RAISE EXCEPTION 'Unknown deactivation liability liquidation version.' USING ERRCODE = '23514';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(-w."balance_delta"), 0)
  INTO ledger_count, ledger_amount
  FROM "wallet_ledger_entries" w
  WHERE w."entry_type" = 'deactivation_forfeit'
    AND w."source_kind" = 'deactivation'
    AND w."source_event_id" = NEW."id"
    AND w."user_id" = NEW."reseller_id";

  SELECT COALESCE(SUM(f."amount"), 0)
  INTO forfeiture_total
  FROM "payable_lot_forfeitures" f
  WHERE f."deactivation_event_id" = NEW."id";

  SELECT
    COALESCE((SELECT SUM("remaining_amount") FROM "direct_referral_reserve_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "binary_payable_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "product_binary_payable_lots" WHERE "user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "rank_bonus_awards" WHERE "user_id" = NEW."reseller_id"), 0)
  INTO remaining_total;

  SELECT COUNT(*), COUNT(*) FILTER (
    WHERE c."type" = 'deactivation_wallet_transfer'::"CommissionType"
      AND c."amount" = NEW."wallet_value"
      AND c."source_user_id" = NEW."reseller_id"
      AND c."is_pair_overflow" = true
  )
  INTO transfer_count, exact_transfer_count
  FROM "commissions" c
  WHERE c."source_event_kind" = 'deactivation'
    AND c."source_event_id" = NEW."id";

  SELECT COUNT(*) INTO audit_count
  FROM "audit_logs" a
  WHERE a."activity_type" = 'reseller_deactivated'
    AND a."status" = 'completed'
    AND a."metadata"->>'deactivation_event_id' = NEW."id";

  SELECT w."balance", w."reserved_balance"
  INTO current_wallet_balance, current_wallet_reserved
  FROM "wallets" w WHERE w."user_id" = NEW."reseller_id";

  SELECT COALESCE(rp."left_points", 0), COALESCE(rp."right_points", 0), rp."is_active"
  INTO profile_left, profile_right, profile_active
  FROM "reseller_profiles" rp WHERE rp."user_id" = NEW."reseller_id";

  SELECT u."status"::text INTO current_status
  FROM "users" u WHERE u."id" = NEW."reseller_id";

  IF ledger_count <> 1 OR ledger_amount <> NEW."wallet_value"
     OR forfeiture_total <> NEW."wallet_value" OR remaining_total <> 0
     OR current_wallet_balance IS DISTINCT FROM 0 OR current_wallet_reserved IS DISTINCT FROM 0
     OR profile_left IS DISTINCT FROM 0 OR profile_right IS DISTINCT FROM 0 OR profile_active IS DISTINCT FROM false
     OR current_status IS DISTINCT FROM 'inactive' OR audit_count <> 1
     OR (NEW."wallet_value" > 0 AND (transfer_count <> 1 OR exact_transfer_count <> 1))
     OR (NEW."wallet_value" = 0 AND transfer_count <> 0) THEN
    RAISE EXCEPTION 'Deactivation financial liquidation is incomplete or inconsistent.' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "verify_deactivation_fresh_zero_state"()
RETURNS TRIGGER AS $$
DECLARE
  wallet_count BIGINT := 0;
  wallet_balance DECIMAL(12,2) := 0;
  wallet_reserved DECIMAL(12,2) := 0;
  remaining_payable DECIMAL(12,2) := 0;
  open_payout_count BIGINT := 0;
  profile_count BIGINT := 0;
  profile_left INTEGER := 0;
  profile_right INTEGER := 0;
  profile_active BOOLEAN;
  product_left INTEGER := 0;
  product_right INTEGER := 0;
  audit_count BIGINT := 0;
  current_status TEXT;
BEGIN
  SELECT COUNT(*), COALESCE(SUM(w."balance"), 0),
         COALESCE(SUM(w."reserved_balance"), 0)
  INTO wallet_count, wallet_balance, wallet_reserved
  FROM "wallets" w
  WHERE w."user_id" = NEW."reseller_id";

  SELECT
    COALESCE((SELECT SUM(l."remaining_amount") FROM "direct_referral_reserve_lots" l WHERE l."user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM(l."remaining_amount") FROM "binary_payable_lots" l WHERE l."user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM(l."remaining_amount") FROM "product_binary_payable_lots" l WHERE l."user_id" = NEW."reseller_id"), 0)
    + COALESCE((SELECT SUM("remaining_amount") FROM "rank_bonus_awards" WHERE "user_id" = NEW."reseller_id"), 0)
  INTO remaining_payable;

  SELECT COUNT(*)
  INTO open_payout_count
  FROM "payouts" p
  WHERE p."user_id" = NEW."reseller_id"
    AND p."status" IN ('pending'::"PayoutStatus", 'approved'::"PayoutStatus");

  SELECT COUNT(*), COALESCE(SUM(COALESCE(rp."left_points", 0)), 0)::INTEGER,
         COALESCE(SUM(COALESCE(rp."right_points", 0)), 0)::INTEGER,
         BOOL_AND(rp."is_active")
  INTO profile_count, profile_left, profile_right, profile_active
  FROM "reseller_profiles" rp
  WHERE rp."user_id" = NEW."reseller_id";

  SELECT COALESCE(SUM(position."left_carryover_pu"), 0)::INTEGER,
         COALESCE(SUM(position."right_carryover_pu"), 0)::INTEGER
  INTO product_left, product_right
  FROM "product_binary_positions" position
  WHERE position."user_id" = NEW."reseller_id";

  SELECT COUNT(*)
  INTO audit_count
  FROM "audit_logs" audit
  WHERE audit."activity_type" = 'reseller_deactivated'
    AND audit."status" = 'completed'
    AND audit."metadata"->>'deactivation_event_id' = NEW."id"
    AND audit."created_at" = NEW."created_at";

  SELECT u."status"::text
  INTO current_status
  FROM "users" u
  WHERE u."id" = NEW."reseller_id";

  IF NEW."created_at" IS DISTINCT FROM transaction_timestamp()
     OR audit_count <> 1
     OR current_status IS DISTINCT FROM 'inactive'
     OR wallet_count <> 1 OR wallet_balance <> 0 OR wallet_reserved <> 0
     OR remaining_payable <> 0 OR open_payout_count <> 0
     OR profile_count <> 1 OR profile_left <> 0 OR profile_right <> 0
     OR profile_active IS DISTINCT FROM false
     OR product_left <> 0 OR product_right <> 0 THEN
    RAISE EXCEPTION 'Deactivation requires fresh same-transaction evidence and a zero-liability closing state.' USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "verify_reseller_status_transition"()
RETURNS TRIGGER AS $$
DECLARE
  profile_count BIGINT := 0;
  profile_active BOOLEAN;
  profile_left INTEGER := 0;
  profile_right INTEGER := 0;
  product_left INTEGER := 0;
  product_right INTEGER := 0;
  evidence_count BIGINT := 0;
  wallet_count BIGINT := 0;
  wallet_balance DECIMAL(12,2) := 0;
  wallet_reserved DECIMAL(12,2) := 0;
  remaining_payable DECIMAL(12,2) := 0;
  open_payout_count BIGINT := 0;
  current_status TEXT;
BEGIN
  IF OLD."role" <> 'reseller'::"Role"
     OR NEW."status" IS NOT DISTINCT FROM OLD."status" THEN
    RETURN NEW;
  END IF;

  SELECT COUNT(*), BOOL_AND(rp."is_active"),
         COALESCE(SUM(COALESCE(rp."left_points", 0)), 0)::INTEGER,
         COALESCE(SUM(COALESCE(rp."right_points", 0)), 0)::INTEGER
  INTO profile_count, profile_active, profile_left, profile_right
  FROM "reseller_profiles" rp
  WHERE rp."user_id" = NEW."id";

  SELECT u."status"::text
  INTO current_status
  FROM "users" u
  WHERE u."id" = NEW."id";

  IF current_status IS DISTINCT FROM NEW."status"::text
     OR profile_count <> 1
     OR profile_active IS DISTINCT FROM (NEW."status" = 'active'::"UserStatus") THEN
    RAISE EXCEPTION 'Reseller status and profile activity are inconsistent.' USING ERRCODE = '23514';
  END IF;

  IF NEW."status" = 'inactive'::"UserStatus" THEN
    SELECT COUNT(*)
    INTO evidence_count
    FROM "reseller_deactivation_events" event
    WHERE event."reseller_id" = NEW."id"
      AND event."liability_liquidation_version" = 'deactivation-liability-v1'
      AND event."created_at" = transaction_timestamp();

    SELECT COUNT(*), COALESCE(SUM(w."balance"), 0),
           COALESCE(SUM(w."reserved_balance"), 0)
    INTO wallet_count, wallet_balance, wallet_reserved
    FROM "wallets" w
    WHERE w."user_id" = NEW."id";

    SELECT
      COALESCE((SELECT SUM(l."remaining_amount") FROM "direct_referral_reserve_lots" l WHERE l."user_id" = NEW."id"), 0)
      + COALESCE((SELECT SUM(l."remaining_amount") FROM "binary_payable_lots" l WHERE l."user_id" = NEW."id"), 0)
      + COALESCE((SELECT SUM(l."remaining_amount") FROM "product_binary_payable_lots" l WHERE l."user_id" = NEW."id"), 0)
      + COALESCE((SELECT SUM("remaining_amount") FROM "rank_bonus_awards" WHERE "user_id" = NEW."id"), 0)
    INTO remaining_payable;

    SELECT COUNT(*)
    INTO open_payout_count
    FROM "payouts" p
    WHERE p."user_id" = NEW."id"
      AND p."status" IN ('pending'::"PayoutStatus", 'approved'::"PayoutStatus");

    SELECT COALESCE(SUM(position."left_carryover_pu"), 0)::INTEGER,
           COALESCE(SUM(position."right_carryover_pu"), 0)::INTEGER
    INTO product_left, product_right
    FROM "product_binary_positions" position
    WHERE position."user_id" = NEW."id";

    IF evidence_count <> 1
       OR wallet_count <> 1 OR wallet_balance <> 0 OR wallet_reserved <> 0
       OR remaining_payable <> 0 OR open_payout_count <> 0
       OR profile_left <> 0 OR profile_right <> 0
       OR product_left <> 0 OR product_right <> 0 THEN
      RAISE EXCEPTION 'Inactive reseller transition requires one fresh sealed settlement and zero remaining liability or carryover.' USING ERRCODE = '23514';
    END IF;
  ELSE
    SELECT COUNT(*)
    INTO evidence_count
    FROM "audit_logs" audit
    WHERE audit."activity_type" = 'reseller_status_changed'
      AND audit."status" = 'completed'
      AND audit."metadata"->>'reseller_id' = NEW."id"
      AND audit."metadata"->>'to_status' = NEW."status"::text
      AND audit."created_at" = transaction_timestamp();

    IF evidence_count <> 1 THEN
      RAISE EXCEPTION 'Reseller activation or suspension requires one fresh immutable audit event.' USING ERRCODE = '23514';
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW "wallet_funding_reconciliation" AS
SELECT
  w."user_id",
  w."balance",
  w."reserved_balance",
  COALESCE(d."amount", 0) + COALESCE(b."amount", 0) + COALESCE(pb."amount", 0) + COALESCE(rb."amount", 0)
    + COALESCE(ap."amount", 0) AS "source_backed_liability",
  w."balance" - (
    COALESCE(d."amount", 0) + COALESCE(b."amount", 0) + COALESCE(pb."amount", 0) + COALESCE(rb."amount", 0)
    + COALESCE(ap."amount", 0)
  ) AS "unreconciled_balance"
FROM "wallets" w
LEFT JOIN (
  SELECT "user_id", SUM("remaining_amount") AS amount
  FROM "direct_referral_reserve_lots" GROUP BY "user_id"
) d ON d."user_id" = w."user_id"
LEFT JOIN (
  SELECT "user_id", SUM("remaining_amount") AS amount
  FROM "binary_payable_lots" GROUP BY "user_id"
) b ON b."user_id" = w."user_id"
LEFT JOIN (
  SELECT "user_id", SUM("remaining_amount") AS amount
  FROM "product_binary_payable_lots" GROUP BY "user_id"
) pb ON pb."user_id" = w."user_id"
LEFT JOIN (
  SELECT "user_id", SUM("remaining_amount") AS amount
  FROM "rank_bonus_awards" GROUP BY "user_id"
) rb ON rb."user_id" = w."user_id"
LEFT JOIN (
  SELECT "user_id", SUM("amount") AS amount
  FROM "payouts" WHERE "status" = 'approved'::"PayoutStatus" GROUP BY "user_id"
) ap ON ap."user_id" = w."user_id";


ALTER FUNCTION public.apply_wallet_ledger_entry() SECURITY DEFINER;
ALTER FUNCTION public.apply_wallet_ledger_entry() SET search_path TO pg_catalog, public, pg_temp;
REVOKE ALL ON FUNCTION public.apply_wallet_ledger_entry() FROM PUBLIC;
ALTER FUNCTION public.liquidate_deactivation_payable_lots() SECURITY DEFINER;
ALTER FUNCTION public.liquidate_deactivation_payable_lots() SET search_path TO pg_catalog, public, pg_temp;
REVOKE ALL ON FUNCTION public.liquidate_deactivation_payable_lots() FROM PUBLIC;

-- Match the existing application grants on financial evidence. Only the
-- guarded settlement function and payout/deactivation triggers write awards.
DO $$
DECLARE runtime_role record;
BEGIN
  FOR runtime_role IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role') LOOP
    EXECUTE format('REVOKE ALL ON public.rank_bonus_programs, public.rank_bonus_funding, public.rank_bonus_awards, public.rank_bonus_payout_consumptions FROM %I', runtime_role.rolname);
    EXECUTE format('REVOKE ALL ON FUNCTION public.process_rank_bonus_awards(timestamptz, integer) FROM %I', runtime_role.rolname);
    EXECUTE format('REVOKE ALL ON FUNCTION public.rank_bonus_progress(text, timestamptz, timestamptz) FROM %I', runtime_role.rolname);
  END LOOP;
  FOR runtime_role IN
    SELECT DISTINCT role.rolname
    FROM pg_proc proc
    CROSS JOIN LATERAL aclexplode(proc.proacl) access
    JOIN pg_roles role ON role.oid = access.grantee
    WHERE proc.oid = 'public.release_product_binary_pool_week(date)'::regprocedure
      AND access.privilege_type = 'EXECUTE'
      AND role.rolname NOT IN ('anon', 'authenticated', 'service_role')
      AND NOT role.rolsuper
  LOOP
    EXECUTE format('GRANT SELECT ON public.rank_bonus_programs, public.rank_bonus_funding, public.rank_bonus_awards, public.rank_bonus_payout_consumptions TO %I', runtime_role.rolname);
    EXECUTE format('GRANT INSERT ON public.rank_bonus_programs, public.rank_bonus_funding TO %I', runtime_role.rolname);
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.process_rank_bonus_awards(timestamptz, integer), public.rank_bonus_progress(text, timestamptz, timestamptz) TO %I', runtime_role.rolname);
  END LOOP;
END;
$$;

COMMIT;

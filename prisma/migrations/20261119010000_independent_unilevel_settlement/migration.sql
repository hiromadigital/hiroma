BEGIN;

-- A paid order can reserve stock funding and pay its Unilevel sponsors before
-- binary matching succeeds. The binary obligation remains durable and must
-- still contain the complete ancestor set before it can be marked completed.
CREATE TABLE public.unilevel_product_order_preparations (
  order_event_id uuid PRIMARY KEY REFERENCES public.product_binary_order_events(id) DEFERRABLE INITIALLY DEFERRED,
  settlement_job_id uuid NOT NULL UNIQUE REFERENCES public.product_binary_settlement_jobs(id),
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);
CREATE TABLE public.unilevel_settlement_jobs (
  settlement_job_id uuid PRIMARY KEY REFERENCES public.unilevel_qualified_orders(settlement_job_id),
  status text NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','failed','settled')),
  attempts integer NOT NULL DEFAULT 0 CHECK(attempts >= 0),
  next_attempt_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  last_error text,
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp(),
  CHECK((status='settled') = (settled_at IS NOT NULL))
);
CREATE INDEX unilevel_matching_pending_idx ON public.product_binary_settlement_jobs(id) WHERE status<>'completed';
CREATE INDEX unilevel_jobs_due_idx ON public.unilevel_settlement_jobs(next_attempt_at,settlement_job_id)
WHERE status IN ('pending','failed');
CREATE TRIGGER unilevel_preparations_immutable BEFORE UPDATE OR DELETE ON public.unilevel_product_order_preparations
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();
REVOKE ALL ON public.unilevel_product_order_preparations,public.unilevel_settlement_jobs FROM PUBLIC;

-- Original stock policies fund their original levels. Increasing the current
-- depth cannot dilute a previously funded PHP1 slot or invent a new earmark.
CREATE VIEW public.unilevel_level_funding AS
SELECT movement.order_event_id,slot.level,SUM(movement.units::numeric) AS funded_amount
FROM public.product_binary_inventory_reserve_transfers movement
JOIN public.unilevel_inventory_earmarks earmark USING(source_order_item_id)
CROSS JOIN LATERAL generate_series(1,earmark.levels) slot(level)
GROUP BY movement.order_event_id,slot.level;
REVOKE ALL ON public.unilevel_level_funding FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.capture_unilevel_qualification() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
  configured_levels integer := public.unilevel_level_count();
  month_start timestamptz;
BEGIN
  IF NEW.qualification_status <> 'qualified_paid_delivery'
     OR NEW.qualified_at IS NULL OR COALESCE(NEW.eligible_units_snapshot,0) <= 0 THEN RETURN NEW; END IF;
  -- A reduced current depth cannot erase the original funded levels of
  -- remaining stock. Capture enough fixed sponsor positions for those receipts;
  -- only the levels actually funded by FIFO transfers can receive money.
  SELECT GREATEST(configured_levels,COALESCE(MAX(earmark.levels),configured_levels)) INTO configured_levels
  FROM public.orders sale JOIN public.order_items item ON item.order_id=sale.id
  JOIN public.product_binary_inventory_reserves stock ON stock.distributor_id=sale.seller_id AND stock.product_id=item.product_id
  JOIN public.unilevel_inventory_earmarks earmark USING(source_order_item_id)
  WHERE sale.id=NEW.order_id AND stock.remaining_units>0 AND item.binary_eligible_snapshot AND item.pu_value_snapshot>0;
  INSERT INTO public.unilevel_qualified_orders(settlement_job_id,levels,qualified_at)
  VALUES(NEW.id,configured_levels,NEW.qualified_at) ON CONFLICT DO NOTHING;
  IF NOT FOUND THEN RETURN NEW; END IF;
  month_start := date_trunc('month', NEW.qualified_at AT TIME ZONE 'Asia/Manila') AT TIME ZONE 'Asia/Manila';
  INSERT INTO public.unilevel_qualified_recipients(settlement_job_id,level,user_id,disposition)
  WITH RECURSIVE sponsors AS (
    SELECT 1 AS level,node.sponsor_id AS user_id,ARRAY[NEW.buyer_user_id,node.sponsor_id] AS visited
    FROM public.binary_tree_nodes node
    WHERE node.user_id=NEW.buyer_user_id AND node.sponsor_id <> NEW.buyer_user_id
    UNION ALL
    SELECT sponsor.level+1,node.sponsor_id,sponsor.visited||node.sponsor_id
    FROM sponsors sponsor JOIN public.binary_tree_nodes node ON node.user_id=sponsor.user_id
    WHERE sponsor.level < configured_levels AND node.sponsor_id <> ALL(sponsor.visited)
  )
  SELECT NEW.id,slot.level,sponsor.user_id,
    CASE WHEN sponsor.user_id IS NULL THEN 'no_sponsor'
      WHEN member.role IS DISTINCT FROM 'reseller' OR member.status IS DISTINCT FROM 'active'
        OR profile.is_active IS DISTINCT FROM true THEN 'inactive_account'
      WHEN NOT EXISTS (
        SELECT 1 FROM public.product_binary_settlement_jobs job
        WHERE job.buyer_user_id=sponsor.user_id AND job.qualification_status='qualified_paid_delivery'
          AND job.eligible_units_snapshot>=1 AND job.qualified_at>=month_start AND job.qualified_at<=NEW.qualified_at
      ) THEN 'monthly_purchase_required'
      ELSE 'qualified' END
  FROM generate_series(1,configured_levels) slot(level)
  LEFT JOIN sponsors sponsor ON sponsor.level=slot.level
  LEFT JOIN public.users member ON member.id=sponsor.user_id
  LEFT JOIN public.reseller_profiles profile ON profile.user_id=sponsor.user_id;
  RETURN NEW;
END;
$$;
CREATE FUNCTION public.assert_complete_product_order(event_key uuid) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE mismatch boolean;
BEGIN
  WITH RECURSIVE ancestors AS (
    SELECT parent.id,parent.user_id,parent.parent_id
    FROM public.product_binary_order_events event
    JOIN public.binary_tree_nodes buyer ON buyer.user_id=event.buyer_user_id
    JOIN public.binary_tree_nodes parent ON parent.id=buyer.parent_id WHERE event.id=event_key
    UNION ALL
    SELECT parent.id,parent.user_id,parent.parent_id FROM ancestors child
    JOIN public.binary_tree_nodes parent ON parent.id=child.parent_id
  ), expected AS (
    SELECT a.user_id FROM ancestors a JOIN public.reseller_profiles p ON p.user_id=a.user_id
  ), recorded AS (
    SELECT recipient_user_id AS user_id FROM public.product_binary_pair_events WHERE order_event_id=event_key
  ) SELECT EXISTS(
    (SELECT user_id FROM expected EXCEPT SELECT user_id FROM recorded)
    UNION ALL (SELECT user_id FROM recorded EXCEPT SELECT user_id FROM expected)
  ) INTO mismatch;
  IF mismatch THEN
    RAISE EXCEPTION 'Product Binary order requires one volume event for every eligible ancestor.' USING ERRCODE='23514';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.validate_product_binary_order_event_completeness() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
  IF EXISTS(SELECT 1 FROM public.unilevel_product_order_preparations preparation
    JOIN public.product_binary_settlement_jobs job ON job.id=preparation.settlement_job_id
    WHERE preparation.order_event_id=NEW.id AND job.status<>'completed') THEN RETURN NEW; END IF;
  PERFORM public.assert_complete_product_order(NEW.id);
  RETURN NEW;
END;
$$;

CREATE FUNCTION public.require_completed_prepared_product_order() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE event_key uuid; job_status text;
BEGIN
  IF TG_TABLE_NAME='product_binary_pair_events' THEN
    event_key:=NEW.order_event_id;
  ELSE
    IF NEW.status<>'completed' THEN RETURN NEW; END IF;
    SELECT order_event_id INTO event_key FROM public.unilevel_product_order_preparations WHERE settlement_job_id=NEW.id;
  END IF;
  SELECT job.status INTO job_status FROM public.unilevel_product_order_preparations preparation
  JOIN public.product_binary_settlement_jobs job ON job.id=preparation.settlement_job_id
  WHERE preparation.order_event_id=event_key;
  IF NOT FOUND THEN RETURN NEW; END IF;
  IF job_status<>'completed' THEN
    RAISE EXCEPTION 'Prepared binary volume cannot commit before matching completes.' USING ERRCODE='23514';
  END IF;
  PERFORM public.assert_complete_product_order(event_key);
  RETURN NEW;
END;
$$;
CREATE CONSTRAINT TRIGGER product_binary_prepared_pairs_complete
AFTER INSERT ON public.product_binary_pair_events DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.require_completed_prepared_product_order();
CREATE CONSTRAINT TRIGGER product_binary_prepared_job_complete
AFTER UPDATE OF status ON public.product_binary_settlement_jobs DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW EXECUTE FUNCTION public.require_completed_prepared_product_order();

CREATE FUNCTION public.enqueue_unilevel_order() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
  INSERT INTO public.unilevel_settlement_jobs(settlement_job_id)
  SELECT NEW.id WHERE EXISTS(SELECT 1 FROM public.unilevel_qualified_orders WHERE settlement_job_id=NEW.id)
  ON CONFLICT DO NOTHING;
  RETURN NEW;
END;
$$;
CREATE TRIGGER zz_product_orders_enqueue_unilevel
AFTER INSERT OR UPDATE OF qualification_status,qualified_at ON public.product_binary_settlement_jobs
FOR EACH ROW EXECUTE FUNCTION public.enqueue_unilevel_order();

-- Compatibility trigger only enqueues work. A Unilevel credit failure must
-- never roll back completed binary matching in another transaction.
CREATE OR REPLACE FUNCTION public.settle_unilevel_order() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
  IF NEW.status='completed' THEN
    INSERT INTO public.unilevel_settlement_jobs(settlement_job_id)
    SELECT NEW.id WHERE EXISTS(SELECT 1 FROM public.unilevel_qualified_orders WHERE settlement_job_id=NEW.id)
    ON CONFLICT DO NOTHING;
  END IF;
  RETURN NEW;
END;
$$;

-- Enqueue only orders whose original paid-delivery qualification was captured.
-- Earlier transactions without that immutable evidence gain no new credits.
INSERT INTO public.unilevel_settlement_jobs(settlement_job_id,status,settled_at)
SELECT qualification.settlement_job_id,
  CASE WHEN settlement.order_event_id IS NOT NULL THEN 'settled' ELSE 'pending' END,
  settlement.settled_at
FROM public.unilevel_qualified_orders qualification
LEFT JOIN public.product_binary_order_events event ON event.settlement_job_id=qualification.settlement_job_id
LEFT JOIN public.unilevel_order_settlements settlement ON settlement.order_event_id=event.id;

CREATE FUNCTION public.settle_funded_unilevel_order(event_key uuid) RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE
  source_event public.product_binary_order_events;
  funding numeric(12,2);
  share numeric(12,2);
  total_credit numeric(12,2) := 0;
  total_retained numeric(12,2) := 0;
  slot_count integer;
  allocation record;
  recipient text;
  reason text;
  lot_id uuid;
  credit_id text;
BEGIN
  SELECT * INTO source_event FROM public.product_binary_order_events WHERE id=event_key;
  IF NOT FOUND OR EXISTS(SELECT 1 FROM public.unilevel_order_settlements WHERE order_event_id=source_event.id) THEN RETURN false; END IF;
  SELECT COUNT(*) INTO slot_count FROM public.unilevel_order_allocations WHERE order_event_id=source_event.id;
  IF slot_count=0 THEN RETURN false; END IF;
  SELECT COALESCE(funded_amount,0) INTO funding FROM public.unilevel_order_funding WHERE order_event_id=source_event.id;
  funding := COALESCE(funding,0);
  FOR recipient IN SELECT DISTINCT user_id FROM public.unilevel_order_allocations
    WHERE order_event_id=source_event.id AND user_id IS NOT NULL ORDER BY user_id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtext('financial-user:'||recipient));
  END LOOP;
  FOR allocation IN SELECT * FROM public.unilevel_order_allocations
    WHERE order_event_id=source_event.id ORDER BY level
  LOOP
    SELECT COALESCE(SUM(funded_amount),0) INTO share FROM public.unilevel_level_funding
    WHERE order_event_id=source_event.id AND level=allocation.level;
    share:=LEAST(source_event.eligible_units::numeric,share);
    IF share=0 THEN CONTINUE; END IF;
    reason := allocation.disposition;
    IF reason='qualified' THEN
      PERFORM 1 FROM public.users member JOIN public.reseller_profiles profile ON profile.user_id=member.id
      WHERE member.id=allocation.user_id AND member.role='reseller' AND member.status='active' AND profile.is_active
      FOR SHARE OF member,profile;
      IF NOT FOUND THEN reason := 'recipient_unavailable_at_credit'; END IF;
    END IF;
    IF reason='qualified' THEN
      lot_id := gen_random_uuid();
      credit_id := gen_random_uuid()::text;
      INSERT INTO public.wallets(id,user_id,updated_at) VALUES(gen_random_uuid()::text,allocation.user_id,CURRENT_TIMESTAMP)
      ON CONFLICT(user_id) DO NOTHING;
      INSERT INTO public.unilevel_payable_lots(id,order_event_id,level,user_id,original_amount,remaining_amount,commission_id)
      VALUES(lot_id,source_event.id,allocation.level,allocation.user_id,share,share,credit_id);
      INSERT INTO public.commissions(id,event_key,source_event_kind,source_event_id,rule_version,user_id,type,amount,source_user_id)
      VALUES(credit_id,'unilevel:'||source_event.id||':level:'||allocation.level,'unilevel_order',lot_id::text,
        'unilevel-v2',allocation.user_id,'multilevel',share,source_event.buyer_user_id);
      total_credit := total_credit+share;
    ELSE
      INSERT INTO public.unilevel_retention_entries(order_event_id,level,user_id,reason,amount)
      VALUES(source_event.id,allocation.level,allocation.user_id,reason,share);
      total_retained := total_retained+share;
    END IF;
  END LOOP;
  IF funding>total_credit+total_retained THEN
    INSERT INTO public.unilevel_retention_entries(order_event_id,level,reason,amount)
    VALUES(source_event.id,0,'rounding_or_excess_funding',funding-total_credit-total_retained);
    total_retained := funding-total_credit;
  END IF;
  INSERT INTO public.unilevel_order_settlements(order_event_id,funded_amount,credited_amount,retained_amount)
  VALUES(source_event.id,funding,total_credit,total_retained);
  RETURN true;
END;
$$;


CREATE FUNCTION public.process_unilevel_order(order_key text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
DECLARE job public.product_binary_settlement_jobs; event_key uuid; member_key text; queued boolean;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('product-binary:'||order_key));
  SELECT * INTO job FROM public.product_binary_settlement_jobs WHERE order_id=order_key FOR UPDATE;
  IF NOT FOUND OR job.qualification_status<>'qualified_paid_delivery'
    OR job.snapshot_version IS DISTINCT FROM 'product-binary-order-v1'
    OR COALESCE(job.eligible_units_snapshot,0)<=0
    OR NOT EXISTS(SELECT 1 FROM public.unilevel_qualified_orders WHERE settlement_job_id=job.id)
  THEN RETURN 'not_eligible'; END IF;
  PERFORM 1 FROM public.unilevel_settlement_jobs WHERE settlement_job_id=job.id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Qualified Unilevel order has no durable settlement job.'; END IF;
  IF EXISTS(SELECT 1 FROM public.unilevel_settlement_jobs WHERE settlement_job_id=job.id AND status='settled')
  THEN RETURN 'already_settled'; END IF;

  -- Same financial lock order as matching, including sponsor-only ancestors.
  FOR member_key IN
    WITH RECURSIVE chain AS (
      SELECT node.id,node.user_id,node.parent_id FROM public.binary_tree_nodes node WHERE node.user_id=job.buyer_user_id
      UNION ALL SELECT parent.id,parent.user_id,parent.parent_id FROM chain child
      JOIN public.binary_tree_nodes parent ON parent.id=child.parent_id
    ) SELECT user_id FROM chain
      UNION SELECT user_id FROM public.unilevel_qualified_recipients WHERE settlement_job_id=job.id AND user_id IS NOT NULL
      UNION SELECT job.buyer_user_id ORDER BY user_id
  LOOP PERFORM pg_advisory_xact_lock(hashtext('financial-user:'||member_key)); END LOOP;

  SELECT id INTO event_key FROM public.product_binary_order_events WHERE settlement_job_id=job.id;
  IF NOT FOUND THEN
    event_key:=gen_random_uuid();
    INSERT INTO public.unilevel_product_order_preparations(order_event_id,settlement_job_id) VALUES(event_key,job.id);
    INSERT INTO public.product_binary_order_events(id,order_id,buyer_user_id,eligible_units,total_pu,recorded_gross_margin,settlement_job_id)
    VALUES(event_key,job.order_id,job.buyer_user_id,job.eligible_units_snapshot,job.total_pu_snapshot,job.gross_margin_snapshot,job.id);
    SELECT public.queue_product_binary_pool_order(event_key,transaction_timestamp(),(public.product_binary_pair_amount()*100)::integer) INTO queued;
    IF NOT queued THEN RAISE EXCEPTION 'Unilevel funding requires the approved weekly stock funding path.'; END IF;
  END IF;
  IF NOT public.settle_funded_unilevel_order(event_key) AND NOT EXISTS(
    SELECT 1 FROM public.unilevel_order_settlements WHERE order_event_id=event_key
  ) THEN RAISE EXCEPTION 'Unilevel source snapshots require reconciliation.'; END IF;
  UPDATE public.unilevel_settlement_jobs SET status='settled',settled_at=transaction_timestamp(),
    attempts=attempts+1,last_error=NULL WHERE settlement_job_id=job.id;
  RETURN 'settled';
END;
$$;

CREATE FUNCTION public.claim_pending_unilevel_orders(requested integer) RETURNS TABLE(order_id text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
  RETURN QUERY WITH due AS (
    SELECT settlement.settlement_job_id FROM public.unilevel_settlement_jobs settlement
    WHERE settlement.status IN ('pending','failed') AND settlement.next_attempt_at<=clock_timestamp()
    ORDER BY settlement.next_attempt_at,settlement.settlement_job_id
    FOR UPDATE SKIP LOCKED LIMIT LEAST(GREATEST(requested,1),10)
  ), leased AS (
    UPDATE public.unilevel_settlement_jobs settlement SET next_attempt_at=clock_timestamp()+interval '2 minutes'
    FROM due WHERE settlement.settlement_job_id=due.settlement_job_id RETURNING settlement.settlement_job_id
  ) SELECT job.order_id::text FROM leased JOIN public.product_binary_settlement_jobs job ON job.id=leased.settlement_job_id;
END;
$$;

CREATE FUNCTION public.record_unilevel_retry(order_key text,failure text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
  UPDATE public.unilevel_settlement_jobs settlement SET status='failed',attempts=settlement.attempts+1,
    last_error=left(failure,2000),next_attempt_at=clock_timestamp()+make_interval(secs=>LEAST(3600,30*power(2,LEAST(settlement.attempts,6)))::integer)
  FROM public.product_binary_settlement_jobs job
  WHERE job.id=settlement.settlement_job_id AND job.order_id=order_key AND settlement.status<>'settled';
END;
$$;

DO $updates$
DECLARE definition text; needle text; replacement text;
BEGIN
  SELECT pg_get_functiondef('public.validate_exact_commission_entitlement()'::regprocedure) INTO definition;
  needle:='NEW.rule_version IS DISTINCT FROM ''unilevel-v1''';
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'Unilevel entitlement boundary is missing.'; END IF;
  EXECUTE replace(definition,needle,'(NEW.rule_version IS NULL OR NEW.rule_version NOT IN (''unilevel-v1'',''unilevel-v2''))');

  SELECT replace(pg_get_functiondef('public.apply_wallet_ledger_entry()'::regprocedure),chr(13),'') INTO definition;
  needle:=$old$lot.original_amount=LEAST(allocation.bottle_count::numeric,trunc(funding.funded_amount /
            (SELECT COUNT(*) FROM public.unilevel_order_allocations slots WHERE slots.order_event_id=lot.order_event_id),2))$old$;
  replacement:=$new$lot.original_amount=CASE WHEN commission_row.rule_version='unilevel-v2' THEN
            LEAST(allocation.bottle_count::numeric,COALESCE((SELECT level_funding.funded_amount FROM public.unilevel_level_funding level_funding
              WHERE level_funding.order_event_id=lot.order_event_id AND level_funding.level=lot.level),0))
          ELSE LEAST(allocation.bottle_count::numeric,trunc(funding.funded_amount /
            (SELECT COUNT(*) FROM public.unilevel_order_allocations slots WHERE slots.order_event_id=lot.order_event_id),2)) END$new$;
  needle:=replace(needle,chr(13),''); replacement:=replace(replacement,chr(13),'');
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'Unilevel wallet funding boundary is missing.'; END IF;
  EXECUTE replace(definition,needle,replacement);

  SELECT pg_get_functiondef('public.close_product_binary_pool_week(date)'::regprocedure) INTO definition;
  needle:='  INSERT INTO public.product_binary_week_preparation(week_start)';
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'Binary preparation boundary is missing.'; END IF;
  EXECUTE replace(definition,needle,$guard$
  IF NOT EXISTS(SELECT 1 FROM public.product_binary_week_preparation frozen WHERE frozen.week_start=target_week)
    AND EXISTS(SELECT 1 FROM public.unilevel_product_order_preparations uni_prepared
    JOIN public.product_binary_pool_orders pool_source ON pool_source.order_event_id=uni_prepared.order_event_id
    JOIN public.product_binary_settlement_jobs binary_job ON binary_job.id=uni_prepared.settlement_job_id
    WHERE pool_source.week_start=target_week AND binary_job.status<>'completed') THEN
    RETURN w;
  END IF;
  INSERT INTO public.product_binary_week_preparation(week_start)$guard$);

  SELECT pg_get_functiondef('public.configure_financial_runtime_role(text)'::regprocedure) INTO definition;
  needle:=$needle$'unilevel_inventory_earmarks'$needle$;
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'Financial runtime configuration is missing.'; END IF;
  definition:=replace(definition,needle,$tables$'unilevel_inventory_earmarks',
      'unilevel_settlement_jobs','unilevel_product_order_preparations','unilevel_level_funding'$tables$);
  needle:=$needle$'public.rank_bonus_progress(text,timestamp with time zone,timestamp with time zone)'$needle$;
  IF strpos(definition,needle)=0 THEN RAISE EXCEPTION 'Runtime entry point allowlist is missing.'; END IF;
  definition:=replace(definition,needle,$entries$'public.rank_bonus_progress(text,timestamp with time zone,timestamp with time zone)',
      'public.process_unilevel_order(text)','public.claim_pending_unilevel_orders(integer)',
      'public.record_unilevel_retry(text,text)'$entries$);
  EXECUTE definition;
END;
$updates$;

DO $permissions$
DECLARE signature text; runtime_role record;
BEGIN
  FOREACH signature IN ARRAY ARRAY[
    'public.assert_complete_product_order(uuid)','public.require_completed_prepared_product_order()',
    'public.validate_product_binary_order_event_completeness()','public.enqueue_unilevel_order()',
    'public.settle_funded_unilevel_order(uuid)','public.process_unilevel_order(text)',
    'public.claim_pending_unilevel_orders(integer)','public.record_unilevel_retry(text,text)'
  ] LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC',signature); END LOOP;
  FOR runtime_role IN
    SELECT DISTINCT role.rolname FROM pg_proc procedure
    CROSS JOIN LATERAL aclexplode(procedure.proacl) access JOIN pg_roles role ON role.oid=access.grantee
    WHERE procedure.oid='public.queue_product_binary_pool_order(uuid,timestamptz,integer)'::regprocedure
      AND access.privilege_type='EXECUTE' AND NOT role.rolsuper
      AND role.oid<>procedure.proowner AND NOT pg_has_role(role.oid,procedure.proowner,'MEMBER')
  LOOP PERFORM public.configure_financial_runtime_role(runtime_role.rolname); END LOOP;
END;
$permissions$;


COMMIT;

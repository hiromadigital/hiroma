BEGIN;

CREATE TABLE public.unilevel_order_allocations (
  order_event_id uuid NOT NULL REFERENCES public.product_binary_order_events(id),
  level integer NOT NULL CHECK (level BETWEEN 1 AND 5),
  user_id text REFERENCES public.users(id),
  bottle_count integer NOT NULL CHECK (bottle_count > 0),
  disposition text NOT NULL CHECK (disposition IN ('qualified', 'no_sponsor', 'inactive_account', 'monthly_purchase_required')),
  PRIMARY KEY (order_event_id, level),
  CHECK (disposition <> 'qualified' OR user_id IS NOT NULL)
);

CREATE TRIGGER unilevel_order_allocations_append_only
BEFORE UPDATE OR DELETE ON public.unilevel_order_allocations
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();

REVOKE ALL ON public.unilevel_order_allocations FROM PUBLIC;

CREATE FUNCTION public.snapshot_unilevel_order_allocations()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  earning_time timestamptz;
  month_start timestamptz;
BEGIN
  SELECT job.qualified_at INTO earning_time
  FROM public.product_binary_settlement_jobs job
  WHERE job.id = NEW.settlement_job_id
    AND job.qualification_status = 'qualified_paid_delivery';

  IF earning_time IS NULL OR NEW.eligible_units <= 0 THEN
    RETURN NEW;
  END IF;

  month_start := date_trunc('month', earning_time AT TIME ZONE 'Asia/Manila') AT TIME ZONE 'Asia/Manila';

  INSERT INTO public.unilevel_order_allocations (order_event_id, level, user_id, bottle_count, disposition)
  WITH RECURSIVE sponsors AS (
    SELECT 1 AS level, node.sponsor_id AS user_id,
           ARRAY[NEW.buyer_user_id, node.sponsor_id] AS visited
    FROM public.binary_tree_nodes node
    WHERE node.user_id = NEW.buyer_user_id AND node.sponsor_id <> NEW.buyer_user_id
    UNION ALL
    SELECT sponsor.level + 1, node.sponsor_id, sponsor.visited || node.sponsor_id
    FROM sponsors sponsor
    JOIN public.binary_tree_nodes node ON node.user_id = sponsor.user_id
    WHERE sponsor.level < 5 AND node.sponsor_id <> ALL(sponsor.visited)
  )
  SELECT NEW.id, slot.level, sponsor.user_id, NEW.eligible_units,
    CASE
      WHEN sponsor.user_id IS NULL THEN 'no_sponsor'
      WHEN member.role IS DISTINCT FROM 'reseller' OR member.status IS DISTINCT FROM 'active'
           OR profile.is_active IS DISTINCT FROM true THEN 'inactive_account'
      WHEN NOT EXISTS (
        SELECT 1
        FROM public.product_binary_settlement_jobs job
        WHERE job.buyer_user_id = sponsor.user_id
          AND job.qualification_status = 'qualified_paid_delivery'
          AND job.eligible_units_snapshot >= 1
          AND job.qualified_at >= month_start AND job.qualified_at <= earning_time
      ) THEN 'monthly_purchase_required'
      ELSE 'qualified'
    END
  FROM generate_series(1, 5) AS slot(level)
  LEFT JOIN sponsors sponsor ON sponsor.level = slot.level
  LEFT JOIN public.users member ON member.id = sponsor.user_id
  LEFT JOIN public.reseller_profiles profile ON profile.user_id = sponsor.user_id;

  RETURN NEW;
END;
$$;

REVOKE ALL ON FUNCTION public.snapshot_unilevel_order_allocations() FROM PUBLIC;

CREATE TRIGGER unilevel_snapshot_order_allocations
AFTER INSERT ON public.product_binary_order_events
FOR EACH ROW EXECUTE FUNCTION public.snapshot_unilevel_order_allocations();

CREATE TABLE public.unilevel_inventory_earmarks (
  source_order_item_id text PRIMARY KEY REFERENCES public.product_binary_inventory_reserves(source_order_item_id),
  funded_units integer NOT NULL CHECK (funded_units > 0),
  amount numeric(12,2) GENERATED ALWAYS AS (funded_units::numeric * 5) STORED,
  created_at timestamptz NOT NULL DEFAULT transaction_timestamp()
);

CREATE TRIGGER unilevel_inventory_earmarks_append_only
BEFORE UPDATE OR DELETE ON public.unilevel_inventory_earmarks
FOR EACH ROW EXECUTE FUNCTION public.reject_financial_history_change();

CREATE FUNCTION public.earmark_unilevel_stock()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
BEGIN
  INSERT INTO public.unilevel_inventory_earmarks (source_order_item_id, funded_units)
  VALUES (NEW.source_order_item_id, NEW.funded_units);
  RETURN NEW;
END;
$$;

CREATE TRIGGER unilevel_earmark_stock
AFTER INSERT ON public.product_binary_inventory_reserves
FOR EACH ROW EXECUTE FUNCTION public.earmark_unilevel_stock();

-- The FIFO movement identifies the same physical units for both earmarks.
-- Existing stock can still fulfill a sale without creating a new earmark.
CREATE VIEW public.unilevel_order_funding AS
SELECT movement.order_event_id, SUM(movement.units)::integer AS funded_units,
       SUM(movement.units::numeric * 5) AS funded_amount
FROM public.product_binary_inventory_reserve_transfers movement
JOIN public.unilevel_inventory_earmarks earmark USING (source_order_item_id)
GROUP BY movement.order_event_id;

REVOKE ALL ON public.unilevel_inventory_earmarks, public.unilevel_order_funding FROM PUBLIC;
REVOKE ALL ON FUNCTION public.earmark_unilevel_stock() FROM PUBLIC;

DO $$
DECLARE runtime_role record;
BEGIN
  FOR runtime_role IN SELECT rolname FROM pg_roles WHERE rolname IN ('anon', 'authenticated', 'service_role') LOOP
    EXECUTE format('REVOKE ALL ON public.unilevel_inventory_earmarks, public.unilevel_order_allocations, public.unilevel_order_funding FROM %I', runtime_role.rolname);
    EXECUTE format('REVOKE ALL ON FUNCTION public.snapshot_unilevel_order_allocations(), public.earmark_unilevel_stock() FROM %I', runtime_role.rolname);
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
    EXECUTE format('GRANT SELECT ON public.unilevel_inventory_earmarks, public.unilevel_order_allocations, public.unilevel_order_funding TO %I', runtime_role.rolname);
  END LOOP;
END;
$$;

COMMIT;

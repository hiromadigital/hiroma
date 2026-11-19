BEGIN;
CREATE FUNCTION public.unilevel_level_count() RETURNS integer
LANGUAGE sql STABLE SET search_path=pg_catalog,public,pg_temp AS $$
 SELECT COALESCE((SELECT value::integer FROM public.system_settings WHERE key='unilevel_levels'),5)
$$;
ALTER TABLE public.system_settings ADD CONSTRAINT unilevel_levels_valid
 CHECK (CASE WHEN key='unilevel_levels' THEN value ~ '^[0-9]+$' AND value::numeric BETWEEN 1 AND 10 ELSE true END);
ALTER TABLE public.unilevel_order_allocations DROP CONSTRAINT unilevel_order_allocations_level_check;
ALTER TABLE public.unilevel_order_allocations ADD CONSTRAINT unilevel_order_allocations_level_check CHECK(level BETWEEN 1 AND 10);
ALTER TABLE public.unilevel_inventory_earmarks ADD COLUMN levels integer NOT NULL DEFAULT 5 CHECK(levels BETWEEN 1 AND 10);
ALTER TABLE public.unilevel_inventory_earmarks DROP COLUMN amount;
ALTER TABLE public.unilevel_inventory_earmarks ADD COLUMN amount numeric(12,2) GENERATED ALWAYS AS(funded_units::numeric * levels) STORED;
CREATE OR REPLACE FUNCTION public.earmark_unilevel_stock()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public,pg_temp AS $$
BEGIN
 INSERT INTO public.unilevel_inventory_earmarks(source_order_item_id,funded_units,levels)
 VALUES(NEW.source_order_item_id,NEW.funded_units,public.unilevel_level_count());
 RETURN NEW;
END;
$$;
CREATE OR REPLACE FUNCTION public.snapshot_unilevel_order_allocations()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  earning_time timestamptz;
  month_start timestamptz;
  configured_levels integer := public.unilevel_level_count();
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
    WHERE sponsor.level < configured_levels AND node.sponsor_id <> ALL(sponsor.visited)
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
  FROM generate_series(1, configured_levels) AS slot(level)
  LEFT JOIN sponsors sponsor ON sponsor.level = slot.level
  LEFT JOIN public.users member ON member.id = sponsor.user_id
  LEFT JOIN public.reseller_profiles profile ON profile.user_id = sponsor.user_id;

  RETURN NEW;
END;
$$;


CREATE OR REPLACE VIEW public.unilevel_order_funding AS
SELECT movement.order_event_id, SUM(movement.units)::integer AS funded_units,
 SUM(movement.units::numeric * earmark.levels) AS funded_amount
FROM public.product_binary_inventory_reserve_transfers movement
JOIN public.unilevel_inventory_earmarks earmark USING(source_order_item_id)
GROUP BY movement.order_event_id;
COMMIT;

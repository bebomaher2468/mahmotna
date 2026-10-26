-- Run once in Supabase SQL Editor to protect the site owner's account.
-- The owner profile currently has display_name = 'bebomaher2468'.
DO $$
DECLARE
  owner_ids uuid[];
BEGIN
  SELECT array_agg(id)
  INTO owner_ids
  FROM public.profiles
  WHERE lower(coalesce(display_name, '')) = 'bebomaher2468'
    AND role = 'admin';

  IF coalesce(array_length(owner_ids, 1), 0) <> 1 THEN
    RAISE EXCEPTION 'Expected exactly one admin profile named bebomaher2468. No changes were applied.';
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS public.site_owner_guard (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  user_id uuid NOT NULL UNIQUE REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.site_owner_guard ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.site_owner_guard FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO public.site_owner_guard (singleton, user_id)
SELECT true, id
FROM public.profiles
WHERE lower(coalesce(display_name, '')) = 'bebomaher2468'
  AND role = 'admin'
ON CONFLICT (singleton) DO UPDATE SET user_id = EXCLUDED.user_id;

CREATE OR REPLACE FUNCTION public.protect_site_owner_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  is_site_owner boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM public.site_owner_guard
    WHERE user_id = OLD.id
  )
  INTO is_site_owner;

  IF is_site_owner THEN
    IF TG_OP = 'DELETE' THEN
      RAISE EXCEPTION 'The site owner account cannot be deleted.';
    END IF;

    IF NEW.id IS DISTINCT FROM OLD.id
       OR NEW.role IS DISTINCT FROM 'admin' THEN
      RAISE EXCEPTION 'The site owner account cannot be demoted or removed.';
    END IF;
  END IF;

  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_site_owner_profile ON public.profiles;

CREATE TRIGGER protect_site_owner_profile
BEFORE UPDATE OR DELETE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.protect_site_owner_profile();

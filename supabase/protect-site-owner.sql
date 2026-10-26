-- Reserve the website owner account so other admins cannot demote or delete it.
-- The owner username is the one mapped to the site owner in index.html.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE lower(coalesce(username, '')) = 'bebomaher2468'
      AND role = 'admin'
  ) THEN
    RAISE EXCEPTION 'Site owner profile was not found as an admin. Check the owner username before running this script.';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.protect_site_owner_profile()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    IF lower(coalesce(OLD.username, '')) = 'bebomaher2468' THEN
      RAISE EXCEPTION 'The site owner account cannot be deleted.';
    END IF;
    RETURN OLD;
  END IF;

  IF lower(coalesce(OLD.username, '')) = 'bebomaher2468'
     AND (
       NEW.id IS DISTINCT FROM OLD.id
       OR lower(coalesce(NEW.username, '')) IS DISTINCT FROM 'bebomaher2468'
       OR NEW.role IS DISTINCT FROM 'admin'
     ) THEN
    RAISE EXCEPTION 'The site owner account cannot be renamed, demoted, or removed.';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS protect_site_owner_profile ON public.profiles;

CREATE TRIGGER protect_site_owner_profile
BEFORE UPDATE OR DELETE ON public.profiles
FOR EACH ROW
EXECUTE FUNCTION public.protect_site_owner_profile();

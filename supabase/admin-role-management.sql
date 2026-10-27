-- Run once in Supabase SQL Editor to enable the admin/member role button.
-- The function checks that the caller is an admin and protects the reserved site owner.
CREATE OR REPLACE FUNCTION public.admin_set_profile_role(
  p_user_id uuid,
  p_role text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
BEGIN
  IF auth.uid() IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM public.profiles
       WHERE id = auth.uid()
         AND role = 'admin'
     ) THEN
    RAISE EXCEPTION 'Only an admin can change profile roles.'
      USING ERRCODE = '42501';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'A target profile is required.';
  END IF;

  IF p_user_id = auth.uid() THEN
    RAISE EXCEPTION 'You cannot change your own role from this action.';
  END IF;

  IF p_role NOT IN ('member', 'admin') THEN
    RAISE EXCEPTION 'The requested role is not allowed.';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.site_owner_guard
    WHERE user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'The site owner account is protected.';
  END IF;

  UPDATE public.profiles
  SET role = p_role
  WHERE id = p_user_id
    AND role IN ('member', 'admin');

  IF NOT FOUND THEN
    RAISE EXCEPTION 'The target profile was not found.';
  END IF;

  RETURN jsonb_build_object('ok', true, 'role', p_role);
END;
$$;

REVOKE ALL ON FUNCTION public.admin_set_profile_role(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_profile_role(uuid, text) TO authenticated;

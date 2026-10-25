-- مهمتنا: Supabase schema + RLS + private file storage
-- شغّل السكربت كله في Supabase Dashboard > SQL Editor > New query.
create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  role text not null default 'member' check (role in ('member','admin')),
  created_at timestamptz not null default now()
);
create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(title) between 1 and 140),
  description text not null default '',
  due_date date,
  status text not null default 'open' check (status in ('open','done')),
  reference_url text,
  submission_type text not null default 'both' check (submission_type in ('both','file','link')),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.submissions (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  link_url text,
  file_path text,
  file_name text,
  note text not null default '',
  status text not null default 'submitted' check (status in ('submitted','reviewing','accepted','revision')),
  admin_feedback text,
  reviewed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint submission_has_content check (link_url is not null or file_path is not null)
);

create index if not exists tasks_created_at_idx on public.tasks(created_at desc);
create index if not exists submissions_task_id_idx on public.submissions(task_id);
create index if not exists submissions_user_id_idx on public.submissions(user_id, created_at desc);

-- إنشاء profile تلقائيًا لكل حساب جديد، والدور يبدأ member دائمًا.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name, role)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', split_part(new.email, '@', 1)), 'member')
  on conflict (id) do nothing;
  return new;
end;
$$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
for each row execute procedure public.handle_new_user();

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists(select 1 from public.profiles p where p.id = (select auth.uid()) and p.role = 'admin');
$$;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

alter table public.profiles enable row level security;
alter table public.tasks enable row level security;
alter table public.submissions enable row level security;

-- Profiles: المستخدم يشوف بياناته، والمسؤول يشوف الكل. لا توجد سياسة تسمح للأعضاء بتغيير role.
drop policy if exists "profile read own or admin" on public.profiles;
create policy "profile read own or admin" on public.profiles for select to authenticated
using (id = (select auth.uid()) or public.is_admin());
drop policy if exists "profile update own name" on public.profiles;
create policy "profile update own name" on public.profiles for update to authenticated
using (id = (select auth.uid())) with check (id = (select auth.uid()) and role = (select role from public.profiles p where p.id = (select auth.uid())));

-- Tasks: كل الناس تقدر تقرأ؛ المسؤولون فقط يضيفوا/يعدّلوا/يحذفوا.
drop policy if exists "tasks visible to everyone" on public.tasks;
create policy "tasks visible to everyone" on public.tasks for select to anon, authenticated using (true);
drop policy if exists "admin inserts tasks" on public.tasks;
create policy "admin inserts tasks" on public.tasks for insert to authenticated with check (public.is_admin() and created_by = (select auth.uid()));
drop policy if exists "admin updates tasks" on public.tasks;
create policy "admin updates tasks" on public.tasks for update to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists "admin deletes tasks" on public.tasks;
create policy "admin deletes tasks" on public.tasks for delete to authenticated using (public.is_admin());

-- Submissions: العضو يرى/يضيف/يعدّل/يحذف تسليماته هو فقط؛ المسؤول يرى الجميع ويحدّث حالة المراجعة.
drop policy if exists "read own submissions or admin" on public.submissions;
create policy "read own submissions or admin" on public.submissions for select to authenticated using (user_id = (select auth.uid()) or public.is_admin());
drop policy if exists "members submit as themselves" on public.submissions;
create policy "members submit as themselves" on public.submissions for insert to authenticated with check (user_id = (select auth.uid()) and exists(select 1 from public.tasks t where t.id = task_id and t.status = 'open'));
drop policy if exists "members update own pending submissions" on public.submissions;
create policy "members update own pending submissions" on public.submissions for update to authenticated
using (user_id = (select auth.uid()) or public.is_admin())
with check (
  public.is_admin() or (
    user_id = (select auth.uid()) and
    status = 'submitted' and admin_feedback is null and reviewed_by is null
  )
);
drop policy if exists "members delete own submissions or admin" on public.submissions;
create policy "members delete own submissions or admin" on public.submissions for delete to authenticated using (user_id = (select auth.uid()) or public.is_admin());

-- Bucket خاص للملفات، أقصى حجم 15MB، والواجهة تقبل أنواع ملفات شائعة.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('submissions', 'submissions', false, 15728640,
  array['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint','application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'image/png','image/jpeg','application/zip','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/plain',
  'application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = 15728640, allowed_mime_types = excluded.allowed_mime_types;

alter table storage.objects enable row level security;
drop policy if exists "members upload to own folder" on storage.objects;
create policy "members upload to own folder" on storage.objects for insert to authenticated
with check (bucket_id = 'submissions' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists "read own files or admin" on storage.objects;
create policy "read own files or admin" on storage.objects for select to authenticated
using (bucket_id = 'submissions' and ((storage.foldername(name))[1] = (select auth.uid())::text or public.is_admin()));
drop policy if exists "delete own files or admin" on storage.objects;
create policy "delete own files or admin" on storage.objects for delete to authenticated
using (bucket_id = 'submissions' and ((storage.foldername(name))[1] = (select auth.uid())::text or public.is_admin()));

-- بعد ما تنشئ حساب المسؤول من الموقع، استبدل الإيميل في السطر التالي وشغّله منفصلًا:
-- update public.profiles p set role = 'admin'
-- from auth.users u where p.id = u.id and u.email = 'admin@example.com';

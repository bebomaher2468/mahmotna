-- شغّل الملف بالكامل في Supabase SQL Editor مرة واحدة.
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null, body text,
 kind text not null check (kind in ('new_task','due_soon','accepted','revision')),
 task_id uuid references public.tasks(id) on delete cascade,
 submission_id uuid references public.submissions(id) on delete cascade,
 read_at timestamptz, created_at timestamptz not null default now()
);
create index if not exists notifications_user_created_idx on public.notifications(user_id,created_at desc);
create unique index if not exists notifications_due_once_idx on public.notifications(user_id,task_id,kind);
alter table public.notifications enable row level security;
drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications" on public.notifications for select to authenticated using(user_id=auth.uid());
drop policy if exists "Users update own notifications" on public.notifications;
create policy "Users update own notifications" on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "Users create own due reminders" on public.notifications;
create policy "Users create own due reminders" on public.notifications for insert to authenticated with check(user_id=auth.uid() and kind='due_soon');
create or replace function public.notify_members_new_task() returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.notifications(user_id,title,body,kind,task_id)
 select p.id,'مهمة جديدة','تمت إضافة مهمة جديدة: '||new.title,'new_task',new.id from public.profiles p where p.role='member';
 return new;
end; $$;
drop trigger if exists tasks_notify_members on public.tasks;
create trigger tasks_notify_members after insert on public.tasks for each row execute function public.notify_members_new_task();
create or replace function public.notify_submission_status() returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status and new.status in ('accepted','revision') then
  insert into public.notifications(user_id,title,body,kind,task_id,submission_id)
  values(new.user_id,case when new.status='accepted' then 'تم قبول التسليم' else 'التسليم محتاج تعديل' end,
  case when new.status='accepted' then 'تم قبول تسليمك.' else 'المسؤول طلب تعديل التسليم. افتح التسليم لمراجعة الملاحظات.' end,
  new.status,new.task_id,new.id);
 end if;
 return new;
end; $$;
drop trigger if exists submissions_notify_status on public.submissions;
create trigger submissions_notify_status after update of status on public.submissions for each row execute function public.notify_submission_status();
do $$ begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end $$;

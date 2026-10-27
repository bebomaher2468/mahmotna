-- شغّل الملف بالكامل في Supabase SQL Editor. إعادة تشغيله آمنة.
create table if not exists public.notifications (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 title text not null, body text,
 kind text not null check (kind in ('new_task','due_soon','accepted','revision','new_submission')),
 task_id uuid references public.tasks(id) on delete cascade,
 submission_id uuid references public.submissions(id) on delete cascade,
 read_at timestamptz, created_at timestamptz not null default now()
);
-- حدّث القيد لو جدول الإشعارات كان موجودًا من قبل.
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
 check (kind in ('new_task','due_soon','accepted','revision','new_submission'));
-- علامة تمنع إعادة إرسال إشعار الجهاز نفسه عند إعادة طلب الـ Edge Function.
alter table public.submissions add column if not exists push_notified_at timestamptz;
create index if not exists notifications_user_created_idx on public.notifications(user_id,created_at desc);
drop index if exists public.notifications_due_once_idx;
create unique index if not exists notifications_one_per_kind_per_task_idx
 on public.notifications(user_id,task_id,kind);
alter table public.notifications enable row level security;
drop policy if exists "Users read own notifications" on public.notifications;
create policy "Users read own notifications" on public.notifications for select to authenticated using(user_id=auth.uid());
drop policy if exists "Users update own notifications" on public.notifications;
create policy "Users update own notifications" on public.notifications for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
drop policy if exists "Users create own due reminders" on public.notifications;
create policy "Users create own due reminders" on public.notifications for insert to authenticated with check(user_id=auth.uid() and kind='due_soon');

-- اشتراكات Web Push: لا يمكن لأي عضو قراءة أو حذف اشتراك جهاز شخص آخر.
create table if not exists public.push_subscriptions (
 id uuid primary key default gen_random_uuid(),
 user_id uuid not null references auth.users(id) on delete cascade,
 endpoint text not null unique,
 keys jsonb not null,
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint push_subscription_endpoint_https check (left(endpoint,8)='https://'),
 constraint push_subscription_keys_valid check (
  jsonb_typeof(keys)='object'
  and coalesce(keys->>'p256dh','')<>''
  and coalesce(keys->>'auth','')<>''
 )
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions(user_id);
alter table public.push_subscriptions enable row level security;
drop policy if exists "Users read own push subscriptions" on public.push_subscriptions;
create policy "Users read own push subscriptions" on public.push_subscriptions for select to authenticated using(user_id=auth.uid());
drop policy if exists "Users delete own push subscriptions" on public.push_subscriptions;
create policy "Users delete own push subscriptions" on public.push_subscriptions for delete to authenticated using(user_id=auth.uid());
revoke all on public.push_subscriptions from anon;
revoke insert,update on public.push_subscriptions from authenticated;
grant select,delete on public.push_subscriptions to authenticated;
grant all on public.push_subscriptions to service_role;

-- حفظ/تحديث اشتراك الجهاز من خلال جلسة المستخدم فقط.
create or replace function public.save_push_subscription(p_endpoint text,p_keys jsonb)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
 v_user_id uuid;
begin
 v_user_id:=auth.uid();
 if v_user_id is null then raise exception 'Authentication required'; end if;
 if p_endpoint is null or length(p_endpoint)>4096 or left(p_endpoint,8)<>'https://' then
  raise exception 'Invalid push endpoint';
 end if;
 if jsonb_typeof(p_keys)<>'object'
    or coalesce(p_keys->>'p256dh','')=''
    or coalesce(p_keys->>'auth','')='' then
  raise exception 'Invalid push subscription keys';
 end if;
 insert into public.push_subscriptions(user_id,endpoint,keys,updated_at)
 values(v_user_id,p_endpoint,p_keys,now())
 on conflict(endpoint) do update
 set user_id=excluded.user_id,keys=excluded.keys,updated_at=now();
end;
$$;
revoke all on function public.save_push_subscription(text,jsonb) from public,anon;
grant execute on function public.save_push_subscription(text,jsonb) to authenticated;

create or replace function public.notify_members_new_task()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 insert into public.notifications(user_id,title,body,kind,task_id)
 select p.id,'مهمة جديدة','تمت إضافة مهمة جديدة: '||new.title,'new_task',new.id
 from public.profiles p
 where p.role='member' or p.id=new.created_by
 on conflict(user_id,task_id,kind) do update
 set title=excluded.title,body=excluded.body,read_at=null,created_at=now();
 return new;
end; $$;
drop trigger if exists tasks_notify_members on public.tasks;
create trigger tasks_notify_members after insert on public.tasks for each row execute function public.notify_members_new_task();

-- إشعار لكل الأعضاء والمسؤولين عند تسجيل عضو تسليمًا جديدًا.
-- صاحب التسليم لا يصله إشعار عن نفسه، وكل تسليم يحتفظ بإشعار مستقل.
create or replace function public.notify_users_new_submission()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
 insert into public.notifications(user_id,title,body,kind,task_id,submission_id)
 select p.id,
  'تسليم جديد',
  'العضو '||coalesce(nullif(btrim(sender.display_name),''),nullif(btrim(sender.username),''),'عضو')||' سلّم مهمة: '||coalesce(t.title,'مهمة'),
  'new_submission',
  null,
  new.id
 from public.profiles p
 left join public.profiles sender on sender.id=new.user_id
 left join public.tasks t on t.id=new.task_id
 where p.role in ('admin','member') and p.id is distinct from new.user_id;
 return new;
end;
$$;
drop trigger if exists submissions_notify_admins_new on public.submissions;
drop trigger if exists submissions_notify_users_new on public.submissions;
drop function if exists public.notify_admins_new_submission();
create trigger submissions_notify_users_new
 after insert on public.submissions
 for each row
 when (new.status='submitted')
 execute function public.notify_users_new_submission();

create or replace function public.notify_submission_status()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.status is distinct from old.status and new.status in ('accepted','revision') then
  insert into public.notifications(user_id,title,body,kind,task_id,submission_id)
  values(new.user_id,
   case when new.status='accepted' then 'تم قبول التسليم' else 'التسليم محتاج تعديل' end,
   case when new.status='accepted' then 'تم قبول تسليمك.' else 'المسؤول طلب تعديل التسليم. افتح التسليم لمراجعة الملاحظات.' end,
   new.status,new.task_id,new.id)
  on conflict(user_id,task_id,kind) do update
  set submission_id=excluded.submission_id,title=excluded.title,body=excluded.body,read_at=null,created_at=now();
 end if;
 return new;
end; $$;
drop trigger if exists submissions_notify_status on public.submissions;
create trigger submissions_notify_status after update of status on public.submissions for each row execute function public.notify_submission_status();

do $$ begin
 alter publication supabase_realtime add table public.notifications;
exception when duplicate_object then null;
end $$;

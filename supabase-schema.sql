-- mAIPrompter Supabase SaaS schema
-- Run this in a fresh Supabase project's SQL editor.
-- It assumes Supabase Auth is enabled and uses auth.users as the source of login identity.

create extension if not exists "pgcrypto";

create type public.user_role as enum ('user', 'admin', 'super_admin');
create type public.member_role as enum ('owner', 'admin', 'editor', 'viewer');
create type public.subscription_status as enum ('trialing', 'active', 'past_due', 'cancelled', 'expired');
create type public.payment_gateway as enum ('razorpay', 'stripe', 'manual', 'demo');
create type public.recording_status as enum ('started', 'paused', 'completed', 'failed', 'deleted');

create table public.plans (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  price_inr integer not null default 0,
  billing_interval text not null default 'month',
  prompt_limit integer,
  prompt_char_limit integer,
  recording_limit integer,
  watermark_enabled boolean not null default true,
  max_resolution text not null default '720p',
  features jsonb not null default '[]'::jsonb,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  avatar_url text,
  role public.user_role not null default 'user',
  default_workspace_id uuid,
  onboarding_completed boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null,
  slug text unique,
  plan_code text not null default 'free' references public.plans(code),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles
  add constraint profiles_default_workspace_id_fkey
  foreign key (default_workspace_id) references public.workspaces(id) on delete set null;

create table public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.member_role not null default 'owner',
  invited_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (workspace_id, user_id)
);

create table public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  plan_code text not null references public.plans(code),
  status public.subscription_status not null default 'active',
  gateway public.payment_gateway not null default 'demo',
  gateway_customer_id text,
  gateway_subscription_id text,
  current_period_start timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.prompts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  created_by uuid not null references public.profiles(id) on delete cascade,
  title text not null default 'Untitled script',
  body text not null,
  char_count integer generated always as (char_length(body)) stored,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.recordings (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  prompt_id uuid references public.prompts(id) on delete set null,
  created_by uuid not null references public.profiles(id) on delete cascade,
  status public.recording_status not null default 'started',
  file_name text,
  mime_type text,
  duration_seconds numeric(10,2),
  resolution_width integer,
  resolution_height integer,
  file_size_bytes bigint,
  watermark_applied boolean not null default true,
  local_download_only boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.usage_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  event_name text not null,
  quantity integer not null default 1,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  subscription_id uuid references public.subscriptions(id) on delete set null,
  gateway public.payment_gateway not null,
  gateway_payment_id text,
  amount_inr integer not null,
  currency text not null default 'INR',
  status text not null default 'created',
  invoice_url text,
  paid_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.gateway_webhook_events (
  id uuid primary key default gen_random_uuid(),
  gateway public.payment_gateway not null,
  event_id text,
  event_type text not null,
  payload jsonb not null,
  processed_at timestamptz,
  created_at timestamptz not null default now(),
  unique (gateway, event_id)
);

create index prompts_workspace_created_idx on public.prompts (workspace_id, created_at desc);
create index recordings_workspace_created_idx on public.recordings (workspace_id, created_at desc);
create index usage_events_workspace_created_idx on public.usage_events (workspace_id, created_at desc);
create index payments_workspace_created_idx on public.payments (workspace_id, created_at desc);
create index subscriptions_workspace_status_idx on public.subscriptions (workspace_id, status);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger plans_set_updated_at
before update on public.plans
for each row execute function public.set_updated_at();

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger workspaces_set_updated_at
before update on public.workspaces
for each row execute function public.set_updated_at();

create trigger subscriptions_set_updated_at
before update on public.subscriptions
for each row execute function public.set_updated_at();

create trigger prompts_set_updated_at
before update on public.prompts
for each row execute function public.set_updated_at();

create or replace function public.is_platform_admin(check_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles
    where id = check_user_id
      and role in ('admin', 'super_admin')
  );
$$;

create or replace function public.is_workspace_member(check_workspace_id uuid, check_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members
    where workspace_id = check_workspace_id
      and user_id = check_user_id
  ) or public.is_platform_admin(check_user_id);
$$;

create or replace function public.is_workspace_admin(check_workspace_id uuid, check_user_id uuid default auth.uid())
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.workspace_members
    where workspace_id = check_workspace_id
      and user_id = check_user_id
      and role in ('owner', 'admin')
  ) or public.is_platform_admin(check_user_id);
$$;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  workspace_id uuid;
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    coalesce(new.email, ''),
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'name'),
    new.raw_user_meta_data->>'avatar_url'
  )
  on conflict (id) do nothing;

  insert into public.workspaces (owner_id, name, slug, plan_code)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'workspace_name', split_part(coalesce(new.email, 'Creator'), '@', 1) || '''s Workspace'),
    null,
    'free'
  )
  returning id into workspace_id;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (workspace_id, new.id, 'owner');

  update public.profiles
  set default_workspace_id = workspace_id
  where id = new.id;

  insert into public.subscriptions (workspace_id, plan_code, status, gateway)
  values (workspace_id, 'free', 'active', 'demo');

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

alter table public.plans enable row level security;
alter table public.profiles enable row level security;
alter table public.workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.subscriptions enable row level security;
alter table public.prompts enable row level security;
alter table public.recordings enable row level security;
alter table public.usage_events enable row level security;
alter table public.payments enable row level security;
alter table public.gateway_webhook_events enable row level security;

create policy "plans are publicly readable"
on public.plans for select
using (is_active = true);

create policy "platform admins manage plans"
on public.plans for all
using (public.is_platform_admin())
with check (public.is_platform_admin());

create policy "users read own profile"
on public.profiles for select
using (id = auth.uid() or public.is_platform_admin());

create policy "users update own profile"
on public.profiles for update
using (id = auth.uid() or public.is_platform_admin())
with check (id = auth.uid() or public.is_platform_admin());

create policy "members read workspace"
on public.workspaces for select
using (public.is_workspace_member(id));

create policy "owners update workspace"
on public.workspaces for update
using (public.is_workspace_admin(id))
with check (public.is_workspace_admin(id));

create policy "members read memberships"
on public.workspace_members for select
using (public.is_workspace_member(workspace_id));

create policy "workspace admins manage memberships"
on public.workspace_members for all
using (public.is_workspace_admin(workspace_id))
with check (public.is_workspace_admin(workspace_id));

create policy "members read subscriptions"
on public.subscriptions for select
using (public.is_workspace_member(workspace_id));

create policy "platform admins manage subscriptions"
on public.subscriptions for all
using (public.is_platform_admin())
with check (public.is_platform_admin());

create policy "members read prompts"
on public.prompts for select
using (public.is_workspace_member(workspace_id));

create policy "members create prompts"
on public.prompts for insert
with check (created_by = auth.uid() and public.is_workspace_member(workspace_id));

create policy "members update prompts"
on public.prompts for update
using (public.is_workspace_member(workspace_id))
with check (public.is_workspace_member(workspace_id));

create policy "members delete prompts"
on public.prompts for delete
using (public.is_workspace_admin(workspace_id) or created_by = auth.uid());

create policy "members read recordings"
on public.recordings for select
using (public.is_workspace_member(workspace_id));

create policy "members create recordings"
on public.recordings for insert
with check (created_by = auth.uid() and public.is_workspace_member(workspace_id));

create policy "members update own recordings"
on public.recordings for update
using (created_by = auth.uid() or public.is_workspace_admin(workspace_id))
with check (created_by = auth.uid() or public.is_workspace_admin(workspace_id));

create policy "members read usage"
on public.usage_events for select
using (public.is_workspace_member(workspace_id));

create policy "members create usage"
on public.usage_events for insert
with check (user_id = auth.uid() and public.is_workspace_member(workspace_id));

create policy "workspace admins read payments"
on public.payments for select
using (public.is_workspace_admin(workspace_id) or public.is_platform_admin());

create policy "platform admins manage payments"
on public.payments for all
using (public.is_platform_admin())
with check (public.is_platform_admin());

create policy "platform admins manage webhook events"
on public.gateway_webhook_events for all
using (public.is_platform_admin())
with check (public.is_platform_admin());

create or replace view public.admin_dashboard_metrics as
select
  (select count(*) from public.profiles) as total_users,
  (select count(*) from public.workspaces) as total_workspaces,
  (select count(*) from public.workspaces where plan_code = 'free') as free_workspaces,
  (select count(*) from public.subscriptions where status in ('trialing', 'active') and plan_code <> 'free') as active_paid_subscriptions,
  (select coalesce(sum(amount_inr), 0) from public.payments where status in ('paid', 'captured', 'succeeded')) as lifetime_revenue_inr,
  (select count(*) from public.prompts where created_at >= date_trunc('month', now())) as prompts_this_month,
  (select count(*) from public.recordings where created_at >= date_trunc('month', now())) as recordings_this_month;

insert into public.plans (code, name, price_inr, billing_interval, prompt_limit, prompt_char_limit, recording_limit, watermark_enabled, max_resolution, features)
values
  ('free', 'Free', 0, 'month', 3, 1000, 3, true, '720p', '["3 prompts", "1000 characters per prompt", "Watermarked exports", "Browser recording"]'::jsonb),
  ('creator', 'Creator', 99, 'month', null, null, null, false, '1080p', '["Watermark-free exports", "Unlimited prompts", "Saved defaults", "External microphone support"]'::jsonb),
  ('pro', 'Pro', 149, 'month', null, null, null, false, '1440p', '["Everything in Creator", "Higher-resolution capture requests", "Advanced voice controls", "Priority feature access"]'::jsonb),
  ('studio', 'Studio', 200, 'month', null, null, null, false, '4K', '["Everything in Pro", "Studio workspace", "Team roadmap", "Enterprise onboarding eligibility"]'::jsonb)
on conflict (code) do update set
  name = excluded.name,
  price_inr = excluded.price_inr,
  billing_interval = excluded.billing_interval,
  prompt_limit = excluded.prompt_limit,
  prompt_char_limit = excluded.prompt_char_limit,
  recording_limit = excluded.recording_limit,
  watermark_enabled = excluded.watermark_enabled,
  max_resolution = excluded.max_resolution,
  features = excluded.features,
  is_active = true,
  updated_at = now();

-- After you create your own Supabase Auth user, make yourself super admin:
-- update public.profiles
-- set role = 'super_admin'
-- where email = 'YOUR_EMAIL_HERE';

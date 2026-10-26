import { createClient } from "npm:@supabase/supabase-js@2.53.0";
import * as webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const APP_URL = "https://bebomaher2468.github.io/mahmotna/";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "https://bebomaher2468.github.io",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin"
};

function readDefaultSecret(): string {
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}");
    return typeof keys.default === "string" ? keys.default : "";
  } catch {
    return "";
  }
}

const SERVICE_KEY =
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  readDefaultSecret();

function json(data: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" }
  });
}

function getAdminClient() {
  if (!SUPABASE_URL || !SERVICE_KEY) {
    throw new Error("Supabase server credentials are not configured.");
  }
  return createClient(SUPABASE_URL, SERVICE_KEY, {
    auth: { autoRefreshToken: false, persistSession: false }
  });
}

async function requireUser(req: Request, admin: ReturnType<typeof getAdminClient>) {
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!token) return { user: null, error: "سجّل دخولك الأول." };

  const { data, error } = await admin.auth.getUser(token);
  if (error || !data.user) return { user: null, error: "الجلسة غير صالحة. سجّل الدخول مرة أخرى." };
  return { user: data.user, error: null };
}

async function requireAdmin(admin: ReturnType<typeof getAdminClient>, userId: string) {
  const { data, error } = await admin.from("profiles").select("role").eq("id", userId).maybeSingle();
  if (error) throw new Error("تعذر التحقق من صلاحيات المسؤول.");
  if (data?.role !== "admin") throw new Error("العملية دي للمسؤولين فقط.");
}

function vapidSettings() {
  const publicKey = Deno.env.get("VAPID_PUBLIC_KEY") || "";
  const privateKey = Deno.env.get("VAPID_PRIVATE_KEY") || "";
  const subject = Deno.env.get("VAPID_SUBJECT") || "";
  if (!publicKey || !privateKey || !subject) {
    throw new Error("إعداد مفاتيح إشعارات الجهاز غير مكتمل في Supabase.");
  }
  webpush.setVapidDetails(subject, publicKey, privateKey);
  return { publicKey };
}

async function sendToUsers(
  admin: ReturnType<typeof getAdminClient>,
  userIds: string[],
  notice: { title: string; body: string; taskId?: string | null; kind: string }
) {
  const ids = [...new Set(userIds.filter(Boolean))];
  if (!ids.length) return { sent: 0, failed: 0, noSubscriptions: 0 };

  const { data: subscriptions, error } = await admin
    .from("push_subscriptions")
    .select("id,user_id,endpoint,keys")
    .in("user_id", ids);

  if (error) throw new Error("تعذر قراءة اشتراكات الإشعارات.");
  if (!subscriptions?.length) return { sent: 0, failed: 0, noSubscriptions: ids.length };

  const payload = JSON.stringify({
    id: crypto.randomUUID(),
    title: notice.title,
    body: notice.body,
    kind: notice.kind,
    task_id: notice.taskId || null,
    url: APP_URL + "#tasksSection"
  });

  let sent = 0;
  let failed = 0;
  await Promise.all(subscriptions.map(async (subscription) => {
    try {
      await webpush.sendNotification(
        { endpoint: subscription.endpoint, keys: subscription.keys },
        payload,
        { TTL: 604800, urgency: "high" }
      );
      sent++;
    } catch (error) {
      const statusCode = Number((error as { statusCode?: number })?.statusCode || 0);
      if (statusCode === 404 || statusCode === 410) {
        await admin.from("push_subscriptions").delete().eq("id", subscription.id);
      }
      failed++;
      console.error("Push delivery failed:", statusCode || "unknown");
    }
  }));
  return { sent, failed, noSubscriptions: 0 };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ ok: false, error: "الطلب غير مدعوم." }, 405);

  let admin: ReturnType<typeof getAdminClient>;
  try {
    admin = getAdminClient();
  } catch (error) {
    return json({ ok: false, error: (error as Error).message }, 500);
  }

  const auth = await requireUser(req, admin);
  if (!auth.user) return json({ ok: false, error: auth.error || "غير مصرح." }, 401);

  let input: { action?: string; task_id?: string; submission_id?: string };
  try {
    input = await req.json();
  } catch {
    return json({ ok: false, error: "بيانات الطلب غير صحيحة." }, 400);
  }

  try {
    if (input.action === "public_key") {
      const { publicKey } = vapidSettings();
      return json({ ok: true, publicKey });
    }

    if (input.action === "send_test") {
      vapidSettings();
      const result = await sendToUsers(admin, [auth.user.id], {
        title: "إشعار تجريبي",
        body: "إشعارات الجهاز شغالة على موقع مهمتنا.",
        kind: "test"
      });
      return json({ ok: true, ...result });
    }

    await requireAdmin(admin, auth.user.id);

    if (input.action === "task_created") {
      if (!input.task_id) return json({ ok: false, error: "معرّف المهمة مطلوب." }, 400);
      const { data: task, error: taskError } = await admin
        .from("tasks")
        .select("id,title,created_by")
        .eq("id", input.task_id)
        .maybeSingle();
      if (taskError || !task) return json({ ok: false, error: "المهمة غير موجودة." }, 404);
      if (task.created_by !== auth.user.id) return json({ ok: false, error: "غير مصرح بإرسال هذا التنبيه." }, 403);

      const { data: profiles, error: profilesError } = await admin.from("profiles").select("id,role");
      if (profilesError) throw new Error("تعذر تحميل قائمة الأعضاء.");
      const recipients = (profiles || [])
        .filter((profile) => profile.role === "member" || profile.id === task.created_by)
        .map((profile) => profile.id);

      vapidSettings();
      const result = await sendToUsers(admin, recipients, {
        title: "مهمة جديدة",
        body: "تمت إضافة مهمة جديدة: " + task.title,
        taskId: task.id,
        kind: "new_task"
      });
      return json({ ok: true, ...result });
    }

    if (input.action === "submission_status") {
      if (!input.submission_id) return json({ ok: false, error: "معرّف التسليم مطلوب." }, 400);
      const { data: submission, error: submissionError } = await admin
        .from("submissions")
        .select("id,user_id,task_id,status,admin_feedback")
        .eq("id", input.submission_id)
        .maybeSingle();
      if (submissionError || !submission) return json({ ok: false, error: "التسليم غير موجود." }, 404);
      if (submission.status !== "accepted" && submission.status !== "revision") {
        return json({ ok: true, sent: 0, skipped: true });
      }

      const { data: task } = await admin.from("tasks").select("title").eq("id", submission.task_id).maybeSingle();
      const taskTitle = task?.title || "المهمة";
      const accepted = submission.status === "accepted";
      const body = accepted
        ? "تم قبول تسليمك لمهمة: " + taskTitle
        : "مطلوب تعديل تسليمك لمهمة: " + taskTitle;

      vapidSettings();
      const result = await sendToUsers(admin, [submission.user_id], {
        title: accepted ? "تم قبول التسليم" : "التسليم محتاج تعديل",
        body,
        taskId: submission.task_id,
        kind: submission.status
      });
      return json({ ok: true, ...result });
    }

    return json({ ok: false, error: "نوع الإشعار غير معروف." }, 400);
  } catch (error) {
    console.error("send-push:", (error as Error)?.message || "unknown error");
    const message = (error as Error)?.message || "تعذر إرسال الإشعار.";
    const status = message.includes("للمسؤولين") ? 403 : 500;
    return json({ ok: false, error: message }, status);
  }
});

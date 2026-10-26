self.addEventListener("install", event => {
  event.waitUntil(self.skipWaiting());
});

self.addEventListener("activate", event => {
  event.waitUntil(self.clients.claim());
});

self.addEventListener("push", event => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch {
    data = { body: event.data ? event.data.text() : "" };
  }

  const title = data.title || "مهمتنا";
  const options = {
    body: data.body || "فيه تحديث جديد على التاسكات.",
    icon: new URL("./default-avatar.webp", self.registration.scope).href,
    badge: new URL("./default-avatar.webp", self.registration.scope).href,
    dir: "rtl",
    lang: "ar",
    tag: data.tag || data.id || undefined,
    renotify: true,
    data: { taskId: data.task_id || null }
  };

  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const url = new URL("./#tasksSection", self.registration.scope).href;

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const appPath = new URL(self.registration.scope).pathname;
    for (const client of windows) {
      if (!new URL(client.url).pathname.startsWith(appPath)) continue;
      if ("focus" in client) {
        if ("navigate" in client) await client.navigate(url);
        return client.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});

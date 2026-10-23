// Rackoon's service worker: shows alert notifications sent by Web Push, and opens the alert's page when clicked.
self.addEventListener("push", (event) => {
  let data = { title: "Rackoon", body: "", path: "/#/dashboard/alerts" };
  try { data = { ...data, ...event.data.json() }; } catch (e) { /* not JSON */ }
  event.waitUntil(self.registration.showNotification(data.title, {
    body: data.body, icon: "/rackoon-icon.svg", data: { path: data.path }, tag: data.path,
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const path = (event.notification.data && event.notification.data.path) || "/";
  event.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
    for (const w of windows) {
      if (new URL(w.url).origin === self.location.origin) {
        w.navigate(path);
        return w.focus();
      }
    }
    return self.clients.openWindow(path);
  }));
});

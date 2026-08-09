export default {
  async fetch(request, env) {
    const incoming = new URL(request.url);
    const route =
      incoming.hostname === env.REST_HOSTNAME
        ? "REST"
        : incoming.hostname === env.VIEWER_HOSTNAME
          ? "VIEWER"
          : incoming.hostname === env.CONSOLE_HOSTNAME
            ? "CONSOLE"
            : null;
    const origin = route ? env[`${route}_ORIGIN`] : null;
    if (!origin) {
      return new Response("Not found", { status: 404 });
    }
    if (route === "CONSOLE" && env.CONSOLE_ENABLED !== "true") {
      return new Response("Cloudflare Access must be configured first", {
        status: 503,
      });
    }

    const target = new URL(incoming.pathname + incoming.search, origin);
    const proxied = new Request(target, request);
    proxied.headers.delete("host");
    if (route === "CONSOLE") {
      proxied.headers.set("X-Ai-Stack-Origin", env.CONSOLE_ORIGIN_SECRET);
    }
    return fetch(proxied);
  },
};

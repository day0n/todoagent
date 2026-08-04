import { EnvHttpProxyAgent, setGlobalDispatcher } from "undici";

/**
 * Routes pi's HTTP through the machine's proxy, when it has one.
 *
 * Without this, every model call on a proxied machine dies with
 * `UND_ERR_CONNECT_TIMEOUT` and the symptom is maximally misleading: the model
 * resolves, `/api/chat/status` reports ready, and chat answers with "这轮没有得到
 * 模型回复" while classification silently falls back to its heuristic. Nothing says
 * "network". `curl` to the same endpoint works, which sends you looking at the key.
 *
 * Why the environment is not enough:
 *
 *   - `https_proxy` is honoured by curl, not by Node. Node's own fetch needs
 *     `NODE_USE_ENV_PROXY=1`, and that flag is read at process start — setting it in
 *     code is too late.
 *   - That flag would not help anyway. pi does not use Node's global fetch: it
 *     imports `undici` directly, so only undici's own dispatcher applies.
 *   - pi ships `configureHttpDispatcher()` which does exactly this, but its package
 *     `exports` map only exposes `.` and `./rpc-entry`, so an SDK embedder cannot
 *     reach it. It is called from pi's CLI entry points, which we do not use.
 *
 * `EnvHttpProxyAgent` is undici's own reader of `http_proxy` / `https_proxy` /
 * `no_proxy`, so behaviour matches curl including the no-proxy exceptions. undici is
 * declared as a direct dependency at the exact version pi depends on, which is what
 * makes this the same module instance pi resolves — pnpm hoists neither, so a
 * different version would install a dispatcher into a copy nothing reads.
 *
 * A no-op when no proxy is set: `EnvHttpProxyAgent` then behaves as the default
 * agent, so this is safe to call unconditionally.
 */
export function installProxyDispatcher(): void {
  const proxy =
    process.env["https_proxy"] ??
    process.env["HTTPS_PROXY"] ??
    process.env["http_proxy"] ??
    process.env["HTTP_PROXY"];

  if (proxy === undefined || proxy.trim() === "") return;

  setGlobalDispatcher(new EnvHttpProxyAgent());
  console.log(`HTTP proxy in use for model calls: ${proxy}`);
}

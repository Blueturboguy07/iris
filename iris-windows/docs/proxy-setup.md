# Proxy Server Setup

By default, Clicky calls APIs directly using your keys. For team deployments, you can route all API calls through a proxy server — useful for centralized key management, usage tracking, and access control.

## Why Use a Proxy

- **Centralized keys** — team members don't need individual API keys
- **Usage monitoring** — track API spend per user or department
- **Access control** — authenticate users before allowing API access
- **Rate limiting** — prevent runaway costs
- **Compliance** — single point of audit for all API traffic

## Cloudflare Worker (Recommended)

The proxy is a lightweight Cloudflare Worker that forwards requests to Anthropic, AssemblyAI, and ElevenLabs with your API keys injected server-side.

### Deploy

```bash
# Clone the repo
git clone https://github.com/tekram/clicky-windows.git
cd clicky-windows/worker

# Install dependencies
npm install

# Set your API keys as secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY

# Deploy
npx wrangler deploy
```

After deploy, Wrangler outputs your worker URL (e.g., `https://clicky-proxy.your-subdomain.workers.dev`).

### Configure Clicky

1. Open Settings
2. Enable **Use API proxy**
3. Paste your worker URL in **Proxy URL**
4. Clear API key fields (the proxy handles keys now)
5. Save

### Worker Architecture

```
User (Clicky app)
  │
  ├─ POST /v1/messages ──────────► Cloudflare Worker ──► Anthropic API
  ├─ POST /v2/realtime/token ────► Cloudflare Worker ──► AssemblyAI API
  └─ POST /v1/text-to-speech ───► Cloudflare Worker ──► ElevenLabs API
```

The worker adds API keys from Cloudflare secrets, forwards the request, and returns the response. No data is stored by the worker.

## Self-Hosting Other Options

You can point the proxy URL at any server that implements the same API routes:

| Option | Best for |
|--------|----------|
| Cloudflare Worker | Low-cost, global edge deployment |
| Express/Fastify server | Custom auth, logging, on-premise |
| Nginx reverse proxy | Simple passthrough with header injection |

The only requirement is that your proxy accepts the same request format and adds the appropriate API keys before forwarding.

## Adding Authentication

The base proxy has no authentication. For team use, add one of:

- **Bearer token** — check `Authorization` header in the worker
- **IP allowlist** — restrict to your office/VPN IPs
- **OAuth/SSO** — for larger orgs, validate tokens against your IdP

Example (adding bearer token check to the worker):

```typescript
// In worker/src/index.ts
const authToken = request.headers.get("Authorization");
if (authToken !== `Bearer ${env.PROXY_AUTH_TOKEN}`) {
  return new Response("Unauthorized", { status: 401 });
}
```

Then in Clicky, the app sends the token with each request.

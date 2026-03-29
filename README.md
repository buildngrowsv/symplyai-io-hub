# symplyai-io-hub

Corporate **root site** for **symplyai.io** — static HTML on **Cloudflare Pages**, deployed from **GitHub**. Built so ad platforms, DSPs, and partners can verify a real company, branded email on-domain, and **live product URLs** (subdomains documented in your internal DNS ops log).

**Canonical Git remote:** [github.com/buildngrowsv/symplyai-io-hub](https://github.com/buildngrowsv/symplyai-io-hub)

## Why this is a separate repo

Cloudflare’s **Connect to Git** flow expects a dedicated repository (or a monorepo with a root build — this project is simpler as its own repo). The parent `UserRoot` tree can keep a copy of these files for editing, but **GitHub + Pages** should track **this folder as the repo root**.

## Quick start (local preview)

```bash
cd "$(dirname "$0")"
npm install
npm run preview
# Open http://127.0.0.1:7832 — non-default port to avoid collisions with other agents.
```

## Create the GitHub repository and push

From **this directory** (must contain `public/` and `wrangler.toml` at repo root):

```bash
git init -b main
git add .
git commit -m "Initial: Symply AI corporate hub for Cloudflare Pages"
# Create an empty repo on GitHub named e.g. symplyai-io-hub, then:
git remote add origin https://github.com/<your-org>/symplyai-io-hub.git
git push -u origin main
```

## Cloudflare Pages (GitHub integration)

1. Cloudflare Dashboard → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**.
2. Select the GitHub repo; set:
   - **Framework preset:** None
   - **Build command:** (empty)
   - **Build output directory:** `public`
3. Save — first build deploys `public/` as the site.

**Verified 2026-03-29:** If `https://symplyai-io-hub.pages.dev` shows “Deployment Not Found”, run `npx wrangler pages deploy public --project-name=symplyai-io-hub` from this directory (OAuth login required). That serves the hub on `*.pages.dev`; **apex `symplyai.io` still requires** adding **Custom domains** on the Pages project (see ops log `Github/ops-logs/dns/symplyai-io-cnames.md`).
4. **Custom domains:** add `symplyai.io` and `www.symplyai.io`. Apply the DNS records Cloudflare shows (apex CNAME flatten + `www` CNAME to your `*.pages.dev` host).
5. If you see **525** or SSL errors on the custom domain: in the zone **SSL/TLS** overview, use **Full (strict)** when the origin is Pages; remove conflicting legacy proxies or old apex records pointing at a dead origin.

### GoDaddy DNS vs Cloudflare nameservers (apex hub)

Your internal ops log may show **product subdomains** on GoDaddy pointing at Vercel while **apex/`www`** are planned on **Cloudflare Pages**. Those only work together if you reconcile authority:

- **If the zone uses Cloudflare nameservers:** add the Pages apex/`www` CNAMEs in Cloudflare (orange cloud) per the ops log; keep separate records for `*.symplyai.io` → Vercel as documented.
- **If the zone is still on GoDaddy DNS only:** you cannot toggle “Proxied” in Cloudflare until the zone is on Cloudflare — use **Cloudflare Pages custom-domain instructions for third-party DNS** (often CNAME `www` + apex ALIAS/ANAME or the IPs Pages provides) until nameservers are migrated.

Confirm in the registrar which nameservers are **actually** live before debugging 525.

## GitHub Actions (alternative to built-in Pages Git hook)

This repo includes `.github/workflows/deploy-cloudflare-pages.yml`. Add secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Each push to `main` or `master` runs `wrangler pages deploy public --project-name=symplyai-io-hub`.

Use **either** Cloudflare’s native Git integration **or** this workflow — not both unless you intend duplicate deploys.

## First paid channel to turn on (when the site resolves cleanly)

Enterprise DSPs (StackAdapt, Simpli.fi signup flows, etc.) often move slower or hit technical blockers. For **fastest path to a live ads account** with a credible business URL:

1. **Reddit Ads** — self-serve at [ads.reddit.com/register](https://ads.reddit.com/register); generally lighter than programmatic DSP onboarding; still benefits from a real **symplyai.io** presence.
2. **Google Ads** — [ads.google.com](https://ads.google.com); expects a working landing domain and clear business identity.

Complete **Cloudflare Email Routing** for `adam@` / `media@` before you use those addresses in signup forms.

## Contact policy (public HTML)

Only **@symplyai.io** addresses appear on the public site. Personal Gmail must not be embedded in `mailto:` or visible copy (scraper persistence).

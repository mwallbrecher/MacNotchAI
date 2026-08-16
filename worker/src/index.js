// AI Drop — hosted free-tier metering proxy (Cloudflare Worker).
//
// Holds the host Gemini key as a secret and forwards completions, metering each
// device: a one-time TRIAL_TOTAL-call trial, then a per-day TOKEN budget — the actual
// tokens Gemini bills (input + output), captured from each response, so text, PDFs and
// IMAGES all debit fairly (a char count would miss the image bytes). Pro skips the
// trial and gets a far larger budget. A GLOBAL_DAILY_CAP circuit-breaker bounds total
// daily interactions regardless of abuse.
//
// The macOS app never sees GEMINI_API_KEY — it only knows this Worker's URL.
//
// Endpoints:
//   POST /v1/complete  { system, messages: [{role,content}], max_tokens?,
//                        image?: {mime, data(base64)} }
//                      headers: X-Device-Id  → { text, usage }
//   POST /v1/stream    same body → SSE: `data: {choices:[{delta:{content}}]}` …,
//                      then one `data: {usage}` and `data: [DONE]`
//   GET  /v1/usage     headers: X-Device-Id  → { usage }   (no quota consumed)
//   GET  /v1/stats     headers: X-Admin-Token → { rows, totals }  (spend roll-up + est. USD)

const GEMINI_URL =
  "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";

// Per-request content ceiling lives in [vars] (MAX_CONTENT_CHARS / _PRO) so it's
// tunable without a deploy and can differ per tier. See readLimits().
const MAX_IMAGE_BASE64_BYTES = 7_000_000; // ~5MB image after base64 inflation

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (request.method === "OPTIONS") return cors(new Response(null, { status: 204 }));

    try {
      if (url.pathname === "/v1/complete" && request.method === "POST") {
        return cors(await handleComplete(request, env, ctx));
      }
      // Same contract as /v1/complete, delivered as an event stream. Kept as a separate
      // route rather than a flag on /v1/complete so an app build that predates this
      // deploy — and one that postdates it talking to an older Worker — both keep
      // working: the client falls back to /v1/complete on 404.
      if (url.pathname === "/v1/stream" && request.method === "POST") {
        return cors(await handleStream(request, env, ctx));
      }
      if (url.pathname === "/v1/usage" && request.method === "GET") {
        return cors(await handleUsage(request, env));
      }
      if (url.pathname === "/v1/stats" && request.method === "GET") {
        return cors(await handleStats(request, env));
      }
      if (url.pathname === "/" || url.pathname === "/health") {
        return cors(json({ ok: true, service: "aidrop" }));
      }
      return cors(json({ error: "Not found" }, 404));
    } catch (err) {
      return cors(json({ error: "Server error", detail: String(err) }, 500));
    }
  },
};

// ── Shared request preparation (/v1/complete and /v1/stream) ─────────────────
//
// Validation, the per-request input ceiling, and BOTH quota gates. The two endpoints
// MUST run this identically — a streaming path that skipped a gate would be a free
// bypass of the entire metering scheme. Returns `{ error: Response }` to reject the
// request outright, otherwise the context needed to run and then meter the completion.
async function prepareCompletion(request, env) {
  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId) return { error: json({ error: "Missing X-Device-Id" }, 400) };

  const body = await request.json().catch(() => null);
  if (!body) return { error: json({ error: "Invalid JSON" }, 400) };

  // The app sends the WHOLE conversation as `messages` (multi-turn; the document is
  // folded into the first user turn). Accept a legacy single `content` string too,
  // in case an old client calls in.
  const messages = Array.isArray(body.messages)
    ? body.messages
        .filter((m) => m && (m.role === "user" || m.role === "assistant") &&
                       typeof m.content === "string")
        .map((m) => ({ role: m.role, content: m.content }))
    : (typeof body.content === "string"
        ? [{ role: "user", content: body.content }]
        : []);
  if (messages.length === 0) return { error: json({ error: "Missing messages" }, 400) };

  const totalChars = messages.reduce((n, m) => n + m.content.length, 0);

  // Per-request input ceiling — a PRE-FLIGHT guard (char-based, since real token cost
  // isn't known until after the call) that rejects an oversized request before any
  // spend. Pro is SERVER-verified from the device's account row — a client can't
  // self-elevate by lying. The client mirrors this with its own free/pro extraction
  // cap, so an honest client never trips it.
  const limits = readLimits(env);
  const isPro = await isProDevice(env, deviceId);
  const contentCap = isPro ? limits.maxContentCharsPro : limits.maxContentChars;
  if (totalChars > contentCap) return { error: json({ error: "Content too large" }, 413) };

  // This device's daily TOKEN budget (actual tokens billed, debited after the call).
  const dailyTokenBudget = isPro ? limits.proDailyTokens : limits.freeDailyTokens;

  if (body.image && typeof body.image.data === "string" &&
      body.image.data.length > MAX_IMAGE_BASE64_BYTES) {
    return { error: json({ error: "Image too large for hosted tier — use your own key." }, 413) };
  }

  const system = typeof body.system === "string" && body.system.length
    ? body.system : "You are a helpful assistant.";

  // Honor the app's per-action output ceiling, with Gemini thinking-headroom: on
  // Google's OpenAI-compat endpoint "thinking" tokens count against max_tokens, so a
  // tight cap can starve the visible answer (the 2.5-Flash cut-off). Add room + a
  // floor — identical to the BYOK GeminiProvider.
  const requested = Number.isInteger(body.max_tokens) ? body.max_tokens : 1024;
  const maxTokens = Math.max(requested + 1024, 2048);

  const completion = { system, messages, image: body.image, maxTokens };

  const day = utcDay();

  // Budget circuit-breaker: hard stop on total daily interactions.
  const globalCount = await getCount(
    env, "SELECT count FROM global_usage WHERE day = ?", [day]
  );
  if (globalCount >= limits.globalDailyCap) {
    return {
      error: json({ error: "Free tier is busy right now. Try again later or use your own key." }, 503),
    };
  }

  await env.DB.prepare(
    "INSERT OR IGNORE INTO accounts (device_id) VALUES (?)"
  ).bind(deviceId).run();

  const trialUsed = await getCount(
    env, "SELECT trial_used FROM accounts WHERE device_id = ?", [deviceId]
  );
  // Pro skips the trial entirely → straight to its (much larger) daily token budget.
  const inTrial = !isPro && trialUsed < limits.trialTotal;

  let dailyTokens = 0;
  if (!inTrial) {
    dailyTokens = await getCount(
      env, "SELECT tokens FROM usage WHERE device_id = ? AND day = ?", [deviceId, day]
    );
    // Gate on the budget already consumed (the last request of the day may slightly
    // overshoot — a relief valve, not a hard ceiling; per-request cap bounds the spill).
    if (dailyTokens >= dailyTokenBudget) {
      return {
        error: json(
          {
            error: "Daily free limit reached.",
            usage: usagePayload(limits, isPro, trialUsed, dailyTokens),
          },
          429
        ),
      };
    }
  }

  return {
    deviceId, day, limits, isPro, inTrial, trialUsed, dailyTokens,
    completion, totalChars, tier: body.tier,
  };
}

// ── /v1/complete ────────────────────────────────────────────────────────────

async function handleComplete(request, env, ctx) {
  const prep = await prepareCompletion(request, env);
  if (prep.error) return prep.error;
  const { isPro, totalChars } = prep;

  // Pick the model from the tier hint (missing/unknown → the capable default). Pro is
  // server-verified, so entitled devices resolve each tier to a more capable model
  // (funded by the subscription). Forward to Gemini; quota is only consumed on success.
  const strongModel = pickModel(env, "strong", isPro); // this user's capable default
  const model = pickModel(env, prep.tier, isPro);
  const completion = prep.completion;
  let usedModel = model;
  let result = await callGemini(env, completion, model);
  if (!result.ok && model !== strongModel) {
    // The routed (cheaper) model failed — fall back once to this user's capable default
    // so they still get an answer instead of an error. Log WHY: this is the only place a
    // fast-tier request silently ends up billed on the strong model, and the cause
    // (upstream 4xx / empty completion) is otherwise invisible. Watch via `wrangler tail`.
    console.warn(`tier-fallback ${model}->${strongModel}: ${result.error || "unknown"}`);
    usedModel = strongModel;
    result = await callGemini(env, completion, strongModel);
  }
  if (!result.ok) {
    return json({ error: result.error || "Upstream error" }, 502);
  }

  const usage = await meterCompletion(env, ctx, {
    ...prep,
    usedModel,
    tokens: result.tokens,
    promptTokens: result.promptTokens,
    completionTokens: result.completionTokens,
    fallbackChars: totalChars,
  });

  return json({ text: result.text, usage });
}

// ── Shared metering (/v1/complete and /v1/stream) ────────────────────────────
//
// Debits a SUCCESSFUL completion and returns the fresh usage snapshot the app mirrors
// into UsageStore. Split out so the streaming path books exactly the same way — the
// only difference there is WHEN it runs (after the stream drains, via waitUntil).
async function meterCompletion(env, ctx, p) {
  const { deviceId, day, limits, isPro, inTrial, trialUsed, dailyTokens, usedModel } = p;

  // Tokens actually billed by Gemini (input + output). Falls back to a char estimate
  // only if the upstream usage block is missing, so a request never meters as free.
  const tokensUsed =
    p.tokens && p.tokens > 0 ? p.tokens : Math.max(1, Math.ceil(p.fallbackChars / 4));

  // Weight the raw tokens by the model ACTUALLY billed (incl. the fallback model) so the
  // daily budget caps COST, not just count — a gemini-2.5-pro token drains it 4x faster,
  // a flash-lite token only 0.5x. The SPEND roll-up below stays RAW (real prompt/completion
  // tokens) for accurate $ math; ONLY this budget debit is weighted.
  const billedTokens = Math.max(1, Math.round(tokensUsed * modelWeight(usedModel)));

  // Consume usage. Trial debits one interaction; post-trial debits this request's
  // WEIGHTED tokens against the daily budget (and bumps count for instrumentation).
  if (inTrial) {
    await env.DB.prepare(
      "UPDATE accounts SET trial_used = trial_used + 1 WHERE device_id = ?"
    ).bind(deviceId).run();
  } else {
    await env.DB.prepare(
      `INSERT INTO usage (device_id, day, count, tokens) VALUES (?, ?, 1, ?)
       ON CONFLICT(device_id, day) DO UPDATE SET count = count + 1, tokens = tokens + excluded.tokens`
    ).bind(deviceId, day, billedTokens).run();
  }
  await env.DB.prepare(
    `INSERT INTO global_usage (day, count) VALUES (?, 1)
     ON CONFLICT(day) DO UPDATE SET count = count + 1`
  ).bind(day).run();

  // Spend instrumentation (best-effort — never break the response if logging fails).
  // Rolls up per day × model billed × requested tier, splitting in/out tokens so the
  // bill can be estimated accurately. Read via GET /v1/stats.
  //
  // Pushed OFF the response path via ctx.waitUntil(): pure logging, so it runs AFTER
  // the response is sent → zero user-facing latency. The consume/global writes above
  // stay awaited (they gate the next request's limits and must be race-free). Falls
  // back to a plain await if ctx is unavailable (e.g. a direct unit-test call).
  const pt = Number.isInteger(p.promptTokens) ? p.promptTokens : tokensUsed;
  const ct = Number.isInteger(p.completionTokens) ? p.completionTokens : 0;
  const tierHint = ["fast", "strong", "extra"].includes(p.tier) ? p.tier : "other";
  const spendWrite = env.DB.prepare(
    `INSERT INTO spend (day, model, tier, calls, prompt_tokens, completion_tokens)
     VALUES (?, ?, ?, 1, ?, ?)
     ON CONFLICT(day, model, tier) DO UPDATE SET
       calls = calls + 1,
       prompt_tokens = prompt_tokens + excluded.prompt_tokens,
       completion_tokens = completion_tokens + excluded.completion_tokens`
  ).bind(day, usedModel, tierHint, pt, ct).run().catch(() => {}); // logging is non-fatal
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(spendWrite);
  else await spendWrite;

  const newTrial = inTrial ? trialUsed + 1 : trialUsed;
  const newTokens = inTrial ? dailyTokens : dailyTokens + billedTokens;
  return usagePayload(limits, isPro, newTrial, newTokens);
}

// ── /v1/stream ───────────────────────────────────────────────────────────────

async function handleStream(request, env, ctx) {
  const prep = await prepareCompletion(request, env);
  if (prep.error) return prep.error;

  const strongModel = pickModel(env, "strong", prep.isPro);
  const model = pickModel(env, prep.tier, prep.isPro);
  let usedModel = model;

  // callGeminiStream only resolves once the FIRST content delta has arrived, so the
  // tier fallback still works: both failure modes it exists for (an upstream 4xx and an
  // empty completion) surface before a single byte has been committed to the client.
  // After that point the 200 and its headers are gone and no retry is possible.
  let stream = await callGeminiStream(env, prep.completion, model);
  if (!stream.ok && model !== strongModel) {
    console.warn(`tier-fallback ${model}->${strongModel}: ${stream.error || "unknown"}`);
    usedModel = strongModel;
    stream = await callGeminiStream(env, prep.completion, strongModel);
  }
  if (!stream.ok) return json({ error: stream.error || "Upstream error" }, 502);

  const encoder = new TextEncoder();
  let fullText = "";
  let usage = stream.usage;
  let metered = false;

  // Exactly one metering pass, whether the stream drains normally OR the client
  // disconnects halfway. Without the disconnect path, closing the shelf mid-answer
  // would consume host tokens for free — the tokens are billed by Google either way.
  const meter = async () => {
    if (metered) return null;
    metered = true;
    return await meterCompletion(env, ctx, {
      ...prep,
      usedModel,
      tokens: usage?.total_tokens,
      promptTokens: usage?.prompt_tokens,
      completionTokens: usage?.completion_tokens,
      // Upstream usage is missing on an aborted stream; bill what was actually produced.
      fallbackChars: prep.totalChars + fullText.length,
    });
  };
  const meterInBackground = () => {
    if (metered) return;
    const p = meter().catch((err) => console.warn(`stream-meter failed: ${err}`));
    if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(p);
  };

  const body = new ReadableStream({
    async start(controller) {
      const send = (obj) =>
        controller.enqueue(encoder.encode(`data: ${JSON.stringify(obj)}\n\n`));
      try {
        for (const text of stream.primed) {
          fullText += text;
          send(deltaEvent(text));
        }
        let rest = stream.rest;
        for (;;) {
          const { done, value } = await stream.reader.read();
          if (done) break;
          rest += stream.decoder.decode(value, { stream: true });
          const drained = drainSSE(rest);
          rest = drained.rest;
          for (const payload of drained.payloads) {
            if (payload === "[DONE]") continue;
            let event;
            try { event = JSON.parse(payload); } catch { continue; }
            if (event.usage) usage = event.usage;
            const text = event?.choices?.[0]?.delta?.content;
            if (text) {
              fullText += text;
              send(deltaEvent(text));
            }
          }
        }
        // Terminal events: the usage snapshot the app mirrors into UsageStore (the
        // streaming stand-in for /v1/complete's `usage` field), then [DONE].
        const snapshot = await meter();
        if (snapshot) send({ usage: snapshot });
        controller.enqueue(encoder.encode("data: [DONE]\n\n"));
        controller.close();
      } catch (err) {
        // Past the 200 a failure can no longer be a status code — report it in-band and
        // let the client decide (it keeps whatever text already arrived).
        try {
          send({ error: String(err) });
          controller.close();
        } catch { /* client already gone */ }
      } finally {
        meterInBackground();
      }
    },
    cancel() {
      // Client hung up. Stop pulling from Gemini, but still bill what it produced.
      stream.reader.cancel().catch(() => {});
      meterInBackground();
    },
  });

  return new Response(body, {
    headers: {
      "Content-Type": "text/event-stream",
      // no-transform is the load-bearing part: without it an edge compression pass can
      // buffer the whole stream and deliver every token in one burst at the end.
      "Cache-Control": "no-cache, no-transform",
    },
  });
}

function deltaEvent(text) {
  return { choices: [{ delta: { content: text } }] };
}

// Pull complete `data:` payloads out of a rolling SSE buffer, returning the partial
// tail that must stay buffered until the next network chunk completes it.
function drainSSE(buffer) {
  const payloads = [];
  let idx;
  while ((idx = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, idx).trim();
    buffer = buffer.slice(idx + 1);
    if (line.startsWith("data:")) payloads.push(line.slice(5).trim());
  }
  return { payloads, rest: buffer };
}

// ── /v1/usage ─────────────────────────────────────────────────────────────────

async function handleUsage(request, env) {
  const deviceId = request.headers.get("X-Device-Id");
  if (!deviceId) return json({ error: "Missing X-Device-Id" }, 400);

  const limits = readLimits(env);
  const isPro = await isProDevice(env, deviceId);
  const day = utcDay();
  const trialUsed = await getCount(
    env, "SELECT trial_used FROM accounts WHERE device_id = ?", [deviceId]
  );
  const dailyTokens = await getCount(
    env, "SELECT tokens FROM usage WHERE device_id = ? AND day = ?", [deviceId, day]
  );
  return json({ usage: usagePayload(limits, isPro, trialUsed, dailyTokens) });
}

// ── /v1/stats (admin) ─────────────────────────────────────────────────────────

// Operator-only spend roll-up. Guarded by a constant ADMIN_TOKEN secret (set via
// `wrangler secret put ADMIN_TOKEN`); if the secret is unset the endpoint is closed.
// `?days=N` (default 7, max 90) windows the result. est_usd is a LIST-PRICE estimate
// from PRICES — informational, not a billing source of truth.
async function handleStats(request, env) {
  const token = request.headers.get("X-Admin-Token");
  if (!env.ADMIN_TOKEN || token !== env.ADMIN_TOKEN) {
    return json({ error: "Unauthorized" }, 401);
  }
  const url = new URL(request.url);
  const days = Math.min(90, Math.max(1, parseInt(url.searchParams.get("days") || "7", 10)));
  const since = utcDayOffset(-(days - 1));

  let results = [];
  try {
    const res = await env.DB.prepare(
      `SELECT day, model, tier, calls, prompt_tokens, completion_tokens
       FROM spend WHERE day >= ? ORDER BY day DESC, model, tier`
    ).bind(since).all();
    results = res?.results || [];
  } catch {
    return json({ error: "No spend data yet (run the schema to create the table)." }, 200);
  }

  const rows = results.map((r) => ({
    ...r,
    est_usd: round4(estimateCost(r.model, r.prompt_tokens, r.completion_tokens)),
  }));
  const totals = rows.reduce(
    (t, r) => {
      t.calls += r.calls;
      t.prompt_tokens += r.prompt_tokens;
      t.completion_tokens += r.completion_tokens;
      t.est_usd += r.est_usd;
      return t;
    },
    { calls: 0, prompt_tokens: 0, completion_tokens: 0, est_usd: 0 }
  );
  totals.est_usd = round4(totals.est_usd);
  return json({ days, since, rows, totals });
}

// Gemini list price per 1M tokens (USD). gemini-2.5-pro doubles above 200k ctx — this
// uses the ≤200k figure (the common case). Unknown model → 0 (shown as $0, not an error).
const PRICES = {
  "gemini-2.5-flash-lite": { in: 0.1, out: 0.4 },
  "gemini-2.5-flash": { in: 0.3, out: 2.5 },
  "gemini-2.5-pro": { in: 1.25, out: 10.0 },
};

function estimateCost(model, promptTokens, completionTokens) {
  const p = PRICES[model];
  if (!p) return 0;
  return (promptTokens / 1e6) * p.in + (completionTokens / 1e6) * p.out;
}

// Budget weight per model — how fast a model drains the daily TOKEN budget, RELATIVE to
// the default (flash = 1.0). This turns the budget into a COST guard, not just a raw token
// count: gemini-2.5-pro costs ~4x flash and ~18x flash-lite per token, so an UNweighted
// budget let a Pro user spam the pricey model "within budget" while the real bill ran away
// (the worst-case ~$15–23/mo column). Weighting the debit by model makes the worst case
// roughly flat regardless of which model gets used.
//
// Weights are deliberately GENEROUS — compressed well below the true cost ratio — so the
// everyday experience is unchanged or better:
//   flash-lite 0.5  → the cheap path is REWARDED (thrifty mode → ~2x effective headroom)
//   flash      1.0  → the anchor; today's 30k/200k budgets keep their exact feel
//   pro        4.0  → ≈ its $/token vs flash, so a Pro user maxing the premium model costs
//                     about the same as one maxing flash (~$4/mo) instead of ~$15–23/mo.
// Unknown/renamed model → 1.0 (never 0 — an unrecognised model must NOT be a free pass).
const BUDGET_WEIGHTS = {
  "gemini-2.5-flash-lite": 0.5,
  "gemini-2.5-flash": 1.0,
  "gemini-2.5-pro": 4.0,
};
function modelWeight(model) {
  const w = BUDGET_WEIGHTS[model];
  return Number.isFinite(w) && w > 0 ? w : 1.0;
}

function round4(n) {
  return Math.round(n * 10000) / 10000;
}

function utcDayOffset(deltaDays) {
  const d = new Date();
  d.setUTCDate(d.getUTCDate() + deltaDays);
  return d.toISOString().slice(0, 10);
}

// ── Gemini call ─────────────────────────────────────────────────────────────

async function callGemini(env, req, model) {
  const resp = await fetch(GEMINI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GEMINI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(geminiPayload(env, req, model)),
  });

  const data = await resp.json().catch(() => null);
  if (!resp.ok) {
    return { ok: false, error: data?.error?.message || `HTTP ${resp.status}` };
  }
  const text = data?.choices?.[0]?.message?.content;
  if (!text) return { ok: false, error: "Empty response" };
  // Capture actual token usage for metering (input + output, so image tokens count).
  // Gemini's OpenAI-compat endpoint returns usage.{prompt,completion,total}_tokens;
  // null if absent → the caller falls back to a char estimate.
  const u = data?.usage || {};
  const promptTokens = Number.isInteger(u.prompt_tokens) ? u.prompt_tokens : null;
  const completionTokens = Number.isInteger(u.completion_tokens) ? u.completion_tokens : null;
  const tokens = Number.isInteger(u.total_tokens)
    ? u.total_tokens
    : ((promptTokens || 0) + (completionTokens || 0)) || null;
  return { ok: true, text, tokens, promptTokens, completionTokens };
}

// Streaming twin of callGemini. Resolves only AFTER the first content delta, so the
// caller can still fall back to another model on failure; the caller then pumps the
// returned reader for the rest.
async function callGeminiStream(env, req, model) {
  const resp = await fetch(GEMINI_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GEMINI_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      ...geminiPayload(env, req, model),
      stream: true,
      // Without this the OpenAI-compat stream omits usage entirely and every streamed
      // request would meter on the char estimate instead of real tokens.
      stream_options: { include_usage: true },
    }),
  });

  if (!resp.ok || !resp.body) {
    const data = await resp.json().catch(() => null);
    return { ok: false, error: data?.error?.message || `HTTP ${resp.status}` };
  }

  const reader = resp.body.getReader();
  const decoder = new TextDecoder();
  let rest = "";
  let usage = null;
  const primed = [];

  while (primed.length === 0) {
    const { done, value } = await reader.read();
    if (done) break;
    rest += decoder.decode(value, { stream: true });
    const drained = drainSSE(rest);
    rest = drained.rest;
    for (const payload of drained.payloads) {
      if (payload === "[DONE]") continue;
      let event;
      try { event = JSON.parse(payload); } catch { continue; }
      if (event.usage) usage = event.usage;
      const text = event?.choices?.[0]?.delta?.content;
      if (text) primed.push(text);
    }
  }

  if (primed.length === 0) {
    reader.cancel().catch(() => {});
    return { ok: false, error: "Empty response" };
  }
  return { ok: true, reader, decoder, rest, primed, usage };
}

// Shared OpenAI-compat request body for both callGemini variants.
function geminiPayload(env, req, model) {
  // Rebuild the OpenAI-compat messages array: system first, then the conversation.
  // The image (if any) is inlined into the FIRST user turn — same shape the BYOK
  // providers use.
  const messages = [{ role: "system", content: req.system }];
  let imageUsed = false;
  for (const m of req.messages) {
    if (!imageUsed && m.role === "user" && req.image && req.image.data) {
      imageUsed = true;
      const mime = req.image.mime || "image/png";
      messages.push({
        role: "user",
        content: [
          { type: "image_url", image_url: { url: `data:${mime};base64,${req.image.data}` } },
          { type: "text", text: m.content || "" },
        ],
      });
    } else {
      messages.push({ role: m.role, content: m.content });
    }
  }

  return {
    model: model || env.GEMINI_MODEL || "gemini-2.5-flash",
    messages,
    max_tokens: req.maxTokens,
    temperature: 0.3,
    reasoning_effort: "low",
  };
}

// ── Helpers ───────────────────────────────────────────────────────────────────

// Map the client's `tier` hint → a concrete Gemini model. The hint is UNTRUSTED: only
// an explicit "fast" gets the cheap model; missing/unknown/"strong" → the capable
// default. So a bad or absent tier degrades cost, never quality (and never errors).
function pickModel(env, tier, isPro = false) {
  const fast = env.GEMINI_MODEL_FAST || "gemini-2.5-flash-lite";
  const strong = env.GEMINI_MODEL || "gemini-2.5-flash";
  // `extra` is the Pro-only top model. It fires rarely — a tiny client whitelist
  // (findBugs/refactor) and the manual "Go deeper" escalation. Funded by the
  // subscription. GEMINI_MODEL_EXTRA is OPTIONAL → unset falls back to `strong`
  // (flash), so enabling it never silently jumps to a pricier model.
  const extra = env.GEMINI_MODEL_EXTRA || strong;

  // ── Thrifty mode (FREE tier only) ───────────────────────────────────────────
  // ROUTING_MODE=thrifty squeezes the free ladder down a rung to protect the
  // operator's bill as traffic grows: EVERY free request runs on flash-lite (the
  // cheap model — and the always-on `reasoning_effort:"low"` still gives the more
  // complex `strong` tasks a little thinking), and only the rare `extra`
  // escalation steps up to flash for real reasoning. Pro is NEVER thrifted —
  // paying users keep the full generous ladder below. Default "generous"
  // preserves launch behaviour; flip the env var (no logic redeploy) to switch.
  const thrifty = (env.ROUTING_MODE || "generous") === "thrifty";
  if (thrifty && !isPro) {
    if (tier === "extra") return strong; // flash — the one step-up free gets
    return fast;                         // fast & strong (and any hint) → flash-lite
  }

  // ── Generous mode (default; also every Pro request) ─────────────────────────
  if (tier === "fast") return fast;
  // Free devices can't reach the top model — `extra` degrades to the capable default.
  if (tier === "extra") return isPro ? extra : strong;
  return strong; // "strong" or any unknown/missing tier → capable default (fail-safe)
}

function readLimits(env) {
  return {
    trialTotal: parseInt(env.TRIAL_TOTAL ?? "30", 10),
    // Daily quota is metered in ACTUAL TOKENS billed by Gemini (input + output).
    freeDailyTokens: parseInt(env.FREE_DAILY_TOKENS ?? "30000", 10),
    proDailyTokens: parseInt(env.PRO_DAILY_TOKENS ?? "200000", 10),
    globalDailyCap: parseInt(env.GLOBAL_DAILY_CAP ?? "2000", 10),
    // Per-request input guard (char-based pre-flight — token cost isn't known until
    // after the call). Bounds a single request's size before any spend.
    maxContentChars: parseInt(env.MAX_CONTENT_CHARS ?? "40000", 10),
    maxContentCharsPro: parseInt(env.MAX_CONTENT_CHARS_PRO ?? "80000", 10),
  };
}

// Server-trusted Pro check. Reads the `pro` flag from the device's account row and
// is the ONLY thing that grants Pro perks — never a client-sent value — so a modified
// client can't self-elevate. Defaults to false for unknown devices, and the try/catch
// keeps it safe to deploy BEFORE the column migration runs (a missing `pro` column
// throws → treated as free). The future Paddle webhook sets accounts.pro = 1.
async function isProDevice(env, deviceId) {
  try {
    const row = await env.DB.prepare(
      "SELECT pro FROM accounts WHERE device_id = ?"
    ).bind(deviceId).first();
    return !!(row && row.pro);
  } catch {
    return false;
  }
}

function usagePayload(limits, isPro, trialUsed, dailyTokens) {
  // Pro skips the trial; free runs trial (interactions) then the daily token budget.
  const inTrial = !isPro && trialUsed < limits.trialTotal;
  const trialRemaining = Math.max(0, limits.trialTotal - trialUsed);
  const dailyTokenBudget = isPro ? limits.proDailyTokens : limits.freeDailyTokens;
  const dailyTokensRemaining = Math.max(0, dailyTokenBudget - dailyTokens);
  return {
    tier: isPro ? "pro" : "free",
    inTrial,
    trialRemaining,
    dailyTokenBudget,
    dailyTokensRemaining,
    resetAt: nextUtcMidnightISO(),
  };
}

async function getCount(env, sql, binds) {
  const row = await env.DB.prepare(sql).bind(...binds).first();
  if (!row) return 0;
  const v = row.count ?? row.tokens ?? row.trial_used ?? 0;
  return typeof v === "number" ? v : 0;
}

function utcDay() {
  return new Date().toISOString().slice(0, 10); // YYYY-MM-DD (UTC)
}

function nextUtcMidnightISO() {
  const now = new Date();
  const next = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate() + 1, 0, 0, 0
  ));
  return next.toISOString();
}

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function cors(resp) {
  resp.headers.set("Access-Control-Allow-Origin", "*");
  resp.headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");
  resp.headers.set("Access-Control-Allow-Headers", "Content-Type, X-Device-Id");
  return resp;
}

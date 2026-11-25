import { generateReport, ReportGenerationError } from "./generate.ts";
const url = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const dispatchSecret = Deno.env.get("SUMMARY_DISPATCH_SECRET");
const hexToken = /^[0-9a-f]{64}$/;
const maxBodyBytes = 4096;
const oversized = Symbol("oversized");

function matchesSecret(token: string): boolean {
  if (!dispatchSecret || !hexToken.test(dispatchSecret)) return false;
  let difference = 0;
  for (let i = 0; i < 64; i++) {
    difference |= token.charCodeAt(i) ^ dispatchSecret.charCodeAt(i);
  }
  return difference === 0;
}

async function readRequest(req: Request) {
  const length = req.headers.get("content-length");
  if (length !== null && Number(length) > maxBodyBytes) return oversized;
  const reader = req.body?.getReader();
  if (!reader) throw new Error("Missing body");
  const buffer = new Uint8Array(maxBodyBytes);
  let used = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (used + value.length > maxBodyBytes) {
        void reader.cancel().catch(() => {});
        return oversized;
      }
      buffer.set(value, used);
      used += value.length;
    }
  } finally {
    reader.releaseLock();
  }
  return JSON.parse(
    new TextDecoder("utf-8", { fatal: true }).decode(buffer.subarray(0, used)),
  );
}

async function rpc(name: string, body: unknown) {
  const result = await fetch(`${url}/rest/v1/rpc/${name}`, {
    method: "POST",
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20000),
  });
  if (!result.ok) {
    if (result.status === 403 && name === "ai_summary_claim_job") {
      const error = await result.json().catch(() => null);
      if (error?.message === "invalid_job_token") {
        throw new Error("invalid_job_token");
      }
    } else {
      await result.body?.cancel();
    }
    throw new Error("database_request_failed");
  }
  const text = await result.text();
  return text ? JSON.parse(text) : null;
}
Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }
  const token = req.headers.get("x-summary-job-token");
  if (!dispatchSecret || !hexToken.test(dispatchSecret)) {
    return new Response("Worker unavailable", { status: 503 });
  }
  if (!token || !hexToken.test(token) || !matchesSecret(token)) {
    return new Response("Unauthorized", { status: 401 });
  }
  let manualJob: string | null = null;
  try {
    const body = await readRequest(req);
    if (body === oversized) {
      return new Response("Request too large", { status: 413 });
    }
    if (!body || typeof body !== "object" || Array.isArray(body)) {
      return new Response("Invalid request", { status: 400 });
    }
    if (body.manual_job_id !== undefined) {
      if (
        typeof body.manual_job_id !== "string" ||
        !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
          body.manual_job_id,
        )
      ) {
        return new Response("Invalid job", { status: 400 });
      }
      manualJob = body.manual_job_id;
    }
  } catch {
    return new Response("Invalid request", { status: 400 });
  }
  const run = crypto.randomUUID();
  let claimed = false;
  try {
    const job = await rpc("ai_summary_claim_job", {
      p_job_token: token,
      p_run_id: run,
      p_manual_job: manualJob,
    });
    if (!job) return Response.json({ status: "skipped" });
    claimed = true;
    const content = await generateReport(job);
    await rpc("ai_summary_finish", { p_run_id: run, p_content: content });
    return Response.json({ status: "ready" });
  } catch (error) {
    // No prompts, API keys, provider response bodies or business records in logs/errors.
    const code = error instanceof ReportGenerationError
      ? error.code
      : "generation_failed";
    if (claimed) {
      try {
        await rpc("ai_summary_finish", { p_run_id: run, p_error: code });
      } catch { /* lease permits bounded retry */ }
    }
    if (!claimed) {
      const invalid = error instanceof Error &&
        error.message === "invalid_job_token";
      return Response.json(
        { status: invalid ? "unauthorized" : "unavailable" },
        {
          status: invalid ? 401 : 503,
        },
      );
    }
    return Response.json({ status: "failed" }, { status: 502 });
  }
});

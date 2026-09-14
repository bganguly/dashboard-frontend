import { useCallback, useEffect, useRef, useState } from "react";

// ── Types ─────────────────────────────────────────────────────────────────────

type WakeStatus = "waking" | "ready" | "resolving" | null;

interface RunResult {
  json: unknown;
  ms: number;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

async function fetchTimed(path: string): Promise<RunResult> {
  const t0 = performance.now();
  const res = await fetch(path);
  if (!res.ok) throw new Error("HTTP " + res.status);
  const json = await res.json();
  return { json, ms: Math.round(performance.now() - t0) };
}

function timingClass(ms: number) {
  if (ms < 300) return { bg: "rgba(16,185,129,0.12)", color: "#34d399", border: "1px solid rgba(16,185,129,0.25)" };
  if (ms < 1000) return { bg: "rgba(245,158,11,0.12)", color: "#fbbf24", border: "1px solid rgba(245,158,11,0.25)" };
  return { bg: "rgba(239,68,68,0.12)", color: "#f87171", border: "1px solid rgba(239,68,68,0.25)" };
}

function statusStyle(s: string) {
  const k = (s || "").toLowerCase();
  if (k.includes("complet")) return { bg: "rgba(16,185,129,0.15)", color: "#6ee7b7" };
  if (k.includes("pend")) return { bg: "rgba(245,158,11,0.15)", color: "#fcd34d" };
  if (k.includes("cancel")) return { bg: "rgba(239,68,68,0.15)", color: "#fca5a5" };
  if (k.includes("process")) return { bg: "rgba(99,102,241,0.15)", color: "#a5b4fc" };
  return { bg: "rgba(100,116,139,0.15)", color: "#94a3b8" };
}

// ── Sub-components ────────────────────────────────────────────────────────────

function MetaBar({ ms, label }: { ms: number; label: string }) {
  const t = timingClass(ms);
  return (
    <div style={{ display: "flex", alignItems: "center", gap: "0.75rem", marginBottom: "1rem" }}>
      <span style={{ fontSize: "0.6875rem", padding: "0.25rem 0.5rem", borderRadius: "9999px",
        fontFamily: "monospace", display: "inline-flex", alignItems: "center", gap: "0.25rem",
        background: t.bg, color: t.color, border: t.border }}>
        ⚡ {ms}ms
      </span>
      <span style={{ fontSize: "0.75rem", color: "#71717a" }}>{label}</span>
    </div>
  );
}

function RawJson({ data }: { data: unknown }) {
  const [open, setOpen] = useState(false);
  return (
    <div style={{ marginTop: "0.75rem" }}>
      <button onClick={() => setOpen(o => !o)}
        style={{ display: "inline-flex", alignItems: "center", gap: "0.375rem", background: "none",
          border: "none", cursor: "pointer", fontSize: "0.6875rem", color: "#52525b", padding: 0 }}>
        <span style={{ fontSize: "0.55rem", transition: "transform .15s", transform: open ? "rotate(90deg)" : "none" }}>▶</span>
        View raw JSON
      </button>
      {open && (
        <pre style={{ marginTop: "0.5rem", borderRadius: "0.5rem", padding: "0.75rem",
          fontSize: "0.6875rem", overflow: "auto", maxHeight: "12rem",
          background: "rgba(0,0,0,0.3)", border: "1px solid rgba(255,255,255,0.06)",
          color: "#71717a", fontFamily: "monospace", whiteSpace: "pre" }}>
          {JSON.stringify(data, null, 2)}
        </pre>
      )}
    </div>
  );
}

function OrderTable({ rows }: { data?: unknown; rows: Record<string, unknown>[] }) {
  return (
    <div style={{ border: "1px solid rgba(255,255,255,0.06)", borderRadius: "0.75rem", overflow: "hidden", overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.75rem" }}>
        <thead>
          <tr>{["#","ID","Status","Total","Customer","Region","Placed"].map(h => (
            <th key={h} style={{ textAlign: "left", padding: "0.5rem 0.75rem", fontWeight: 500,
              color: "#71717a", borderBottom: "1px solid rgba(255,255,255,0.06)", whiteSpace: "nowrap" }}>{h}</th>
          ))}</tr>
        </thead>
        <tbody>
          {rows.map((o, i) => {
            const c = (o.customer as Record<string,string>) || {};
            const r = (o.region as Record<string,string>) || {};
            const name = c.name || [c.firstName, c.lastName].filter(Boolean).join(" ") || "—";
            const ss = statusStyle(String(o.status || ""));
            return (
              <tr key={i}>
                <td style={TD}><span style={{ color: "#71717a" }}>{i+1}</span></td>
                <td style={{ ...TD, fontFamily: "monospace" }}>{String(o.id ?? "—")}</td>
                <td style={TD}>
                  <span style={{ fontSize: "0.6875rem", fontWeight: 600, padding: "0.125rem 0.5rem",
                    borderRadius: "9999px", background: ss.bg, color: ss.color }}>
                    {String(o.status || "—")}
                  </span>
                </td>
                <td style={{ ...TD, fontFamily: "monospace", color: "#34d399" }}>
                  {String(o.currency || "$")}{Number(o.total || 0).toFixed(2)}
                </td>
                <td style={TD}>{name}</td>
                <td style={{ ...TD, color: "#71717a" }}>{r.name || r.code || "—"}</td>
                <td style={{ ...TD, fontFamily: "monospace", color: "#71717a" }}>{String(o.placedAt || "—").slice(0,10)}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function CustomerTable({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <div style={{ border: "1px solid rgba(255,255,255,0.06)", borderRadius: "0.75rem", overflow: "hidden", overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.75rem" }}>
        <thead>
          <tr>{["#","Name","Email","Region"].map(h => (
            <th key={h} style={{ textAlign: "left", padding: "0.5rem 0.75rem", fontWeight: 500,
              color: "#71717a", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>{h}</th>
          ))}</tr>
        </thead>
        <tbody>
          {rows.map((c, i) => {
            const r = (c.region as Record<string,string>) || {};
            const name = (c.name as string) || [(c as Record<string,string>).firstName, (c as Record<string,string>).lastName].filter(Boolean).join(" ") || "—";
            return (
              <tr key={i}>
                <td style={{ ...TD, color: "#71717a" }}>{i+1}</td>
                <td style={TD}>{name}</td>
                <td style={{ ...TD, fontFamily: "monospace", color: "#a1a1aa", fontSize: "0.7rem" }}>{String(c.email || "—")}</td>
                <td style={{ ...TD, color: "#71717a" }}>{r.name || r.code || String(c.regionCode || "—")}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

function StatGrid({ stats }: { stats: { label: string; value: string; color?: string }[] }) {
  return (
    <div style={{ display: "grid", gridTemplateColumns: "repeat(3,1fr)", gap: "0.75rem", marginBottom: "1rem" }}>
      {stats.map(s => (
        <div key={s.label} style={{ background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.07)",
          borderRadius: "0.625rem", padding: "0.75rem 1rem" }}>
          <div style={{ fontSize: "0.625rem", fontWeight: 500, letterSpacing: ".08em", textTransform: "uppercase",
            color: "#52525b", marginBottom: "0.25rem" }}>{s.label}</div>
          <div style={{ fontSize: "1.125rem", fontWeight: 700, color: s.color || "#f4f4f5" }}>{s.value}</div>
        </div>
      ))}
    </div>
  );
}

function AggTable({ rows }: { rows: Record<string, unknown>[] }) {
  return (
    <div style={{ border: "1px solid rgba(255,255,255,0.06)", borderRadius: "0.75rem", overflow: "hidden", overflowX: "auto" }}>
      <table style={{ width: "100%", borderCollapse: "collapse", fontSize: "0.75rem" }}>
        <thead>
          <tr>{["Date","Orders","Revenue","Categories"].map(h => (
            <th key={h} style={{ textAlign: "left", padding: "0.5rem 0.75rem", fontWeight: 500,
              color: "#71717a", borderBottom: "1px solid rgba(255,255,255,0.06)" }}>{h}</th>
          ))}</tr>
        </thead>
        <tbody>
          {rows.slice(0,10).map((day, i) => {
            const cats = Object.values((day.categories as Record<string, { totalOrders?: number; totalRevenue?: number }>) || {});
            const dOrders  = cats.reduce((s, c) => s + (c.totalOrders  || 0), 0);
            const dRevenue = cats.reduce((s, c) => s + (c.totalRevenue || 0), 0);
            const catNames = Object.keys((day.categories as object) || {}).slice(0,3).join(", ");
            return (
              <tr key={i}>
                <td style={{ ...TD, fontFamily: "monospace", color: "#a1a1aa" }}>{String(day.date || "—")}</td>
                <td style={TD}>{dOrders.toLocaleString()}</td>
                <td style={{ ...TD, fontFamily: "monospace", color: "#34d399" }}>
                  ${dRevenue.toLocaleString(undefined, { maximumFractionDigits: 0 })}
                </td>
                <td style={{ ...TD, color: "#52525b", fontSize: "0.7rem" }}>{catNames}</td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

const TD: React.CSSProperties = { padding: "0.5rem 0.75rem", color: "#d4d4d8", borderBottom: "1px solid rgba(255,255,255,0.04)" };

// ── Card shell ────────────────────────────────────────────────────────────────

function Card({ method = "GET", path, subtitle, children }: {
  method?: "GET" | "POST";
  path: string;
  subtitle: string;
  children: React.ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const isPost = method === "POST";
  return (
    <div style={{ borderRadius: "1rem", overflow: "hidden",
      background: "rgba(255,255,255,0.03)", border: "1px solid rgba(255,255,255,0.08)" }}>
      <button onClick={() => setOpen(o => !o)}
        style={{ width: "100%", display: "flex", alignItems: "center", justifyContent: "space-between",
          gap: "1rem", padding: "1rem 1.5rem", background: "none", border: "none", cursor: "pointer",
          textAlign: "left" }}>
        <div style={{ display: "flex", alignItems: "center", gap: "0.75rem", minWidth: 0 }}>
          <span style={{ flexShrink: 0, fontSize: "0.6875rem", padding: "0.125rem 0.5rem",
            borderRadius: "9999px", fontWeight: 600,
            background: isPost ? "rgba(99,102,241,0.12)" : "rgba(16,185,129,0.12)",
            border: isPost ? "1px solid rgba(99,102,241,0.3)" : "1px solid rgba(16,185,129,0.3)",
            color: isPost ? "#a5b4fc" : "#34d399" }}>
            {method}
          </span>
          <span style={{ fontFamily: "monospace", fontSize: "0.8125rem", color: "#a1a1aa", flexShrink: 0 }}>{path}</span>
          <span style={{ fontSize: "0.75rem", color: "#52525b", whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{subtitle}</span>
        </div>
        <svg style={{ width: "1rem", height: "1rem", color: "#52525b", flexShrink: 0,
          transition: "transform .2s", transform: open ? "rotate(180deg)" : "none" }}
          viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
          <path d="M6 9l6 6 6-6"/>
        </svg>
      </button>
      {open && (
        <div style={{ padding: "0 1.5rem 1.5rem", borderTop: "1px solid rgba(255,255,255,0.06)" }}>
          {children}
        </div>
      )}
    </div>
  );
}

function RunBtn({ onClick, loading }: { onClick: () => void; loading: boolean }) {
  return (
    <button onClick={onClick} disabled={loading}
      style={{ display: "inline-flex", alignItems: "center", gap: "0.375rem",
        fontSize: "0.75rem", fontWeight: 600, borderRadius: "0.5rem", padding: "0.375rem 1rem",
        border: "1px solid rgba(139,92,246,0.4)", cursor: loading ? "default" : "pointer",
        background: "rgba(139,92,246,0.15)", color: "#c4b5fd", opacity: loading ? 0.4 : 1, flexShrink: 0 }}>
      {loading ? <Spinner /> : <PlayIcon />}
      {loading ? "Running…" : "Run"}
    </button>
  );
}

function Spinner() {
  return (
    <span style={{ display: "inline-block", width: "0.875rem", height: "0.875rem",
      border: "2px solid rgba(139,92,246,0.3)", borderTopColor: "#a78bfa",
      borderRadius: "50%", animation: "spin .6s linear infinite" }} />
  );
}

function PlayIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="currentColor">
      <path d="M5 3l14 9-14 9V3z"/>
    </svg>
  );
}

function MonoParam({ label, val }: { label: string; val: string }) {
  return (
    <span style={{ fontSize: "0.6875rem", fontFamily: "monospace", color: "#52525b" }}>
      {label}=<span style={{ color: "#a78bfa" }}>{val}</span>
    </span>
  );
}

function ErrBox({ msg }: { msg: string }) {
  return (
    <div style={{ borderRadius: "0.5rem", padding: "0.75rem", fontSize: "0.75rem", color: "#f87171",
      background: "rgba(239,68,68,0.08)", border: "1px solid rgba(239,68,68,0.2)" }}>
      {msg}
    </div>
  );
}

function LoadingRow() {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: "0.5rem", fontSize: "0.75rem", color: "#52525b" }}>
      <Spinner /> Sending request…
    </div>
  );
}

// ── Individual cards ──────────────────────────────────────────────────────────

function OrdersCard() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    setLoading(true); setErr(null); setResult(null);
    try {
      const r = await fetchTimed("/api/orders?pageSize=10&sort=placedAt&dir=desc");
      setResult(r);
    } catch (e) { setErr(String(e)); }
    setLoading(false);
  }

  const json = result?.json as { data?: unknown[]; total?: number } | null;
  const rows = (json?.data ?? []) as Record<string, unknown>[];
  const total = json?.total ?? rows.length;

  return (
    <Card path="/api/orders" subtitle="Latest orders — paginated, sorted by date descending">
      <div style={ROW}>
        <div style={PARAMS}>
          <MonoParam label="pageSize" val="10" />
          <MonoParam label="sort" val="placedAt" />
          <MonoParam label="dir" val="desc" />
        </div>
        <RunBtn onClick={run} loading={loading} />
      </div>
      {loading && <LoadingRow />}
      {err && <ErrBox msg={err} />}
      {result && !loading && (
        <>
          <MetaBar ms={result.ms} label={`${Number(total).toLocaleString()} total orders · showing first 10`} />
          {rows.length > 0 && <OrderTable rows={rows} />}
          <RawJson data={result.json} />
        </>
      )}
    </Card>
  );
}

function SearchCard() {
  const [q, setQ] = useState("");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    if (!q.trim()) return;
    setLoading(true); setErr(null); setResult(null);
    try {
      const r = await fetchTimed("/api/orders?q=" + encodeURIComponent(q.trim()) + "&pageSize=10");
      setResult(r);
    } catch (e) { setErr(String(e)); }
    setLoading(false);
  }

  const json = result?.json as { data?: unknown[]; total?: number } | null;
  const rows = (json?.data ?? []) as Record<string, unknown>[];
  const total = json?.total ?? rows.length;

  return (
    <Card path="/api/orders?q=…" subtitle="Full-text search via GIN pg_bigm index — 2-char minimum">
      <div style={ROW}>
        <div style={{ ...PARAMS, alignItems: "center" }}>
          <input
            value={q} onChange={e => setQ(e.target.value)}
            onKeyDown={e => e.key === "Enter" && run()}
            placeholder="e.g. gupta, sara, east…"
            style={{ background: "rgba(255,255,255,0.05)", border: "1px solid rgba(255,255,255,0.1)",
              color: "#e4e4e7", borderRadius: "0.5rem", padding: "0.375rem 0.75rem",
              fontSize: "0.8rem", fontFamily: "monospace", outline: "none", width: "220px" }}
          />
          <MonoParam label="pageSize" val="10" />
        </div>
        <RunBtn onClick={run} loading={loading} />
      </div>
      {loading && <LoadingRow />}
      {err && <ErrBox msg={err} />}
      {result && !loading && (
        <>
          <MetaBar ms={result.ms} label={`${Number(total).toLocaleString()} match${Number(total) !== 1 ? "es" : ""} for "${q}"`} />
          {rows.length > 0
            ? <OrderTable rows={rows} />
            : <p style={{ fontSize: ".75rem", color: "#71717a" }}>No results.</p>}
          <RawJson data={result.json} />
        </>
      )}
    </Card>
  );
}

function AggregatesCard() {
  const today  = new Date().toISOString().slice(0, 10);
  const ago60  = new Date(Date.now() - 60 * 864e5).toISOString().slice(0, 10);
  const [from, setFrom] = useState(ago60);
  const [to,   setTo]   = useState(today);
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    if (!from || !to) return;
    setLoading(true); setErr(null); setResult(null);
    try {
      const r = await fetchTimed(`/api/aggregates?from=${from}&to=${to}&topCategories=3`);
      setResult(r);
    } catch (e) { setErr(String(e)); }
    setLoading(false);
  }

  const json = result?.json as { data?: unknown[] } | unknown[] | null;
  const raw  = Array.isArray(json) ? json : (json as { data?: unknown[] })?.data ?? [];
  type AggRow = { categories?: Record<string, { totalOrders?: number; totalRevenue?: number }> };
  const rows = raw as AggRow[];
  let orders = 0, revenue = 0;
  rows.forEach(d => Object.values(d.categories || {}).forEach(c => {
    orders  += c.totalOrders  || 0;
    revenue += c.totalRevenue || 0;
  }));

  return (
    <Card path="/api/aggregates" subtitle="Pre-aggregated daily totals by category — millisecond response">
      <div style={ROW}>
        <div style={{ ...PARAMS, alignItems: "center" }}>
          <span style={{ fontSize: "0.6875rem", fontFamily: "monospace", color: "#52525b" }}>from</span>
          <input type="date" value={from} onChange={e => setFrom(e.target.value)}
            style={{ ...DATE_INPUT, width: "150px" }} />
          <span style={{ fontSize: "0.6875rem", fontFamily: "monospace", color: "#52525b" }}>to</span>
          <input type="date" value={to} onChange={e => setTo(e.target.value)}
            style={{ ...DATE_INPUT, width: "150px" }} />
          <MonoParam label="topCategories" val="3" />
        </div>
        <RunBtn onClick={run} loading={loading} />
      </div>
      {loading && <LoadingRow />}
      {err && <ErrBox msg={err} />}
      {result && !loading && (
        <>
          <MetaBar ms={result.ms} label={`${rows.length} day${rows.length !== 1 ? "s" : ""} · ${from} → ${to}`} />
          <StatGrid stats={[
            { label: "Total Orders",  value: orders.toLocaleString() },
            { label: "Est. Revenue",  value: "$" + revenue.toLocaleString(undefined, { maximumFractionDigits: 0 }), color: "#34d399" },
            { label: "Days Returned", value: String(rows.length) },
          ]} />
          <AggTable rows={rows as unknown as Record<string, unknown>[]} />
          <RawJson data={result.json} />
        </>
      )}
    </Card>
  );
}

function CustomersCard() {
  const [q, setQ] = useState("");
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    setLoading(true); setErr(null); setResult(null);
    try {
      const url = "/api/customers?limit=10" + (q.trim() ? "&q=" + encodeURIComponent(q.trim()) : "");
      const r = await fetchTimed(url);
      setResult(r);
    } catch (e) { setErr(String(e)); }
    setLoading(false);
  }

  const json = result?.json;
  const rows = (Array.isArray(json) ? json : (json as { data?: unknown[] })?.data ?? []) as Record<string, unknown>[];

  return (
    <Card path="/api/customers" subtitle="Customer list — cursor-paginated">
      <div style={ROW}>
        <div style={{ ...PARAMS, alignItems: "center" }}>
          <input
            value={q} onChange={e => setQ(e.target.value)}
            onKeyDown={e => e.key === "Enter" && run()}
            placeholder="e.g. gupta, sara…"
            style={{ background: "rgba(255,255,255,0.05)", border: "1px solid rgba(255,255,255,0.1)",
              color: "#e4e4e7", borderRadius: "0.5rem", padding: "0.375rem 0.75rem",
              fontSize: "0.8rem", fontFamily: "monospace", outline: "none", width: "200px" }}
          />
          <MonoParam label="limit" val="10" />
        </div>
        <RunBtn onClick={run} loading={loading} />
      </div>
      {loading && <LoadingRow />}
      {err && <ErrBox msg={err} />}
      {result && !loading && (
        <>
          <MetaBar ms={result.ms} label={`${rows.length} customer${rows.length !== 1 ? "s" : ""} returned`} />
          {rows.length > 0
            ? <CustomerTable rows={rows} />
            : <p style={{ fontSize: ".75rem", color: "#71717a" }}>No results.</p>}
          <RawJson data={result.json} />
        </>
      )}
    </Card>
  );
}

function RegionsCard() {
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState<RunResult | null>(null);
  const [err, setErr] = useState<string | null>(null);

  async function run() {
    setLoading(true); setErr(null); setResult(null);
    try { setResult(await fetchTimed("/api/regions")); }
    catch (e) { setErr(String(e)); }
    setLoading(false);
  }

  const rows = Array.isArray(result?.json) ? result!.json as unknown[] : [];

  return (
    <Card path="/api/regions" subtitle="All regions — no parameters">
      <div style={ROW}>
        <p style={{ fontSize: ".6875rem", color: "#52525b" }}>Returns the full list of regions used for filtering.</p>
        <RunBtn onClick={run} loading={loading} />
      </div>
      {loading && <LoadingRow />}
      {err && <ErrBox msg={err} />}
      {result && !loading && (
        <>
          <MetaBar ms={result.ms} label={`${rows.length} region${rows.length !== 1 ? "s" : ""} returned`} />
          <RawJson data={result.json} />
        </>
      )}
    </Card>
  );
}

// ── Brush card ────────────────────────────────────────────────────────────────

interface DayRow { date: string; categories: Record<string, { totalOrders?: number; totalRevenue?: number }> }
interface BrushState { data: DayRow[]; brushL: number; brushR: number; res: (RunResult & { from: string; to: string }) | null; fetching: boolean }

function BrushCard() {
  const S = useRef<BrushState>({ data: [], brushL: 0, brushR: 1, res: null, fetching: false });
  const brushTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const [phase, setPhase] = useState<"idle" | "loading" | "ready">("idle");
  const [tick, setTick] = useState(0);
  const svgRef  = useRef<SVGSVGElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const fillRef  = useRef<HTMLDivElement>(null);
  const hlRef    = useRef<HTMLDivElement>(null);
  const hrRef    = useRef<HTMLDivElement>(null);
  const dlRef    = useRef<HTMLSpanElement>(null);
  const drRef    = useRef<HTMLSpanElement>(null);

  function buildBars() {
    if (!svgRef.current) return;
    const { data } = S.current;
    const n = data.length;
    const totals = data.map(d => Object.values(d.categories || {}).reduce((s, c) => s + (c.totalOrders || 0), 0));
    const mx = Math.max(...totals, 1);
    svgRef.current.innerHTML = totals.map((v, i) => {
      const x = (i / n) * 600, bw = 600 / n, h = Math.max(2, (v / mx) * 76);
      return `<rect id="bb-${i}" x="${x.toFixed(2)}" y="${(80 - h).toFixed(2)}" width="${(bw - 0.4).toFixed(2)}" height="${h.toFixed(2)}" fill="#1e293b" rx="1"/>`;
    }).join("");
  }

  function updateVisuals() {
    const { data, brushL, brushR } = S.current;
    const n = data.length;
    const li = Math.round(brushL * (n - 1)), ri = Math.round(brushR * (n - 1));
    if (svgRef.current) {
      for (let i = 0; i < n; i++) {
        const bar = svgRef.current.querySelector(`#bb-${i}`);
        if (bar) bar.setAttribute("fill", (i >= li && i <= ri) ? "#818cf8" : "#1e293b");
      }
    }
    if (fillRef.current) { fillRef.current.style.left = `${brushL * 100}%`; fillRef.current.style.width = `${(brushR - brushL) * 100}%`; }
    if (hlRef.current)   hlRef.current.style.left = `${brushL * 100}%`;
    if (hrRef.current)   hrRef.current.style.left = `${brushR * 100}%`;
    if (dlRef.current)   dlRef.current.textContent = data[li]?.date || "";
    if (drRef.current)   drRef.current.textContent = data[ri]?.date || "";
  }

  async function doBrushFetch() {
    const { data, brushL, brushR } = S.current;
    const n = data.length;
    if (!n) return;
    const li = Math.round(brushL * (n - 1)), ri = Math.round(brushR * (n - 1));
    const from = data[li]?.date, to = data[ri]?.date;
    if (!from || !to) return;
    S.current.fetching = true; setTick(t => t + 1);
    try {
      const r = await fetchTimed(`/api/aggregates?from=${from}&to=${to}&topCategories=1`);
      S.current.res = { ...r, from, to };
    } catch { }
    S.current.fetching = false; setTick(t => t + 1);
  }

  const attachHandlers = useCallback(() => {
    ["l", "r"].forEach(side => {
      const handle = side === "l" ? hlRef.current : hrRef.current;
      const track  = trackRef.current;
      if (!handle || !track) return;
      handle.addEventListener("pointerdown", e => { e.preventDefault(); (e.target as Element).setPointerCapture(e.pointerId); });
      handle.addEventListener("pointermove", e => {
        if (!(e.target as Element).hasPointerCapture(e.pointerId) || !S.current.data.length) return;
        const rect = track.getBoundingClientRect();
        const pos  = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
        const min  = 1 / Math.max(S.current.data.length, 1);
        if (side === "l") S.current.brushL = Math.min(pos, S.current.brushR - min);
        else              S.current.brushR = Math.max(pos, S.current.brushL + min);
        updateVisuals();
        if (brushTimer.current) clearTimeout(brushTimer.current);
        brushTimer.current = setTimeout(() => doBrushFetch(), 180);
      });
      handle.addEventListener("pointerup", e => (e.target as Element).releasePointerCapture(e.pointerId));
    });
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  async function initBrush() {
    setPhase("loading");
    const today = new Date().toISOString().slice(0, 10);
    const ago   = new Date(Date.now() - 365 * 864e5).toISOString().slice(0, 10);
    try {
      const { json, ms } = await fetchTimed(`/api/aggregates?from=${ago}&to=${today}&topCategories=1`);
      const raw  = (json as { data?: DayRow[] })?.data ?? (json as DayRow[]);
      const data = Array.isArray(raw) ? raw : [];
      if (!data.length) throw new Error("no data");
      S.current = { data, brushL: 0, brushR: 1, fetching: false,
        res: { json, ms, from: data[0].date, to: data[data.length - 1].date } };
      setPhase("ready");
      setTimeout(() => { buildBars(); updateVisuals(); attachHandlers(); setTick(t => t + 1); }, 0);
    } catch {
      setPhase("idle");
    }
  }

  const res = S.current.res;
  const resRaw  = res ? (Array.isArray(res.json) ? res.json : ((res.json as { data?: DayRow[] })?.data ?? [])) as DayRow[] : [];
  let bOrders = 0, bRevenue = 0;
  resRaw.forEach(d => Object.values(d.categories || {}).forEach(c => { bOrders += c.totalOrders || 0; bRevenue += c.totalRevenue || 0; }));

  return (
    <Card path="/api/aggregates?from=…&to=…" subtitle="Drag brush handles · sub-second re-fetch">
      {phase === "idle" && (
        <div style={ROW}>
          <p style={{ fontSize: ".6875rem", color: "#52525b" }}>Loads a year of aggregate data, then drag the handles to re-query any sub-range live.</p>
          <RunBtn onClick={initBrush} loading={false} />
        </div>
      )}
      {phase === "loading" && (
        <div style={ROW}>
          <p style={{ fontSize: ".6875rem", color: "#52525b" }}>Loading…</p>
          <RunBtn onClick={() => {}} loading={true} />
        </div>
      )}
      {phase === "ready" && (
        <div style={{ marginTop: "1rem" }}>
          <svg ref={svgRef} viewBox="0 0 600 80" width="100%" height="80"
            preserveAspectRatio="none"
            style={{ display: "block", borderRadius: "6px", marginBottom: "0.5rem" }} />
          <div ref={trackRef} style={{ position: "relative", height: "20px", marginTop: "8px",
            background: "rgba(255,255,255,0.04)", borderRadius: "10px", userSelect: "none" }}>
            <div ref={fillRef} style={{ position: "absolute", top: 0, height: "100%", left: "0%", width: "100%",
              background: "rgba(129,140,248,0.18)", border: "1px solid rgba(129,140,248,0.45)",
              borderRadius: "10px", pointerEvents: "none" }} />
            <div ref={hlRef} style={{ position: "absolute", top: "50%", left: "0%",
              transform: "translate(-50%,-50%)", width: "10px", height: "22px", background: "#818cf8",
              borderRadius: "3px", cursor: "ew-resize", touchAction: "none", zIndex: 2 }} />
            <div ref={hrRef} style={{ position: "absolute", top: "50%", left: "100%",
              transform: "translate(-50%,-50%)", width: "10px", height: "22px", background: "#818cf8",
              borderRadius: "3px", cursor: "ew-resize", touchAction: "none", zIndex: 2 }} />
          </div>
          <div style={{ display: "flex", justifyContent: "space-between", marginTop: "6px" }}>
            <span ref={dlRef} style={{ fontSize: "0.625rem", fontFamily: "monospace", color: "#52525b" }} />
            <span ref={drRef} style={{ fontSize: "0.625rem", fontFamily: "monospace", color: "#52525b" }} />
          </div>
          <div style={{ marginTop: "1rem" }}>
            {S.current.fetching
              ? <LoadingRow />
              : res && (
                <>
                  <MetaBar ms={res.ms} label={`${resRaw.length} day${resRaw.length !== 1 ? "s" : ""} · ${res.from} → ${res.to}`} />
                  <StatGrid stats={[
                    { label: "Orders",        value: bOrders.toLocaleString() },
                    { label: "Est. Revenue",  value: "$" + bRevenue.toLocaleString(undefined, { maximumFractionDigits: 0 }), color: "#34d399" },
                    { label: "Days in range", value: String(resRaw.length) },
                  ]} />
                </>
              )
            }
          </div>
        </div>
      )}
    </Card>
  );
}

// ── Shared styles ─────────────────────────────────────────────────────────────

const ROW: React.CSSProperties = {
  display: "flex", alignItems: "center", justifyContent: "space-between",
  flexWrap: "wrap", gap: "0.75rem", paddingTop: "1rem", marginBottom: "1rem",
};
const PARAMS: React.CSSProperties = { display: "flex", flexWrap: "wrap", alignItems: "center", gap: "0.5rem" };
const DATE_INPUT: React.CSSProperties = {
  background: "rgba(255,255,255,0.05)", border: "1px solid rgba(255,255,255,0.1)",
  color: "#e4e4e7", borderRadius: "0.5rem", padding: "0.375rem 0.75rem",
  fontSize: "0.8rem", fontFamily: "monospace", outline: "none",
};

// ── Page ──────────────────────────────────────────────────────────────────────

const SLOW_WAKING_MS = 800;

export default function ApiExplorer() {
  const [wakeStatus, setWakeStatus] = useState<WakeStatus>(null);
  const [wakeMs, setWakeMs] = useState(0);
  const wakeStart   = useRef(0);
  const wakeInterval = useRef<ReturnType<typeof setInterval> | null>(null);
  const slowTimer   = useRef<ReturnType<typeof setTimeout> | null>(null);
  const readyTimer  = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    wakeStart.current = performance.now();
    slowTimer.current = setTimeout(() => {
      setWakeStatus("waking");
      setWakeMs(0);
      wakeInterval.current = setInterval(() => setWakeMs(Math.round(performance.now() - wakeStart.current)), 100);
    }, SLOW_WAKING_MS);

    const markReady = () => {
      if (slowTimer.current)   { clearTimeout(slowTimer.current);   slowTimer.current = null; }
      if (wakeInterval.current){ clearInterval(wakeInterval.current); wakeInterval.current = null; }
      setWakeStatus(s => (s === "waking" ? "ready" : null));
      readyTimer.current = setTimeout(() => setWakeStatus(s => (s === "ready" ? null : s)), 1200);
    };

    fetch("/api/runtime").then(r => r.ok ? r.json() : Promise.reject()).then(markReady).catch(markReady);

    return () => {
      if (slowTimer.current)    clearTimeout(slowTimer.current);
      if (wakeInterval.current) clearInterval(wakeInterval.current);
      if (readyTimer.current)   clearTimeout(readyTimer.current);
    };
  }, []);

  return (
    <div style={{ background: "#0f0f13", color: "#f4f4f5", minHeight: "100vh",
      fontFamily: "-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
      fontSize: "14px", WebkitFontSmoothing: "antialiased" }}>
      <style>{`@keyframes spin { to { transform: rotate(360deg); } }`}</style>

      {/* Nav */}
      <nav style={{ position: "fixed", top: 0, left: 0, right: 0, zIndex: 40,
        borderBottom: "1px solid rgba(255,255,255,0.06)",
        background: "rgba(15,15,19,0.9)", backdropFilter: "blur(16px)" }}>
        <div style={{ maxWidth: "64rem", margin: "0 auto", padding: "0 1.5rem",
          height: "3.5rem", display: "flex", alignItems: "center", justifyContent: "space-between" }}>
          <a href="https://bganguly.github.io/?open=orders_dashboard"
            style={{ display: "flex", alignItems: "center", gap: "0.5rem",
              color: "#71717a", textDecoration: "none", fontSize: "0.875rem" }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M19 12H5M5 12l7-7M5 12l7 7"/>
            </svg>
            Portfolio
          </a>
          <div style={{ display: "flex", alignItems: "center", gap: "0.75rem" }}>
            {wakeStatus === "waking" && (
              <div style={{ display: "flex", alignItems: "center", gap: "0.5rem",
                background: "rgba(251,191,36,0.12)", border: "1px solid rgba(251,191,36,0.30)",
                color: "#fbbf24", borderRadius: "0.5rem", padding: "0.375rem 0.75rem", fontSize: "0.75rem" }}>
                <Spinner />
                Backend waking up —
                <span style={{ fontFamily: "monospace", marginLeft: "4px" }}>{(wakeMs / 1000).toFixed(1)}s</span>
              </div>
            )}
            {wakeStatus === "ready" && (
              <div style={{ display: "flex", alignItems: "center", gap: "0.5rem",
                background: "rgba(34,197,94,0.12)", border: "1px solid rgba(34,197,94,0.30)",
                color: "#4ade80", borderRadius: "0.5rem", padding: "0.375rem 0.75rem", fontSize: "0.75rem" }}>
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5">
                  <polyline points="20 6 9 17 4 12" />
                </svg>
                Backend ready
              </div>
            )}
            <span style={{ fontSize: "0.6875rem", padding: "0.125rem 0.5rem", borderRadius: "9999px",
              background: "rgba(99,102,241,0.12)", border: "1px solid rgba(99,102,241,0.3)", color: "#a5b4fc" }}>
              Spring Boot 4.1 · Java 21 · GCP · Cloud Run
            </span>
          </div>
        </div>
      </nav>

      {/* Hero */}
      <div style={{ padding: "7rem 1.5rem 2.5rem", maxWidth: "64rem", margin: "0 auto" }}>
        <p style={{ fontSize: "0.75rem", fontWeight: 500, letterSpacing: ".1em", textTransform: "uppercase",
          color: "#818cf8", marginBottom: "0.75rem" }}>API Explorer</p>
        <h1 style={{ fontSize: "1.5rem", fontWeight: 700, color: "#f4f4f5", marginBottom: "0.5rem" }}>
          Live API — Orders Dashboard (GCP · Spring Boot 4.1)
        </h1>
        <p style={{ fontSize: "0.875rem", color: "#71717a", maxWidth: "36rem" }}>
          Run real requests against the Spring Boot REST API backed by PostgreSQL 16 with pg_bigm full-text search.
        </p>
        <div style={{ display: "inline-flex", alignItems: "center", gap: "0.375rem",
          padding: "0.375rem 0.75rem", borderRadius: "0.5rem", marginTop: "1rem",
          background: "rgba(255,255,255,0.04)", border: "1px solid rgba(255,255,255,0.08)",
          color: "#52525b", fontSize: "0.75rem", fontFamily: "monospace" }}>
          <span style={{ width: "0.375rem", height: "0.375rem", borderRadius: "50%",
            background: "#818cf8", flexShrink: 0, display: "inline-block" }} />
          {window.location.origin}/api
        </div>
      </div>

      {/* Cards */}
      <div style={{ maxWidth: "64rem", margin: "0 auto", padding: "0 1.5rem 6rem",
        display: "flex", flexDirection: "column", gap: "1.25rem" }}>
        <OrdersCard />
        <SearchCard />
        <AggregatesCard />
        <CustomersCard />
        <RegionsCard />
        <BrushCard />
      </div>
    </div>
  );
}

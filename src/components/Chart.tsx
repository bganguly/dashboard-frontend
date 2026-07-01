import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  Bar, BarChart, Brush, CartesianGrid, Legend, Rectangle,
  ResponsiveContainer, Tooltip, XAxis, YAxis,
} from "recharts";
import { useIsDark } from "../hooks/useIsDark";
import { appendFilterParams, type OrderFilters } from "./FilterSidebar";

export interface AggregateBucket { date: string; [series: string]: string | number; }
interface RawCategory { totalOrders?: number; totalRevenue?: number; totalItems?: number; }
export interface RawAggregate { date: string; categories: Record<string, RawCategory>; }

const DEFAULT_TOP_N = 4;
const OTHER_KEY = "Others";
const OTHER_COLOR = "#94a3b8";
const COLORS = ["#6366f1","#22c55e","#f59e0b","#ef4444","#06b6d4","#a855f7","#ec4899"];
const STACK_ID = "aggregates";
const DRAG_DEBOUNCE_MS = 250;

function isOther(n: string) { const v = n.trim().toLowerCase(); return v === "other" || v === "others"; }

function computeTotals(data: RawAggregate[]) {
  const map = new Map<string, { revenue: number; orders: number }>();
  for (const entry of data)
    for (const [cat, c] of Object.entries(entry.categories ?? {})) {
      const prev = map.get(cat) ?? { revenue: 0, orders: 0 };
      prev.revenue += c.totalRevenue ?? 0; prev.orders += c.totalOrders ?? 0;
      map.set(cat, prev);
    }
  return [...map.entries()].map(([category, v]) => ({ category, ...v })).sort((a, b) => b.orders - a.orders);
}

function buildBucket(entry: RawAggregate, top: string[], withOther: boolean): AggregateBucket {
  const topSet = new Set(top);
  const bucket: AggregateBucket = { date: entry.date };
  for (const cat of top) bucket[cat] = 0;
  if (withOther) bucket[OTHER_KEY] = 0;
  for (const [cat, c] of Object.entries(entry.categories ?? {})) {
    const key = topSet.has(cat) ? cat : withOther ? OTHER_KEY : null;
    if (key) bucket[key] = (bucket[key] as number) + (c.totalOrders ?? 0);
  }
  return bucket;
}

const compact = (n: number) => {
  const a = Math.abs(n);
  if (a >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (a >= 1_000) return `${(n / 1_000).toFixed(0)}k`;
  return `${n}`;
};
const full = (n: number) => n.toLocaleString();

function isoDay(d: Date) { return d.toISOString().slice(0, 10); }
function defaultRange() { return { from: "2020-01-01", to: isoDay(new Date()) }; }

interface ChartProps { endpoint?: string; topN?: number; filters?: OrderFilters; searchQuery?: string; onRangeChange?: (from: string, to: string) => void; }

export default function Chart({ endpoint = "/api/aggregates", topN = DEFAULT_TOP_N, filters, searchQuery, onRangeChange }: ChartProps) {
  const [rawData, setRawData] = useState<RawAggregate[]>([]);
  const [range, setRange] = useState(defaultRange);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showOthers, setShowOthers] = useState(false);
  const abortRef = useRef<AbortController | null>(null);
  const dragTimer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const fetchAggregates = useCallback(async (from: string, to: string) => {
    abortRef.current?.abort();
    const ctrl = new AbortController(); abortRef.current = ctrl;
    setLoading(true); setError(null);
    try {
      const params = new URLSearchParams({ from: filters?.from || from, to: filters?.to || to });
      params.set("topCategories", String(topN));
      appendFilterParams(params, filters);
      if (searchQuery) params.set("q", searchQuery);
      const res = await fetch(`${endpoint}?${params}`, { signal: ctrl.signal });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      setRawData(Array.isArray(json.data) ? json.data : []);
    } catch (err) {
      if ((err as Error).name === "AbortError") return;
      setError((err as Error).message);
    } finally { setLoading(false); }
  }, [endpoint, topN, filters, searchQuery]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    fetchAggregates(range.from, range.to);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [fetchAggregates]);

  useEffect(() => () => { abortRef.current?.abort(); if (dragTimer.current) clearTimeout(dragTimer.current); }, []);

  const isDark = useIsDark();
  const gridStroke = isDark ? "#374151" : "#e5e7eb";
  const axisColor  = isDark ? "#9ca3af" : "#6b7280";
  const tooltipStyle = { backgroundColor: isDark ? "#1f2937" : "#fff", border: `1px solid ${isDark ? "#374151" : "#e5e7eb"}`, borderRadius: 8, color: isDark ? "#f3f4f6" : "#111827" };

  const categoryTotals = useMemo(() => computeTotals(rawData), [rawData]);
  const topCategories  = useMemo(() => categoryTotals.filter(c => !isOther(c.category)).slice(0, topN).map(c => c.category), [categoryTotals, topN]);
  const withOther = categoryTotals.length > topCategories.length;
  const buckets   = useMemo(() => rawData.map(e => buildBucket(e, topCategories, withOther)), [rawData, topCategories, withOther]);

  const seriesRanked = useMemo(() => {
    const topSet = new Set(topCategories);
    const entries = topCategories.map(cat => ({ key: cat, orders: categoryTotals.find(c => c.category === cat)?.orders ?? 0 }));
    if (withOther) {
      const othersOrders = categoryTotals.filter(c => !topSet.has(c.category)).reduce((s, c) => s + c.orders, 0);
      entries.push({ key: OTHER_KEY, orders: othersOrders });
    }
    return entries.sort((a, b) => b.orders - a.orders);
  }, [categoryTotals, topCategories, withOther]);

  const seriesKeys = useMemo(() => seriesRanked.filter(s => showOthers || s.key !== OTHER_KEY).map(s => s.key), [seriesRanked, showOthers]);
  const colorMap   = useMemo(() => { const m = new Map<string,string>(); topCategories.forEach((c,i) => m.set(c, COLORS[i % COLORS.length])); return m; }, [topCategories]);
  const colorFor   = (k: string) => k === OTHER_KEY ? OTHER_COLOR : (colorMap.get(k) ?? OTHER_COLOR);

  const displayTotals = useMemo(() => {
    const tops = seriesRanked.filter(s => s.key !== OTHER_KEY).map(s => ({ category: s.key, orders: s.orders }));
    const others = seriesRanked.find(s => s.key === OTHER_KEY);
    if (others) tops.push({ category: others.key, orders: others.orders });
    return tops;
  }, [seriesRanked]);

  const handleBrushChange = useCallback(({ startIndex, endIndex }: { startIndex?: number; endIndex?: number }) => {
    if (startIndex == null || endIndex == null || !buckets.length || startIndex < 0 || endIndex >= buckets.length) return;
    const from = String(buckets[startIndex].date); const to = String(buckets[endIndex].date);
    if (from === range.from && to === range.to) return;
    setRange({ from, to });
    if (dragTimer.current) clearTimeout(dragTimer.current);
    dragTimer.current = setTimeout(() => {
      fetchAggregates(from, to);
      onRangeChange?.(from, to);
    }, DRAG_DEBOUNCE_MS);
  }, [buckets, range.from, range.to, fetchAggregates]);

  return (
    <section data-testid="chart" data-loading={loading ? "true" : undefined}
      className="relative rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <header className="mb-3 flex items-center justify-between">
        <div>
          <h2 className="text-base font-semibold">Aggregates</h2>
          <p className="text-xs text-gray-500">{range.from} → {range.to}<span className="ml-2 text-gray-400">drag slider to rescan</span></p>
        </div>
        {loading && <span className="text-xs text-indigo-500" aria-live="polite">updating…</span>}
      </header>
      {error ? (
        <div className="flex h-72 items-center justify-center text-sm text-red-500">Failed: {error}</div>
      ) : buckets.length === 0 ? (
        <div className="flex h-72 items-center justify-center text-sm text-gray-400">{loading ? "Loading…" : "No data."}</div>
      ) : (
        <>
          <ResponsiveContainer width="100%" height={320}>
            <BarChart data={buckets} margin={{ top: 8, right: 16, left: 0, bottom: 0 }}>
              <CartesianGrid strokeDasharray="3 3" stroke={gridStroke} />
              <XAxis dataKey="date" fontSize={12} tickMargin={8} stroke={axisColor} tick={{ fill: axisColor }} />
              <YAxis fontSize={12} width={56} stroke={axisColor} tick={{ fill: axisColor }} tickFormatter={compact} />
              <Tooltip contentStyle={tooltipStyle} labelStyle={{ color: tooltipStyle.color }} itemStyle={{ color: tooltipStyle.color }} cursor={{ fill: isDark ? "#ffffff10" : "#00000008" }} formatter={(v) => Number(v).toLocaleString()} />
              <Legend wrapperStyle={{ fontSize: 12 }} content={() => (
                <div className="flex flex-wrap items-center justify-center gap-x-4 gap-y-1 pt-2 text-xs">
                  {displayTotals.filter(ct => ct.category !== OTHER_KEY).map(ct => (
                    <span key={ct.category} data-testid="aggregate-tile" data-category={ct.category} className="inline-flex items-center gap-1.5 whitespace-nowrap" style={{ color: axisColor }}>
                      <span aria-hidden className="h-2.5 w-2.5 shrink-0 rounded-sm" style={{ backgroundColor: colorFor(ct.category) }} />
                      {ct.category}
                      <span className="font-medium tabular-nums text-gray-900 dark:text-gray-100">{full(ct.orders)}</span>
                    </span>
                  ))}
                  {withOther && (() => {
                    const othersTotal = displayTotals.find(ct => ct.category === OTHER_KEY);
                    return (
                      <label className="inline-flex cursor-pointer items-center gap-1.5" style={{ color: axisColor }}>
                        <input type="checkbox" checked={showOthers} onChange={e => setShowOthers(e.target.checked)} className="h-3.5 w-3.5 rounded border-gray-300 text-indigo-600 focus:ring-indigo-500" />
                        Others
                        {othersTotal && <span className="font-medium tabular-nums text-gray-900 dark:text-gray-100">{full(othersTotal.orders)}</span>}
                      </label>
                    );
                  })()}
                </div>
              )} />
              {seriesKeys.map((key, i) => (
                <Bar key={key} dataKey={key} stackId={STACK_ID} fill={colorFor(key)}
                  radius={i === seriesKeys.length - 1 ? [4,4,0,0] : [0,0,0,0]}
                  shape={(props: object) => <g data-testid="chart-bar" data-category={key}><Rectangle {...props} /></g>} />
              ))}
              <Brush dataKey="date" height={28} stroke="#6366f1" fill={isDark ? "#111827" : "#fff"} travellerWidth={10} onChange={handleBrushChange} />
            </BarChart>
          </ResponsiveContainer>
        </>
      )}
    </section>
  );
}

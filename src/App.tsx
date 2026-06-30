import { useCallback, useEffect, useState } from "react";
import Chart from "./components/Chart";
import SearchTable, { type SearchRow } from "./components/SearchTable";
import ThemeToggle from "./components/ThemeToggle";
import FilterSidebar, {
  EMPTY_FILTERS,
  type OrderFilters,
  type RegionOption,
} from "./components/FilterSidebar";

function mergeRegions(prev: RegionOption[], incoming: RegionOption[]): RegionOption[] {
  const map = new Map(prev.map((r) => [r.code, r]));
  let changed = false;
  for (const r of incoming) {
    if (!r?.code) continue;
    const existing = map.get(r.code);
    const name = r.name || existing?.name || r.code;
    if (!existing || existing.name !== name) { map.set(r.code, { code: r.code, name }); changed = true; }
  }
  if (!changed) return prev;
  return [...map.values()].sort((a, b) => a.code.localeCompare(b.code));
}

export default function App() {
  const [filters, setFilters] = useState<OrderFilters>(EMPTY_FILTERS);
  const [regionOptions, setRegionOptions] = useState<RegionOption[]>([]);
  const [searchQuery, setSearchQuery] = useState("");

  useEffect(() => {
    let cancelled = false;
    fetch("/api/regions")
      .then((r) => (r.ok ? r.json() : Promise.reject()))
      .then((data: RegionOption[]) => {
        if (cancelled || !Array.isArray(data)) return;
        setRegionOptions((prev) => mergeRegions(prev, data));
      })
      .catch(() => {});
    return () => { cancelled = true; };
  }, []);

  const handleRows = useCallback((rows: SearchRow[]) => {
    const incoming: RegionOption[] = [];
    for (const row of rows) {
      const region = row.region as { code?: string; name?: string } | undefined;
      if (region?.code) incoming.push({ code: region.code, name: region.name ?? region.code });
    }
    if (incoming.length === 0) return;
    setRegionOptions((prev) => mergeRegions(prev, incoming));
  }, []);

  return (
    <div className="min-h-screen bg-zinc-50 font-sans dark:bg-black">
      <main className="w-full px-5 py-8">
        <header className="mb-6 flex items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold tracking-tight">Dashboard</h1>
            <p className="text-sm text-gray-500">Aggregates, search, and order history.</p>
          </div>
          <ThemeToggle />
        </header>
        <div className="flex flex-col gap-6 lg:flex-row">
          <FilterSidebar value={filters} onChange={setFilters} regionOptions={regionOptions} />
          <div className="min-w-0 flex-1 grid grid-cols-1 gap-6">
            <Chart filters={filters} searchQuery={searchQuery} onRangeChange={(from, to) => setFilters(f => ({ ...f, from, to }))} />
            <SearchTable filters={filters} onRows={handleRows} onQueryChange={setSearchQuery} />
          </div>
        </div>
      </main>
    </div>
  );
}

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { appendFilterParams } from "@/components/FilterSidebar";
import {
  type SearchRow, type SortDir, type SearchResponse,
  type SearchTableProps, type PageItem,
  getPageItems,
} from "./SearchTableTypes";

export function useSearchTable({
  refreshSignal = 0,
  endpoint = "/api/orders",
  pageSize = 20,
  filters,
  onRows,
  highlightId,
  highlightKey,
  onQueryChange,
  controlledResponse,
  controlledLoading = false,
  controlledError = null,
  onRequestStateChange,
  externalTotal,
  backendReady = true,
  onLoadingChange,
}: SearchTableProps) {
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [rows, setRows] = useState<SearchRow[]>([]);
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [total, setTotal] = useState(0);

  const displayTotal = typeof externalTotal === "number" ? externalTotal : total;
  const displayTotalPages = typeof externalTotal === "number"
    ? Math.max(1, Math.ceil(externalTotal / pageSize))
    : totalPages;

  const [sort, setSort] = useState<string>("placedAt");
  const [dir, setDir] = useState<SortDir>("desc");
  const [loading, setLoading] = useState(false);
  const [fetchDone, setFetchDone] = useState(false);
  const [searchLoading, setSearchLoading] = useState(false);
  const [warmingUp, setWarmingUp] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [flashId, setFlashId] = useState<string | number | null>(null);
  const [newFirstId, setNewFirstId] = useState<string | number | null>(null);

  const abortRef = useRef<AbortController | null>(null);
  const isControlled = onRequestStateChange != null;

  const onLoadingChangeRef = useRef(onLoadingChange);
  useEffect(() => { onLoadingChangeRef.current = onLoadingChange; }, [onLoadingChange]);
  const effectiveLoading = isControlled ? controlledLoading : loading;
  useEffect(() => { onLoadingChangeRef.current?.(effectiveLoading); }, [effectiveLoading]);

  const onRowsRef = useRef(onRows);
  useEffect(() => { onRowsRef.current = onRows; });

  const cursorAnchorRef = useRef<{
    page: number;
    firstId: unknown;
    firstPlacedAt: string;
    lastId: unknown;
    lastPlacedAt: string;
  } | null>(null);
  const skipNextFetchRef = useRef(false);

  const applyResponse = useCallback(
    (json: SearchResponse, p: number, sortCol: string, sortDir: SortDir) => {
      const data = Array.isArray(json.data) ? json.data : [];
      setRows(data);
      setTotalPages(Math.max(1, json.totalPages ?? 1));
      setTotal(json.total ?? 0);
      onRowsRef.current?.(data);
      if (sortCol === "placedAt" && sortDir === "desc" && data.length > 0) {
        const first = data[0] as { id?: unknown; placedAt?: unknown };
        const last = data[data.length - 1] as { id?: unknown; placedAt?: unknown };
        if (typeof first.placedAt === "string" && typeof last.placedAt === "string") {
          cursorAnchorRef.current = {
            page: p,
            firstId: first.id,
            firstPlacedAt: first.placedAt,
            lastId: last.id,
            lastPlacedAt: last.placedAt,
          };
        } else {
          cursorAnchorRef.current = null;
        }
      } else {
        cursorAnchorRef.current = null;
      }
    },
    [],
  );

  const fetchPage = useCallback(
    async (
      q: string,
      p: number,
      sortCol: string,
      sortDir: SortDir,
      f: typeof filters,
      showSearchIndicator: boolean,
    ) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setLoading(true);
      setSearchLoading(showSearchIndicator);
      setError(null);
      try {
        const params = new URLSearchParams({
          q,
          page: String(p),
          pageSize: String(pageSize),
        });
        if (sortCol) {
          params.set("sort", sortCol);
          params.set("dir", sortDir);
        }
        appendFilterParams(params, f);
        const res = await fetch(`${endpoint}?${params}`, {
          signal: controller.signal,
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json: SearchResponse = await res.json();
        applyResponse(json, p, sortCol, sortDir);
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
        setError((err as Error).message);
        setRows([]);
        setTotalPages(1);
        setTotal(0);
        cursorAnchorRef.current = null;
      } finally {
        if (abortRef.current === controller) {
          setLoading(false);
          setSearchLoading(false);
          setFetchDone(true);
        }
      }
    },
    [endpoint, pageSize, applyResponse],
  );

  const fetchAdjacentByCursor = useCallback(
    async (
      q: string,
      targetPage: number,
      f: typeof filters,
      cursorId: unknown,
      cursorPlacedAt: string,
      direction: "next" | "prev",
    ) => {
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setLoading(true);
      setSearchLoading(false);
      setError(null);
      try {
        const params = new URLSearchParams({
          q,
          page: String(targetPage),
          pageSize: String(pageSize),
          sort: "placedAt",
          dir: "desc",
          cursorId: String(cursorId),
          cursorPlacedAt,
          cursorDir: direction,
        });
        appendFilterParams(params, f);
        const res = await fetch(`${endpoint}?${params}`, {
          signal: controller.signal,
        });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const json: SearchResponse = await res.json();
        applyResponse(json, targetPage, "placedAt", "desc");
      } catch (err) {
        if ((err as Error).name === "AbortError") return;
        setError((err as Error).message);
        setRows([]);
        setTotalPages(1);
        setTotal(0);
        cursorAnchorRef.current = null;
      } finally {
        if (abortRef.current === controller) {
          setLoading(false);
          setSearchLoading(false);
          setFetchDone(true);
        }
      }
    },
    [endpoint, pageSize, applyResponse],
  );

  useEffect(() => {
    onQueryChange?.(debouncedQuery);
  }, [debouncedQuery, onQueryChange]);

  useEffect(() => {
    if (!isControlled) return;
    if (!controlledResponse) return;
    const data = Array.isArray(controlledResponse.data)
      ? controlledResponse.data
      : [];
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setRows(data);
    setTotalPages(Math.max(1, controlledResponse.totalPages ?? 1));
    setTotal(controlledResponse.total ?? 0);
    setError(null);
    onRowsRef.current?.(data);
  }, [controlledResponse, isControlled]);

  useEffect(() => {
    if (!isControlled) return;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setError(controlledError);
    if (!controlledError) return;
    setRows([]);
    setTotalPages(1);
    setTotal(0);
  }, [controlledError, isControlled]);

  const lastFiltersKey = useRef<string>(JSON.stringify(filters ?? {}));
  const lastFetchedQuery = useRef(debouncedQuery);
  useEffect(() => {
    if (!backendReady) return;
    if (skipNextFetchRef.current) {
      skipNextFetchRef.current = false;
      return;
    }
    const key = JSON.stringify(filters ?? {});
    if (key !== lastFiltersKey.current) {
      lastFiltersKey.current = key;
      if (page !== 1) {
        // eslint-disable-next-line react-hooks/set-state-in-effect
        setPage(1);
        return;
      }
    }
    const queryChanged = debouncedQuery !== lastFetchedQuery.current;
    lastFetchedQuery.current = debouncedQuery;
    if (isControlled) {
      onRequestStateChange?.({
        q: debouncedQuery,
        page,
        pageSize,
        sort,
        dir,
      });
      return;
    }
    fetchPage(debouncedQuery, page, sort, dir, filters, queryChanged);
  }, [
    debouncedQuery,
    page,
    pageSize,
    sort,
    dir,
    filters,
    refreshSignal,
    fetchPage,
    isControlled,
    onRequestStateChange,
    backendReady,
  ]);

  useEffect(() => {
    return () => abortRef.current?.abort();
  }, []);

  useEffect(() => {
    const isLoading = isControlled ? controlledLoading : loading;
    if (!isLoading) { setWarmingUp(false); return; }
    const t = setTimeout(() => setWarmingUp(true), 8000);
    return () => clearTimeout(t);
  }, [loading, controlledLoading, isControlled]);

  const lastFlashKey = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (highlightKey == null || highlightId == null) return;
    if (highlightKey === lastFlashKey.current) return;
    const present = rows.some((r) => String(r.id) === String(highlightId));
    if (!present) return;
    lastFlashKey.current = highlightKey;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setFlashId(highlightId);
    const t = setTimeout(() => setFlashId(null), 1600);
    return () => clearTimeout(t);
  }, [rows, highlightKey, highlightId]);

  const lastNewFirstKey = useRef<number | undefined>(undefined);
  useEffect(() => {
    if (highlightKey == null || highlightId == null) return;
    if (highlightKey === lastNewFirstKey.current) return;
    const firstId = rows[0]?.id as string | number | undefined;
    if (firstId == null) return;
    if (String(firstId) !== String(highlightId)) return;
    lastNewFirstKey.current = highlightKey;
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setNewFirstId(firstId);
    const t = setTimeout(() => setNewFirstId(null), 600);
    return () => clearTimeout(t);
  }, [rows, highlightKey, highlightId]);

  const toggleSort = useCallback(
    (sortKey: string) => {
      if (sort === sortKey) {
        setDir((d) => (d === "asc" ? "desc" : "asc"));
      } else {
        setSort(sortKey);
        setDir("asc");
      }
      setPage(1);
    },
    [sort],
  );

  const goToPage = useCallback(
    (n: number) => {
      const clamped = Math.min(Math.max(n, 1), displayTotalPages);
      setPage(clamped);
    },
    [displayTotalPages],
  );

  const goToAdjacentPage = useCallback(
    (direction: "prev" | "next") => {
      const targetPage = direction === "next" ? page + 1 : page - 1;
      const clamped = Math.min(Math.max(targetPage, 1), displayTotalPages);
      if (clamped === page) return;

      const anchor = cursorAnchorRef.current;
      if (anchor && anchor.page === page) {
        const cursorId = direction === "next" ? anchor.lastId : anchor.firstId;
        const cursorPlacedAt = direction === "next" ? anchor.lastPlacedAt : anchor.firstPlacedAt;
        if (cursorId != null) {
          skipNextFetchRef.current = true;
          setPage(clamped);
          fetchAdjacentByCursor(debouncedQuery, clamped, filters, cursorId, cursorPlacedAt, direction);
          return;
        }
      }
      goToPage(clamped);
    },
    [page, displayTotalPages, debouncedQuery, filters, fetchAdjacentByCursor, goToPage],
  );

  const pageItems = useMemo(
    () => getPageItems(page, displayTotalPages),
    [page, displayTotalPages],
  ) as PageItem[];

  const footerLoading = isControlled ? controlledLoading : searchLoading;

  return {
    query, setQuery, debouncedQuery, setDebouncedQuery,
    rows, page, setPage, totalPages, total,
    displayTotal, displayTotalPages,
    sort, dir, loading, fetchDone, searchLoading, warmingUp, error,
    flashId, newFirstId,
    isControlled, effectiveLoading,
    toggleSort, goToPage, goToAdjacentPage,
    pageItems, footerLoading,
    controlledLoading,
  };
}

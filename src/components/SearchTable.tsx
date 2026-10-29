
import { useSearchTable } from "./useSearchTable";
import { COLUMNS, cn } from "./SearchTableTypes";

export type { SearchRow } from "./SearchTableTypes";
export type { SearchResponse, TableRequestState } from "./SearchTableTypes";
export type { SearchTableProps } from "./SearchTableTypes";

import type { SearchTableProps } from "./SearchTableTypes";

export default function SearchTable(props: SearchTableProps) {
  const {
    query, setQuery, debouncedQuery, setDebouncedQuery,
    rows, page,
    displayTotal, displayTotalPages,
    sort, dir, loading, fetchDone, searchLoading, warmingUp, error,
    flashId, newFirstId,
    isControlled, controlledLoading,
    toggleSort, goToPage, goToAdjacentPage,
    pageItems, footerLoading,
  } = useSearchTable(props);

  const { pageSize = 20, externalTotal, backendReady = true, suppressLoader = false } = props;

  return (
    <section className="rounded-lg border border-gray-200 bg-white p-4 shadow-sm dark:border-gray-800 dark:bg-gray-900">
      <div className="mb-4 flex items-center gap-3">
        <h2 className="text-xl font-semibold">Search orders</h2>
        {(isControlled ? controlledLoading : loading) && (
          <span className="text-xs text-indigo-500" aria-live="polite">
            {searchLoading ? "searching…" : "updating…"}
          </span>
        )}
      </div>

      <div className="relative mb-4">
        <svg
          aria-hidden
          viewBox="0 0 20 20"
          fill="none"
          className="pointer-events-none absolute left-4 top-1/2 h-5 w-5 -translate-y-1/2 text-gray-400"
        >
          <circle cx="9" cy="9" r="6" stroke="currentColor" strokeWidth="1.5" />
          <path d="M14 14L18 18" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" />
        </svg>
        <input
          data-testid="search-input"
          type="search"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            if (e.target.value === "") {
              setDebouncedQuery("");
              goToPage(1);
            }
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              setDebouncedQuery(query);
              goToPage(1);
            }
          }}
          placeholder="Search records…"
          className="w-full rounded-full border border-gray-300 bg-white py-3 pl-11 pr-4 text-base text-gray-900 shadow-sm outline-none placeholder:text-gray-400 focus:border-indigo-500 focus:ring-2 focus:ring-indigo-500 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
          aria-label="Search records"
        />
      </div>

      {debouncedQuery.trim().split(/\s+/).some((t) => t.length > 0 && t.length < 3) && (
        <p className="mb-3 text-xs text-gray-400">
          Short search terms may take a moment — adding more characters speeds things up.
        </p>
      )}

      <div className="overflow-x-auto" style={{ minHeight: (pageSize + 1) * 41 }}>
        {error ? (
          <div className="py-10 text-center text-sm text-red-500">
            Search failed: {error}
          </div>
        ) : rows.length === 0 ? (
          <div
            className="flex flex-col items-center justify-center gap-2 py-12 text-sm text-gray-400"
            aria-live="polite"
          >
            {suppressLoader ? null : (isControlled ? controlledLoading : loading) ? (
              <>
                <span
                  aria-hidden
                  className="h-6 w-6 animate-spin rounded-full border-2 border-gray-300 border-t-indigo-500 dark:border-gray-700 dark:border-t-indigo-400"
                />
                <span className={searchLoading && !warmingUp ? "animate-pulse" : undefined}>
                  {warmingUp
                    ? "Backend waking up…"
                    : (isControlled ? controlledLoading : searchLoading)
                    ? "Searching…"
                    : "Loading…"}
                </span>
                {warmingUp && (
                  <span className="text-xs text-gray-300 dark:text-gray-600 text-center">
                    Cloud Run scales to zero when idle — first request takes ~30s
                  </span>
                )}
              </>
            ) : backendReady && fetchDone ? (
              "No results."
            ) : null}
          </div>
        ) : (
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b border-gray-200 text-left dark:border-gray-800">
                {COLUMNS.map((col) => {
                  const isSorted = col.sortKey ? sort === col.sortKey : false;
                  const sortable = !!col.sortKey;
                  return (
                    <th
                      key={col.key}
                      {...(sortable
                        ? { "data-testid": `sort-${col.sortKey}` }
                        : {})}
                      onClick={
                        sortable ? () => toggleSort(col.sortKey!) : undefined
                      }
                      aria-sort={
                        isSorted
                          ? dir === "asc"
                            ? "ascending"
                            : "descending"
                          : "none"
                      }
                      className={cn(
                        "px-3 py-2 font-medium text-gray-500 dark:text-gray-400",
                        sortable &&
                          "cursor-pointer select-none hover:text-gray-700 dark:hover:text-gray-200",
                        col.numeric && "text-right",
                      )}
                    >
                      <span className="inline-flex items-center gap-1">
                        {col.label}
                        {sortable && (
                          <span
                            aria-hidden
                            className={cn(
                              "text-xs",
                              isSorted
                                ? "text-indigo-500"
                                : "text-transparent",
                            )}
                          >
                            {isSorted ? (dir === "asc" ? "▲" : "▼") : "▲"}
                          </span>
                        )}
                      </span>
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, i) => (
                <tr
                  key={(row.id as string | number | undefined) ?? i}
                  data-testid="search-result"
                  data-id={row.id as string | number | undefined}
                  data-order-id={row.id as string | number | undefined}
                  data-new={
                    i === 0 &&
                    newFirstId != null &&
                    String(row.id) === String(newFirstId)
                      ? "true"
                      : undefined
                  }
                  className={cn(
                    "border-b border-gray-100 hover:bg-gray-50 dark:border-gray-800 dark:hover:bg-gray-800/50",
                    flashId != null &&
                      String(row.id) === String(flashId) &&
                      "row-insert",
                  )}
                >
                  {COLUMNS.map((col) => (
                    <td
                      key={col.key}
                      className={cn(
                        "px-3 py-2 align-top",
                        col.numeric && "text-right tabular-nums",
                      )}
                    >
                      {col.render(row)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <footer className="mt-4 flex flex-wrap items-center justify-between gap-3">
        <span className="text-xs text-gray-500 dark:text-gray-400">
          Page {page} of{" "}
          {footerLoading || externalTotal === null
            ? <span className="inline-block h-3 w-8 animate-pulse rounded bg-gray-200 align-middle dark:bg-gray-700" />
            : displayTotalPages}{" "}·{" "}
          <span data-testid="search-total" data-total={displayTotal}>
            {footerLoading || externalTotal === null
              ? <span className="inline-block h-3 w-14 animate-pulse rounded bg-gray-200 align-middle dark:bg-gray-700" />
              : displayTotal.toLocaleString()}
          </span>{" "}
          {footerLoading || externalTotal === null
            ? <span className="inline-block h-3 w-10 animate-pulse rounded bg-gray-200 align-middle dark:bg-gray-700" />
            : "results"}
        </span>

        {(footerLoading || externalTotal === null) && displayTotalPages > 1 ? (
          <nav aria-label="Pagination">
            <ul className="flex items-center gap-1">
              <li>
                <button type="button" disabled
                  className="flex h-9 items-center rounded-md border border-gray-300 px-3 text-sm disabled:cursor-not-allowed disabled:opacity-40 dark:border-gray-700">
                  Prev
                </button>
              </li>
              <li>
                <button type="button" aria-current="page"
                  className="flex h-9 min-w-9 items-center justify-center rounded-md px-3 text-sm bg-indigo-600 text-white">
                  {page}
                </button>
              </li>
              <li aria-hidden className="px-1">
                <span className="inline-block h-3 w-24 animate-pulse rounded bg-gray-200 align-middle dark:bg-gray-700" />
              </li>
              <li>
                <button type="button" disabled
                  className="flex h-9 items-center rounded-md border border-gray-300 px-3 text-sm disabled:cursor-not-allowed disabled:opacity-40 dark:border-gray-700">
                  Next
                </button>
              </li>
            </ul>
          </nav>
        ) : displayTotalPages > 1 ? (
          <nav aria-label="Pagination">
            <ul className="flex items-center gap-1">
              <li>
                <button
                  type="button"
                  data-testid="prev-page"
                  onClick={() => goToAdjacentPage("prev")}
                  disabled={page <= 1 || (isControlled ? controlledLoading : loading)}
                  className="flex h-9 items-center rounded-md border border-gray-300 px-3 text-sm hover:bg-gray-100 disabled:cursor-not-allowed disabled:opacity-40 dark:border-gray-700 dark:hover:bg-gray-800"
                >
                  Prev
                </button>
              </li>

              {pageItems.map((item) => {
                if (item === "left-ellipsis" || item === "right-ellipsis") {
                  return (
                    <li
                      key={item}
                      aria-hidden
                      className="px-2 text-sm text-gray-400"
                    >
                      …
                    </li>
                  );
                }
                const isActive = item === page;
                const handleClick =
                  item === page - 1
                    ? () => goToAdjacentPage("prev")
                    : item === page + 1
                      ? () => goToAdjacentPage("next")
                      : () => goToPage(item);
                return (
                  <li key={item} data-testid={`page-${item}`}>
                    <button
                      type="button"
                      onClick={handleClick}
                      aria-current={isActive ? "page" : undefined}
                      data-testid={isActive ? "current-page" : undefined}
                      className={cn(
                        "flex h-9 min-w-9 items-center justify-center rounded-md px-3 text-sm transition-colors",
                        isActive
                          ? "bg-indigo-600 text-white"
                          : "border border-gray-300 hover:bg-gray-100 dark:border-gray-700 dark:hover:bg-gray-800",
                      )}
                    >
                      {item}
                    </button>
                  </li>
                );
              })}

              <li>
                <button
                  type="button"
                  data-testid="next-page"
                  onClick={() => goToAdjacentPage("next")}
                  disabled={page >= displayTotalPages || (isControlled ? controlledLoading : loading)}
                  className="flex h-9 items-center rounded-md border border-gray-300 px-3 text-sm hover:bg-gray-100 disabled:cursor-not-allowed disabled:opacity-40 dark:border-gray-700 dark:hover:bg-gray-800"
                >
                  Next
                </button>
              </li>
            </ul>
          </nav>
        ) : null}
      </footer>
    </section>
  );
}

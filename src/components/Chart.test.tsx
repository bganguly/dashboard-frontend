import { beforeEach, describe, expect, it, vi } from "vitest";
import { cloneElement, type ReactElement } from "react";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import Chart, { type RawAggregate } from "./Chart";
import { EMPTY_FILTERS } from "./FilterSidebar";

// jsdom gives ResponsiveContainer zero size; hand the chart a fixed one instead.
vi.mock("recharts", async (importOriginal) => {
  const original = await importOriginal<typeof import("recharts")>();
  return {
    ...original,
    ResponsiveContainer: ({ children }: { children: ReactElement }) =>
      cloneElement(children, { width: 800, height: 320 } as object),
  };
});

function day(date: string, categories: Record<string, number>): RawAggregate {
  return {
    date,
    categories: Object.fromEntries(
      Object.entries(categories).map(([cat, orders]) => [
        cat,
        { totalOrders: orders, totalRevenue: orders * 10, totalItems: orders },
      ]),
    ),
  };
}

let fetchMock: ReturnType<typeof vi.fn>;

function mockFetchOnce(body: unknown, ok = true, status = 200) {
  fetchMock.mockResolvedValueOnce({ ok, status, json: async () => body });
}

beforeEach(() => {
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});

describe("Chart", () => {
  it("shows 'No data.' when the API returns nothing", async () => {
    mockFetchOnce({ data: [] });
    render(<Chart />);

    expect(await screen.findByText("No data.")).toBeInTheDocument();
  });

  it("shows the error state on a failed fetch", async () => {
    mockFetchOnce({}, false, 500);
    render(<Chart />);

    expect(await screen.findByText(/Failed: HTTP 500/)).toBeInTheDocument();
  });

  it("requests aggregates with filters and the committed search query", async () => {
    mockFetchOnce({ data: [] });
    render(
      <Chart
        filters={{ ...EMPTY_FILTERS, status: ["PENDING"], from: "2026-01-01", to: "2026-01-31" }}
        searchQuery="smith"
      />,
    );

    await waitFor(() => expect(fetchMock).toHaveBeenCalled());
    const url = fetchMock.mock.calls[0][0] as string;
    expect(url).toContain("/api/aggregates?");
    expect(url).toContain("from=2026-01-01");
    expect(url).toContain("to=2026-01-31");
    expect(url).toContain("topCategories=4");
    expect(url).toContain("status=PENDING");
    expect(url).toContain("q=smith");
  });

  it("renders legend tiles for the top categories and rolls the rest into Others", async () => {
    const user = userEvent.setup();
    mockFetchOnce({
      data: [
        day("2026-01-01", { A: 10, B: 9, C: 8, D: 7, E: 2, F: 1 }),
        day("2026-01-02", { A: 5, B: 4 }),
      ],
    });
    render(<Chart />);

    await waitFor(() =>
      expect(screen.getAllByTestId("aggregate-tile").length).toBeGreaterThan(0),
    );
    const tiles = screen.getAllByTestId("aggregate-tile");
    expect(tiles.map((t) => t.getAttribute("data-category"))).toEqual(["A", "B", "C", "D"]);
    expect(tiles[0]).toHaveTextContent("15"); // A: 10 + 5 orders

    // Others starts hidden; the checkbox reveals its series
    const othersToggle = screen.getByRole("checkbox");
    expect(othersToggle).not.toBeChecked();
    expect(screen.getByText("Others")).toBeInTheDocument();
    await user.click(othersToggle);
    expect(othersToggle).toBeChecked();
  });
});

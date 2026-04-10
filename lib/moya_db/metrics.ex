defmodule MoyaDB.Metrics do
  @moduledoc """
  Tracks inbound API request metrics over a rolling time window.
  """

  use GenServer

  @default_window_ms 1_000
  @default_db_id "db-1"

  # --- Public API -----------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record one inbound request with status and latency."
  def record(status, latency_ms) when is_integer(status) and is_number(latency_ms) do
    GenServer.cast(__MODULE__, {:record, status, latency_ms})
  end

  @doc "Return a metrics snapshot over the active rolling window."
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc "Clear all collected samples."
  def reset do
    GenServer.cast(__MODULE__, :reset)
  end

  # --- GenServer callbacks --------------------------------------------------

  @impl true
  def init(_opts) do
    window_ms = Application.get_env(:moya_db, :metrics_window_ms, @default_window_ms)
    db_id = Application.get_env(:moya_db, :db_id, @default_db_id)

    {:ok,
     %{
       window_ms: window_ms,
       db_id: db_id,
       samples: []
     }}
  end

  @impl true
  def handle_cast({:record, status, latency_ms}, state) do
    now = System.system_time(:millisecond)
    sample = {now, status, latency_ms}
    samples = prune([sample | state.samples], state.window_ms, now)
    {:noreply, %{state | samples: samples}}
  end

  def handle_cast(:reset, state) do
    {:noreply, %{state | samples: []}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    now = System.system_time(:millisecond)
    samples = prune(state.samples, state.window_ms, now)

    statuses = Enum.map(samples, fn {_ts, status, _latency} -> status end)
    latencies = Enum.map(samples, fn {_ts, _status, latency} -> latency end)

    response = %{
      "window_ms" => state.window_ms,
      "timestamp" => now,
      "role" => "database",
      "db_id" => state.db_id,
      "inbound" => %{
        "query_count" => length(samples),
        "responses" => %{
          "2xx" => count_bucket(statuses, 200, 299),
          "4xx" => count_bucket(statuses, 400, 499),
          "5xx" => count_bucket(statuses, 500, 599)
        },
        "last_status" => last_status(samples)
      },
      "health" => %{
        "ready" => true,
        "latency_ms_p50" => percentile(latencies, 50),
        "latency_ms_p95" => percentile(latencies, 95)
      }
    }

    {:reply, response, %{state | samples: samples}}
  end

  # --- Private helpers ------------------------------------------------------

  defp prune(samples, window_ms, now) do
    cutoff = now - window_ms
    Enum.filter(samples, fn {ts, _status, _latency} -> ts >= cutoff end)
  end

  defp count_bucket(statuses, min, max) do
    Enum.count(statuses, fn status -> status >= min and status <= max end)
  end

  defp last_status([]), do: nil

  defp last_status(samples) do
    samples
    |> Enum.max_by(fn {ts, _status, _latency} -> ts end)
    |> elem(1)
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    size = length(sorted)
    index = trunc(Float.ceil((p / 100) * size)) - 1
    index = max(index, 0)
    value = Enum.at(sorted, index)
    Float.round(value * 1.0, 1)
  end
end
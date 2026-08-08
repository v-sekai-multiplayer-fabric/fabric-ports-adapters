defmodule RivetFabric.Http do
  @moduledoc """
  Minimal HTTP client over `:httpc`, for talking to the engine's API.

  OTP rather than a dependency, per
  [RFD 0015](../../rfd/0015-tooling-constraints.md). Only the two shapes the
  engine needs are here: a health probe and a JSON PUT.
  """

  @doc "GET a URL, returning `{:ok, status, body}` or `{:error, reason}`."
  def get(url, headers \\ []) do
    request(:get, url, headers, nil)
  end

  @doc "PUT a JSON body."
  def put_json(url, body, headers \\ []) do
    request(:put, url, headers, JSON.encode!(body))
  end

  defp request(method, url, headers, body) do
    :inets.start()
    :ssl.start()

    headers = Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)

    req =
      case body do
        nil -> {to_charlist(url), headers}
        b -> {to_charlist(url), headers, ~c"application/json", b}
      end

    case :httpc.request(method, req, [{:timeout, 30_000}], body_format: :binary) do
      {:ok, {{_, status, _}, _resp_headers, resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Poll a URL until it answers 200.

  The engine takes a while to come up: it has to open the FoundationDB cluster,
  create the default namespace, and run every startup backfill workflow before
  it serves anything.
  """
  def await_ok(url, attempts \\ 60) do
    case get(url) do
      {:ok, 200, body} ->
        {:ok, body}

      other ->
        if attempts > 0 do
          Process.sleep(2000)
          await_ok(url, attempts - 1)
        else
          {:error, "#{url} never returned 200, last was #{inspect(other)}"}
        end
    end
  end
end

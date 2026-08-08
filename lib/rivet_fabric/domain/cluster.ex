defmodule RivetFabric.Domain.Cluster do
  @moduledoc """
  Pure cluster logic. No I/O, no substrate.

  Every function here encodes something that was learned by breaking a real
  deployment. The comments say which, because none of it is guessable from the
  Rivet source.
  """

  @doc """
  Format one coordinator address.

  FoundationDB cluster files require IPv6 addresses to be bracketed. Fly's
  private network (6PN) is IPv6-only, so this is the normal case there, not an
  edge case.

      iex> RivetFabric.Domain.Cluster.address("fdaa:0:5132::2", 4500)
      "[fdaa:0:5132::2]:4500"

      iex> RivetFabric.Domain.Cluster.address("10.89.0.4", 4500)
      "10.89.0.4:4500"
  """
  def address(ip, port) do
    if String.contains?(ip, ":"), do: "[#{ip}]:#{port}", else: "#{ip}:#{port}"
  end

  @doc """
  Build the coordinator list from node addresses.

  Sorted so the string is stable across runs; an unstable coordinator list
  rewrites the cluster file on every deploy for no reason.
  """
  def coordinators(ips, port) do
    ips
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&address(&1, port))
    |> Enum.sort()
    |> Enum.join(",")
  end

  @doc """
  The contents of an `fdb.cluster` file.

      iex> RivetFabric.Domain.Cluster.cluster_file("rivet", "rivet", "10.0.0.1:4500")
      "rivet:rivet@10.0.0.1:4500"
  """
  def cluster_file(description, id, coordinators) do
    "#{description}:#{id}@#{coordinators}"
  end

  @doc """
  The engine's topology config.

  Two traps are encoded here, both of which cost a broken deployment:

  1. This must be a **file**, not environment variables. `topology.datacenters`
     deserializes through an untagged enum, and the env-var source cannot merge
     into it. Setting `RIVET__TOPOLOGY__DATACENTERS__DEFAULT__*` fails startup
     with `failed to deserialize config` even when every required field is set.

  2. `name` must be **omitted**. In the map form it is derived from the key, and
     setting it explicitly is rejected with "cannot have the `name` property set
     because it is automatically derived from key".

  `public_url` is what the engine hands each envoy as `x-rivet-endpoint`, and
  the envoy dials it. The default is `http://127.0.0.1:6420`, which an envoy
  resolves inside its *own* container, so it must be an address that reaches the
  engine from elsewhere on the network.
  """
  def topology(opts) do
    host = Keyword.fetch!(opts, :host)
    port = Keyword.get(opts, :port, 6420)
    peer_port = Keyword.get(opts, :peer_port, 6421)
    scheme = Keyword.get(opts, :scheme, "http")

    %{
      "topology" => %{
        "datacenter_label" => 1,
        "datacenters" => %{
          "default" => %{
            "datacenter_label" => 1,
            "is_leader" => true,
            "public_url" => "#{scheme}://#{host}:#{port}",
            "peer_url" => "#{scheme}://#{host}:#{peer_port}"
          }
        }
      }
    }
  end

  @doc """
  The engine's FoundationDB config.

  `addresses` is a list because the engine writes its own cluster file from it
  at `cluster_file_write_path`. Supplying a pre-made `cluster_file` path instead
  is also valid, but the addresses are only knowable after the nodes exist.
  """
  def fdb_config(coordinators, opts \\ []) do
    %{
      "foundationdb" => %{
        "addresses" => String.split(coordinators, ","),
        "cluster_description" => Keyword.get(opts, :description, "rivet"),
        "cluster_id" => Keyword.get(opts, :id, "rivet"),
        "cluster_file_write_path" =>
          Keyword.get(opts, :write_path, "/etc/foundationdb/fdb.cluster")
      }
    }
  end

  @doc """
  A serverless runner config.

  Returns `{:error, reason}` rather than letting the engine reject it with a
  400: `drain_grace_period` defaults to 1800s and must be strictly less than
  `request_lifespan`, which is not obvious from the API docs.
  """
  def runner_config(url, opts \\ []) do
    lifespan = Keyword.get(opts, :request_lifespan, 900)
    grace = Keyword.get(opts, :drain_grace_period, 60)
    max_actors = Keyword.get(opts, :max_concurrent_actors, 4)

    cond do
      grace >= lifespan ->
        {:error,
         "drain_grace_period (#{grace}s) must be less than request_lifespan (#{lifespan}s)"}

      true ->
        {:ok,
         %{
           "datacenters" => %{
             "default" => %{
               "serverless" => %{
                 "url" => url,
                 "request_lifespan" => lifespan,
                 "drain_grace_period" => grace,
                 "max_concurrent_actors" => max_actors
               }
             }
           }
         }}
    end
  end

  @doc """
  Whether every node agrees on the coordinator set.

  A node created before the coordinators are known writes a cluster file naming
  only itself. Three such nodes are three independent one-node clusters, and
  each one logs `FDBD joined cluster`, so they look healthy. This is the check
  that catches it before `configure new` silently succeeds against one of them.
  """
  def cluster_files_agree?(contents) do
    case Enum.uniq(Enum.map(contents, &String.trim/1)) do
      [_single] -> true
      _ -> false
    end
  end

  @doc """
  The `configure` command for a node count.

  `double` needs at least three processes; below that only `single` is valid,
  and it has no fault tolerance.
  """
  def configure_command(node_count, storage \\ "ssd") do
    redundancy = if node_count >= 3, do: "double", else: "single"
    "configure new #{redundancy} #{storage}"
  end
end

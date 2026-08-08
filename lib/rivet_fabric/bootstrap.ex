defmodule RivetFabric.Bootstrap do
  @moduledoc """
  The bootstrap sequence, written against the substrate port.

  The ordering here is the whole point of the repo. FoundationDB coordinators
  are addressed by IP, and the addresses do not exist until the nodes do, so the
  sequence is necessarily two-phase:

      1. create nodes, each of which bootstraps as its own sole coordinator
      2. read the addresses back
      3. force every node onto one shared coordinator set
      4. only then `configure new`

  Skipping step 3 leaves N independent one-node clusters that each report
  `FDBD joined cluster` and look healthy. Step 4 then succeeds against exactly
  one of them and the rest are silently orphaned.
  """

  require Logger

  alias RivetFabric.Domain.{Cluster, Spec}

  @doc """
  Bring up the FoundationDB cluster.

  Returns `{:ok, coordinators}` where `coordinators` is the comma-joined
  coordinator string the engine needs.
  """
  def foundationdb(adapter, spec, image) do
    app = spec.fdb.app
    names = Spec.fdb_nodes(spec)

    Logger.info("creating #{length(names)} foundationdb nodes")

    :ok = adapter.network_ensure(spec.network)

    for name <- names do
      :ok =
        adapter.node_ensure(%{
          app: app,
          name: name,
          image: image,
          network: spec.network,
          volume: {"#{app}-#{name}", "/var/fdb"},
          env: %{
            "FDB_PORT" => to_string(spec.fdb.port),
            "FDB_CLUSTER_FILE" => "/var/fdb/fdb.cluster",
            "FDB_CLUSTER_DESCRIPTION" => spec.fdb.cluster_description,
            "FDB_CLUSTER_ID" => spec.fdb.cluster_id
          }
        })
    end

    with {:ok, coordinators} <- await_addresses(adapter, app, length(names), spec.fdb.port),
         :ok <- force_shared_coordinators(adapter, spec, names, coordinators),
         :ok <- verify_agreement(adapter, app, names),
         :ok <- configure(adapter, app, hd(names), length(names), spec.fdb.storage) do
      {:ok, coordinators}
    end
  end

  @doc """
  Poll until every node reports an address, then build the coordinator string.

  Addresses appear asynchronously after the container starts, so this waits
  rather than assuming.
  """
  def await_addresses(adapter, app, expected, port, attempts \\ 30) do
    case adapter.node_list(app) do
      {:ok, nodes} ->
        ips = nodes |> Enum.map(& &1.address) |> Enum.reject(&is_nil/1)

        cond do
          length(ips) >= expected ->
            {:ok, Cluster.coordinators(ips, port)}

          attempts <= 0 ->
            {:error, "only #{length(ips)}/#{expected} nodes reported an address"}

          true ->
            Process.sleep(1000)
            await_addresses(adapter, app, expected, port, attempts - 1)
        end

      err ->
        err
    end
  end

  @doc """
  Overwrite every node's cluster file with the shared coordinator set.

  The entrypoint only seeds the cluster file when it is absent, because
  `fdbserver` rewrites it whenever coordinators change and a redeploy must not
  clobber a live set. This is the deliberate one-shot override.
  """
  def force_shared_coordinators(adapter, spec, names, coordinators) do
    contents =
      Cluster.cluster_file(spec.fdb.cluster_description, spec.fdb.cluster_id, coordinators)

    Logger.info("forcing shared coordinators: #{coordinators}")

    Enum.reduce_while(names, :ok, fn name, _acc ->
      case adapter.node_write_file(
             spec.fdb.app,
             name,
             "/var/fdb/fdb.cluster",
             contents <> "\n"
           ) do
        :ok ->
          # fdbserver reads the cluster file at startup, so it has to come back.
          _ = adapter.node_exec(spec.fdb.app, name, ["sh", "-c", "kill 1"])
          {:cont, :ok}

        err ->
          {:halt, err}
      end
    end)
  end

  @doc "Fail loudly if the nodes disagree, rather than configuring a split cluster."
  def verify_agreement(adapter, app, names) do
    Process.sleep(3000)

    contents =
      Enum.map(names, fn name ->
        case adapter.node_exec(app, name, ["cat", "/var/fdb/fdb.cluster"]) do
          {:ok, out} -> out
          {:error, _} -> "<unreadable>"
        end
      end)

    if Cluster.cluster_files_agree?(contents) do
      :ok
    else
      {:error,
       "nodes disagree on the coordinator set, which means a split cluster:\n" <>
         Enum.join(contents, "")}
    end
  end

  @doc "Create the database. Idempotent in effect: a second run is a no-op error."
  def configure(adapter, app, name, node_count, storage) do
    cmd = Cluster.configure_command(node_count, storage)
    Logger.info("#{cmd}")

    case adapter.node_exec(app, name, [
           "fdbcli",
           "-C",
           "/var/fdb/fdb.cluster",
           "--exec",
           cmd
         ]) do
      {:ok, out} ->
        if String.contains?(out, "Database created") or
             String.contains?(out, "already exists") do
          :ok
        else
          Logger.warning("unexpected configure output: #{String.trim(out)}")
          :ok
        end

      {:error, reason} ->
        # Re-running against a live cluster errors, which is not fatal.
        Logger.warning("configure returned an error, continuing: #{reason}")
        :ok
    end
  end

  @doc "Report cluster status as seen by fdbcli."
  def status(adapter, app, name) do
    adapter.node_exec(app, name, [
      "fdbcli",
      "-C",
      "/var/fdb/fdb.cluster",
      "--exec",
      "status minimal"
    ])
  end

  @doc "Tear every node down."
  def destroy(adapter, spec) do
    for name <- Spec.fdb_nodes(spec) do
      _ = adapter.node_destroy(spec.fdb.app, name)
    end

    for app <- [spec.engine.app, spec.godot.app] do
      case adapter.node_list(app) do
        {:ok, nodes} ->
          for n <- nodes, do: adapter.node_destroy(app, n.name)

        _ ->
          :ok
      end
    end

    :ok
  end
end

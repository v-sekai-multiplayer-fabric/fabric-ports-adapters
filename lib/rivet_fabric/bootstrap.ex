defmodule RivetFabric.Bootstrap do
  @moduledoc """
  The bootstrap sequence, written against the substrate port.

  ## Why addresses are allocated, not discovered

  FoundationDB coordinators are addressed by IP, so a cluster cannot form until
  the addresses are known. The obvious sequence is to create the nodes, read
  their addresses back, rewrite each cluster file, and restart. That does not
  work under podman, and every step of the failure is quiet:

  * A node created without `FDB_COORDINATORS` names itself as sole coordinator.
    N such nodes are N independent one-node clusters, and each logs
    `FDBD joined cluster`, so they all look healthy.
  * Rewriting the cluster file is not enough: `fdbserver` reads it once at
    startup, and signalling PID 1 from inside the container is discarded by the
    kernel, so the restart must come from the substrate.
  * That restart then assigns a **new** address, invalidating the coordinator
    list just written. The sequence is circular.

  Allocating static addresses up front removes all three problems at once. The
  coordinator set is known before anything exists, so it is passed at creation
  and no node ever runs with a self-only cluster file.
  """

  require Logger

  alias RivetFabric.Domain.{Cluster, Spec}

  @doc "Bring up the FoundationDB cluster. Returns `{:ok, coordinators}`."
  def foundationdb(adapter, spec, image) do
    plan = Spec.fdb_plan(spec)
    coordinators = Cluster.coordinators(Enum.map(plan, &elem(&1, 1)), spec.fdb.port)
    names = Enum.map(plan, &elem(&1, 0))

    Logger.info("coordinators allocated up front: #{coordinators}")

    with :ok <-
           adapter.network_ensure(spec.network, subnet: spec.subnet, gateway: spec.gateway),
         :ok <- create_nodes(adapter, spec, plan, image, coordinators),
         :ok <- verify_agreement(adapter, spec.fdb.app, names),
         :ok <-
           configure(adapter, spec.fdb.app, hd(names), length(names), spec.fdb.storage) do
      {:ok, coordinators}
    end
  end

  defp create_nodes(adapter, spec, plan, image, coordinators) do
    Enum.reduce_while(plan, :ok, fn {name, ip}, _acc ->
      node = %{
        app: spec.fdb.app,
        name: name,
        image: image,
        network: spec.network,
        ip: ip,
        volume: {"#{spec.fdb.app}-#{name}", "/var/fdb"},
        env: %{
          "FDB_PORT" => to_string(spec.fdb.port),
          "FDB_PUBLIC_IP" => ip,
          "FDB_COORDINATORS" => coordinators,
          "FDB_CLUSTER_FILE" => "/var/fdb/fdb.cluster",
          "FDB_CLUSTER_DESCRIPTION" => spec.fdb.cluster_description,
          "FDB_CLUSTER_ID" => spec.fdb.cluster_id
        }
      }

      case adapter.node_ensure(node) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  @doc """
  Fail loudly if the nodes disagree, rather than configuring a split cluster.

  Cheap, and it is what distinguishes "three nodes in one cluster" from "three
  one-node clusters that each look healthy".
  """
  def verify_agreement(adapter, app, names, attempts \\ 20) do
    contents =
      Enum.map(names, fn name ->
        case adapter.node_exec(app, name, ["cat", "/var/fdb/fdb.cluster"]) do
          {:ok, out} -> out
          {:error, _} -> ""
        end
      end)

    cond do
      Enum.any?(contents, &(String.trim(&1) == "")) and attempts > 0 ->
        Process.sleep(1000)
        verify_agreement(adapter, app, names, attempts - 1)

      Cluster.cluster_files_agree?(contents) ->
        :ok

      attempts > 0 ->
        Process.sleep(1000)
        verify_agreement(adapter, app, names, attempts - 1)

      true ->
        {:error,
         "nodes disagree on the coordinator set, which means a split cluster:\n" <>
           Enum.join(contents, "")}
    end
  end

  @doc """
  Create the database.

  Retries, because the coordinators need a moment to elect before `configure`
  can win. Re-running against a live cluster is an error from fdbcli's point of
  view but not from ours.
  """
  def configure(adapter, app, name, node_count, storage, attempts \\ 30) do
    cmd = Cluster.configure_command(node_count, storage)

    case adapter.node_exec(app, name, ["fdbcli", "-C", "/var/fdb/fdb.cluster", "--exec", cmd]) do
      {:ok, out} ->
        cond do
          String.contains?(out, "Database created") ->
            Logger.info("#{cmd}: database created")
            :ok

          String.contains?(out, "already") ->
            Logger.info("#{cmd}: database already exists")
            :ok

          attempts > 0 ->
            Process.sleep(2000)
            configure(adapter, app, name, node_count, storage, attempts - 1)

          true ->
            {:error, "configure did not take: #{String.trim(out)}"}
        end

      {:error, reason} ->
        if attempts > 0 do
          Process.sleep(2000)
          configure(adapter, app, name, node_count, storage, attempts - 1)
        else
          {:error, "configure failed: #{reason}"}
        end
    end
  end

  @doc """
  Wait for the database to report itself available.

  `configure new` succeeding only means the configuration was accepted;
  recruitment happens afterwards, so this is a separate wait.
  """
  def await_available(adapter, app, name, attempts \\ 60) do
    case status(adapter, app, name) do
      {:ok, out} ->
        cond do
          String.contains?(out, "available") and not String.contains?(out, "unavailable") ->
            {:ok, String.trim(out)}

          attempts > 0 ->
            Process.sleep(2000)
            await_available(adapter, app, name, attempts - 1)

          true ->
            {:error, "database never became available: #{String.trim(out)}"}
        end

      {:error, reason} ->
        if attempts > 0 do
          Process.sleep(2000)
          await_available(adapter, app, name, attempts - 1)
        else
          {:error, reason}
        end
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
        {:ok, nodes} -> for n <- nodes, do: adapter.node_destroy(app, n.name)
        _ -> :ok
      end
    end

    :ok
  end
end

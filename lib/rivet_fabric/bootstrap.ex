defmodule RivetFabric.Bootstrap do
  @moduledoc """
  The bootstrap sequence.

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
  alias RivetFabric.{Http, Quadlet}

  @doc "Bring up the FoundationDB cluster. Returns `{:ok, coordinators}`."
  def foundationdb(spec, image) do
    plan = Spec.fdb_plan(spec)
    coordinators = Cluster.coordinators(Enum.map(plan, &elem(&1, 1)), spec.fdb.port)
    names = Enum.map(plan, &elem(&1, 0))

    Logger.info("coordinators allocated up front: #{coordinators}")

    with :ok <-
           Quadlet.network_ensure(spec.network, subnet: spec.subnet, gateway: spec.gateway),
         :ok <- create_nodes(spec, plan, image, coordinators),
         :ok <- verify_agreement(spec.fdb.app, names),
         :ok <-
           configure(spec.fdb.app, hd(names), length(names), spec.fdb.storage) do
      {:ok, coordinators}
    end
  end

  defp create_nodes(spec, plan, image, coordinators) do
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

      case Quadlet.node_ensure(node) do
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
  def verify_agreement(app, names, attempts \\ 20) do
    contents =
      Enum.map(names, fn name ->
        case Quadlet.node_exec(app, name, ["cat", "/var/fdb/fdb.cluster"]) do
          {:ok, out} -> out
          {:error, _} -> ""
        end
      end)

    cond do
      Enum.any?(contents, &(String.trim(&1) == "")) and attempts > 0 ->
        Process.sleep(1000)
        verify_agreement(app, names, attempts - 1)

      Cluster.cluster_files_agree?(contents) ->
        :ok

      attempts > 0 ->
        Process.sleep(1000)
        verify_agreement(app, names, attempts - 1)

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
  def configure(app, name, node_count, storage, attempts \\ 30) do
    cmd = Cluster.configure_command(node_count, storage)

    case Quadlet.node_exec(app, name, ["fdbcli", "-C", "/var/fdb/fdb.cluster", "--exec", cmd]) do
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
            configure(app, name, node_count, storage, attempts - 1)

          true ->
            {:error, "configure did not take: #{String.trim(out)}"}
        end

      {:error, reason} ->
        if attempts > 0 do
          Process.sleep(2000)
          configure(app, name, node_count, storage, attempts - 1)
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
  def await_available(app, name, attempts \\ 60) do
    case status(app, name) do
      {:ok, out} ->
        cond do
          String.contains?(out, "available") and not String.contains?(out, "unavailable") ->
            {:ok, String.trim(out)}

          attempts > 0 ->
            Process.sleep(2000)
            await_available(app, name, attempts - 1)

          true ->
            {:error, "database never became available: #{String.trim(out)}"}
        end

      {:error, reason} ->
        if attempts > 0 do
          Process.sleep(2000)
          await_available(app, name, attempts - 1)
        else
          {:error, reason}
        end
    end
  end

  @doc """
  Bring up the Rivet engine against the FoundationDB cluster.

  Config is complete at the moment the container starts. This is deliberate. An
  earlier version started the engine first and delivered config afterwards with
  `podman cp` plus a restart. The engine has no cluster file at first start, so
  it exits immediately with `foundationdb error 1515`, and `Restart=always`
  crash-loops it until systemd gives up. Delivering everything up front removes
  the loop rather than racing it.

  The two mechanisms mirror the Fly deploy (`self-host/fly/deploy.sh`), which is
  the proven reference for this fork:

  * FoundationDB is configured by **coordinator addresses**, not a mounted
    cluster file. The engine's `resolve_cluster_file` writes its own cluster
    file from `RIVET__FOUNDATIONDB__ADDRESSES` at startup, so the same
    coordinators the nodes agreed on are reached without injecting a file.
  * The topology is a **file bind-mounted at creation**, because
    `topology.datacenters` deserializes through an untagged enum that the
    env-var source cannot merge into. See
    [RFD 0003](../../rfd/0003-engine-configuration.md). Fly delivers it with
    `flyctl machine update --file-literal`; podman's equivalent is a read-only
    bind mount into `/etc/rivet`, which the engine loads as a config directory.
  """
  def engine(spec, image, coordinators) do
    name = spec.engine.app
    host = Quadlet.container_name(spec.engine.app, name)

    # public_url must be reachable from other containers. The default is
    # http://127.0.0.1:6420, which an envoy resolves inside its own container.
    topology =
      Cluster.topology(
        host: host,
        port: spec.engine.port,
        peer_port: spec.engine.peer_port
      )

    topology_host = Path.join(Quadlet.node_state_dir(spec.engine.app, name), "topology.json")
    File.mkdir_p!(Path.dirname(topology_host))
    File.write!(topology_host, JSON.encode!(topology) <> "\n")

    with :ok <-
           Quadlet.node_ensure(%{
             app: spec.engine.app,
             name: name,
             image: image,
             network: spec.network,
             ip: spec.engine.ip,
             publish: [{spec.engine.port, spec.engine.port}],
             mounts: [{topology_host, "/etc/rivet/topology.json"}],
             env: %{
               "RIVET__FOUNDATIONDB__ADDRESSES" => coordinators,
               "RIVET__FOUNDATIONDB__CLUSTER_DESCRIPTION" => spec.fdb.cluster_description,
               "RIVET__FOUNDATIONDB__CLUSTER_ID" => spec.fdb.cluster_id,
               "RIVET__FOUNDATIONDB__CLUSTER_FILE_WRITE_PATH" => "/etc/foundationdb/fdb.cluster",
               "RIVET__AUTH__ADMIN_TOKEN" => spec.engine.admin_token
             }
           }),
         {:ok, body} <- Http.await_ok(engine_url(spec) <> "/health") do
      {:ok, body}
    end
  end

  @doc "Base URL for the engine, as reached from the host."
  def engine_url(spec), do: "http://127.0.0.1:#{spec.engine.port}"

  @doc """
  Register a container as a serverless runner.

  `Cluster.runner_config/2` rejects a `drain_grace_period` that is not strictly
  less than `request_lifespan` before the engine can, per
  [RFD 0010](../../rfd/0010-serverless-runner-configuration.md).
  """
  def register_runner(spec, url) do
    with {:ok, config} <-
           Cluster.runner_config(url,
             request_lifespan: spec.godot.request_lifespan,
             drain_grace_period: spec.godot.drain_grace_period,
             max_concurrent_actors: spec.godot.max_concurrent_actors
           ) do
      endpoint =
        engine_url(spec) <>
          "/runner-configs/#{spec.godot.runner_name}?namespace=default"

      case Http.put_json(endpoint, %{"datacenters" => config["datacenters"]}, [
             {"authorization", "Bearer " <> spec.engine.admin_token}
           ]) do
        {:ok, 200, body} -> {:ok, body}
        {:ok, status, body} -> {:error, "engine returned #{status}: #{body}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    end
  end

  @doc "Report cluster status as seen by fdbcli."
  def status(app, name) do
    Quadlet.node_exec(app, name, [
      "fdbcli",
      "-C",
      "/var/fdb/fdb.cluster",
      "--exec",
      "status minimal"
    ])
  end

  @doc "Tear every node down."
  def destroy(spec) do
    for name <- Spec.fdb_nodes(spec) do
      _ = Quadlet.node_destroy(spec.fdb.app, name)
    end

    for app <- [spec.engine.app, spec.godot.app] do
      case Quadlet.node_list(app) do
        {:ok, nodes} -> for n <- nodes, do: Quadlet.node_destroy(app, n.name)
        _ -> :ok
      end
    end

    :ok
  end
end

defmodule RivetFabric.Adapters.Fake do
  @moduledoc """
  In-memory substrate adapter.

  Exists so the bootstrap ordering can be tested without podman or a cloud
  account. It models the one behaviour that actually matters: a node created
  before the coordinator set is known writes a cluster file naming only itself.
  That is the failure the real deployment hit, and it is reproducible here.
  """

  @behaviour RivetFabric.Ports.Substrate

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{
          nodes: %{},
          networks: MapSet.new(),
          images: MapSet.new(),
          files: %{},
          execs: [],
          applied: 0,
          next_ip: Keyword.get(opts, :first_ip, 1)
        }
      end,
      name: __MODULE__
    )
  end

  def stop, do: Agent.stop(__MODULE__)
  def state, do: Agent.get(__MODULE__, & &1)

  @impl true
  def network_ensure(net) do
    Agent.update(__MODULE__, &%{&1 | networks: MapSet.put(&1.networks, net)})
    :ok
  end

  @impl true
  def image_ensure(%{tag: tag}) do
    Agent.update(__MODULE__, &%{&1 | images: MapSet.put(&1.images, tag)})
    {:ok, tag}
  end

  @impl true
  def node_ensure(spec) do
    Agent.update(__MODULE__, fn s ->
      key = {spec.app, spec.name}
      ip = "10.89.0.#{s.next_ip}"

      # A fresh FoundationDB node names itself as sole coordinator, exactly as
      # the real entrypoint does when FDB_COORDINATORS is unset.
      files =
        if String.contains?(spec.app, "fdb") do
          desc = get_in(spec, [:env, "FDB_CLUSTER_DESCRIPTION"]) || "rivet"
          id = get_in(spec, [:env, "FDB_CLUSTER_ID"]) || "rivet"
          port = get_in(spec, [:env, "FDB_PORT"]) || "4500"
          Map.put(s.files, {key, "/var/fdb/fdb.cluster"}, "#{desc}:#{id}@#{ip}:#{port}\n")
        else
          s.files
        end

      %{
        s
        | nodes: Map.put(s.nodes, key, %{name: spec.name, address: ip, state: :started}),
          files: files,
          next_ip: s.next_ip + 1
      }
    end)

    :ok
  end

  @impl true
  def node_list(app) do
    nodes =
      state().nodes
      |> Enum.filter(fn {{a, _}, _} -> a == app end)
      |> Enum.map(fn {_, v} -> v end)
      |> Enum.sort_by(& &1.name)

    {:ok, nodes}
  end

  @impl true
  def node_exec(app, name, argv) do
    Agent.update(__MODULE__, &%{&1 | execs: &1.execs ++ [{app, name, argv}]})

    case argv do
      ["cat", path] ->
        {:ok, Map.get(state().files, {{app, name}, path}, "")}

      ["fdbcli" | _] ->
        {:ok, "Database created"}

      _ ->
        {:ok, ""}
    end
  end

  @impl true
  def node_write_file(app, name, path, content) do
    Agent.update(__MODULE__, &%{&1 | files: Map.put(&1.files, {{app, name}, path}, content)})
    :ok
  end

  @impl true
  def node_stop(app, name) do
    Agent.update(__MODULE__, fn s ->
      %{s | nodes: Map.update!(s.nodes, {app, name}, &%{&1 | state: :stopped})}
    end)

    :ok
  end

  @impl true
  def node_destroy(app, name) do
    Agent.update(__MODULE__, &%{&1 | nodes: Map.delete(&1.nodes, {app, name})})
    :ok
  end

  @impl true
  def apply do
    Agent.update(__MODULE__, &%{&1 | applied: &1.applied + 1})
    :ok
  end
end

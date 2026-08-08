defmodule RivetFabric.BootstrapTest do
  @moduledoc """
  Exercises the bootstrap ordering against the in-memory adapter.

  These are the tests that would have caught the split-cluster bug before it
  reached a real deployment.
  """
  use ExUnit.Case, async: false

  alias RivetFabric.Adapters.Fake
  alias RivetFabric.Bootstrap
  alias RivetFabric.Domain.{Cluster, Spec}

  setup do
    # start_supervised! ties the agent's lifetime to the test process, so it is
    # deterministically down before the next test starts. A bare start_link plus
    # on_exit races: on_exit runs after the test process dies, and the next
    # test's start_link can hit {:error, {:already_started, _}}.
    start_supervised!(%{id: Fake, start: {Fake, :start_link, [[]]}})
    :ok
  end

  defp spec, do: Spec.merge(%{network: "test-net"})

  test "nodes created without coordinators each name themselves" do
    s = spec()
    :ok = Fake.network_ensure(s.network)

    # No FDB_COORDINATORS, which is what the discovery-then-restart approach
    # produced. Kept as a regression: this is the state the bootstrap must
    # never leave a cluster in.
    for name <- Spec.fdb_nodes(s) do
      :ok =
        Fake.node_ensure(%{
          app: s.fdb.app,
          name: name,
          image: "fdb",
          network: s.network,
          env: %{"FDB_PORT" => "4500"}
        })
    end

    contents =
      for name <- Spec.fdb_nodes(s) do
        {:ok, out} = Fake.node_exec(s.fdb.app, name, ["cat", "/var/fdb/fdb.cluster"])
        out
      end

    # Three separate one-node clusters. Every one of them would log
    # "FDBD joined cluster" and look healthy.
    refute Cluster.cluster_files_agree?(contents)
  end

  test "every node starts with the shared coordinator set, never a self-only one" do
    s = spec()
    assert {:ok, coordinators} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    expected = Enum.map(Spec.fdb_plan(s), &elem(&1, 1))
    assert coordinators == Cluster.coordinators(expected, 4500)

    contents =
      for name <- Spec.fdb_nodes(s) do
        {:ok, out} = Fake.node_exec(s.fdb.app, name, ["cat", "/var/fdb/fdb.cluster"])
        out
      end

    assert Cluster.cluster_files_agree?(contents)
    assert hd(contents) =~ coordinators
  end

  test "configure runs only after the nodes agree" do
    s = spec()
    {:ok, _} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    execs = Fake.state().execs
    configure_idx = Enum.find_index(execs, fn {_, _, argv} -> match?(["fdbcli" | _], argv) end)
    cat_idx = Enum.find_index(execs, fn {_, _, argv} -> match?(["cat" | _], argv) end)

    assert cat_idx < configure_idx,
           "agreement must be verified before the database is created"
  end

  test "no node is restarted during bootstrap" do
    s = spec()
    {:ok, _} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    # podman assigns a new address on restart, which would invalidate the
    # coordinator list the restart was meant to apply. Allocating addresses up
    # front means no restart is needed at all.
    assert Fake.state().restarts == []
  end

  test "bootstrap never signals PID 1 to reload config" do
    s = spec()
    {:ok, _} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    # The kernel discards unhandled signals sent to PID 1 from inside its own
    # PID namespace, so this silently does nothing.
    kills =
      Enum.filter(Fake.state().execs, fn {_, _, argv} ->
        Enum.any?(argv, &String.contains?(&1, "kill"))
      end)

    assert kills == []
  end

  test "addresses are static, so they survive a restart" do
    s = spec()
    {:ok, coordinators} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    :ok = Fake.node_restart(s.fdb.app, hd(Spec.fdb_nodes(s)))
    {:ok, nodes} = Fake.node_list(s.fdb.app)

    for n <- nodes do
      assert String.contains?(coordinators, n.address),
             "#{n.name} at #{n.address} is not in the coordinator set"
    end
  end

  test "destroy removes every node" do
    s = spec()
    {:ok, _} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")
    :ok = Bootstrap.destroy(Fake, s)
    assert {:ok, []} = Fake.node_list(s.fdb.app)
  end
end

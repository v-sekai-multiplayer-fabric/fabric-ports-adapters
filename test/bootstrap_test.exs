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

  test "fresh nodes each name themselves, which is the split-cluster trap" do
    s = spec()
    :ok = Fake.network_ensure(s.network)

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

  test "full bootstrap converges every node onto one coordinator set" do
    s = spec()
    assert {:ok, coordinators} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")

    assert coordinators ==
             Cluster.coordinators(["10.89.0.1", "10.89.0.2", "10.89.0.3"], 4500)

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

  test "await_addresses fails rather than hanging when nodes never appear" do
    assert {:error, msg} = Bootstrap.await_addresses(Fake, "nope", 3, 4500, 0)
    assert msg =~ "0/3"
  end

  test "destroy removes every node" do
    s = spec()
    {:ok, _} = Bootstrap.foundationdb(Fake, s, "fdb:7.3.76")
    :ok = Bootstrap.destroy(Fake, s)
    assert {:ok, []} = Fake.node_list(s.fdb.app)
  end
end

defmodule RivetFabric.ClusterTest do
  use ExUnit.Case, async: true
  doctest RivetFabric.Domain.Cluster

  alias RivetFabric.Domain.Cluster

  describe "address/2" do
    test "brackets IPv6, which is what Fly 6PN hands out" do
      assert Cluster.address("fdaa:0:5132:a7b:70:9779:90d6:2", 4500) ==
               "[fdaa:0:5132:a7b:70:9779:90d6:2]:4500"
    end

    test "leaves IPv4 alone, which is what podman hands out" do
      assert Cluster.address("10.89.0.4", 4500) == "10.89.0.4:4500"
    end
  end

  describe "coordinators/2" do
    test "sorts so the string is stable across runs" do
      a = Cluster.coordinators(["10.89.0.3", "10.89.0.1", "10.89.0.2"], 4500)
      b = Cluster.coordinators(["10.89.0.2", "10.89.0.3", "10.89.0.1"], 4500)
      assert a == b
      assert a == "10.89.0.1:4500,10.89.0.2:4500,10.89.0.3:4500"
    end

    test "drops nodes that have not reported an address yet" do
      assert Cluster.coordinators(["10.89.0.1", nil], 4500) == "10.89.0.1:4500"
    end
  end

  describe "topology/1" do
    test "omits name, which the engine rejects in the map form" do
      dc = Cluster.topology(host: "engine.internal")["topology"]["datacenters"]["default"]
      refute Map.has_key?(dc, "name")
    end

    test "public_url is the reachable host, not loopback" do
      dc = Cluster.topology(host: "engine.internal")["topology"]["datacenters"]["default"]
      assert dc["public_url"] == "http://engine.internal:6420"
      assert dc["peer_url"] == "http://engine.internal:6421"
      refute String.contains?(dc["public_url"], "127.0.0.1")
    end

    test "encodes to JSON the engine can load" do
      json = JSON.encode!(Cluster.topology(host: "engine.internal"))
      assert JSON.decode!(json)["topology"]["datacenter_label"] == 1
    end
  end

  describe "runner_config/2" do
    test "rejects a grace period the engine would 400 on" do
      assert {:error, msg} =
               Cluster.runner_config("http://x/api/rivet",
                 request_lifespan: 300,
                 drain_grace_period: 1800
               )

      assert msg =~ "must be less than"
    end

    test "accepts a valid pairing" do
      assert {:ok, cfg} =
               Cluster.runner_config("http://x/api/rivet",
                 request_lifespan: 900,
                 drain_grace_period: 60
               )

      sl = cfg["datacenters"]["default"]["serverless"]
      assert sl["url"] == "http://x/api/rivet"
      assert sl["drain_grace_period"] < sl["request_lifespan"]
    end

    test "defaults are internally consistent" do
      assert {:ok, _} = Cluster.runner_config("http://x/api/rivet")
    end
  end

  describe "cluster_files_agree?/1" do
    test "detects the split-cluster case" do
      refute Cluster.cluster_files_agree?([
               "rivet:rivet@10.89.0.1:4500\n",
               "rivet:rivet@10.89.0.2:4500\n"
             ])
    end

    test "accepts agreement despite whitespace" do
      assert Cluster.cluster_files_agree?([
               "rivet:rivet@10.89.0.1:4500,10.89.0.2:4500\n",
               "rivet:rivet@10.89.0.1:4500,10.89.0.2:4500"
             ])
    end
  end

  describe "configure_command/2" do
    test "double needs three nodes" do
      assert Cluster.configure_command(3) == "configure new double ssd"
      assert Cluster.configure_command(1) == "configure new single ssd"
    end
  end
end

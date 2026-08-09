defmodule RivetFabric.QuadletTest do
  use ExUnit.Case, async: true

  alias RivetFabric.Quadlet

  describe "render_unit/1" do
    test "renders a named volume, a static address, and sorted env" do
      unit =
        Quadlet.render_unit(%{
          app: "mf-rivet-fdb",
          name: "mf-rivet-fdb-1",
          image: "rivet-fabric/foundationdb:7.3.76",
          network: "rivet-fabric",
          ip: "10.89.100.11",
          volume: {"mf-rivet-fdb-mf-rivet-fdb-1", "/var/fdb"},
          env: %{"FDB_PORT" => "4500", "FDB_PUBLIC_IP" => "10.89.100.11"}
        })

      assert unit =~ "ContainerName=mf-rivet-fdb--mf-rivet-fdb-1"
      assert unit =~ "Network=rivet-fabric:ip=10.89.100.11"
      assert unit =~ "Volume=mf-rivet-fdb-mf-rivet-fdb-1:/var/fdb"
      # Env is sorted, so the unit is stable across runs.
      assert unit =~ "Environment=FDB_PORT=4500\nEnvironment=FDB_PUBLIC_IP=10.89.100.11"
    end

    test "renders a read-only bind mount for host config delivered at start" do
      unit =
        Quadlet.render_unit(%{
          app: "mf-rivet-engine",
          name: "mf-rivet-engine",
          image: "rivet-fabric/engine:latest",
          network: "rivet-fabric",
          ip: "10.89.100.20",
          publish: [{6420, 6420}],
          mounts: [{"/home/u/.local/share/rivet-fabric/nodes/e/topology.json", "/etc/rivet/topology.json"}],
          env: %{
            "RIVET__FOUNDATIONDB__ADDRESSES" => "10.89.100.11:4500,10.89.100.12:4500",
            "RIVET__AUTH__ADMIN_TOKEN" => "local-dev-token"
          }
        })

      # SELinux relabel and read-only, so rootless podman on Fedora can read it
      # and the container cannot mutate host config.
      assert unit =~
               "Volume=/home/u/.local/share/rivet-fabric/nodes/e/topology.json:/etc/rivet/topology.json:ro,Z"

      assert unit =~ "PublishPort=6420:6420"

      # The engine is configured by coordinator addresses, not a mounted cluster
      # file. The engine writes its own cluster file from these at startup.
      assert unit =~ "Environment=RIVET__FOUNDATIONDB__ADDRESSES=10.89.100.11:4500,10.89.100.12:4500"
      refute unit =~ "RIVET__FOUNDATIONDB__CLUSTER_FILE="
    end
  end

  describe "node_state_dir/2" do
    test "is a host path under the rivet-fabric data dir, keyed by the unit name" do
      dir = Quadlet.node_state_dir("mf-rivet-engine", "mf-rivet-engine")
      assert String.ends_with?(dir, "rivet-fabric/nodes/mf-rivet-engine--mf-rivet-engine")
    end
  end
end

defmodule RivetFabric.Domain.Spec do
  @moduledoc """
  The cluster specification. Pure data.

  Versions are pinned rather than floating because two of them are coupled:
  the engine image embeds `libfdb_c.so`, and its version must be
  protocol-compatible with the `fdbserver` running in the FoundationDB nodes.
  Bumping one without the other fails at connect time.
  """

  def default do
    %{
      org: "personal",
      # sea is deprecated on Fly and rejects new volume provisioning.
      region: "sjc",
      network: "rivet-fabric",
      fdb: %{
        app: "mf-rivet-fdb",
        port: 4500,
        # 3 nodes is the minimum for `double` redundancy, tolerating one loss.
        # 1 node with `single` is the cheap smoke-test configuration.
        count: 3,
        storage: "ssd",
        cluster_description: "rivet",
        cluster_id: "rivet",
        volume_size_gb: 10,
        version: "7.3.76"
      },
      engine: %{
        app: "mf-rivet-engine",
        port: 6420,
        peer_port: 6421,
        # The FoundationDB backend is not in upstream Rivet. It lives on this
        # branch of the fork, pinned so the build is reproducible.
        rivet_repo: "https://github.com/v-sekai-multiplayer-fabric/rivet.git",
        rivet_ref: "a6cd747fcd49e9f28f9c8a0c622456e763e3d771"
      },
      godot: %{
        app: "mf-rivet-godot",
        runner_name: "godot-zone",
        actor_name: "game",
        # container-runner's default serverless base path.
        base_path: "/api/rivet",
        port: 8080,
        godot_version: "4.7.1-stable",
        mcp_repo: "https://github.com/v-sekai-multiplayer-fabric/vsekai-godot-mcp",
        mcp_commit: "580bb5fedc7c1bb56eb38b8377f918d9c5ffc998",
        request_lifespan: 900,
        drain_grace_period: 60,
        max_concurrent_actors: 4
      }
    }
  end

  @doc "Deep-merge overrides one level per section."
  def merge(overrides) do
    Map.merge(default(), overrides, fn
      _k, %{} = a, %{} = b -> Map.merge(a, b)
      _k, _a, b -> b
    end)
  end

  @doc "Node names for the FoundationDB app, stable and ordered."
  def fdb_nodes(spec) do
    for i <- 1..spec.fdb.count, do: "#{spec.fdb.app}-#{i}"
  end
end

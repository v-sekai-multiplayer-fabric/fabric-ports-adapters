defmodule RivetFabric.Domain.Spec do
  @moduledoc """
  The cluster specification. Pure data.

  Versions are pinned rather than floating because two of them are coupled: the
  engine image embeds `libfdb_c.so`, and its version must stay
  protocol-compatible with the `fdbserver` running in the FoundationDB nodes.
  Bumping one without the other fails at connect time.

  Node addresses are **static**. Podman assigns a fresh address on every
  restart, so any scheme that discovers addresses after creation is circular:
  the restart that applies a new cluster file also invalidates the addresses in
  it. Allocating addresses up front removes the problem instead of working
  around it.
  """

  def default do
    %{
      network: "rivet-fabric",
      # A dedicated subnet, so allocation is ours and does not collide with
      # podman's default 10.89.0.0/24 pool.
      subnet: "10.89.100.0/24",
      gateway: "10.89.100.1",
      # Node N gets host address ip_base + N.
      ip_prefix: "10.89.100.",
      ip_base: 10,
      fdb: %{
        app: "mf-rivet-fdb",
        port: 4500,
        # 3 nodes is the minimum for `double` redundancy, tolerating one loss.
        # 1 node with `single` is the cheap smoke-test configuration.
        count: 3,
        storage: "ssd",
        cluster_description: "rivet",
        cluster_id: "rivet",
        version: "7.3.76"
      },
      engine: %{
        app: "mf-rivet-engine",
        # Statically addressed for the same reason the FoundationDB nodes are.
        ip: "10.89.100.20",
        port: 6420,
        peer_port: 6421,
        admin_token: "local-dev-token",
        # The FoundationDB backend, WebTransport, and the datagram transport are
        # not in upstream Rivet. They live on the fork's webtransport-datagrams
        # branch, pinned at its HEAD so a build reproduces the engine that is
        # actually run.
        rivet_repo: "https://github.com/v-sekai-multiplayer-fabric/rivet.git",
        rivet_ref: "9d9e1b934d6385e771d8ecbe8c5c547673db88c2"
      },
      godot: %{
        app: "mf-rivet-godot",
        runner_name: "godot-zone",
        actor_name: "game",
        # container-runner's default serverless base path.
        base_path: "/api/rivet",
        port: 8080,
        # The fork's double-precision build, from
        # v-sekai-multiplayer-fabric/godot-images. Not interchangeable with an
        # upstream godotengine.org release: mixing precisions breaks networked
        # state between the zone and its clients. The package is private, so it
        # needs `podman login ghcr.io` or a local build from that repo.
        runtime_image: "ghcr.io/v-sekai-multiplayer-fabric/zone-godot-runtime",
        runtime_tag: "latest",
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

  @doc """
  Node names for the FoundationDB app, stable and ordered.

      iex> RivetFabric.Domain.Spec.fdb_nodes(RivetFabric.Domain.Spec.default())
      ["mf-rivet-fdb-1", "mf-rivet-fdb-2", "mf-rivet-fdb-3"]
  """
  def fdb_nodes(spec) do
    for i <- 1..spec.fdb.count, do: "#{spec.fdb.app}-#{i}"
  end

  @doc """
  Statically allocated address for node N, one-indexed.

      iex> RivetFabric.Domain.Spec.fdb_ip(RivetFabric.Domain.Spec.default(), 1)
      "10.89.100.11"
  """
  def fdb_ip(spec, index) do
    "#{spec.ip_prefix}#{spec.ip_base + index}"
  end

  @doc """
  Every FoundationDB node paired with its address, in order.

  Known before anything is created, which is what lets the coordinator set be
  supplied at node creation rather than discovered afterwards.
  """
  def fdb_plan(spec) do
    spec
    |> fdb_nodes()
    |> Enum.with_index(1)
    |> Enum.map(fn {name, i} -> {name, fdb_ip(spec, i)} end)
  end
end

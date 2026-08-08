defmodule RivetFabric.Ports.Substrate do
  @moduledoc """
  The substrate port.

  Everything the bootstrap needs from the outside world, in substrate-neutral
  terms, so the same sequence runs against systemd quadlets locally and Fly.io
  remotely.

  A **node** is one running instance with a stable name, an address its peers
  can reach, and optional persistent storage. That describes a podman container
  under quadlet and a machine on Fly equally well, and the domain logic does not
  know which it is talking to.

  This distinction is what makes FoundationDB testable at all: the cluster is
  addressed by IP, and the bootstrap has to read addresses back after creating
  nodes. Both substrates support that, so the tricky ordering can be exercised
  locally before it costs money.
  """

  @type app :: String.t()
  @type node_name :: String.t()

  @type node_spec :: %{
          required(:app) => app,
          required(:name) => node_name,
          required(:image) => String.t(),
          optional(:env) => %{String.t() => String.t()},
          optional(:volume) => {String.t(), String.t()} | nil,
          optional(:publish) => [{non_neg_integer(), non_neg_integer()}],
          optional(:command) => [String.t()],
          optional(:network) => String.t()
        }

  @type node_info :: %{name: node_name, address: String.t() | nil, state: atom()}

  @type image_spec :: %{
          required(:tag) => String.t(),
          required(:containerfile) => String.t(),
          required(:context) => String.t(),
          optional(:build_args) => %{String.t() => String.t()}
        }

  @doc "Create the shared network if it does not exist."
  @callback network_ensure(String.t()) :: :ok | {:error, term()}

  @doc "Build or pull an image, returning the tag other calls should reference."
  @callback image_ensure(image_spec) :: {:ok, String.t()} | {:error, term()}

  @doc "Create the node if absent and make sure it is running."
  @callback node_ensure(node_spec) :: :ok | {:error, term()}

  @doc "List nodes for an app, including the peer-reachable address of each."
  @callback node_list(app) :: {:ok, [node_info]} | {:error, term()}

  @doc "Run a command inside a node and return its stdout."
  @callback node_exec(app, node_name, [String.t()]) :: {:ok, String.t()} | {:error, term()}

  @doc """
  Write a file into a running node.

  Needed because the engine's topology cannot be supplied through environment
  variables. See `RivetFabric.Domain.Cluster.topology/1`.
  """
  @callback node_write_file(app, node_name, String.t(), String.t()) :: :ok | {:error, term()}

  @callback node_stop(app, node_name) :: :ok | {:error, term()}
  @callback node_destroy(app, node_name) :: :ok | {:error, term()}

  @doc """
  Commit pending declarative state.

  A no-op for imperative substrates. For quadlet this is the `systemctl
  daemon-reload` that makes newly written unit files visible.
  """
  @callback apply() :: :ok | {:error, term()}
end

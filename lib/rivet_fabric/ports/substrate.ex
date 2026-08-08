defmodule RivetFabric.Ports.Substrate do
  @moduledoc """
  The substrate port.

  Everything the bootstrap needs from the outside world, stated in terms of
  nodes rather than containers, so the sequence in `RivetFabric.Bootstrap` stays
  free of podman specifics and can be exercised against an in-memory fake.

  A **node** is one running instance with a stable name, a fixed address its
  peers can reach, and optional persistent storage. Under the quadlet adapter
  that is a podman container driven by a `.container` systemd unit.

  Addresses are assigned by the caller, not discovered, because podman gives a
  container a new address on every restart. See `RivetFabric.Bootstrap` for why
  that matters.
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
          optional(:network) => String.t(),
          optional(:ip) => String.t()
        }

  @type node_info :: %{name: node_name, address: String.t() | nil, state: atom()}

  @type image_spec :: %{
          required(:tag) => String.t(),
          required(:containerfile) => String.t(),
          required(:context) => String.t(),
          optional(:build_args) => %{String.t() => String.t()}
        }

  @doc """
  Create the shared network if absent, with a caller-chosen subnet.

  The subnet is explicit so node addresses can be allocated up front instead of
  discovered after the fact.
  """
  @callback network_ensure(String.t(), keyword()) :: :ok | {:error, term()}

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

  @doc """
  Restart a node from outside its PID namespace.

  Required because rewriting a config file is not enough: `fdbserver` reads the
  cluster file once at startup. Signalling PID 1 from *inside* the container
  does not work, since the kernel discards unhandled signals sent to PID 1 from
  within its own PID namespace, so the restart has to come from the substrate.
  """
  @callback node_restart(app, node_name) :: :ok | {:error, term()}

  @callback node_stop(app, node_name) :: :ok | {:error, term()}
  @callback node_destroy(app, node_name) :: :ok | {:error, term()}

  @doc """
  Commit pending declarative state.

  A no-op for imperative substrates. For quadlet this is the `systemctl
  daemon-reload` that makes newly written unit files visible.
  """
  @callback apply() :: :ok | {:error, term()}
end

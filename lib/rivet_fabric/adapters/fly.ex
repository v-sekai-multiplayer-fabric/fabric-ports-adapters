defmodule RivetFabric.Adapters.Fly do
  @moduledoc """
  Substrate adapter backed by flyctl.

  Kept deliberately close to the quadlet adapter so the bootstrap sequence in
  `RivetFabric.Bootstrap` is identical on both. Where Fly differs, the
  difference is confined here:

  * Nodes are machines within an app, so `app` maps to a Fly app and node names
    are tracked through machine metadata.
  * Addresses are IPv6 6PN, which the domain already brackets.
  * Machines keep their 6PN address for their lifetime, so destroying and
    recreating one invalidates the coordinator set. Scale by cloning.
  """

  @behaviour RivetFabric.Ports.Substrate

  alias RivetFabric.Shell

  @impl true
  def network_ensure(_net), do: :ok

  @impl true
  def image_ensure(%{tag: tag}), do: {:ok, tag}

  @impl true
  def node_ensure(spec) do
    app = spec.app
    ensure_app(app)

    env_args =
      spec
      |> Map.get(:env, %{})
      |> Enum.sort()
      |> Enum.flat_map(fn {k, v} -> ["--env", "#{k}=#{v}"] end)

    args =
      ["machine", "run", spec.image, "--app", app, "--name", spec.name] ++
        env_args ++
        case Map.get(spec, :volume) do
          {vol, mount} -> ["--volume", "#{vol}:#{mount}"]
          _ -> []
        end

    case Shell.run("flyctl", args, timeout: :timer.minutes(15)) do
      {_, 0} -> :ok
      {out, code} -> {:error, "machine run failed (#{code}): #{out}"}
    end
  end

  defp ensure_app(app) do
    case Shell.run("flyctl", ["status", "--app", app], log: false) do
      {_, 0} ->
        :ok

      _ ->
        case Shell.run("flyctl", ["apps", "create", app]) do
          {_, 0} -> :ok
          {out, code} -> {:error, "apps create failed (#{code}): #{out}"}
        end
    end
  end

  @impl true
  def node_list(app) do
    case Shell.run("flyctl", ["machine", "list", "--app", app, "--json"], log: false) do
      {out, 0} ->
        nodes =
          out
          |> JSON.decode!()
          |> Enum.map(fn m ->
            %{
              name: m["name"],
              address: m["private_ip"],
              state: normalize_state(m["state"])
            }
          end)
          |> Enum.sort_by(& &1.name)

        {:ok, nodes}

      {out, code} ->
        {:error, "machine list failed (#{code}): #{out}"}
    end
  rescue
    e -> {:error, "could not parse machine list: #{inspect(e)}"}
  end

  defp normalize_state("started"), do: :started
  defp normalize_state("stopped"), do: :stopped
  defp normalize_state(other), do: String.to_atom(to_string(other))

  defp machine_id(app, name) do
    with {:ok, _} <- {:ok, nil},
         {out, 0} <- Shell.run("flyctl", ["machine", "list", "--app", app, "--json"], log: false) do
      out
      |> JSON.decode!()
      |> Enum.find(&(&1["name"] == name))
      |> case do
        nil -> {:error, "no machine named #{name} in #{app}"}
        m -> {:ok, m["id"]}
      end
    else
      {out, code} -> {:error, "machine list failed (#{code}): #{out}"}
    end
  end

  @impl true
  def node_exec(app, name, argv) do
    with {:ok, id} <- machine_id(app, name) do
      command = Enum.join(argv, " ")

      case Shell.run(
             "flyctl",
             ["ssh", "console", "--app", app, "--machine", id, "--command", command],
             timeout: :timer.minutes(5)
           ) do
        {out, 0} -> {:ok, out}
        {out, code} -> {:error, "ssh exec failed (#{code}): #{out}"}
      end
    end
  end

  @impl true
  def node_write_file(app, name, guest_path, content) do
    # A [[files]] block in fly.toml does not apply on deploy; --file-literal on
    # a machine update does. This is how the engine topology gets in place.
    with {:ok, id} <- machine_id(app, name) do
      case Shell.run(
             "flyctl",
             [
               "machine",
               "update",
               id,
               "--app",
               app,
               "--file-literal",
               "#{guest_path}=#{content}",
               "--yes"
             ],
             timeout: :timer.minutes(10)
           ) do
        {_, 0} -> :ok
        {out, code} -> {:error, "file-literal update failed (#{code}): #{out}"}
      end
    end
  end

  @impl true
  def node_stop(app, name) do
    with {:ok, id} <- machine_id(app, name) do
      case Shell.run("flyctl", ["machine", "stop", id, "--app", app]) do
        {_, 0} -> :ok
        {out, code} -> {:error, "stop failed (#{code}): #{out}"}
      end
    end
  end

  @impl true
  def node_destroy(app, name) do
    with {:ok, id} <- machine_id(app, name) do
      case Shell.run("flyctl", ["machine", "destroy", id, "--app", app, "--force"]) do
        {_, 0} -> :ok
        {out, code} -> {:error, "destroy failed (#{code}): #{out}"}
      end
    end
  end

  @impl true
  def apply, do: :ok
end

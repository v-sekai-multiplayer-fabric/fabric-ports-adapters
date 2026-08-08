defmodule RivetFabric.CLI do
  @moduledoc """
  Entry point.

      mix run -e 'RivetFabric.CLI.main(["fdb-up"])'
      ./rivet_fabric fdb-up            # after `mix escript.build`

  The only substrate is podman + systemd quadlets.
  """

  alias RivetFabric.Quadlet
  alias RivetFabric.{Bootstrap, Shell}
  alias RivetFabric.Domain.Spec

  @assets Path.expand("../../assets", __DIR__)

  def main(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [count: :integer])

    spec = build_spec(opts)

    case args do
      ["fdb-up"] -> fdb_up(spec)
      ["fdb-status"] -> fdb_status(spec)
      ["build"] -> build_images(spec)
      ["destroy"] -> destroy(spec)
      ["doctor"] -> doctor()
      _ -> usage()
    end
  end

  defp build_spec(opts) do
    spec = Spec.merge(%{})

    case Keyword.get(opts, :count) do
      nil -> spec
      n -> put_in(spec, [:fdb, :count], n)
    end
  end

  defp fdb_up(spec) do
    image =
      case build_fdb_image(spec) do
        {:ok, image} ->
          image

        {:error, reason} ->
          IO.puts(:stderr, "image build failed: #{reason}")
          System.halt(1)
      end

    case Bootstrap.foundationdb(spec, image) do
      {:ok, coordinators} ->
        IO.puts("\ncoordinators: #{coordinators}")
        node = hd(Spec.fdb_nodes(spec))

        case Bootstrap.await_available(spec.fdb.app, node) do
          {:ok, out} ->
            IO.puts(out)

          {:error, reason} ->
            IO.puts(:stderr, "cluster came up but never became available: #{reason}")
            System.halt(1)
        end

      {:error, reason} ->
        IO.puts(:stderr, "\nbootstrap failed: #{reason}")
        System.halt(1)
    end
  end

  defp build_fdb_image(spec) do
    Quadlet.image_ensure(%{
      tag: "rivet-fabric/foundationdb:#{spec.fdb.version}",
      containerfile: Path.join([@assets, "foundationdb", "Containerfile"]),
      context: Path.join(@assets, "foundationdb"),
      build_args: %{"FDB_VERSION" => spec.fdb.version}
    })
  end

  defp build_images(spec) do
    case build_fdb_image(spec) do
      {:ok, tag} ->
        IO.puts("built #{tag}")

      {:error, reason} ->
        IO.puts(:stderr, "image build failed: #{reason}")
        System.halt(1)
    end

    IO.puts("""

    The engine and godot-zone images compile Rust from source and take a long
    time. Build them explicitly when you want them:

      podman build -t rivet-fabric/engine \\
        --build-arg RIVET_REF=#{spec.engine.rivet_ref} \\
        -f assets/engine/Containerfile assets/engine

      podman build -t rivet-fabric/godot-zone \\
        --build-arg RIVET_REF=#{spec.engine.rivet_ref} \\
        -f assets/godot_zone/Containerfile assets/godot_zone
    """)
  end

  defp fdb_status(spec) do
    node = hd(Spec.fdb_nodes(spec))

    case Bootstrap.status(spec.fdb.app, node) do
      {:ok, out} -> IO.puts(String.trim(out))
      {:error, reason} -> IO.puts(:stderr, "status failed: #{reason}")
    end
  end

  defp destroy(spec) do
    :ok = Bootstrap.destroy(spec)
    IO.puts("destroyed")
  end

  defp doctor() do
    check("podman", Shell.available?("podman"))
    check("systemctl", Shell.available?("systemctl"))

    generator = "/usr/lib/systemd/user-generators/podman-user-generator"
    check("quadlet user generator", File.exists?(generator))

    {out, _} = Shell.run("systemctl", ["--user", "is-system-running"], log: false)
    IO.puts("  user systemd: #{String.trim(out)}")
    IO.puts("  unit dir:     #{Quadlet.unit_dir()}")
  end

  defp check(label, true), do: IO.puts("  ok      #{label}")
  defp check(label, false), do: IO.puts("  MISSING #{label}")

  defp usage do
    IO.puts("""
    rivet-fabric-ports-adapters

      fdb-up        bring up the FoundationDB cluster
      fdb-status    fdbcli status minimal
      build         build the FoundationDB image
      destroy       tear every node down
      doctor        check the substrate prerequisites

    options
      --count N     FoundationDB node count (default 3)
    """)
  end
end

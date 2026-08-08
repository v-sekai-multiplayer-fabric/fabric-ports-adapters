defmodule RivetFabric.MixProject do
  use Mix.Project

  def project do
    [
      app: :rivet_fabric,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: RivetFabric.CLI],
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :inets, :ssl, :public_key]]
  end

  # No external dependencies on purpose. This is a bootstrap tool that has to
  # run before anything else exists, so it uses only OTP: :json for encoding,
  # :httpc for the engine API, and System.cmd/3 for the substrate CLIs.
  defp deps, do: []
end

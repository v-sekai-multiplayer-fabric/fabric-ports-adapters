defmodule RivetFabric.Shell do
  @moduledoc """
  Process execution, isolated so adapters stay thin and tests never shell out.

  stderr is merged into stdout because every CLI this drives reports its real
  diagnostics there.
  """

  require Logger

  @doc """
  Run a command. Returns `{combined_output, exit_status}`.

  Never raises on a non-zero exit; callers decide what a failure means.
  """
  def run(cmd, args, opts \\ []) do
    if Keyword.get(opts, :log, true) do
      Logger.debug("$ #{cmd} #{Enum.join(args, " ")}")
    end

    task =
      Task.async(fn ->
        System.cmd(cmd, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, Keyword.get(opts, :timeout, :timer.minutes(10))) ||
           Task.shutdown(task, :brutal_kill) do
      {:ok, {out, code}} -> {out, code}
      nil -> {"timed out running #{cmd}", 124}
    end
  rescue
    e in ErlangError ->
      {"failed to run #{cmd}: #{inspect(e)}", 127}
  end

  @doc "Run a command, raising with the captured output when it fails."
  def run!(cmd, args, opts \\ []) do
    case run(cmd, args, opts) do
      {out, 0} -> out
      {out, code} -> raise "#{cmd} exited #{code}:\n#{out}"
    end
  end

  @doc "Whether an executable is on PATH."
  def available?(cmd), do: System.find_executable(cmd) != nil
end

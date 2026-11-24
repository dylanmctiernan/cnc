defmodule CNC.Controllers.Config do
  @moduledoc """
  A connected controller's configuration, which lives on the controller.

  FluidNC keeps config files (YAML) on its local filesystem and loads one at
  boot, named by `$Config/Filename`. Several can sit side by side (a
  baseline, a variation you're trying), and switching is choosing another
  file and restarting. What's running can differ from the file once settings
  are changed live; `save_running_as/2` writes it out.

  Everything goes through `CNC.Machine.request/3`, so it needs the machine
  connected and `:idle` or `:alarm`.
  """

  alias CNC.Machine

  @type file :: %{name: String.t(), size: non_neg_integer}

  @doc "The config files on the controller and the one it loads at boot."
  @spec files(GenServer.server()) ::
          {:ok, %{files: [file], active: String.t() | nil}} | {:error, term}
  def files(machine) do
    with {:ok, listing} <- Machine.request(machine, "$LocalFS/List"),
         {:ok, chosen} <- Machine.request(machine, "$Config/Filename") do
      files = listing |> parse_files() |> Enum.sort_by(&String.downcase(&1.name))
      {:ok, %{files: files, active: parse_filename(chosen)}}
    end
  end

  @doc "A config file's text."
  @spec show(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term}
  def show(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, lines} <- Machine.request(machine, "$LocalFS/Show=" <> name) do
      {:ok, text(lines)}
    else
      {:error, 66} -> {:error, :not_found}
      other -> other
    end
  end

  @doc "The configuration the controller is running now (`$CD`)."
  @spec running(GenServer.server()) :: {:ok, String.t()} | {:error, term}
  def running(machine) do
    with {:ok, lines} <- Machine.request(machine, "$CD"), do: {:ok, text(lines)}
  end

  @doc """
  Write the running configuration to a file on the controller (`$CD=`):
  how to copy a config, or keep changes made live.
  """
  @spec save_running_as(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, term}
  def save_running_as(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, _} <- Machine.request(machine, "$CD=" <> name),
         do: {:ok, name}
  end

  @doc """
  Load a different config file: chosen for boot, then the controller
  restarts (it comes back locked, like any reconnect). Only a file that's on
  the controller: FluidNC doesn't check, and would boot with nothing.
  """
  @spec activate(GenServer.server(), String.t()) :: :ok | {:error, term}
  def activate(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, %{files: files}} <- files(machine),
         true <- Enum.any?(files, &(&1.name == name)) || {:error, :not_found},
         {:ok, _} <- Machine.request(machine, "$Config/Filename=" <> name),
         {:ok, _} <- Machine.request(machine, "$Bye") do
      :ok
    else
      # The restart can cut the link before its ok arrives
      {:error, :reset} -> :ok
      other -> other
    end
  end

  @doc "Delete a config file (not the one loaded at boot)."
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, term}
  def delete(machine, name) do
    with {:ok, name} <- valid_name(name),
         {:ok, %{active: active}} <- files(machine),
         false <- name == active && {:error, :active},
         {:ok, _} <- Machine.request(machine, "$LocalFS/Delete=" <> name),
         do: :ok
  end

  @doc """
  A config file name: letters, digits, `-`, `_`, `.`, ending in `.yaml`
  (added when there's no extension).

      iex> CNC.Controllers.Config.valid_name("fast accel")
      {:error, :invalid_name}
      iex> CNC.Controllers.Config.valid_name("fast-accel")
      {:ok, "fast-accel.yaml"}
  """
  @spec valid_name(String.t()) :: {:ok, String.t()} | {:error, :invalid_name}
  def valid_name(name) when is_binary(name) do
    name = String.trim(name)
    name = if Regex.match?(~r/\.ya?ml\z/i, name), do: name, else: name <> ".yaml"

    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,40}\.ya?ml\z/i, name),
      do: {:ok, name},
      else: {:error, :invalid_name}
  end

  def valid_name(_), do: {:error, :invalid_name}

  # "[FILE: config.yaml|SIZE:2212]" (other files and directories are skipped)
  defp parse_files(lines) do
    for line <- lines,
        [_, name, size] <- [Regex.run(~r/^\[FILE:\s*(.+?)\|SIZE:(\d+)\]$/, line)],
        Regex.match?(~r/\.ya?ml\z/i, name),
        do: %{name: name, size: String.to_integer(size)}
  end

  defp parse_filename(lines) do
    Enum.find_value(lines, fn
      "$Config/Filename=" <> name -> String.trim(name)
      _ -> nil
    end)
  end

  defp text(lines), do: Enum.join(lines, "\n") <> "\n"
end

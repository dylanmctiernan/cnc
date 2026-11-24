defmodule CNCApp.FluidNCSource do
  @moduledoc """
  Shared by the `cnc.fluidnc.*` tasks: the pinned FluidNC source and its
  PlatformIO toolchain, kept in `.fluidnc/` (git-ignored).

  Stock FluidNC, one pinned commit for both the sim and the board, so what
  runs in dev is what runs on the controller. PlatformIO (FluidNC's build
  tool, Python) is installed into `.fluidnc/venv`, not system-wide.
  """
  @commit "97dfddceb95b499b06c0ad87297ea0b4f9cec662"
  @platformio "6.2.0"
  @repo "https://github.com/bdring/FluidNC.git"

  def commit, do: @commit
  def short_commit, do: String.slice(@commit, 0, 7)
  def work_dir, do: Path.expand(".fluidnc")
  def src_dir, do: Path.join(work_dir(), "src")
  def bin_path, do: Path.join([work_dir(), "bin", "fluidnc"])

  @doc "Check out the pinned commit (clean) and make sure PlatformIO is installed."
  def checkout! do
    src = src_dir()
    File.mkdir_p!(Path.dirname(bin_path()))

    unless File.dir?(Path.join(src, ".git")),
      do: cmd!("git", ["clone", "--quiet", @repo, src])

    # Fetching a single commit needs server support; fall back to everything.
    if cmd("git", ["-C", src, "fetch", "--quiet", "origin", @commit]) != 0,
      do: cmd!("git", ["-C", src, "fetch", "--quiet", "origin"])

    cmd!("git", ["-C", src, "checkout", "--quiet", "--force", @commit])
    cmd!("git", ["-C", src, "clean", "--quiet", "-fd", "-e", ".pio"])
    ensure_platformio!()
  end

  @doc "Run PlatformIO in the FluidNC source tree, streaming its output."
  def pio!(args), do: cmd!(pio_path(), args, cd: src_dir())

  defp ensure_platformio! do
    unless File.exists?(pio_path()) do
      python = System.find_executable("python3") || Mix.raise("python3 is needed for PlatformIO")
      venv = Path.join(work_dir(), "venv")
      cmd!(python, ["-m", "venv", venv])
      cmd!(Path.join([venv, "bin", "pip"]), ["install", "--quiet", "platformio==#{@platformio}"])
    end
  end

  defp pio_path, do: Path.join([work_dir(), "venv", "bin", "pio"])

  defp cmd(exe, args, opts \\ []) do
    exe = System.find_executable(exe) || exe
    {_, status} = System.cmd(exe, args, [into: IO.stream(), stderr_to_stdout: true] ++ opts)
    status
  end

  defp cmd!(exe, args, opts \\ []) do
    case cmd(exe, args, opts) do
      0 -> :ok
      status -> Mix.raise("#{Path.basename(exe)} #{Enum.join(args, " ")} failed (exit #{status})")
    end
  end
end

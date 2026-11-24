defmodule CNCWeb.Shell do
  @moduledoc """
  The workstation shell's live part, mounted on every page in it: keeps
  `@shell_machine` (the machine's state, for the rail's status and Stop)
  current and handles the rail's Stop (`"shell:stop"`). Pages in the shell
  get `{:machine, state}` as before, from this subscription, and don't
  subscribe to the machine themselves.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias CNC.Machine

  def on_mount(:default, _params, session, socket) do
    cnc = CNCWeb.Instance.from_session(session)
    if connected?(socket), do: Machine.subscribe(cnc.topic)

    socket =
      socket
      |> assign(:shell_machine, Machine.status(cnc.machine))
      |> attach_hook(:shell_machine, :handle_info, fn
        {:machine, state}, socket -> {:cont, assign(socket, :shell_machine, state)}
        _other, socket -> {:cont, socket}
      end)
      |> attach_hook(:shell_stop, :handle_event, fn
        "shell:stop", _params, socket ->
          Machine.jog_stop(cnc.machine)
          Machine.feed_hold(cnc.machine)
          {:halt, socket}

        _event, _params, socket ->
          {:cont, socket}
      end)

    {:cont, socket}
  end
end

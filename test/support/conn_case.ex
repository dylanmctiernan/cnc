defmodule CNCWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CNCWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CNCWeb.Endpoint

      use CNCWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CNCWeb.ConnCase
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc """
  Start a private machine (fake sim) and program store for one test and put
  them in the conn's session, so the screens drive these instead of the
  app's (see `CNCWeb.Instance`). Screen tests can then run in parallel.
  Returns `{conn, machine, program}`; the machine boots locked.
  """
  def with_instance(conn, sim_opts \\ []) do
    id = System.unique_integer([:positive])
    machine = :"machine_test_#{id}"
    program = :"program_test_#{id}"
    topic = "machine-test-#{id}"
    program_topic = "program-test-#{id}"

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec(
        {CNC.Machine, name: machine, topic: topic, link: {CNC.Link.FakeSim, sim_opts}},
        id: machine
      )
    )

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({CNC.Program, name: program, topic: program_topic}, id: program)
    )

    instance = %CNCWeb.Instance{
      machine: machine,
      topic: topic,
      program: program,
      program_topic: program_topic
    }

    {Plug.Test.init_test_session(conn, %{"cnc_instance" => instance}), machine, program}
  end
end

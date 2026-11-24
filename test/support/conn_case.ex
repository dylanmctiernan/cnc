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
  Start a private machine, program store and controllers for one test and
  put them in the conn's session, so the screens drive these instead of the
  app's (see `CNCWeb.Instance`). Screen tests can then run in parallel. The
  controllers hold just a fake sim, active, which they connect the machine
  to (the same path as the app). Returns `{conn, machine, program}`; the
  machine boots locked.
  """
  def with_instance(conn) do
    id = System.unique_integer([:positive])
    machine = :"machine_test_#{id}"
    program = :"program_test_#{id}"
    topic = "machine-test-#{id}"
    program_topic = "program-test-#{id}"
    controllers = :"controllers_test_#{id}"
    controllers_topic = "controllers-test-#{id}"
    data_dir = Path.join(System.tmp_dir!(), "cnc-test-#{id}")
    File.rm_rf!(data_dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(data_dir) end)

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({CNC.Machine, name: machine, topic: topic, link: nil}, id: machine)
    )

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec(
        {CNC.Controllers,
         name: controllers,
         topic: controllers_topic,
         data_dir: data_dir,
         machine: machine,
         overridden?: false,
         seed: :fake_only},
        id: controllers
      )
    )

    ExUnit.Callbacks.start_supervised!(
      Supervisor.child_spec({CNC.Program, name: program, topic: program_topic}, id: program)
    )

    instance = %CNCWeb.Instance{
      machine: machine,
      topic: topic,
      program: program,
      program_topic: program_topic,
      controllers: controllers,
      controllers_topic: controllers_topic
    }

    {Plug.Test.init_test_session(conn, %{"cnc_instance" => instance}), machine, program}
  end
end

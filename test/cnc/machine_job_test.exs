defmodule CNC.Machine.JobTest do
  use CNC.MachineCase, async: true

  alias CNC.Machine.Job

  # A square at Z-1, then back up (the fake sim's Z travel is -100..0, so
  # "up" is Z0): quick at the fake sim's feeds.
  @square """
  (square)
  G21 G90
  G0 Z0
  G0 X0 Y0
  G1 Z-1 F600
  G1 X10 F3000
  G1 Y10
  G1 X0
  G1 Y0
  G0 Z0
  M30
  """

  describe "Job (pure)" do
    test "cleans lines: comments, spaces, blanks and % go; line numbers stay" do
      {:ok, job} = Job.new("a.nc", "%\n(head)\nG0 X1 ; rapid\n\n  g1 y2 f100 (feed)\n%")
      assert :queue.to_list(job.queue) == [{3, "G0X1"}, {5, "g1y2f100"}]
      assert {:error, :empty} = Job.new("b.nc", "(nothing)\n\n")

      assert {:error, {:line_too_long, 2}} =
               Job.new("c.nc", "G0 X1\n" <> String.duplicate("X1", 50))
    end

    test "never more than 127 bytes unacked; each ok frees its line" do
      lines = for i <- 1..40, do: "G1X#{i}.12345Y#{i}.12345F1000"
      {:ok, job} = Job.new("big.nc", Enum.join(lines, "\n"))

      {sent, job} = take_all(job, [])
      assert job.bytes <= 127
      assert Enum.sum(for {_, t} <- sent, do: byte_size(t) + 1) == job.bytes

      job = Job.ack(job, :ok)
      assert {:send, _, _} = Job.next(job)
    end

    test "an error halts the stream" do
      {:ok, job} = Job.new("e.nc", "G1 X1\nG1 X2\n")
      {:send, _, job} = Job.next(job)
      job = Job.ack(job, {:error, 22})
      assert job.halted? and job.error == {22, 1, "G1X1"}
      assert Job.next(job) == :wait
      assert Job.drained?(job)
    end
  end

  describe "running a file (FakeSim)" do
    setup do
      m = start_machine({CNC.Link.FakeSim, homing_ms: 50}, "job-#{System.unique_integer()}")
      assert eventually(fn -> Machine.status(m).state == :alarm end)
      :ok = Machine.unlock(m)
      assert eventually(fn -> Machine.status(m).state == :idle end)
      %{m: m}
    end

    test "runs to the end and lands Ready; the outcome is kept", %{m: m} do
      assert :ok = Machine.run(m, "square.nc", @square)
      assert %State{state: :running, job: %{name: "square.nc", total: 10}} = Machine.status(m)

      assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
      %State{job: nil, last_job: last, mpos: {x, y, z}} = Machine.status(m)
      assert %{result: :done, acked: 10, total: 10} = last
      assert_in_delta x, 0.0, 1.0e-6
      assert_in_delta y, 0.0, 1.0e-6
      assert_in_delta z, 0.0, 1.0e-6
    end

    test "only from Ready; nothing else that sends lines while running", %{m: m} do
      :ok = Machine.run(m, "square.nc", @square)
      assert {:error, {:invalid_state, :running}} = Machine.run(m, "again.nc", @square)
      assert {:error, {:invalid_state, :running}} = Machine.jog(m, {1, 0}, :normal)
      assert {:error, {:invalid_state, :running}} = Machine.send_raw(m, "G0 X100")
      assert {:error, {:invalid_state, :running}} = Machine.set_work_zero(m, [:x])
    end

    test "Hold pauses inside the job, Resume carries on", %{m: m} do
      :ok = Machine.run(m, "square.nc", @square)
      assert eventually(fn -> Machine.status(m).controller == :run end)

      :ok = Machine.feed_hold(m)
      assert eventually(fn -> Machine.status(m).controller == :hold end)
      %State{state: :running, mpos: held} = Machine.status(m)
      Process.sleep(100)
      assert %State{state: :running, mpos: ^held} = Machine.status(m)

      :ok = Machine.resume(m)
      assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
      assert %{result: :done} = Machine.status(m).last_job
    end

    test "Abort stops it and the machine comes back locked", %{m: m} do
      :ok = Machine.run(m, "square.nc", @square)
      assert eventually(fn -> Machine.status(m).controller == :run end)

      :ok = Machine.abort(m)
      assert eventually(fn -> Machine.status(m).state == :alarm end)
      assert %{result: :aborted} = Machine.status(m).last_job
      assert {:error, {:invalid_state, :alarm}} = Machine.abort(m)
    end

    test "an error stops the stream and holds; Resume finishes what was sent", %{m: m} do
      # No feed rate before the first G1: error:22 on line 2
      :ok = Machine.run(m, "nofeed.nc", "G0 X5\nG1 X10\nG1 X20 F500\n")
      assert eventually(fn -> Machine.status(m).job && Machine.status(m).job.halted? end)
      %State{job: %{error: {22, 2, "G1X10"}}, last_error: {:error, 22}} = Machine.status(m)

      :ok = Machine.resume(m)
      assert eventually(fn -> Machine.status(m).state == :idle end, 10_000)
      assert %{result: :error, error: {22, 2, _}} = Machine.status(m).last_job
    end

    test "feed override goes out at once and is reported", %{m: m} do
      :ok = Machine.feed_override(m, :plus10)
      assert eventually(fn -> Machine.status(m).overrides == {110, 100, 100} end)
      :ok = Machine.feed_override(m, :reset)
      assert eventually(fn -> Machine.status(m).overrides == {100, 100, 100} end)
    end
  end

  defp take_all(job, acc) do
    case Job.next(job) do
      {:send, line, job} -> take_all(job, [line | acc])
      :wait -> {Enum.reverse(acc), job}
    end
  end
end

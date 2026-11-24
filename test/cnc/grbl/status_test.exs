defmodule CNC.Grbl.StatusTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias CNC.Grbl.{Response, Status}

  test "encode emits MPos, FS and optional WCO/Bf" do
    status = %Status{state: :hold, substate: 0, mpos: {1.5, -2, 0}, feed: 300, buffer: {15, 128}}

    assert Status.encode(status) == "<Hold:0|MPos:1.500,-2.000,0.000|FS:300,0|Bf:15,128>"
  end

  describe "with_wco/2" do
    test "fills a missing offset and derives the work position" do
      s = %Status{state: :idle, mpos: {10.0, 20.0, -5.0}}

      assert %Status{wco: {1.0, 2.0, -1.0}, wpos: {9.0, 18.0, -4.0}} =
               Status.with_wco(s, {1.0, 2.0, -1.0})
    end

    test "derives machine position when the report gave work position" do
      s = %Status{state: :idle, wpos: {9.0, 18.0, -4.0}}
      assert %Status{mpos: {10.0, 20.0, -5.0}} = Status.with_wco(s, {1.0, 2.0, -1.0})
    end

    test "a report with its own offset wins; nothing to carry is a no-op" do
      s = %Status{state: :idle, mpos: {0.0, 0.0, 0.0}, wco: {5.0, 5.0, 5.0}}
      assert Status.with_wco(s, {1.0, 1.0, 1.0}) == s
      assert Status.with_wco(%Status{state: :idle}, nil) == %Status{state: :idle}
    end
  end

  property "encode then parse round-trips" do
    check all status <- status() do
      assert {:status, parsed} = Response.parse(Status.encode(status))
      assert parsed == expected(status)
    end
  end

  defp status do
    gen all state <- member_of(~w(idle run hold jog alarm door check home sleep tool)a),
            substate <- substate(state),
            mpos <- xyz(),
            wco <- one_of([constant(nil), xyz()]),
            feed <- integer(0..6000),
            spindle <- integer(0..24_000),
            buffer <- one_of([constant(nil), tuple({integer(0..35), integer(0..1023)})]) do
      %Status{
        state: state,
        substate: substate,
        mpos: mpos,
        wco: wco,
        feed: feed / 1,
        spindle: spindle / 1,
        buffer: buffer
      }
    end
  end

  defp substate(state) when state in [:hold, :door], do: one_of([constant(nil), integer(0..3)])
  defp substate(_), do: constant(nil)

  # Exact at 3 decimals: thousandths of a mm.
  defp xyz, do: tuple({mm(), mm(), mm()})
  defp mm, do: map(integer(-1_250_000..1_250_000), &(&1 / 1000))

  # wpos is derived on parse when WCO is present.
  defp expected(%Status{wco: nil} = s), do: s

  defp expected(%Status{mpos: {a, b, c}, wco: {x, y, z}} = s),
    do: %{s | wpos: {a - x, b - y, c - z}}
end

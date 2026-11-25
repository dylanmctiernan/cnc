defmodule CNCApp.BitTest do
  use ExUnit.Case, async: true
  doctest CNCApp.Bit

  alias CNCApp.Bit

  setup do
    db = :"bit_db_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "#{db}")
    start_supervised!({CubDB, data_dir: dir, name: db})
    on_exit(fn -> File.rm_rf(dir) end)
    %{db: db}
  end

  test "none until set; set, heard, kept; cleared", %{db: db} do
    assert Bit.get(db) == nil
    Bit.subscribe(db)

    assert {:ok, bit} = Bit.put(db, %{diameter: 6.35, kind: :flat})
    assert bit == %{diameter: 6.35, kind: :flat, angle: nil}
    assert_receive {:bit, ^bit}
    assert Bit.get(db) == bit

    # A V-bit keeps its angle; others drop one
    assert {:ok, %{angle: 90}} = Bit.put(db, %{diameter: 12, kind: :v, angle: 90})
    assert {:ok, %{angle: nil}} = Bit.put(db, %{diameter: 3.175, kind: :ball, angle: 60})

    assert :ok = Bit.clear(db)
    assert_receive {:bit, nil}
    assert Bit.get(db) == nil
  end

  test "a size it can be, a kind it knows, a V-bit's angle", %{db: db} do
    for bad <- [
          %{diameter: 0, kind: :flat},
          %{diameter: 101, kind: :flat},
          %{diameter: "6", kind: :flat},
          %{diameter: 6, kind: :drill},
          %{diameter: 6, kind: :v},
          %{diameter: 6, kind: :v, angle: 45}
        ] do
      assert Bit.put(db, bad) == {:error, :invalid}
    end
  end

  test "with a bit, stock edges are checked where the cutter reaches" do
    stock = %{width: 100.0, depth: 50.0, thickness: 12.0, zero: :front_left}
    # An outside profile around the whole stock with a 6 mm bit: the path
    # runs 3 mm outside every edge, the cutter 6 mm
    path = {{-3.0, 103.0}, {-3.0, 53.0}, {-12.0, 0.0}}
    assert [{:edge, :left, 3.0} | _] = CNCApp.Stock.issues(path, stock)

    assert [{:edge, :left, 6.0}, {:edge, :right, 6.0}, {:edge, :front, 6.0}, {:edge, :back, 6.0}] =
             CNCApp.Stock.issues(path, stock, Bit.radius(%{diameter: 6.0}))

    # A pocket well inside: the cutter's reach doesn't matter
    assert CNCApp.Stock.issues({{20.0, 80.0}, {10.0, 40.0}, {-5.0, 0.0}}, stock, 3.0) == []
  end
end

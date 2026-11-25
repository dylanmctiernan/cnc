defmodule CNCApp.StockTest do
  use ExUnit.Case, async: true
  doctest CNCApp.Stock

  alias CNCApp.Stock

  setup do
    db = :"stock_db_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), "#{db}")
    start_supervised!({CubDB, data_dir: dir, name: db})
    on_exit(fn -> File.rm_rf(dir) end)
    %{db: db}
  end

  test "none until set; set, heard, kept; cleared", %{db: db} do
    assert Stock.get(db) == nil
    Stock.subscribe(db)

    assert {:ok, stock} =
             Stock.put(db, %{width: 300, depth: 200, thickness: 18, zero: :front_left})

    assert stock == %{width: 300.0, depth: 200.0, thickness: 18.0, zero: :front_left}
    assert_receive {:stock, ^stock}
    assert Stock.get(db) == stock

    assert :ok = Stock.clear(db)
    assert_receive {:stock, nil}
    assert Stock.get(db) == nil
  end

  test "sizes must be positive numbers; the zero one it knows", %{db: db} do
    for bad <- [
          %{width: 0, depth: 200, thickness: 18, zero: :front_left},
          %{width: 300, depth: -1, thickness: 18, zero: :front_left},
          %{width: 300, depth: 200, thickness: "18", zero: :front_left},
          %{width: 300, depth: 200, thickness: 18, zero: :back_right},
          %{width: 300, depth: 200}
        ] do
      assert Stock.put(db, bad) == {:error, :invalid}
    end

    assert Stock.get(db) == nil
  end

  describe "issues: where the cuts leave the stock" do
    @stock %{width: 100.0, depth: 50.0, thickness: 12.0, zero: :front_left}

    test "on it: none (and nothing to check without a stock or cuts)" do
      assert Stock.issues({{0.0, 100.0}, {0.0, 50.0}, {-12.0, 0.0}}, @stock) == []
      assert Stock.issues({{0.0, 100.0}, {0.0, 50.0}, {-12.0, 0.0}}, nil) == []
      assert Stock.issues(nil, @stock) == []
    end

    test "past an edge, by how much; deeper than it's thick" do
      assert Stock.issues({{-3.175, 103.175}, {0.0, 50.0}, {-12.3, 0.0}}, @stock) == [
               {:edge, :left, 3.175},
               {:edge, :right, 3.1749999999999972},
               {:through, 0.3000000000000007}
             ]
    end

    test "from the centre: the stock spans both sides of zero" do
      centred = %{@stock | zero: :center}
      assert Stock.issues({{-50.0, 50.0}, {-25.0, 25.0}, {-5.0, 0.0}}, centred) == []

      assert [{:edge, :back, 5.0}] =
               Stock.issues({{-50.0, 50.0}, {-25.0, 30.0}, {-5.0, 0.0}}, centred)
    end
  end
end

defmodule CNC.Machine.UploadTest do
  use CNC.MachineCase, async: true

  alias CNC.Grbl.XModem

  doctest XModem

  test "XModem blocks: 1K, numbered, CRC, the last padded with Ctrl-Z" do
    data = :binary.copy("a", 1500)
    [one, two] = XModem.packets(data)
    assert <<0x02, 1, 254, block::binary-size(1024), crc::16>> = one
    assert crc == XModem.crc16(block)
    assert <<0x02, 2, 253, rest::binary-size(1024), _::16>> = two
    assert rest == :binary.copy("a", 476) <> :binary.copy(<<0x1A>>, 548)
    assert length(XModem.packets(:binary.copy("b", 1024))) == 1
  end

  describe "over a link (XModem)" do
    setup do
      m = start_machine({CNC.ScriptedLink, test: self()}, "upload-#{System.unique_integer()}")
      assert_receive {:scripted_link, link, ^m}
      idle(m)
      # Answer whatever else connecting asked (e.g. the report mask)
      for _ <- 1..Machine.status(m).awaiting_ack//1, do: ok(m)
      assert eventually(fn -> Machine.status(m).awaiting_ack == 0 end)
      %{m: m, link: link}
    end

    test "sends the file block by block, resending on NAK; polls pause", %{m: m} do
      data = :binary.copy("x: 1\n", 300)
      [p1, p2] = XModem.packets(data)
      task = Task.async(fn -> Machine.upload(m, "try.yaml", data) end)

      assert_receive {:line, "$Xmodem/Receive=try.yaml"}
      assert_receive {:raw_mode, true}
      assert eventually(fn -> Machine.status(m).state == :uploading end)

      send(m, {:link, :data, "C"})
      assert_receive {:raw, ^p1}
      send(m, {:link, :data, <<0x15>>})
      assert_receive {:raw, ^p1}
      send(m, {:link, :data, <<0x06>>})
      assert_receive {:raw, ^p2}
      send(m, {:link, :data, <<0x06>>})
      assert_receive {:raw, <<0x04>>}
      send(m, {:link, :data, <<0x06>>})
      assert_receive {:raw_mode, false}

      # No status polls went out meanwhile
      refute_received {:rt, ??}

      send(m, {:link, :line, "[MSG:INFO: Received 1500 bytes to file /localfs/try.yaml]"})
      send(m, {:link, :line, "ok"})
      assert Task.await(task) == {:ok, 1500}
      assert Machine.status(m).state == :idle
    end

    test "the controller cancels: an error, back to lines", %{m: m} do
      task = Task.async(fn -> Machine.upload(m, "x.yaml", "a: 1\n") end)
      assert_receive {:raw_mode, true}
      send(m, {:link, :data, "C"})
      assert_receive {:raw, _block}
      send(m, {:link, :data, <<0x18, 0x18>>})
      assert Task.await(task) == {:error, :canceled}
      assert_receive {:raw_mode, false}
      assert Machine.status(m).state == :idle
    end

    test "names are checked; not while moving", %{m: m} do
      assert Machine.upload(m, "../x", "a") == {:error, :invalid_name}
      :ok = Machine.jog(m, {1, 0}, :normal)
      assert {:error, {:invalid_state, :jogging}} = Machine.upload(m, "x.yaml", "a")
    end
  end
end

defmodule Ohlex.HostLinkOmron.Test do
  use ExUnit.Case
  alias Ohlex.HostLink.Omron

  test "compute_fcs/1" do
    assert Omron.compute_fcs("@04RD02070001") == "56"
    assert Omron.compute_fcs("@04RD000020") == "50"
  end

  describe "is_frame_valid?/1" do
    test "Validates a correct FCS" do
      assert Omron.is_frame_valid?("@04RD0207000156*\r")
    end

    test "Refute invalid FCS" do
      refute Omron.is_frame_valid?("@04RD0207000152*\r")
    end

    test "Validates a frame without a termination" do
      refute Omron.is_frame_valid?("@04RD0207000156")
    end
  end

  describe "build_frame/1" do
    test "Valid Read IR Registers cmd" do
      rr_cmd = [header: :read_ir, len: 7, address: 128, device_id: 1]
      assert Omron.build_frame(rr_cmd) == {:ok, "@01RR012800074D*\r"}
    end

    test "Valid WRITE IR Registers cmd" do
      wr_cmd = [header: :write_ir, address: 256, args: [1, 18, 291, 4660], device_id: 1]
      assert Omron.build_frame(wr_cmd) == {:ok, "@01WR0256000100120123123443*\r"}
    end

    test "Valid Read Data Memory DM cmd" do
      rd_cmd = [header: :read_dm, len: 19, address: 112, device_id: 1]
      assert Omron.build_frame(rd_cmd) == {:ok, "@01RD0112001357*\r"}
    end

    test "Valid WRITE Data Memory DM cmd" do
      wr_cmd = [header: :write_dm, address: 4321, args: [4660, 291, 18, 1], device_id: 1]
      assert Omron.build_frame(wr_cmd) == {:ok, "@01WD4321123401230012000150*\r"}
    end

    test "Invalid Header" do
      cmd = [header: :invalid_header, address: 4321, args: [4660, 291, 18, 1], device_id: 1]
      assert Omron.build_frame(cmd) == {:error, :einval}
    end

    test "Invalid Address" do
      cmd = [header: :write_dm, address: "4321", args: [4660, 291, 18, 1], device_id: 1]
      assert Omron.build_frame(cmd) == {:error, :einval}
    end

    test "Invalid Args" do
      cmd = [header: :write_dm, address: 4321, args: {4660, 291, 18, 1}, device_id: 1]
      assert Omron.build_frame(cmd) == {:error, :einval}
    end

    test "Invalid Device ID" do
      cmd = [header: :write_dm, address: 4321, args: [4660, 291, 18, 1], device_id: "1"]
      assert Omron.build_frame(cmd) == {:error, :einval}
    end

    test "Invalid lenght" do
      cmd = [header: :read_dm, len: "19", address: 112, device_id: 1]
      assert Omron.build_frame(cmd) == {:error, :einval}
    end
  end

  describe "parse/1" do
    test "Valid Read IR Registers cmd" do
      assert Omron.parse("@04RD00002050*\r") == {:ok, <<0x00, 0x20>>}

      assert Omron.parse("@03RD000AD050*\r") == {:ok, <<0x0A, 0xD0>>}
    end

    test "Valid Write IR Registers cmd" do
      assert Omron.parse("@04WR0041*\r") == {:ok, <<>>}
    end

    test "Invalid cmd: No @" do
      assert Omron.parse("04RD00002050*\r") == {:error, "04RD00002050*\r"}
    end

    test "Invalid cmd: No Terminitation" do
      assert Omron.parse("@04RD00002051*\r") == {:error, "@04RD00002051*\r"}
    end

    test "Invalid cmd: FCS error" do
      assert Omron.parse("@04WR0040*\r") == {:error, "@04WR0040*\r"}
    end
  end
end

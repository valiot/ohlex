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
end

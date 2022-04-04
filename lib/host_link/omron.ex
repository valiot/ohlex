defmodule Ohlex.HostLink.Omron do
  @moduledoc """
  Host Link protocol stack of Omron PLCs.
  """
  defmodule Ohlex.HostLink.Omron.Frame do
    defstruct [:cmd_type, :len, :address, :device_id]
  end


  @spec compute_fcs(bitstring) :: binary()
  def compute_fcs(omron_frame) do
    <<int_fcs>> =
      for  <<char <- omron_frame>>, reduce: <<0>> do
        acc ->
          :crypto.exor(acc, <<char>>)
      end
    Integer.to_string(int_fcs, 16)
  end

  @spec is_frame_valid?(binary) :: boolean
  def is_frame_valid?(omron_received_frame) do
    with  {omron_frame, "*\r"} <- String.split_at(omron_received_frame, -2),
          {omron_frame_without_fcs, received_fcs} <- String.split_at(omron_frame, -2),
          computed_fcs <- compute_fcs(omron_frame_without_fcs) do
      received_fcs == computed_fcs
    else
      _error ->
        false
    end
  end
end

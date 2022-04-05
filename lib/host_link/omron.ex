defmodule Ohlex.HostLink.Omron do
  @moduledoc """
  Host Link protocol stack of Omron PLCs.
  Note: maximum length of command string should be <=80 characters
  """

  alias Ohlex.HostLink.Omron.Frame

  @headers %{read_ir: "RR", write_ir: "WR", read_dm: "RD", write_dm: "WD"}

  defmodule Frame do
    @supported_headers [:read_ir, :write_ir, :read_dm, :write_dm, "RR", "WR", "RD", "WD"]

    defstruct [:header, :len, :address, :device_id, :frame, :args]

    def new(cmd_args) do
      with  {:ok, header} <- Keyword.fetch(cmd_args, :header),
            true <- header in @supported_headers,
            {:ok, address} <- Keyword.fetch(cmd_args, :address),
            true <- is_integer(address),
            {:ok, device_id} <- Keyword.fetch(cmd_args, :device_id),
            true <- is_integer(device_id),
            true <- device_id < 256,
            args <- Keyword.get(cmd_args, :args, []),
            true <- is_list(args),
            len <- Keyword.get(cmd_args, :len, 0),
            true <- is_integer(len) do
        {:ok, %__MODULE__{header: header, len: len, address: address, device_id: device_id, frame: "", args: args}}
      else
        _error ->
          {:error, :einval}
      end
    end
  end

  def build_frame(cmd_args) do
    with  {:ok, frame_struct} <- Frame.new(cmd_args) do
      complete_frame =
        frame_struct
        |> add_initial_char()
        |> add_device_id()
        |> add_header()
        |> add_address()
        |> add_args()
        |> add_data_count()
        |> add_fcs()
        |> add_termination()

      {:ok, complete_frame.frame}
    else
      error ->
        error
    end
  end

  def parse(omron_frame) do
    with  {:ok, frame_struct} <- Frame.new(cmd_args) do
      complete_frame =
        frame_struct
        |> add_initial_char()
        |> add_device_id()
        |> add_header()
        |> add_address()
        |> add_args()
        |> add_data_count()
        |> add_fcs()
        |> add_termination()

      {:ok, complete_frame.frame}
    else
      error ->
        error
    end
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

  defp add_initial_char(%{frame: frame} = frame_struct), do: %{frame_struct | frame: frame <> "@"}

  defp add_device_id(%{frame: frame, device_id: device_id} = frame_struct) do
    with  device_id_str <- Integer.to_string(device_id, 16),
          device_id_str <- force_two_digits(device_id_str, device_id) do
      %{frame_struct | frame: frame <> device_id_str}
    end
  end
  defp force_two_digits(device_id_str, device_id) when device_id > 15, do: device_id_str
  defp force_two_digits(device_id_str, _device_id), do: "0" <> device_id_str

  defp add_header(%{header: header, frame: frame} = frame_struct) when is_atom(header),
    do: %{frame_struct | frame: frame <> @headers[header]}
  defp add_header(%{header: header, frame: frame} = frame_struct),
    do: %{frame_struct | frame: frame <> header}

  defp add_address(%{frame: frame, address: address} = frame_struct) do
    with  address_str <- Integer.to_string(address),
          address_str <- force_four_digits(address_str) do
      %{frame_struct | frame: frame <> address_str}
    end
  end

  defp force_four_digits(<<_n_1, _n_2, _n_3, _n_4>> = address), do: address
  defp force_four_digits(number_str) do
    str_len = String.length(number_str)
    for _index <- 0..(3-str_len), reduce: number_str do
      acc ->
        "0" <> acc
    end
  end

  defp add_args(%{args: []} = frame_struct), do: frame_struct
  defp add_args(%{frame: frame, args: args} = frame_struct) do
    args_str =
      for arg <- args, reduce: "" do
        acc ->
          with  arg_str <- Integer.to_string(arg, 16),
                arg_str <- force_four_digits(arg_str) do
            acc <> arg_str
          end
      end
    %{frame_struct | frame: frame <> args_str}
  end

  defp add_data_count(%{len: 0} = frame_struct), do: frame_struct
  defp add_data_count(%{frame: frame, len: len} = frame_struct) do
    with  len_str <- Integer.to_string(len, 16),
          len_str <- force_four_digits(len_str) do
      %{frame_struct | frame: frame <> len_str}
    end
  end

  defp add_fcs(%{frame: frame} = frame_struct),
    do: %{frame_struct | frame: frame <> compute_fcs(frame)}

  defp add_termination(%{frame: frame} = frame_struct),
    do: %{frame_struct | frame: frame <> "*\r"}
end

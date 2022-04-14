defmodule Ohlex.Tcp.Client do
  @moduledoc """
  API for Omnron HostLink TCP Client.
  """
  alias Ohlex.{Tcp.Client, HostLink.Omron}
  use GenServer, restart: :permanent, shutdown: 500
  require Logger

  @timeout 2000
  @tcp_port 950
  @ip {0, 0, 0, 0}
  @active false

  defstruct ip: nil,
            tcp_port: nil,
            socket: nil,
            timeout: nil,
            active: false,
            status: nil,
            ctrl_pid: nil,
            max_retries: 200,
            frame_acc: ""

  @type client_option ::
          {:ip, {byte(), byte(), byte(), byte()}}
          | {:active, boolean}
          | {:tcp_port, non_neg_integer}
          | {:timeout, non_neg_integer}

  @doc """
  Starts a Omnron HostLink TCP Client process.

  The following options are available:

    * `ip` - is the internet address of the desired TCP Server.
    * `tcp_port` - is the desired TCP Server tcp port number.
    * `timeout` - is the connection timeout.
    * `active` - (`true` or `false`) specifies whether data is received as
        messages (mailbox) or by calling `confirmation/1` each time `request/2` is called.

    The messages (when active mode is true) have the following form:

    `{Ohlex.Tcp.Client, cmd, values}`

  ## Example

  ```elixir
  Ohlex.Tcp.Client.start_link(ip: {10,77,0,2}, port: 502, timeout: 2000, active: true)
  ```
  """
  def start_link(parameters, opts \\ []) do
    GenServer.start_link(__MODULE__, {parameters, self()}, opts)
  end

  @doc """
  Stops the Client.
  """
  def stop(pid) do
    GenServer.stop(pid)
  end

  @doc """
  Gets the state of the Client.
  """
  def state(pid) do
    GenServer.call(pid, :state)
  end

  @doc """
  Configure the Client (`status` must be `:closed`).

  The following options are available:

  * `ip` - is the internet address of the desired TCP Server.
  * `tcp_port` - is the TCP Server tcp port number.
  * `timeout` - is the connection timeout.
  * `active` - (`true` or `false`) specifies whether data is received as
       messages (mailbox) or by calling `confirmation/1` each time `request/2` is called.
  """
  def configure(pid, parameters) do
    GenServer.call(pid, {:configure, parameters})
  end

  @doc """
  Connect the Client to a TCP Server.
  """
  def connect(pid) do
    GenServer.call(pid, :connect)
  end

  @doc """
  Close the tcp port of the Client.
  """
  def close(pid) do
    GenServer.call(pid, :close)
  end

  @doc """
  Send a request to Omnron HostLink TCP Server.
  """
  def request(pid, cmd, genserver_timeout \\ :infinity) do
    GenServer.call(pid, {:request, cmd}, genserver_timeout)
  end

  # GenServer Callbacks
  def init({parameters, ctrl_pid}) do
    with port <- Keyword.get(parameters, :tcp_port, @tcp_port),
         true <- is_integer(port) and port <= 65353 and port > 0,
         ip <- Keyword.get(parameters, :ip, @ip),
         true <- check_ip(ip),
         timeout <- Keyword.get(parameters, :timeout, @timeout),
         true <- is_integer(timeout) and timeout >= 0,
         active <- Keyword.get(parameters, :active, @active),
         true <- is_boolean(active) do
      {:ok,
       %Client{
         ip: ip,
         tcp_port: port,
         timeout: timeout,
         status: :closed,
         active: active,
         ctrl_pid: ctrl_pid
       }}
    else
      _error ->
        :ignore
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:configure, args}, _from, %{status: :closed, ctrl_pid: ctrl_pid} = state) do
    with port <- Keyword.get(args, :tcp_port, state.tcp_port),
         true <- is_integer(port) and port <= 65353 and port > 0,
         ip <- Keyword.get(args, :ip, state.ip),
         true <- check_ip(ip),
         timeout <- Keyword.get(args, :timeout, state.timeout),
         true <- is_integer(timeout) and timeout >= 0,
         active <- Keyword.get(args, :active, state.active),
         true <- is_boolean(active) do
      new_state = %Client{
        state
        | ip: ip,
          tcp_port: port,
          timeout: timeout,
          active: active,
          ctrl_pid: ctrl_pid
      }

      {:reply, :ok, new_state}
    else
      _error ->
        {:reply, {:error, :einval}, state}
    end
  end

  def handle_call({:configure, _args}, _from, state), do: {:reply, :error, state}

  def handle_call(:connect, {caller_pid, _ref}, state) do
    with {:ok, socket} <- connect_tcp_client(state) do
      {:reply, :ok, %Client{state | socket: socket, status: :connected, ctrl_pid: caller_pid}}
    else
      error_msg ->
        {:reply, error_msg, state}
    end
  end

  def handle_call(:close, _from, %{socket: nil} = state), do: {:reply, {:error, :closed}, state}
  def handle_call(:close, _from, %{status: :closed} = state), do: {:reply, :ok, state}
  def handle_call(:close, _from, state), do: {:reply, :ok, close_socket(state)}

  def handle_call({:request, _cmd_args}, _from, %{status: :closed} = state),
    do: {:reply, {:error, :closed}, state}

  def handle_call({:request, cmd_args}, _from, %{active: true} = state) do
    with {:ok, frame_data} <- Omron.build_frame(cmd_args),
         :ok <- send_tcp_msg(state, frame_data) do
      {:reply, :ok, state}
    else
      {:error, :closed} ->
        {:reply, {:error, :closed}, close_socket(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:request, cmd_args}, _from, state) do
    with {:ok, frame_data} <- Omron.build_frame(cmd_args),
         :ok <- send_tcp_msg(state, frame_data),
         {:ok, tcp_server_response} <- receive_tcp_msg(state, 0),
         {:ok, values} <- Omron.parse(tcp_server_response),
         gns_response <- build_genserver_response(values) do
      {:reply, gns_response, %Client{state | frame_acc: ""}}
    else
      {:error, :closed} ->
        {:reply, {:error, :closed}, close_socket(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, %Client{state | frame_acc: ""}}
    end
  end

  # Handles incomming TCP frame (active: true only)
  def handle_info({:tcp, _port, response}, %{ctrl_pid: ctrl_pid, frame_acc: frame_acc} = state) do
    with current_frame <- frame_acc <> response,
         {:ok, values} <- Omron.parse(current_frame) do
      send(ctrl_pid, {Ohlex.Tcp.Client, current_frame, values})
      {:noreply, %Client{state | frame_acc: ""}}
    else
      {:error, _reason} ->
        Logger.debug("(#{__MODULE__}) Invalid frame: #{inspect({state.frame_acc, response})}")
        {:noreply, %Client{state | frame_acc: frame_acc <> response}}
    end
  end

  def handle_info({:tcp_closed, _port}, state) do
    new_state = close_socket(state)
    send(state.ctrl_pid, {Ohlex.Tcp.Client, :tcp_closed})
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.error("(#{__MODULE__}) Unhandle message: #{inspect(msg)}")
    {:noreply, state}
  end

  defguard is_octet_valid?(octet) when is_integer(octet) and 0 <= octet and octet <= 255

  defp check_ip({octet1, octet2, octet3, octet4})
       when is_octet_valid?(octet1) and is_octet_valid?(octet2) and is_octet_valid?(octet3) and
              is_octet_valid?(octet4),
       do: true

  defp check_ip(_invalid_ip), do: false

  defp connect_tcp_client(%{ip: ip, tcp_port: tcp_port, active: active, timeout: timeout}),
    do: :gen_tcp.connect(ip, tcp_port, [:binary, packet: :raw, active: active], timeout)

  defp close_socket(state) do
    :ok = :gen_tcp.close(state.socket)
    %Client{state | socket: nil, status: :closed, frame_acc: ""}
  end

  defp send_tcp_msg(state, frame_data), do: :gen_tcp.send(state.socket, frame_data)
  defp receive_tcp_msg(%{max_retries: max_retries} = _state, max_retries), do: {:error, :timeout}

  defp receive_tcp_msg(%{timeout: timeout, socket: socket} = state, retries) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, tcp_server_response} ->
        new_state = %Client{state | frame_acc: state.frame_acc <> tcp_server_response}

        new_state.frame_acc
        |> Omron.is_frame_valid?()
        |> Omron.has_termination?(new_state)
        |> retry_receive_tcp_msg(new_state, retries)

      {:error, :timeout} ->
        receive_tcp_msg(state, retries + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_receive_tcp_msg(
         _is_frame_ready? = true,
         %{frame_acc: tcp_server_response} = _state,
         _retry
       ),
       do: {:ok, tcp_server_response}

  defp retry_receive_tcp_msg(_is_frame_ready? = false, state, retry),
    do: receive_tcp_msg(state, retry + 1)

  defp build_genserver_response(<<>>), do: :ok
  defp build_genserver_response(values), do: {:ok, values}
end

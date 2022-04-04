defmodule Ohlex.Tcp.Client do
  @moduledoc """
  API for Omnron HostLink TCP Client.
  """
  alias Ohlex.Tcp.Client
  use GenServer, restart: :permanent, shutdown: 500
  require Logger

  @timeout 2000
  @tcp_port 950
  @ip {0, 0, 0, 0}
  @active false

  defstruct ip: nil,
            tcp_port: nil,
            device_id: nil,
            socket: nil,
            timeout: nil,
            active: false,
            status: nil,
            ctrl_pid: nil


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
  def request(pid, cmd) do
    GenServer.call(pid, {:request, cmd})
  end

  # callbacks
  def init({parameters, ctrl_pid}) do
    with  port <- Keyword.get(parameters, :tcp_port, @tcp_port),
          ip <- Keyword.get(parameters, :ip, @ip),
          timeout <- Keyword.get(parameters, :timeout, @timeout),
          active <- Keyword.get(parameters, :active, @active) do
      {:ok, %Client{ip: ip, tcp_port: port, timeout: timeout, status: :closed, active: active, ctrl_pid: ctrl_pid}}
    end
  end

  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:configure, args}, _from,  %{status: :closed, ctrl_pid: ctrl_pid} = state) do
    with  port <- Keyword.get(args, :tcp_port, state.tcp_port),
          ip <- Keyword.get(args, :ip, state.ip),
          timeout <- Keyword.get(args, :timeout, state.timeout),
          device_id <- Keyword.get(args, :device_id, state.device_id),
          active <- Keyword.get(args, :active, state.active) do
      new_state =
        %Client{state | ip: ip, tcp_port: port, timeout: timeout, active: active, ctrl_pid: ctrl_pid, device_id: device_id}
      {:reply, :ok, new_state}
    end
  end
  def handle_call({:configure, _args}, _from, state), do: {:reply, :error, state}

  def handle_call(:connect, {caller_pid,_ref}, state) do
    with  {:ok, socket} <- connect_tcp_client(state) do
      {:reply, :ok, %Client{state | socket: socket, status: :connected, ctrl_pid: caller_pid}}
    else
      error_msg ->
        {:reply, error_msg, state}
    end
  end

  def handle_call(:close, _from, %{socket: nil} = state), do: {:reply, {:error, :closed}, state}
  def handle_call(:close, _from, %{status: :closed} = state), do: {:reply, :ok, state}
  def handle_call(:close, _from, state),  do: {:reply, :ok, close_socket(state)}

  def handle_call({:request, cmd}, _from, state) do
    Logger.debug("(#{__MODULE__}, :request) state: #{inspect(state)}")

    case state.status do
      :connected ->
        request = Tcp.pack_req(cmd, state.transid)
        length = Tcp.res_len(cmd)

        case :gen_tcp.send(state.socket, request) do
          :ok ->
            new_state =
              if state.active do
                new_msg = Map.put(state.pending_msg, state.transid, cmd)

                n_msg =
                  if state.transid + 1 > 0xFFFF do
                    0
                  else
                    state.transid + 1
                  end

                %Client{state | msg_len: length, cmd: cmd, pending_msg: new_msg, transid: n_msg}
              else
                %Client{state | msg_len: length, cmd: cmd}
              end

            {:reply, :ok, new_state}

          {:error, :closed} ->
            new_state = close_socket(state)
            {:reply, {:error, :closed}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :closed ->
        {:reply, {:error, :closed}, state}
    end
  end

  # only for active mode (active: true)
  def handle_info({:tcp, _port, response}, %{ctrl_pid: ctrl_pid} = state) do
    with  {:ok, values} <- Omron.parse(response) do
      send(ctrl_pid,  {Ohlex.Tcp.Client, response, values})
    else
      error ->
        Logger.error("(#{__MODULE__}) Receiving Error: #{inspect(error)}")
    end
    {:noreply, state}
  end

  def handle_info({:tcp_closed, _port}, state) do
    new_state = close_socket(state)
    send(state.ctrl_pid, {Ohlex.Tcp.Client, :tcp_closed})
    {:noreply, new_state}
  end

  def handle_info(msg, state) do
    Logger.error("(#{__MODULE__}, :random_msg) msg: #{inspect(msg)}")
    {:noreply, state}
  end

  defp connect_tcp_client(%{ip: ip, tcp_port: tcp_port, active: active, timeout: timeout}), do:
    :gen_tcp.connect(ip, tcp_port, [:binary, packet: :raw, active: active], timeout)

  defp close_socket(state) do
    :ok = :gen_tcp.close(state.socket)
    %Client{state | socket: nil, status: :closed}
  end
end

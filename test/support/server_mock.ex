defmodule Server.Mock.Default do
  use Tcp.Client.Handler

  @impl true
  def init(%{test_pid: test_pid} = state) do
    send(test_pid, :init)
    state
  end

  @impl true
  def handle_msg(socket, data, %{test_pid: test_pid, test_type: :splitted_response} = state) do
    :gen_tcp.send(socket, "@04R")
    :gen_tcp.send(socket, "D00C")
    Process.sleep(100)
    :gen_tcp.send(socket, "E6A2")
    :gen_tcp.send(socket, "3*\r")
    send(test_pid, {:handle_msg, data})
    state
  end

  @impl true
  def handle_msg(socket, data, %{test_pid: test_pid, test_type: :complete_response} = state) do
    :gen_tcp.send(socket, "@04RD0005E900012A*\r")
    send(test_pid, {:handle_msg, data})
    state
  end

  @impl true
  def handle_msg(socket, data, %{test_pid: test_pid} = state) do
    :gen_tcp.send(socket, data)
    send(test_pid, {:handle_msg, data})
    state
  end

  @impl true
  def handle_close(_socket, %{test_pid: test_pid} = state) do
    send(test_pid, :handle_close)
    state
  end
end

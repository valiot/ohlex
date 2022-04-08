defmodule Ohlex.Client.Test do
  use ExUnit.Case
  alias Ohlex.Tcp.Client
  import ExUnit.CaptureLog

  setup_all do
    Tcp.Server.start_link(port: 4004, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)
    :ok
  end

  describe "start_link/1" do
    test "Starts with no configuration, uses default." do
      {:ok, c_pid} = Client.start_link([])

      assert is_pid(c_pid)

      expected_initial_state = %Ohlex.Tcp.Client{
        active: false,
        ctrl_pid: self(),
        frame_acc: "",
        ip: {0, 0, 0, 0},
        max_retries: 200,
        socket: nil,
        status: :closed,
        tcp_port: 950,
        timeout: 2000
      }

      assert Client.state(c_pid) == expected_initial_state
    end

    test "Valid Configuration" do
      {:ok, c_pid} =
        Client.start_link(ip: {127, 0, 0, 1}, tcp_port: 4000, timeout: 1000, active: true)

      assert is_pid(c_pid)

      expected_initial_state = %Ohlex.Tcp.Client{
        active: true,
        ctrl_pid: self(),
        frame_acc: "",
        ip: {127, 0, 0, 1},
        max_retries: 200,
        socket: nil,
        status: :closed,
        tcp_port: 4000,
        timeout: 1000
      }

      assert Client.state(c_pid) == expected_initial_state
    end

    test "Ignore process with invalid IP" do
      # All octets must be integer
      assert :ignore == Client.start_link(ip: {"127", 0, 0, 1})
      # All octets must in range (0..255)
      assert :ignore == Client.start_link(ip: {0, 256, 0, 0})
      assert :ignore == Client.start_link(ip: {0, 0, 0, -1})
    end

    test "Ignore process with invalid Port" do
      # Must be integer
      assert :ignore == Client.start_link(tcp_port: "4040")
      # Must in range (0..65353)
      assert :ignore == Client.start_link(tcp_port: -1)
      assert :ignore == Client.start_link(tcp_port: 65355)
    end

    test "Ignore process with invalid Timeout" do
      # Must be integer
      assert :ignore == Client.start_link(timeout: "4040")
      # Must be positive
      assert :ignore == Client.start_link(timeout: -1)
    end

    test "Ignore process with invalid Active" do
      # Must be boolean
      assert :ignore == Client.start_link(active: "true")
      assert :ignore == Client.start_link(active: -1)
    end
  end

  describe "configure/1" do
    setup do
      {:ok, c_pid} = Client.start_link([])
      {:ok, %{c_pid: c_pid}}
    end

    test "Keeps the parameters that have not been modified", %{c_pid: c_pid} do
      expected_initial_state = %Ohlex.Tcp.Client{
        active: false,
        ctrl_pid: self(),
        frame_acc: "",
        ip: {0, 0, 0, 0},
        max_retries: 200,
        socket: nil,
        status: :closed,
        tcp_port: 950,
        timeout: 2000
      }

      assert :ok == Client.configure(c_pid, [])

      assert Client.state(c_pid) == expected_initial_state
    end

    test "Overwrites the initial state", %{c_pid: c_pid} do
      expected_initial_state = %Ohlex.Tcp.Client{
        active: false,
        ctrl_pid: self(),
        frame_acc: "",
        ip: {0, 0, 0, 0},
        max_retries: 200,
        socket: nil,
        status: :closed,
        tcp_port: 950,
        timeout: 2000
      }

      expected_new_state = %Ohlex.Tcp.Client{
        active: true,
        ctrl_pid: self(),
        frame_acc: "",
        ip: {127, 0, 0, 1},
        max_retries: 200,
        socket: nil,
        status: :closed,
        tcp_port: 4000,
        timeout: 1000
      }

      assert Client.state(c_pid) == expected_initial_state

      assert :ok == Client.configure(c_pid, [ip: {127, 0, 0, 1}, tcp_port: 4000, timeout: 1000, active: true])

      assert Client.state(c_pid) == expected_new_state
    end

    test "Error Tuple with invalid IP", %{c_pid: c_pid} do
      # All octets must be integer
      assert {:error, :einval} == Client.configure(c_pid, ip: {"127", 0, 0, 1})
      # All octets must in range (0..255)
      assert {:error, :einval} == Client.configure(c_pid, ip: {0, 256, 0, 0})
      assert {:error, :einval} == Client.configure(c_pid, ip: {0, 0, 0, -1})
    end

    test "Error Tuple with invalid Port", %{c_pid: c_pid} do
      # Must be integer
      assert {:error, :einval} == Client.configure(c_pid, tcp_port: "4040")
      # Must in range (0..65353)
      assert {:error, :einval} == Client.configure(c_pid, tcp_port: -1)
      assert {:error, :einval} == Client.configure(c_pid, tcp_port: 65355)
    end

    test "Error Tuple with invalid Timeout", %{c_pid: c_pid} do
      # Must be integer
      assert {:error, :einval} == Client.configure(c_pid, timeout: "4040")
      # Must be positive
      assert {:error, :einval} == Client.configure(c_pid, timeout: -1)
    end

    test "Error Tuple with invalid Active", %{c_pid: c_pid} do
      # Must be boolean
      assert {:error, :einval} == Client.configure(c_pid, active: "true")
      assert {:error, :einval} == Client.configure(c_pid, active: -1)
    end

    test "Returns a error when trying to configure a connected Client" do
      {:ok, c_pid} = Client.start_link(tcp_port: 4004)
      assert :ok == Client.connect(c_pid)

      assert :error == Client.configure(c_pid, active: true)
    end
  end

  describe "connect/1" do
    test "Successful connection to a listening server." do
      Tcp.Server.start_link(port: 4000, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)

      {:ok, c_pid} = Client.start_link([ip: {127,0,0,1}, tcp_port: 4000])

      assert :ok == Client.connect(c_pid)

      assert_receive(:init, 1000)
    end

    test "Connection failure, no server is listening." do
      {:ok, c_pid} = Client.start_link([ip: {127,0,0,1}, tcp_port: 4001])

      assert {:error, :econnrefused} == Client.connect(c_pid)
    end
  end

  describe "close/1" do
    test "Close a TCP connection" do
      Tcp.Server.start_link(port: 4002, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)

      {:ok, c_pid} = Client.start_link([ip: {127,0,0,1}, tcp_port: 4002])

      assert :ok == Client.connect(c_pid)
      Process.sleep(100)
      assert :ok == Client.close(c_pid)

      assert_receive(:init, 1000)
      assert_receive(:handle_close, 1000)
    end

    test "Error: If there is no connection" do
      {:ok, c_pid} = Client.start_link([ip: {127,0,0,1}, tcp_port: 4003])

      assert {:error, :closed} == Client.close(c_pid)
    end
  end

  describe "request/2" do
    test "Sends Valid Omron Frame" do
      Tcp.Server.start_link(port: 4005, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4005)

      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      Client.request(c_pid, rd_cmd)
      # Message received by the server
      assert_receive {:handle_msg, "@04RD0207000156*\r"}, 1000
    end

    test "Error: Invalid Response" do
      # This Server replies the same message it receives.
      Tcp.Server.start_link(port: 4006, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4006)

      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      assert {:error, "@04RD0207000156*\r"} == Client.request(c_pid, rd_cmd)
    end

    test "Error: If there is no connection" do
      {:ok, c_pid} = Client.start_link([])

      rd_cmd = [header: :read_dm, len: 19, address: 112, device_id: 1]
      assert {:error, :closed} == Client.request(c_pid, rd_cmd)
    end

    test "Error: If it is an invalid cmd" do
      {:ok, c_pid} = Client.start_link([ip: {127,0,0,1}, tcp_port: 4004])

      assert :ok == Client.connect(c_pid)

      invalid_cmd = [header: :read_ddm, len: "19", address: 112, device_id: 1]
      assert {:error, :einval} == Client.request(c_pid, invalid_cmd)
    end
  end

  test "stop/1" do
    {:ok, c_pid} = Client.start_link([])
    assert Client.stop(c_pid) == :ok
  end

  describe "Passive Mode" do
    test "Polls Data Frame" do
      Tcp.Server.start_link(port: 4007, handler_args: %{test_pid: self(), test_type: :complete_response}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4007, active: false)

      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      assert {:ok, <<5, 233, 0, 1>>} == Client.request(c_pid, rd_cmd)
      # Message received by the server
      assert_receive {:handle_msg, "@04RD0207000156*\r"}, 1000
    end

    test "Waits until the frame is complete" do
      Tcp.Server.start_link(port: 4008, handler_args: %{test_pid: self(), test_type: :splitted_response}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4008, active: false)

      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      assert {:ok, <<0xCE, 0x6A>>} == Client.request(c_pid, rd_cmd)
      # Message received by the server
      assert_receive {:handle_msg, "@04RD0207000156*\r"}, 1000
    end
  end

  describe "Active Mode" do
    test "Polls Data Frame" do
      Tcp.Server.start_link(port: 4009, handler_args: %{test_pid: self(), test_type: :complete_response}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4009, active: true)

      Process.sleep(100)
      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      assert :ok == Client.request(c_pid, rd_cmd)
      # Message received by the server
      assert_receive {:handle_msg, "@04RD0207000156*\r"}, 1000
      assert_receive {Ohlex.Tcp.Client, "@04RD0005E900012A*\r", <<5, 233, 0, 1>>}, 1000
    end

    test "Waits until the frame is complete" do
      Tcp.Server.start_link(port: 4010, handler_args: %{test_pid: self(), test_type: :splitted_response}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4010, active: true)

      Process.sleep(100)
      assert :ok == Client.connect(c_pid)

      rd_cmd = [header: :read_dm, len: 1, address: 207, device_id: 4]

      assert :ok == Client.request(c_pid, rd_cmd)
      # Message received by the server
      assert_receive {:handle_msg, "@04RD0207000156*\r"}, 1000
      assert_receive {Ohlex.Tcp.Client, "@04RD00CE6A23*\r", <<206, 106>>}, 1000
    end

    test "Notifies a closed connection" do
      {:ok, s_pid} = Tcp.Server.start_link(port: 4011, handler_args: %{test_pid: self()}, handler_module: Server.Mock.Default)
      {:ok, c_pid} = Client.start_link(tcp_port: 4011, active: true)

      Process.sleep(100)
      assert :ok == Client.connect(c_pid)

      # Simulates an unexpected connection shutdown.
      :ok = Tcp.Server.stop(s_pid)

      assert_receive {Ohlex.Tcp.Client, :tcp_closed}, 1000
    end
  end

  test "logs unhandled message" do
    {:ok, c_pid} = Client.start_link([])

    logs =
      capture_log(fn ->
        send(c_pid, "unknown message")
        Process.sleep(100)
      end)

    assert logs =~ "(Elixir.Ohlex.Tcp.Client) Unhandle message: \"unknown message\""
  end
end

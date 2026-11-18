defmodule MvmEx.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    data_dir = System.get_env("MVM_DATA_DIR", Path.join(System.tmp_dir!(), "mvm-ex"))
    audit_path = Path.join(data_dir, "audit.log")
    File.mkdir_p!(data_dir)

    children = [
      {MvmEx.Pool, [name: MvmEx.Pool, data_dir: data_dir, audit_path: audit_path]}
    ]

    children =
      case System.get_env("MVM_WEB_PORT") do
        nil -> children
        port -> children ++ [{MvmEx.Web, [port: String.to_integer(port)]}]
      end

    opts = [strategy: :one_for_one, name: MvmEx.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

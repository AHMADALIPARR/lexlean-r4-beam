defmodule MvmEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mvm_ex,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: [],
      escript: [main_module: MvmEx.CLI]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :inets],
      mod: {MvmEx.Application, []}
    ]
  end
end

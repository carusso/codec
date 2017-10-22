defmodule Codec.Mixfile do
  use Mix.Project

  def project do
    [app: :codec,
     version: "0.1.0",
     elixir: "~> 1.5",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: description(),
     package: package(),
     deps: deps()]
  end

  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.18", only: :dev, runtime: false},
      {:mex, "~> 0.0.5", only: [:dev, :test]},
    ]
  end

  defp description do
    """
    facilitates the development of layered binary protocols while mostly sticking with the Elixir bit field syntax.
    """
  end

  defp package do
    [
      name: :codec,
      files: ["lib", "mix.exs", "README*", "LICENSE*"],
      maintainers: ["Chris Russo"],
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/carusso/codec"}
    ]
  end

end

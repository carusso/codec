defmodule Codec.Mixfile do
  use Mix.Project

  def project do
    [app: :codec,
     version: "0.1.0",
     elixir: "~> 1.4",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     description: description(),
     package: package(),
     deps: deps()]
  end

  # Configuration for the OTP application
  #
  # Type "mix help compile.app" for more information
  def application do
    # Specify extra applications you'll use from Erlang/Elixir
    [extra_applications: [:logger]]
  end

  # Dependencies can be Hex packages:
  #
  #   {:my_dep, "~> 0.3.0"}
  #
  # Or git/path repositories:
  #
  #   {:my_dep, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
  #
  # Type "mix help deps" for more examples and options
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},
      {:mex, "~> 0.0.1", only: [:dev, :test]},
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

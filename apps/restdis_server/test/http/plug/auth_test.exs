defmodule RestdisServer.HTTP.Plug.AuthTest do
  use ExUnit.Case, async: true

  alias RestdisServer.HTTP.Plug.Auth

  test "init/1 returns opts unchanged" do
    assert Auth.init(:opts) == :opts
  end
end

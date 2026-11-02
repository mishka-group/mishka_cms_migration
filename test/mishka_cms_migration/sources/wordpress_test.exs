# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_cms_migration/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaCmsMigration.Sources.WordPressTest do
  @moduledoc """
  The WordPress source signing in, against what the seeded WordPress answered: the site it finds,
  and each way a connection is refused.
  """
  use ExUnit.Case, async: true

  import MishkaCmsMigration.Test.WordPress, only: [stub!: 0, stub!: 1]

  alias MishkaCmsMigration.Source
  alias MishkaCmsMigration.Sources.WordPress

  @connection %{"url" => "http://localhost:8089", "user" => "admin"}

  describe "connecting" do
    test "signs in and keeps what the site says of itself" do
      stub!()

      assert {:ok, conn} = WordPress.connect(@connection, "app password")

      assert WordPress.extra(conn) == %{
               "name" => "Mishka Test Blog",
               "home" => "http://localhost:8089",
               "timezone" => "Asia/Tehran",
               "signed_in_as" => "admin"
             }
    end

    test "signs in with the user and the application password" do
      stub!()

      {:ok, _conn} = WordPress.connect(@connection, "app password")

      assert_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/users/me"} = request}
      assert ["Basic " <> basic] = Plug.Conn.get_req_header(request, "authorization")
      assert Base.decode64!(basic) == "admin:app password"
    end

    test "reads a site in a folder under that folder" do
      stub!()

      assert {:ok, _conn} =
               WordPress.connect(%{@connection | "url" => " http://localhost:8089/blog/ "}, "pw")

      assert_received {:wordpress_request, %{request_path: "/blog/wp-json/"}}
    end

    test "is refused for a wrong password or an unknown user" do
      for recording <- [
            "unauthorized-users-me-wrong-password",
            "unauthorized-users-me-unknown-user"
          ] do
        stub!(%{"/wp-json/wp/v2/users/me" => recording})
        assert WordPress.connect(@connection, "wrong") == {:error, :unauthorized}
      end
    end

    test "is refused without a user or a password, without signing in" do
      stub!()

      for {connection, secret} <- [
            {@connection, nil},
            {@connection, ""},
            {Map.delete(@connection, "user"), "pw"},
            {%{@connection | "user" => ""}, "pw"}
          ] do
        assert WordPress.connect(connection, secret) == {:error, :unauthorized}
        refute_received {:wordpress_request, %{request_path: "/wp-json/wp/v2/users/me"}}
      end
    end

    test "says what is wrong with the address before asking for a password" do
      stub!(%{"/wp-json/" => :unreachable})

      assert WordPress.connect(%{"url" => "ftp://example.com"}, nil) == {:error, :invalid_address}
      assert WordPress.connect(%{"url" => "http://localhost:1"}, nil) == {:error, :unreachable}
    end

    test "says no WordPress answers where the address has no REST API" do
      stub!(%{"/wp-json/" => :no_site})

      assert WordPress.connect(@connection, "pw") == {:error, :no_site}
    end

    test "says nothing answered when the site cannot be reached" do
      stub!(%{"/wp-json/" => :unreachable})

      assert WordPress.connect(@connection, "pw") == {:error, :unreachable}
    end

    test "refuses an address that is not a web address" do
      stub!()

      for url <- ["example.com", "ftp://example.com", "https://", ""] do
        assert WordPress.connect(%{@connection | "url" => url}, "pw") ==
                 {:error, :invalid_address}
      end

      assert WordPress.connect(%{}, "pw") == {:error, :invalid_address}
      assert WordPress.connect(%{"url" => 8089}, "pw") == {:error, :invalid_address}
      refute_received {:wordpress_request, _conn}
    end
  end

  describe "the source" do
    test "keeps the host of the address as the run's source host" do
      assert WordPress.host(%{"url" => " https://Blog.Example.com/news/ "}) == "blog.example.com"
      assert WordPress.host(%{"url" => "https://blog.example.com:443"}) == "blog.example.com"
      assert WordPress.host(%{"url" => "http://localhost:8089"}) == "localhost:8089"
      assert WordPress.host(%{"url" => "example.com"}) == nil
      assert WordPress.host(%{}) == nil
    end

    test "is installed with the extension, and reads no content yet" do
      assert {:ok, WordPress} = Source.fetch("wordpress")
      assert WordPress.kinds() == []
    end
  end
end

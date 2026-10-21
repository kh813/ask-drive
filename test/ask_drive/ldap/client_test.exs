defmodule AskDrive.Ldap.ClientTest do
  use ExUnit.Case, async: true

  alias AskDrive.Ldap.Client

  test "an answer without any controls means there are no more pages" do
    assert Client.paged_cookie({:eldap_search_result, [], [], :asn1_NOVALUE}) ==
             {:error, :no_cookie}

    assert Client.paged_cookie({:eldap_search_result, [], [], []}) == {:error, :no_cookie}
  end
end

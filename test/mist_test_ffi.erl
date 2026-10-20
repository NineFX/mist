-module(mist_test_ffi).

-export([stream_request/4, request_unix/5, temp_socket_path/0, delete_file/1]).

%% Sends a request through hackney with a streamed body and collects the
%% whole response.
stream_request(Method, Path, Headers, Body) ->
  try
    {ok, ClientRef} = hackney:request(Method, Path, Headers, stream, []),
    ok = hackney:send_body(ClientRef, Body),
    {ok, Status, RespHeaders, ClientRef} = hackney:start_response(ClientRef),
    {ok, RespBody} = hackney:body(ClientRef),
    {ok, {Status, RespHeaders, RespBody}}
  catch
    _ -> {error, nil}
  end.

%% Sends a request through hackney to the Unix domain socket at `SocketPath`,
%% using its `http+unix` scheme, and collects the whole response. A leading
%% `@` selects Linux's abstract namespace, the same convention glisten uses,
%% and becomes the leading NUL byte the kernel expects.
request_unix(Method, <<"@", Name/binary>>, Path, Headers, Body) ->
  request_unix(Method, <<0, Name/binary>>, Path, Headers, Body);
request_unix(Method, SocketPath, Path, Headers, Body) ->
  Url = <<"http+unix://", (hackney_url:urlencode(SocketPath))/binary, Path/binary>>,
  case hackney:request(Method, Url, Headers, Body, [with_body]) of
    {ok, Status, RespHeaders, RespBody} -> {ok, {Status, RespHeaders, RespBody}};
    {error, Reason} -> {error, Reason}
  end.

%% A unique socket path under the user's temp directory. Unix socket paths
%% are limited to about 104 bytes, so a deep temp directory falls back to /tmp.
temp_socket_path() ->
  Name = "mist_test_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".sock",
  Root = case os:getenv("TMPDIR") of
    false -> "/tmp";
    Dir -> Dir
  end,
  Path = filename:join(Root, Name),
  case length(Path) > 100 of
    true -> list_to_binary(filename:join("/tmp", Name));
    false -> list_to_binary(Path)
  end.

delete_file(Path) ->
  _ = file:delete(Path),
  nil.

import exception
import gleam/bool
import gleam/bytes_tree
import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import mist.{type Connection, type ResponseData}
import scaffold

@external(erlang, "mist_test_ffi", "request_unix")
fn request_unix(
  method method: http.Method,
  socket socket: String,
  path path: String,
  headers headers: List(#(String, String)),
  body body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), Dynamic)

@external(erlang, "mist_test_ffi", "temp_socket_path")
fn temp_socket_path() -> String

@external(erlang, "mist_test_ffi", "delete_file")
fn delete_file(path: String) -> Nil

@external(erlang, "os", "type")
fn os_type() -> #(Atom, Atom)

@external(erlang, "erlang", "unique_integer")
fn unique_integer(modifiers: List(Atom)) -> Int

fn is_linux() -> Bool {
  os_type() == #(atom.create("unix"), atom.create("linux"))
}

fn is_windows() -> Bool {
  os_type() == #(atom.create("win32"), atom.create("nt"))
}

fn with_unix_server(
  at path: String,
  with handler: fn(Request(Connection)) -> Response(ResponseData),
  after perform: fn() -> return,
) -> return {
  let started = process.new_subject()
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.with_unix_socket(path)
    |> mist.after_start_unix(fn(path, scheme) {
      process.send(started, #(path, scheme))
    })
    |> mist.start
  process.unlink(server.pid)

  let assert Ok(#(reported_path, scheme)) = process.receive(started, 5000)
  assert reported_path == path
  assert scheme == http.Http

  let result = exception.rescue(perform)
  scaffold.shutdown(server.pid)
  // Abstract sockets have no file to remove.
  case path {
    "@" <> _ -> Nil
    _ -> delete_file(path)
  }
  case result {
    Ok(return) -> return
    Error(err) -> panic as { "Test failed with: " <> string.inspect(err) }
  }
}

pub fn it_serves_http_over_a_unix_domain_socket_test() {
  use <- bool.guard(when: is_windows(), return: Nil)
  let path = temp_socket_path()
  use <- with_unix_server(path, scaffold.default_handler)

  let assert Ok(#(200, headers, <<"hello, world!":utf8>>)) =
    request_unix(
      method: http.Post,
      socket: path,
      path: "/echo",
      headers: [#("content-type", "text/plain")],
      body: <<"hello, world!":utf8>>,
    )

  assert list.key_find(headers, "content-length") == Ok("13")
  assert list.key_find(headers, "content-type") == Ok("text/plain")
}

pub fn it_reports_no_peer_address_over_a_unix_domain_socket_test() {
  use <- bool.guard(when: is_windows(), return: Nil)
  let path = temp_socket_path()
  let handler = fn(req: Request(Connection)) {
    let body = case mist.get_connection_info(req.body) {
      Ok(info) -> "peer " <> mist.connection_info_to_string(info)
      Error(Nil) -> "no peer address"
    }
    response.new(200)
    |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
  }
  use <- with_unix_server(path, handler)

  let assert Ok(#(200, _headers, <<"no peer address":utf8>>)) =
    request_unix(
      method: http.Get,
      socket: path,
      path: "/",
      headers: [],
      body: <<>>,
    )
  Nil
}

/// Linux's abstract socket namespace has no file on disk; glisten selects it
/// with a leading `@`, and `request_unix` turns that into the leading NUL byte
/// the kernel expects. No other system has this namespace, so elsewhere the
/// test is a no-op.
pub fn it_listens_on_an_abstract_socket_on_linux_test() {
  use <- bool.guard(when: !is_linux(), return: Nil)
  let name =
    "@mist_test_" <> int.to_string(unique_integer([atom.create("positive")]))
  use <- with_unix_server(name, scaffold.default_handler)

  let assert Ok(#(200, headers, <<"abstract":utf8>>)) =
    request_unix(
      method: http.Post,
      socket: name,
      path: "/abstract",
      headers: [#("content-type", "text/plain")],
      body: <<"abstract":utf8>>,
    )

  assert list.key_find(headers, "content-length") == Ok("8")
}

/// OTP has no Unix domain socket support on Windows, so starting a server on
/// one fails instead of listening. The attempt runs in a separate process
/// that traps exits, because a supervisor that fails to start sends its
/// linked caller an exit signal as well as returning the error.
pub fn it_cannot_listen_on_a_unix_socket_on_windows_test() {
  use <- bool.guard(when: !is_windows(), return: Nil)
  let outcome = process.new_subject()
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let started =
      scaffold.default_handler
      |> mist.new
      |> mist.with_unix_socket("mist_windows_test.sock")
      |> mist.after_start_unix(fn(_path, _scheme) { Nil })
      |> mist.start
    process.send(outcome, result.is_error(started))
  })
  assert process.receive(outcome, 10_000) == Ok(True)
}

# API Reference

This reference covers the public Zig API exposed by:

```zig
const rpc = @import("zig_rpc");
```

The library separates two concerns:

- `Connection` reads and writes newline-delimited JSON frames.
- JSON-RPC helpers validate or publish JSON-RPC 2.0 request, response, and error
  objects.

For the transport-level flow between processes, see
[messaging.md](messaging.md).

## Module Constants And Types

### `version`

```zig
pub const version = "0.1.0";
```

Current package version string.

### `JsonValue`

```zig
pub const JsonValue = std.json.Value;
```

Alias used by the API for parsed JSON values.

### `ErrorCode`

```zig
pub const ErrorCode = enum(i64) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    pub fn code(self: ErrorCode) i64;
    pub fn message(self: ErrorCode) []const u8;
};
```

Standard JSON-RPC 2.0 error codes. Use these with
`Connection.sendPredefinedError(...)` when returning common protocol errors.

| Value | Code | Message |
| --- | ---: | --- |
| `.parse_error` | `-32700` | `Parse error` |
| `.invalid_request` | `-32600` | `Invalid Request` |
| `.method_not_found` | `-32601` | `Method not found` |
| `.invalid_params` | `-32602` | `Invalid params` |
| `.internal_error` | `-32603` | `Internal error` |

### `Id`

```zig
pub const Id = union(enum) {
    string: []const u8,
    integer: i64,
    null,
};
```

JSON-RPC request id helper used by `sendRequest(...)` and
`sendRequestNoParams(...)`.

Examples:

```zig
.{ .integer = 1 }
.{ .string = "sum" }
rpc.Id.null
```

### `ProtocolError`

```zig
pub const ProtocolError = error{
    InvalidMessage,
    InvalidVersion,
    InvalidRequest,
    InvalidResponse,
    InvalidMethod,
    ReservedMethod,
    InvalidParams,
    InvalidId,
    InvalidError,
    ResponseMissingId,
    ResponseHasResultAndError,
    ResponseMissingResultOrError,
};
```

Returned by protocol validation helpers such as `ParsedMessage.asRequest()`,
`ParsedMessage.asResponse()`, `parseRequest(...)`, `parseResponse(...)`, and
`validateMethodName(...)`.

## Message Views

These structs are lightweight views into parsed JSON memory. Keep the owning
`ParsedMessage` alive while using them.

### `Request`

```zig
pub const Request = struct {
    method: []const u8,
    params: ?JsonValue,
    id: ?JsonValue,

    pub fn isNotification(self: Request) bool;
};
```

Represents a JSON-RPC request or notification.

| Field | Type | Meaning |
| --- | --- | --- |
| `method` | `[]const u8` | Requested method name. Names starting with `rpc.` are rejected. |
| `params` | `?JsonValue` | Optional params. When present, parsed requests require an object or array. |
| `id` | `?JsonValue` | Request id. Missing `id` means the message is a notification. |

`isNotification()` returns `true` when `id == null`.

### `RpcErrorView`

```zig
pub const RpcErrorView = struct {
    code: i64,
    message: []const u8,
    data: ?JsonValue,
};
```

View of a JSON-RPC response error object.

### `Response`

```zig
pub const Response = struct {
    id: JsonValue,
    result: ?JsonValue,
    rpc_error: ?RpcErrorView,

    pub fn isError(self: Response) bool;
};
```

Represents a JSON-RPC response. A valid response has exactly one of `result` or
`rpc_error`.

`isError()` returns `true` when `rpc_error != null`.

### `ParsedMessage`

```zig
pub const ParsedMessage = struct {
    pub fn deinit(self: *ParsedMessage) void;
    pub fn value(self: *const ParsedMessage) JsonValue;
    pub fn asRequest(self: *const ParsedMessage) ProtocolError!Request;
    pub fn asResponse(self: *const ParsedMessage) ProtocolError!Response;
};
```

Owns the parsed JSON memory returned by `Connection.readMessage()`.

| Method | Use |
| --- | --- |
| `deinit()` | Releases parsed JSON allocations. Call this once when done. |
| `value()` | Returns the raw `std.json.Value`. Useful for debugging or custom dispatch. |
| `asRequest()` | Validates and views the value as a request or notification. |
| `asResponse()` | Validates and views the value as a response. |

Example:

```zig
var message = try conn.readMessage();
defer message.deinit();

std.debug.print("raw message: {any}\n", .{message.value()});

const response = try message.asResponse();
if (response.isError()) {
    std.debug.print("rpc error: {s}\n", .{response.rpc_error.?.message});
}
```

## Connection

`Connection` wraps an existing reader and writer. It does not spawn a process by
itself.

### `ConnectionOptions`

```zig
pub const ConnectionOptions = struct {
    max_message_len: usize = 1024 * 1024,
};
```

| Field | Default | Meaning |
| --- | ---: | --- |
| `max_message_len` | `1048576` | Maximum bytes read before a newline delimiter must appear. |

### `Connection.init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    options: ConnectionOptions,
) Connection;
```

Creates a connection over caller-owned streams.

| Parameter | Meaning |
| --- | --- |
| `allocator` | Used for parsed messages returned by `readMessage()`. |
| `reader` | Input stream used by `readMessage()`. |
| `writer` | Output stream used by all `send*` methods. |
| `options` | Message size limits. Use `.{}` for defaults. |

### `Connection.readMessage`

```zig
pub fn readMessage(self: *Connection) !ParsedMessage;
```

Reads one newline-delimited JSON frame, parses it, and returns an owned
`ParsedMessage`.

Behavior:

- Reads until `\n`, up to `max_message_len`.
- Accepts `\r\n` by trimming the trailing `\r`.
- Returns `error.EndOfStream` when the stream closes without buffered data.
- Returns JSON parse errors if the frame is not valid JSON.

### `Connection.sendRawJson`

```zig
pub fn sendRawJson(self: *Connection, json_message: []const u8) !void;
```

Writes `json_message`, appends `\n`, and flushes the writer. This method does
not validate that the string is valid JSON-RPC.

Example:

```zig
try conn.sendRawJson("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}");
```

Emits:

```json
{"jsonrpc":"2.0","method":"ping"}
```

### `Connection.sendRequest`

```zig
pub fn sendRequest(
    self: *Connection,
    id: Id,
    method: []const u8,
    params: anytype,
) !void;
```

Writes a JSON-RPC request with params.

| Parameter | Meaning |
| --- | --- |
| `id` | Request id. Use a string, integer, or `rpc.Id.null`. |
| `method` | Method name. Names starting with `rpc.` return `error.ReservedMethod`. |
| `params` | Any JSON-serializable Zig value. For parsed peer compatibility, prefer an object or array. |

Example:

```zig
try conn.sendRequest(.{ .integer = 1 }, "echo", .{ .message = "hello" });
```

Emits:

```json
{"jsonrpc":"2.0","method":"echo","params":{"message":"hello"},"id":1}
```

### `Connection.sendRequestNoParams`

```zig
pub fn sendRequestNoParams(
    self: *Connection,
    id: Id,
    method: []const u8,
) !void;
```

Writes a JSON-RPC request without a `params` member.

Example:

```zig
try conn.sendRequestNoParams(.{ .string = "health" }, "health");
```

Emits:

```json
{"jsonrpc":"2.0","method":"health","id":"health"}
```

### `Connection.sendNotification`

```zig
pub fn sendNotification(
    self: *Connection,
    method: []const u8,
    params: anytype,
) !void;
```

Writes a JSON-RPC notification with params. Notifications have no `id`, so the
receiver should not send a response.

Example:

```zig
try conn.sendNotification("log", .{ .message = "started" });
```

Emits:

```json
{"jsonrpc":"2.0","method":"log","params":{"message":"started"}}
```

### `Connection.sendNotificationNoParams`

```zig
pub fn sendNotificationNoParams(
    self: *Connection,
    method: []const u8,
) !void;
```

Writes a JSON-RPC notification without a `params` member.

Example:

```zig
try conn.sendNotificationNoParams("shutdown");
```

Emits:

```json
{"jsonrpc":"2.0","method":"shutdown"}
```

### `Connection.sendResult`

```zig
pub fn sendResult(self: *Connection, id: anytype, result: anytype) !void;
```

Writes a successful JSON-RPC response.

| Parameter | Meaning |
| --- | --- |
| `id` | The request id being answered. Usually pass `request.id.?`. |
| `result` | Any JSON-serializable Zig value. |

Example:

```zig
try conn.sendResult(request.id.?, .{ .ok = true });
```

Emits:

```json
{"jsonrpc":"2.0","result":{"ok":true},"id":1}
```

### `Connection.sendError`

```zig
pub fn sendError(
    self: *Connection,
    id: anytype,
    code: i64,
    message: []const u8,
) !void;
```

Writes a JSON-RPC error response without `error.data`.

Example:

```zig
try conn.sendError(request.id.?, -32000, "Backend unavailable");
```

Emits:

```json
{"jsonrpc":"2.0","error":{"code":-32000,"message":"Backend unavailable"},"id":1}
```

### `Connection.sendErrorWithData`

```zig
pub fn sendErrorWithData(
    self: *Connection,
    id: anytype,
    code: i64,
    message: []const u8,
    data: anytype,
) !void;
```

Writes a JSON-RPC error response with `error.data`.

Example:

```zig
try conn.sendErrorWithData(request.id.?, -32602, "Invalid params", .{
    .expected = "array of integers",
});
```

Emits:

```json
{"jsonrpc":"2.0","error":{"code":-32602,"message":"Invalid params","data":{"expected":"array of integers"}},"id":1}
```

### `Connection.sendPredefinedError`

```zig
pub fn sendPredefinedError(
    self: *Connection,
    id: anytype,
    code: ErrorCode,
) !void;
```

Writes a standard JSON-RPC error response using `ErrorCode.code()` and
`ErrorCode.message()`.

Example:

```zig
try conn.sendPredefinedError(request.id.?, .method_not_found);
```

Emits:

```json
{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}
```

## SubprocessClient

`SubprocessClient` spawns a child process and wires a `Connection` to the
child's stdout and stdin.

### `SubprocessOptions`

```zig
pub const SubprocessOptions = struct {
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 8192,
    max_message_len: usize = 1024 * 1024,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};
```

| Field | Default | Meaning |
| --- | --- | --- |
| `read_buffer_size` | `8192` | Buffer size for reading child stdout. |
| `write_buffer_size` | `8192` | Buffer size for writing child stdin. |
| `max_message_len` | `1048576` | Maximum frame size passed to the created `Connection`. |
| `cwd` | `.inherit` | Working directory for the child process. |
| `environ_map` | `null` | Optional environment map for the child process. |
| `stderr` | `.inherit` | Child stderr behavior. Keeping stderr inherited is useful for debug logs. |

### `SubprocessClient.init`

```zig
pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    options: SubprocessOptions,
) !SubprocessClient;
```

Spawns a child process with piped stdin and stdout.

| Parameter | Meaning |
| --- | --- |
| `allocator` | Used for IO buffers and parsed messages. |
| `io` | Zig IO context used for process and stream operations. |
| `argv` | Command and arguments for the child process. |
| `options` | Spawn and buffer options. Use `.{}` for defaults. |

Example:

```zig
var client = try rpc.SubprocessClient.init(
    gpa,
    io,
    &.{ "python3", "server.py" },
    .{},
);
defer client.deinit();
```

### `SubprocessClient.deinit`

```zig
pub fn deinit(self: *SubprocessClient) void;
```

Kills the child process if it is still running and frees internal buffers.

### `SubprocessClient.connection`

```zig
pub fn connection(self: *SubprocessClient) Connection;
```

Returns a `Connection` wired as:

```text
Connection.readMessage() -> child stdout
Connection.send*()       -> child stdin
```

### `SubprocessClient.closeInput`

```zig
pub fn closeInput(self: *SubprocessClient) !void;
```

Flushes and closes the child stdin pipe. Use this to tell a peer that no more
frames will be sent.

### `SubprocessClient.wait`

```zig
pub fn wait(self: *SubprocessClient) !std.process.Child.Term;
```

Waits for the child process to exit and returns its termination status.

## Protocol Validation Helpers

### `parseRequest`

```zig
pub fn parseRequest(value: JsonValue) ProtocolError!Request;
```

Validates a raw `JsonValue` as a JSON-RPC request or notification.

Validation rules:

- Top-level value must be an object.
- `jsonrpc` must be the string `"2.0"`.
- `method` must be a string.
- `method` must not start with `rpc.`.
- `params`, when present, must be an object or array.
- `id`, when present, must be a string, integer, or null.

### `parseResponse`

```zig
pub fn parseResponse(value: JsonValue) ProtocolError!Response;
```

Validates a raw `JsonValue` as a JSON-RPC response.

Validation rules:

- Top-level value must be an object.
- `jsonrpc` must be the string `"2.0"`.
- `id` is required and must be a string, integer, or null.
- Exactly one of `result` or `error` must be present.
- `error`, when present, must contain integer `code` and string `message`.
- `error.data` is optional and may be any JSON value.

### `validateMethodName`

```zig
pub fn validateMethodName(method: []const u8) ProtocolError!void;
```

Rejects JSON-RPC reserved method names. Any method that starts with `rpc.`
returns `error.ReservedMethod`.

## Common Payload Shapes

Request:

```json
{"jsonrpc":"2.0","method":"echo","params":{"message":"hello"},"id":1}
```

Notification:

```json
{"jsonrpc":"2.0","method":"log","params":{"message":"started"}}
```

Successful response:

```json
{"jsonrpc":"2.0","result":{"message":"hello"},"id":1}
```

Error response:

```json
{"jsonrpc":"2.0","error":{"code":-32601,"message":"Method not found"},"id":1}
```

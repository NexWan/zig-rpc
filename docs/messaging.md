# Messaging Guide

`zig-rpc` sends JSON-RPC 2.0 messages over standard input and standard output.
Each message is one compact JSON object followed by a newline byte (`\n`).

This is newline-delimited JSON:

```text
{"jsonrpc":"2.0","method":"echo","params":{"message":"hello"},"id":1}\n
{"jsonrpc":"2.0","result":{"message":"hello"},"id":1}\n
```

The JSON-RPC object describes what the message means. The newline tells the
receiver where the message ends.

## Process IO Direction

When a Zig process spawns a peer with `rpc.SubprocessClient`, the streams are
connected like this:

```text
Zig parent conn.sendRequest(...) -> child stdin
Zig parent conn.readMessage()    <- child stdout
child stderr                     -> debug logs
```

The child process sees the Zig parent's outgoing messages on `stdin`. The Zig
parent reads the child process responses from `stdout`.

Keep protocol messages on `stdout` only. Use `stderr` for debugging. In Zig,
`std.debug.print` writes to stderr by default, so it is safe for logging received
messages without corrupting the JSON-RPC stream.

## Requests, Responses, And Notifications

A request includes an `id` and expects one response with the same `id`:

```json
{"jsonrpc":"2.0","method":"add","params":[10,20,12],"id":"sum"}
```

The response contains either `result` or `error`:

```json
{"jsonrpc":"2.0","result":42,"id":"sum"}
```

A notification has no `id`, so the receiver should not send a response:

```json
{"jsonrpc":"2.0","method":"echo","params":{"ignored":true}}
```

## Zig Parent Sending To A Python Peer

This is the client-side flow used when Zig starts a Python subprocess:

```zig
const std = @import("std");
const rpc = @import("zig_rpc");

pub fn main(init: std.process.Init) !void {
    var client = try rpc.SubprocessClient.init(
        init.gpa,
        init.io,
        &.{ "python3", "server.py" },
        .{},
    );
    defer client.deinit();

    var conn = client.connection();

    try conn.sendRequest(.{ .integer = 7 }, "echo", .{
        .language = "python",
        .ok = true,
    });

    var message = try conn.readMessage();
    defer message.deinit();

    const response = try message.asResponse();
    if (response.rpc_error) |err| {
        std.debug.print("python returned JSON-RPC error {d}: {s}\n", .{
            err.code,
            err.message,
        });
        return;
    }

    std.debug.print("received response JSON: ", .{});
    message.value().dump();
    std.debug.print("\n", .{});

    std.debug.print("received response id: ", .{});
    response.id.dump();
    std.debug.print("\n", .{});

    const json = try response.asJson();
    debugJsonValue("python result", json.result);

    try client.closeInput();
    _ = try client.wait();
}

fn debugJsonValue(label: []const u8, value: std.json.Value) void {
    std.debug.print("{s} JSON: ", .{label});
    value.dump();
    std.debug.print("\n", .{});

    switch (value) {
        .null => std.debug.print("{s}: null\n", .{label}),
        .bool => |item| std.debug.print("{s}: {}\n", .{ label, item }),
        .integer => |item| std.debug.print("{s}: {d}\n", .{ label, item }),
        .float => |item| std.debug.print("{s}: {d}\n", .{ label, item }),
        .number_string => |item| std.debug.print("{s}: {s}\n", .{ label, item }),
        .string => |item| std.debug.print("{s}: {s}\n", .{ label, item }),
        .array => |items| std.debug.print("{s}: array with {d} item(s)\n", .{
            label,
            items.items.len,
        }),
        .object => |object| {
            std.debug.print("{s}: object\n", .{label});
            if (object.get("message")) |item| debugJsonValue("  message", item);
            if (object.get("language")) |item| debugJsonValue("  language", item);
            if (object.get("ok")) |item| debugJsonValue("  ok", item);
        },
        else => std.debug.print("{s}: {any}\n", .{ label, value }),
    }
}
```

`std.json.Value` is a tagged union. Printing it directly with `{any}` shows
Zig's internal representation of that value, which is useful for debugging the
parser but noisy for application logs. Switch on the JSON tag and use formatters
like `{s}` for strings when you want readable output. Use `value.dump()` when
you want to see the parsed value encoded back as JSON.

For a Python response like:

```json
{"jsonrpc":"2.0","result":"Hello, world! from Python","id":1}
```

the readable stderr output is:

```text
received response JSON: {"jsonrpc":"2.0","result":"Hello, world! from Python","id":1}
received response id: 1
python result JSON: "Hello, world! from Python"
python result: Hello, world! from Python
```

The protocol response itself still stays on stdout as newline-delimited JSON.

The request written by Zig is:

```json
{"jsonrpc":"2.0","method":"echo","params":{"language":"python","ok":true},"id":7}
```

The response read back from Python is:

```json
{"jsonrpc":"2.0","result":{"language":"python","ok":true},"id":7}
```

## Python Receiving Zig Messages

A Python peer receives one JSON-RPC frame per stdin line. It should decode the
line, process the request, then print one compact JSON response to stdout and
flush it.

```python
import json
import sys


def error_response(request_id, code, message):
    return {
        "jsonrpc": "2.0",
        "error": {"code": code, "message": message},
        "id": request_id,
    }


for line in sys.stdin:
    try:
        request = json.loads(line)
    except json.JSONDecodeError:
        print(
            json.dumps(error_response(None, -32700, "Parse error"), separators=(",", ":")),
            flush=True,
        )
        continue

    print(f"received from zig: {request!r}", file=sys.stderr, flush=True)

    request_id = request.get("id")
    if "id" not in request:
        continue

    if request.get("jsonrpc") != "2.0" or not isinstance(request.get("method"), str):
        response = error_response(request_id, -32600, "Invalid Request")
    elif request["method"] == "echo":
        response = {"jsonrpc": "2.0", "result": request.get("params"), "id": request_id}
    elif request["method"] == "add":
        params = request.get("params")
        if isinstance(params, list) and all(isinstance(item, int) for item in params):
            response = {"jsonrpc": "2.0", "result": sum(params), "id": request_id}
        else:
            response = error_response(request_id, -32602, "Invalid params")
    else:
        response = error_response(request_id, -32601, "Method not found")

    print(json.dumps(response, separators=(",", ":")), flush=True)
```

Important details:

- `for line in sys.stdin` matches the newline framing used by `zig-rpc`.
- `json.dumps(..., separators=(",", ":"))` keeps the response compact, but any
  valid single-line JSON object works.
- `flush=True` sends the response immediately. Without it, Zig may block while
  waiting for `conn.readMessage()`.
- Debug output goes to `sys.stderr`, not `stdout`.

## Zig Receiving Python Messages

A Zig peer can also be the process that receives messages on stdin and publishes
responses on stdout. The core loop is:

```zig
const std = @import("std");
const rpc = @import("zig_rpc");

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdout_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var conn = rpc.Connection.init(
        init.gpa,
        &stdin_reader.interface,
        &stdout_writer.interface,
        .{},
    );

    while (true) {
        var message = conn.readMessage() catch |err| switch (err) {
            error.EndOfStream => return,
            else => {
                try conn.sendPredefinedError(rpc.Id.null, .parse_error);
                return err;
            },
        };
        defer message.deinit();

        const request = message.asRequest() catch {
            try conn.sendPredefinedError(rpc.Id.null, .invalid_request);
            continue;
        };

        std.debug.print("received method: {s}\n", .{request.method});

        if (request.isNotification()) {
            std.debug.print("notification method={s}\n", .{request.method});
            continue;
        }

        if (std.mem.eql(u8, request.method, "echo")) {
            try conn.sendResult(request.id.?, request.params orelse std.json.Value.null);
        } else if (std.mem.eql(u8, request.method, "add")) {
            const params = request.params orelse {
                try conn.sendPredefinedError(request.id.?, .invalid_params);
                continue;
            };
            const result = sumParams(params) catch {
                try conn.sendPredefinedError(request.id.?, .invalid_params);
                continue;
            };
            try conn.sendResult(request.id.?, result);
        } else {
            try conn.sendPredefinedError(request.id.?, .method_not_found);
        }
    }
}

fn sumParams(params: std.json.Value) !i64 {
    const items = switch (params) {
        .array => |array| array.items,
        else => return error.InvalidParams,
    };

    var total: i64 = 0;
    for (items) |item| {
        total += switch (item) {
            .integer => |value| value,
            else => return error.InvalidParams,
        };
    }
    return total;
}
```

When Python sends:

```json
{"jsonrpc":"2.0","method":"add","params":[4,5,6],"id":8}
```

The Zig peer writes this response to stdout:

```json
{"jsonrpc":"2.0","result":15,"id":8}
```

## Python Publishing To A Zig Peer

Python can spawn a Zig executable and write JSON-RPC frames to its stdin. The
same newline framing applies in the opposite direction.

```python
import json
import subprocess


child = subprocess.Popen(
    ["./zig-peer"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=None,
    text=True,
)


def call(method, params, request_id):
    request = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": request_id,
    }
    child.stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
    child.stdin.flush()

    line = child.stdout.readline()
    if line == "":
        raise RuntimeError("zig peer closed stdout")
    return json.loads(line)


print(call("echo", {"from": "python"}, 1))
print(call("add", [4, 5, 6], 2))

child.stdin.close()
child.wait()
```

The first `call` writes this to the Zig peer stdin:

```json
{"jsonrpc":"2.0","method":"echo","params":{"from":"python"},"id":1}
```

The Zig peer receives it through `conn.readMessage()`, parses it with
`message.asRequest()`, and publishes the response with `conn.sendResult(...)`.
Python reads that response from `child.stdout.readline()`.

## API Reference For Message Flow

- `Connection.readMessage()` reads one newline-delimited JSON frame and returns a
  parsed message that owns its JSON memory.
- `ParsedMessage.value()` returns the raw parsed `std.json.Value`.
- `ParsedMessage.asRequest()` validates and views the message as a JSON-RPC
  request or notification.
- `ParsedMessage.asResponse()` validates and views the message as a JSON-RPC
  response.
- `Response.asJson()` returns a success-only response view with `id` and
  non-optional `result`.
- `Response.asText()` returns the string result for successful text responses.
- `Connection.sendRequest(...)` writes a request and flushes the frame.
- `Connection.sendNotification(...)` writes a notification and flushes the
  frame.
- `Connection.sendResult(...)` writes a successful response and flushes the
  frame.
- `Connection.sendPredefinedError(...)` writes a standard JSON-RPC error and
  flushes the frame.
- `SubprocessClient.connection()` returns a `Connection` wired to the child
  process stdout and stdin.

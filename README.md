# zig-rpc

JSON-RPC 2.0 helpers for Zig applications that communicate with subprocesses over STDIO.

The transport uses newline-delimited JSON frames: each JSON-RPC request, notification, or response is serialized as one compact JSON object followed by `\n`. JSON-RPC 2.0 is transport-agnostic, so this package keeps the protocol object rules separate from the STDIO framing.

## Use As A Dependency

Expose the module from this package in your project:

```zig
const zig_rpc_dep = b.dependency("zig_rpc", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zig_rpc", zig_rpc_dep.module("zig_rpc"));
```

Then import it:

```zig
const rpc = @import("zig_rpc");
```

## Spawn A STDIO Peer

```zig
var client = try rpc.SubprocessClient.init(gpa, io, &.{ "python3", "server.py" }, .{});
defer client.deinit();

var conn = client.connection();
try conn.sendRequest(.{ .integer = 1 }, "echo", .{ .message = "hello" });

var message = try conn.readMessage();
defer message.deinit();

const response = try message.asResponse();
```

Applications that already own the streams can use `rpc.Connection` directly with `*std.Io.Reader` and `*std.Io.Writer`.

For a fuller walkthrough of how request, response, and notification frames move
between Zig and Python processes, including `std.debug.print()` examples, see
[docs/messaging.md](docs/messaging.md).

## Validate

```sh
zig build test
```

The test step runs unit tests plus STDIO integration checks against a Zig subprocess and a Python subprocess.

## Fetch A Tagged Release

After a version tag is pushed, consume the package with:

```sh
zig fetch --save https://github.com/NexWan/zig-rpc/archive/refs/tags/<VERSION>.tar.gz
```

For example:

```sh
zig fetch --save https://github.com/NexWan/zig-rpc/archive/refs/tags/v0.1.0.tar.gz
```

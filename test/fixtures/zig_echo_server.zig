const std = @import("std");
const rpc = @import("zig_rpc");

pub fn main(init: std.process.Init) !void {
    var stdin_buffer: [8192]u8 = undefined;
    var stdout_buffer: [8192]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    var conn = rpc.Connection.init(init.gpa, &stdin_reader.interface, &stdout_writer.interface, .{});

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

        if (request.isNotification()) continue;

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

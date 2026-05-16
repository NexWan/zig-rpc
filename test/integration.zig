const std = @import("std");
const rpc = @import("zig_rpc");

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();

    _ = args.next() orelse return error.InvalidTestArguments;
    const zig_server_path = args.next() orelse return error.InvalidTestArguments;
    const python_script_path = args.next() orelse return error.InvalidTestArguments;
    if (args.next() != null) return error.InvalidTestArguments;

    try exerciseZigPeer(init.gpa, init.io, zig_server_path);
    try exercisePythonPeer(init.gpa, init.io, python_script_path);
}

fn exerciseZigPeer(gpa: std.mem.Allocator, io: std.Io, server_path: []const u8) !void {
    var client = try rpc.SubprocessClient.init(gpa, io, &.{server_path}, .{});
    defer client.deinit();

    var conn = client.connection();

    try conn.sendRequest(.{ .integer = 1 }, "echo", .{ .message = "hello from zig", .count = 2 });
    var echo_message = try conn.readMessage();
    defer echo_message.deinit();
    const echo_response = try echo_message.asResponse();
    try expectNoRpcError(echo_response);
    const echo_json = try echo_response.asJson();
    try expectEqualStrings("hello from zig", echo_json.result.object.get("message").?.string);
    try expectEqualInt(2, echo_json.result.object.get("count").?.integer);

    try conn.sendNotification("echo", .{ .ignored = true });

    try conn.sendRequest(.{ .string = "sum" }, "add", .{ 10, 20, 12 });
    var sum_message = try conn.readMessage();
    defer sum_message.deinit();
    const sum_response = try sum_message.asResponse();
    try expectNoRpcError(sum_response);
    const sum_json = try sum_response.asJson();
    try expectEqualInt(42, sum_json.result.integer);

    try client.closeInput();
    try expectExitedZero(try client.wait());
}

fn exercisePythonPeer(gpa: std.mem.Allocator, io: std.Io, script_path: []const u8) !void {
    var client = try rpc.SubprocessClient.init(gpa, io, &.{ "python3", script_path }, .{});
    defer client.deinit();

    var conn = client.connection();

    try conn.sendRequest(.{ .integer = 7 }, "echo", .{ .language = "python", .ok = true });
    var echo_message = try conn.readMessage();
    defer echo_message.deinit();
    const echo_response = try echo_message.asResponse();
    try expectNoRpcError(echo_response);
    const echo_json = try echo_response.asJson();
    try expectEqualStrings("python", echo_json.result.object.get("language").?.string);
    try expect(echo_json.result.object.get("ok").?.bool);

    try conn.sendRequest(.{ .integer = 8 }, "add", .{ 4, 5, 6 });
    var add_message = try conn.readMessage();
    defer add_message.deinit();
    const add_response = try add_message.asResponse();
    try expectNoRpcError(add_response);
    const add_json = try add_response.asJson();
    try expectEqualInt(15, add_json.result.integer);

    try client.closeInput();
    try expectExitedZero(try client.wait());
}

fn expectNoRpcError(response: rpc.Response) !void {
    if (response.rpc_error != null) return error.UnexpectedRpcError;
}

fn expect(condition: bool) !void {
    if (!condition) return error.ExpectationFailed;
}

fn expectEqualStrings(expected: []const u8, actual: []const u8) !void {
    if (!std.mem.eql(u8, expected, actual)) return error.ExpectationFailed;
}

fn expectEqualInt(expected: i64, actual: i64) !void {
    if (expected != actual) return error.ExpectationFailed;
}

fn expectExitedZero(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code == 0) return else return error.ChildExitedNonZero,
        else => return error.ChildDidNotExitNormally,
    }
}

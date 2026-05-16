const std = @import("std");

pub const version = "0.1.0";
pub const JsonValue = std.json.Value;

pub const ErrorCode = enum(i64) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    pub fn code(self: ErrorCode) i64 {
        return @intFromEnum(self);
    }

    pub fn message(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        };
    }
};

pub const Id = union(enum) {
    string: []const u8,
    integer: i64,
    null,

    pub fn jsonStringify(self: Id, writer: anytype) !void {
        switch (self) {
            .string => |value| try writer.write(value),
            .integer => |value| try writer.write(value),
            .null => try writer.write(null),
        }
    }
};

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

pub const Request = struct {
    method: []const u8,
    params: ?JsonValue,
    id: ?JsonValue,

    pub fn isNotification(self: Request) bool {
        return self.id == null;
    }
};

pub const RpcErrorView = struct {
    code: i64,
    message: []const u8,
    data: ?JsonValue,
};

pub const Response = struct {
    id: JsonValue,
    result: ?JsonValue,
    rpc_error: ?RpcErrorView,

    pub fn isError(self: Response) bool {
        return self.rpc_error != null;
    }
};

pub const ParsedMessage = struct {
    parsed: std.json.Parsed(JsonValue),

    pub fn deinit(self: *ParsedMessage) void {
        self.parsed.deinit();
    }

    pub fn value(self: *const ParsedMessage) JsonValue {
        return self.parsed.value;
    }

    pub fn asRequest(self: *const ParsedMessage) ProtocolError!Request {
        return parseRequest(self.parsed.value);
    }

    pub fn asResponse(self: *const ParsedMessage) ProtocolError!Response {
        return parseResponse(self.parsed.value);
    }
};

pub const ConnectionOptions = struct {
    max_message_len: usize = 1024 * 1024,
};

pub const Connection = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
    max_message_len: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        reader: *std.Io.Reader,
        writer: *std.Io.Writer,
        options: ConnectionOptions,
    ) Connection {
        return .{
            .allocator = allocator,
            .reader = reader,
            .writer = writer,
            .max_message_len = options.max_message_len,
        };
    }

    pub fn readMessage(self: *Connection) !ParsedMessage {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        _ = try self.reader.streamDelimiterLimit(&out.writer, '\n', .limited(self.max_message_len));
        const found_delimiter = self.reader.seek < self.reader.end and self.reader.buffer[self.reader.seek] == '\n';
        if (found_delimiter) {
            self.reader.toss(1);
        } else if (out.written().len == 0) {
            return error.EndOfStream;
        }

        var line = out.written();
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        return .{
            .parsed = try std.json.parseFromSlice(JsonValue, self.allocator, line, .{
                .allocate = .alloc_always,
            }),
        };
    }

    pub fn sendRawJson(self: *Connection, json_message: []const u8) !void {
        try self.writer.writeAll(json_message);
        try self.finishFrame();
    }

    pub fn sendRequest(self: *Connection, id: Id, method: []const u8, params: anytype) !void {
        try validateMethodName(method);

        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("method");
        try stream.write(method);
        try stream.objectField("params");
        try stream.write(params);
        try stream.objectField("id");
        try stream.write(id);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendRequestNoParams(self: *Connection, id: Id, method: []const u8) !void {
        try validateMethodName(method);

        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("method");
        try stream.write(method);
        try stream.objectField("id");
        try stream.write(id);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendNotification(self: *Connection, method: []const u8, params: anytype) !void {
        try validateMethodName(method);

        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("method");
        try stream.write(method);
        try stream.objectField("params");
        try stream.write(params);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendNotificationNoParams(self: *Connection, method: []const u8) !void {
        try validateMethodName(method);

        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("method");
        try stream.write(method);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendResult(self: *Connection, id: anytype, result: anytype) !void {
        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("result");
        try stream.write(result);
        try stream.objectField("id");
        try stream.write(id);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendError(self: *Connection, id: anytype, code: i64, message: []const u8) !void {
        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("error");
        try writeErrorObject(&stream, code, message, null);
        try stream.objectField("id");
        try stream.write(id);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendErrorWithData(
        self: *Connection,
        id: anytype,
        code: i64,
        message: []const u8,
        data: anytype,
    ) !void {
        var stream: std.json.Stringify = .{ .writer = self.writer, .options = .{} };
        try stream.beginObject();
        try stream.objectField("jsonrpc");
        try stream.write("2.0");
        try stream.objectField("error");
        try writeErrorObject(&stream, code, message, data);
        try stream.objectField("id");
        try stream.write(id);
        try stream.endObject();
        try self.finishFrame();
    }

    pub fn sendPredefinedError(self: *Connection, id: anytype, code: ErrorCode) !void {
        try self.sendError(id, code.code(), code.message());
    }

    fn finishFrame(self: *Connection) !void {
        try self.writer.writeAll("\n");
        try self.writer.flush();
    }
};

pub const SubprocessOptions = struct {
    read_buffer_size: usize = 8192,
    write_buffer_size: usize = 8192,
    max_message_len: usize = 1024 * 1024,
    cwd: std.process.Child.Cwd = .inherit,
    environ_map: ?*const std.process.Environ.Map = null,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
};

pub const SubprocessClient = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    child: std.process.Child,
    reader_buffer: []u8,
    writer_buffer: []u8,
    stdout_reader: std.Io.File.Reader,
    stdin_writer: std.Io.File.Writer,
    max_message_len: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        argv: []const []const u8,
        options: SubprocessOptions,
    ) !SubprocessClient {
        const reader_buffer = try allocator.alloc(u8, options.read_buffer_size);
        errdefer allocator.free(reader_buffer);

        const writer_buffer = try allocator.alloc(u8, options.write_buffer_size);
        errdefer allocator.free(writer_buffer);

        var child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = options.cwd,
            .environ_map = options.environ_map,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = options.stderr,
        });
        errdefer child.kill(io);

        const stdout_file = child.stdout orelse return error.MissingStdoutPipe;
        const stdin_file = child.stdin orelse return error.MissingStdinPipe;

        return .{
            .allocator = allocator,
            .io = io,
            .child = child,
            .reader_buffer = reader_buffer,
            .writer_buffer = writer_buffer,
            .stdout_reader = stdout_file.readerStreaming(io, reader_buffer),
            .stdin_writer = stdin_file.writerStreaming(io, writer_buffer),
            .max_message_len = options.max_message_len,
        };
    }

    pub fn deinit(self: *SubprocessClient) void {
        if (self.child.id != null) {
            self.child.kill(self.io);
        }
        self.allocator.free(self.reader_buffer);
        self.allocator.free(self.writer_buffer);
        self.* = undefined;
    }

    pub fn connection(self: *SubprocessClient) Connection {
        return Connection.init(
            self.allocator,
            &self.stdout_reader.interface,
            &self.stdin_writer.interface,
            .{ .max_message_len = self.max_message_len },
        );
    }

    pub fn closeInput(self: *SubprocessClient) !void {
        try self.stdin_writer.interface.flush();
        if (self.child.stdin) |stdin_file| {
            stdin_file.close(self.io);
            self.child.stdin = null;
        }
    }

    pub fn wait(self: *SubprocessClient) !std.process.Child.Term {
        return self.child.wait(self.io);
    }
};

pub fn parseRequest(value: JsonValue) ProtocolError!Request {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidRequest,
    };

    try validateJsonRpcVersion(object);

    const method_value = object.get("method") orelse return error.InvalidMethod;
    const method = switch (method_value) {
        .string => |method| method,
        else => return error.InvalidMethod,
    };
    try validateMethodName(method);

    const params = object.get("params");
    if (params) |params_value| try validateParams(params_value);

    const id = object.get("id");
    if (id) |id_value| try validateId(id_value);

    return .{
        .method = method,
        .params = params,
        .id = id,
    };
}

pub fn parseResponse(value: JsonValue) ProtocolError!Response {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidResponse,
    };

    try validateJsonRpcVersion(object);

    const id = object.get("id") orelse return error.ResponseMissingId;
    try validateId(id);

    const result = object.get("result");
    const error_value = object.get("error");

    if (result != null and error_value != null) return error.ResponseHasResultAndError;
    if (result == null and error_value == null) return error.ResponseMissingResultOrError;

    return .{
        .id = id,
        .result = result,
        .rpc_error = if (error_value) |err| try parseErrorObject(err) else null,
    };
}

pub fn validateMethodName(method: []const u8) ProtocolError!void {
    if (std.mem.startsWith(u8, method, "rpc.")) return error.ReservedMethod;
}

fn validateJsonRpcVersion(object: std.json.ObjectMap) ProtocolError!void {
    const version_value = object.get("jsonrpc") orelse return error.InvalidVersion;
    const version_text = switch (version_value) {
        .string => |text| text,
        else => return error.InvalidVersion,
    };
    if (!std.mem.eql(u8, version_text, "2.0")) return error.InvalidVersion;
}

fn validateParams(value: JsonValue) ProtocolError!void {
    switch (value) {
        .array, .object => {},
        else => return error.InvalidParams,
    }
}

fn validateId(value: JsonValue) ProtocolError!void {
    switch (value) {
        .string, .integer, .null => {},
        else => return error.InvalidId,
    }
}

fn parseErrorObject(value: JsonValue) ProtocolError!RpcErrorView {
    const object = switch (value) {
        .object => |object| object,
        else => return error.InvalidError,
    };

    const code_value = object.get("code") orelse return error.InvalidError;
    const code = switch (code_value) {
        .integer => |code| code,
        else => return error.InvalidError,
    };

    const message_value = object.get("message") orelse return error.InvalidError;
    const message = switch (message_value) {
        .string => |message| message,
        else => return error.InvalidError,
    };

    return .{
        .code = code,
        .message = message,
        .data = object.get("data"),
    };
}

fn writeErrorObject(stream: *std.json.Stringify, code: i64, message: []const u8, data: anytype) !void {
    try stream.beginObject();
    try stream.objectField("code");
    try stream.write(code);
    try stream.objectField("message");
    try stream.write(message);
    if (@TypeOf(data) != @TypeOf(null)) {
        try stream.objectField("data");
        try stream.write(data);
    }
    try stream.endObject();
}

test "send request uses JSON-RPC 2.0 object shape and newline frame" {
    var reader: std.Io.Reader = .fixed("");
    var output = [_]u8{0} ** 256;
    var writer: std.Io.Writer = .fixed(&output);
    var conn = Connection.init(std.testing.allocator, &reader, &writer, .{});

    try conn.sendRequest(.{ .integer = 1 }, "subtract", .{ 42, 23 });

    try std.testing.expectEqualStrings(
        "{\"jsonrpc\":\"2.0\",\"method\":\"subtract\",\"params\":[42,23],\"id\":1}\n",
        writer.buffered(),
    );
}

test "read response parses owned JSON values" {
    var reader: std.Io.Reader = .fixed("{\"jsonrpc\":\"2.0\",\"result\":{\"ok\":true},\"id\":\"abc\"}\n");
    var output = [_]u8{0} ** 16;
    var writer: std.Io.Writer = .fixed(&output);
    var conn = Connection.init(std.testing.allocator, &reader, &writer, .{});

    var message = try conn.readMessage();
    defer message.deinit();

    const response = try message.asResponse();
    try std.testing.expectEqualStrings("abc", response.id.string);
    try std.testing.expect(response.result.?.object.get("ok").?.bool);
}

test "request validation rejects non-structured params and reserved method names" {
    var invalid_params = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"sum\",\"params\":1,\"id\":1}", .{
        .allocate = .alloc_always,
    });
    defer invalid_params.deinit();

    try std.testing.expectError(error.InvalidParams, parseRequest(invalid_params.value));

    var reserved = try std.json.parseFromSlice(JsonValue, std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"rpc.discover\",\"id\":1}", .{
        .allocate = .alloc_always,
    });
    defer reserved.deinit();

    try std.testing.expectError(error.ReservedMethod, parseRequest(reserved.value));
}

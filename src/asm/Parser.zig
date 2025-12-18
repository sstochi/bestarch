const std = @import("std");
const isa = @import("../cpu/isa.zig");
const Assembler = @import("Assembler.zig");
const Token = @import("Token.zig");
const Reg = isa.Reg;
const CtlReg = isa.CtlReg;

const Self = @This();

buf: []const u8,
idx: usize = 0,
next_token: ?Token = null,

err_msg: ?[]u8 = null,
err_buf: [512]u8 = undefined,

pub fn integer(self: *Self, comptime T: type) Assembler.Error!T {
    const value = try self.expect(.integer) orelse {
        return self.err("Expected an immediate of type {s}", .{@typeName(T)});
    };
    return try self.intCast(T, value);
}

pub fn register(self: *Self, name: []const u8) Assembler.Error!Reg {
    return try self.expect(.reg) orelse {
        return self.err("Expected {s} register", .{name});
    };
}

pub fn ctlRegister(self: *Self, name: []const u8) Assembler.Error!CtlReg {
    return try self.expect(.ctl_reg) orelse {
        return self.err("Expected {s} register", .{name});
    };
}

pub fn operator(self: *Self, comptime kind: Token.Kind) Assembler.Error!void {
    return try self.expect(kind) orelse {
        return self.err("Expected {t}", .{kind});
    };
}

pub fn checkLabel(self: *Self, name: []const u8) Assembler.Error![]const u8 {
    if (!std.mem.startsWith(u8, name, ".")) {
        return self.err("Expected a . before label name", .{});
    }
    if (name.len <= 1) {
        return self.err("Empty label", .{});
    }
    return name[1..];
}

pub fn expect(self: *Self, comptime kind: Token.Kind) Assembler.Error!?@FieldType(Token.Data, @tagName(kind)) {
    const t = try self.peek();
    if (@as(Token.Kind, t.data) != kind) return null;
    self.skip();
    return @field(t.data, @tagName(kind));
}

pub fn err(self: *Self, comptime fmt: []const u8, args: anytype) Assembler.Error {
    self.err_msg = try std.fmt.bufPrint(&self.err_buf, fmt, args);
    return error.ParseError;
}

pub fn intCast(self: *Self, comptime T: type, value: i64) Assembler.Error!T {
    return std.math.cast(T, value) orelse {
        return self.err("Value of {} doesn't fit into an integer of type {s}", .{ value, @typeName(T) });
    };
}

pub fn token(self: *Self) Assembler.Error!Token {
    while (true) {
        if (self.next_token) |next| {
            self.next_token = null;
            return next;
        }

        const start = self.idx;
        const c = self.nextByte();

        const kind: Token.Data = b: switch (c) {
            ' ', '\t'...'\r' => {
                while (true) {
                    const n = self.peekByte();
                    switch (n) {
                        ' ', '\t'...'\r' => self.skipByte(),
                        else => break,
                    }
                }
                continue;
            },
            '#' => {
                while (true) {
                    switch (self.nextByte()) {
                        '\x00', '\n' => break,
                        else => {},
                    }
                }
                continue;
            },
            '_', '.', ':', 'a'...'z', 'A'...'Z' => {
                while (true) {
                    const n = self.peekByte();
                    switch (n) {
                        '_', '.', ':', 'a'...'z', 'A'...'Z', '0'...'9' => self.skipByte(),
                        else => break,
                    }
                }
                const source = self.buf[start..self.idx];
                if (std.meta.stringToEnum(Reg, source)) |reg| break :b Token.Data{ .reg = reg };
                if (std.meta.stringToEnum(CtlReg, source)) |ctl_reg| break :b Token.Data{ .ctl_reg = ctl_reg };
                if (std.meta.stringToEnum(Token.Keyword, source)) |keyword| break :b Token.Data{ .keyword = keyword };
                break :b Token.Data{ .ident = source };
            },
            '-', '0'...'9' => {
                const neg = c == '-';

                var consumed: usize = 0;
                var value: i64 = 0;
                var base: u8 = 10;

                if (!neg) self.idx = start;

                const s = self.idx;

                if (self.takeByte('0')) {
                    if (self.takeByte('b')) {
                        base = 2;
                    } else if (self.takeByte('x')) {
                        base = 16;
                    } else {
                        self.idx = s;
                    }
                }

                while (true) : (consumed += 1) {
                    const n = self.peekByte();
                    switch (n) {
                        '0'...'9', 'A'...'Z', 'a'...'z' => self.skipByte(),
                        else => break,
                    }
                    value *%= base;
                    value += std.fmt.charToDigit(n, base) catch return error.ParseError;
                }

                if (consumed < 1) return error.ParseError;

                if (neg) {
                    value = -%value;
                }

                break :b Token.Data{ .integer = value };
            },
            ',' => .@",",
            '+' => .@"+",
            '!' => .@"!",
            '<' => if (self.takeByte('<')) .@"<<" else continue,
            '>' => if (self.takeByte('>')) .@">>" else continue,
            '\x00' => .eof,
            else => return self.err("Unexpected token: {c}", .{c}),
        };
        const source = self.buf[start..self.idx];
        return Token{ .data = kind, .source = source };
    }
}

pub fn peek(self: *Self) Assembler.Error!Token {
    const t = try self.token();
    self.next_token = t;
    return t;
}

pub fn skip(self: *Self) void {
    std.debug.assert(self.next_token != null);
    self.next_token = null;
}

fn skipByte(self: *Self) void {
    std.debug.assert(self.idx < self.buf.len);
    self.idx += 1;
}

fn nextByte(self: *Self) u8 {
    if (self.idx >= self.buf.len) return '\x00';
    self.skipByte();
    return self.buf[self.idx - 1];
}

fn peekByte(self: *Self) u8 {
    if (self.idx >= self.buf.len) return '\x00';
    return self.buf[self.idx];
}

fn takeByte(self: *Self, byte: u8) bool {
    if (self.peekByte() != byte) return false;
    self.skipByte();
    return true;
}

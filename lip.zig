const std = @import("std");
const allocator = std.heap.page_allocator;
const ArrayList = std.ArrayList;

const opMap = std.ComptimeStringMap(Op, .{
    .{ "+", Op.Add },
    .{ "-", Op.Sub },
    .{ "*", Op.Mul },
    .{ "define", Op.Define },
});

const Tokenator = std.mem.TokenIterator(u8, std.mem.DelimiterType.scalar);
const Env = std.StringHashMap(Exp);
const SyntaxError = error{UnexpectedParent};
const Op = enum { Add, Sub, Mul, Define };

const SymbolType = enum { number, reference };
const Symbol = union(SymbolType) { number: i32, reference: []u8 };

const ListExp = struct {
    op: Op,
    v: ArrayList(*const Exp),
};

const ExpType = enum { atomic, list };
const Exp = union(ExpType) {
    atomic: Symbol,
    list: ListExp,
};

pub fn main() !void {
    var buf_reader = std.io.bufferedReader(std.io.getStdIn().reader());
    var buf: [1024]u8 = undefined;

    while (try buf_reader.reader().readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const ast = try parse(allocator, line);
        print(ast);
        var env = Env.init(allocator);
        defer env.deinit();
        std.debug.print(" = {any}", .{eval(ast, &env).number});
        std.debug.print("\n", .{});
    }
}

pub fn print(exp: *const Exp, env: *const Env) void {
    switch (exp.*) {
        ExpType.atomic => |symbol| {
            switch (symbol) {
                Symbol.number => |number| std.debug.print(" {any}", .{number}),
                Symbol.reference => |reference| std.debug.print(" {any}", .{env.get(reference)}),
            }
        },
        ExpType.list => |list| {
            std.debug.print("({any}", .{list.op});
            for (list.v.items) |item| {
                print(item);
            }
            std.debug.print(")", .{});
        },
    }
}

pub fn parse(all: std.mem.Allocator, line: []const u8) !*const Exp {
    const input = try preprocess(line, all);
    defer all.free(input);
    var tokens: Tokenator = std.mem.tokenizeScalar(u8, input, ' ');
    return try readAst(&tokens, all);
}

pub fn eval(exp: *const Exp, env: *Env) Symbol {
    return switch (exp.*) {
        ExpType.atomic => |v| v,
        ExpType.list => |list| {
            return switch (list.op) {
                Op.Add => {
                    var acc = eval(list.v.items[0], env);
                    for (list.v.items[1..]) |item| {
                        acc = Symbol{ .number = acc.number + eval(item, env).number };
                    }
                    return acc;
                },
                Op.Sub => {
                    var acc = eval(list.v.items[0], env);
                    for (list.v.items[1..]) |item| {
                        acc = acc - eval(item, env).number;
                    }
                    return Symbol{ .number = acc };
                },
                Op.Mul => {
                    var acc = eval(list.v.items[0], env);
                    for (list.v.items[1..]) |item| {
                        acc = acc * eval(item, env).number;
                    }
                    return Symbol{ .number = acc };
                },
                Op.Define => {
                    env.put(list.v.items[0].reference, list.v.items[1]);
                    return Symbol{ .reference = list.v.items[0] };
                },
            };
        },
    };
}

pub fn preprocess(line: []const u8, all: std.mem.Allocator) ![]u8 {
    // add whitespaces before and after paren to simplify tokenization
    var size = std.mem.replacementSize(u8, line, "(", " ( ");
    const leftParen = try all.alloc(u8, size);
    defer allocator.free(leftParen);
    _ = std.mem.replace(u8, line, "(", " ( ", leftParen);
    size = std.mem.replacementSize(u8, leftParen, ")", " ) ");
    const rightParen = try all.alloc(u8, size);
    _ = std.mem.replace(u8, leftParen, ")", " ) ", rightParen);
    return rightParen;
}

pub fn readAst(input: *Tokenator, all: std.mem.Allocator) !*const Exp {
    var tokens = input;
    if (tokens.next()) |token| {
        if (std.mem.eql(u8, token, "(")) {
            if (opMap.has(tokens.peek() orelse unreachable)) {
                const op = opMap.get(tokens.next().?) orelse unreachable;
                var list = ArrayList(*const Exp).init(all);
                while (!std.mem.eql(u8, tokens.peek() orelse unreachable, ")")) {
                    const subtree = try readAst(tokens, all);
                    try list.append(subtree);
                }
                const listExp = try all.create(ListExp);
                listExp.* = .{ .op = op, .v = list };

                const toReturn = try all.create(Exp);
                toReturn.* = .{ .list = listExp.* };
                _ = tokens.next();
                return toReturn;
            }
        } else {
            const number = std.fmt.parseInt(i32, token, 0) catch 0;
            const toReturn = try all.create(Exp);
            toReturn.* = .{ .atomic = Symbol{ .number = number } };
            return toReturn;
        }
    }
    return SyntaxError.UnexpectedParent;
}

const expect = std.testing.expect;

test "SICP 1.1.1" {
    // todo replace allocator with std.testing.allocator
    var env = Env.init(allocator);
    defer env.deinit();

    try expect(eval(try parse(allocator, "(+ 1 2 3)"), &env).number == 6);
    try expect(eval(try parse(allocator, "(+ (* 3 (+ (* 2 4) (+ 3 5))) (+ (- 10 7) 6))"), &env).number == 57);
}

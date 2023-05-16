const std = @import("std");
const aro = @import("aro");
const zig = std.zig;
const Allocator = std.mem.Allocator;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() !void {
    const gpa = general_purpose_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);

    var aro_comp = aro.Compilation.init(gpa);
    defer aro_comp.deinit();

    try aro_comp.addDefaultPragmaHandlers();
    try aro_comp.defineSystemIncludes();

    const local_platform = @import("builtin").target;
    aro_comp.langopts.setEmulatedCompiler(aro.target_util.systemCompiler(local_platform));

    var driver: aro.Driver = .{ .comp = &aro_comp };
    defer driver.deinit();

    driver.only_preprocess = true;
    // From driver.main()
    var macro_buf = std.ArrayList(u8).init(gpa);
    defer macro_buf.deinit();
    _ = try driver.parseArgs(std.io.getStdErr().writer(), macro_buf.writer(), args);
    if (driver.inputs.items.len == 0) {
        std.debug.print("No input files\n", .{});
        return;
    }

    const user_macros = try driver.comp.addSourceFromBuffer("<command line>", macro_buf.items);
    const builtin = try driver.comp.generateBuiltinMacros();

    for (driver.inputs.items) |source| {
        std.debug.print("Processing C {s} :\n{s}\n", .{ source.path, source.buf });
        try aroccProcess(&driver, source, builtin, user_macros);
    }
}

// From Driver.processSource() in arocc
fn aroccProcess(
    d: *aro.Driver,
    source: aro.Source,
    builtin: aro.Source,
    user_macros: aro.Source,
) !void {
    d.comp.generated_buf.items.len = 0;
    var pp = aro.Preprocessor.init(d.comp);
    defer pp.deinit();
    // pp.verbose = true;
    try pp.addBuiltinMacros();

    _ = try pp.preprocess(builtin);
    _ = try pp.preprocess(user_macros);
    const eof = try pp.preprocess(source);
    try pp.tokens.append(pp.comp.gpa, eof);

    if (d.comp.diag.list.items.len != 0) {
        std.debug.print("Errors in preprocess\n", .{});
        d.comp.renderErrors();
        return error.FatalError;
    }

    var tree = try aro.Parser.parse(&pp);
    defer tree.deinit();
    if (d.comp.diag.list.items.len != 0) {
        std.debug.print("Errors in parse\n", .{});
        d.comp.renderErrors();
        return error.FatalError;
    }
    std.debug.print("Aro Ast:\n", .{});
    try tree.dump(false, std.io.getStdErr().writer());

    var ast = try translate(tree, d.comp.gpa);
    defer ast.deinit(d.comp.gpa);

    var outBuf = std.ArrayList(u8).init(d.comp.gpa);
    defer outBuf.deinit();
    try zig.Ast.renderToArrayList(ast, &outBuf);

    std.debug.print("zig:\n{s}\n", .{outBuf.items});
}

const Context = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8),
    tokens: zig.Ast.TokenList = .{},
    nodes: zig.Ast.NodeList = .{},
    tree: *const aro.Tree,
    tmp_buf: std.ArrayList(u8),
    extra_data: std.ArrayListUnmanaged(std.zig.Ast.Node.Index) = .{},

    fn addToken(c: *Context, tag: zig.Token.Tag, bytes: []const u8) Allocator.Error!zig.Ast.TokenIndex {
        return c.addTokenFmt(tag, "{s}", .{bytes});
    }

    fn addIdentifier(c: *Context, bytes: []const u8) Allocator.Error!zig.Ast.TokenIndex {
        if (std.zig.primitives.isPrimitive(bytes))
            return c.addTokenFmt(.identifier, "@\"{s}\"", .{bytes});
        return c.addTokenFmt(.identifier, "{s}", .{std.zig.fmtId(bytes)});
    }

    fn addNode(c: *Context, elem: std.zig.Ast.Node) Allocator.Error!zig.Ast.Node.Index {
        const result = @intCast(zig.Ast.Node.Index, c.nodes.len);
        try c.nodes.append(c.gpa, elem);
        return result;
    }

    fn addTokenFmt(c: *Context, tag: zig.Token.Tag, comptime format: []const u8, args: anytype) Allocator.Error!zig.Ast.TokenIndex {
        const start_index = c.buf.items.len;
        try c.buf.writer().print(format ++ " ", args);

        try c.tokens.append(c.gpa, .{
            .tag = tag,
            .start = @intCast(u32, start_index),
        });

        return @intCast(u32, c.tokens.len - 1);
    }

    fn listToSpan(c: *Context, list: []const zig.Ast.Node.Index) Allocator.Error!std.zig.Ast.Node.SubRange {
        try c.extra_data.appendSlice(c.gpa, list);
        return std.zig.Ast.Node.SubRange{
            .start = @intCast(zig.Ast.Node.Index, c.extra_data.items.len - list.len),
            .end = @intCast(zig.Ast.Node.Index, c.extra_data.items.len),
        };
    }
    fn addExtra(c: *Context, extra: anytype) Allocator.Error!zig.Ast.Node.Index {
        const fields = std.meta.fields(@TypeOf(extra));
        try c.extra_data.ensureUnusedCapacity(c.gpa, fields.len);
        const result = @intCast(u32, c.extra_data.items.len);
        inline for (fields) |field| {
            comptime std.debug.assert(field.type == zig.Ast.Node.Index);
            c.extra_data.appendAssumeCapacity(@field(extra, field.name));
        }
        return result;
    }
};

fn translate(
    tree: aro.Tree,
    alloc: std.mem.Allocator,
) !zig.Ast {
    var context: Context = .{
        .gpa = alloc,
        .buf = std.ArrayList(u8).init(alloc),
        .tree = &tree,
        .tmp_buf = std.ArrayList(u8).init(alloc),
    };
    defer context.tmp_buf.deinit();
    defer context.buf.deinit();
    defer context.nodes.deinit(alloc);
    defer context.tokens.deinit(alloc);
    defer context.extra_data.deinit(alloc);

    const root_len = tree.root_decls.len;

    // Estimate that each top level node has 10 child nodes.
    try context.nodes.ensureTotalCapacity(alloc, root_len * 10);
    // Estimate that each each node has 2 tokens.
    try context.tokens.ensureTotalCapacity(alloc, root_len * 2);
    // Estimate that each each token is 3 bytes long.
    try context.buf.ensureTotalCapacity(root_len * 3);

    try context.nodes.append(alloc, .{
        .tag = .root,
        .main_token = 0,
        .data = .{
            .lhs = undefined,
            .rhs = undefined,
        },
    });

    var root_nodes = std.ArrayList(zig.Ast.Node.Index).init(alloc);
    defer root_nodes.deinit();

    for (tree.root_decls) |aro_node_idx| {
        const idx = try renderNode(&context, aro_node_idx);
        try root_nodes.append(idx);
    }

    const span = try context.listToSpan(root_nodes.items);
    context.nodes.items(.data)[0] = .{ .lhs = span.start, .rhs = span.end };
    try context.tokens.append(alloc, .{
        .tag = .eof,
        .start = @intCast(u32, context.buf.items.len),
    });

    return zig.Ast{
        .source = try context.buf.toOwnedSliceSentinel(0),
        .tokens = context.tokens.toOwnedSlice(),
        .nodes = context.nodes.toOwnedSlice(),
        .extra_data = try context.extra_data.toOwnedSlice(alloc),
        .errors = &.{},
    };
}

fn renderNode(c: *Context, aro_node_idx: aro.Tree.NodeIndex) !zig.Ast.Node.Index {
    const tag = c.tree.nodes.items(.tag)[@enumToInt(aro_node_idx)];
    const data = c.tree.nodes.items(.data)[@enumToInt(aro_node_idx)];
    const ty = c.tree.nodes.items(.ty)[@enumToInt(aro_node_idx)];

    switch (tag) {
        .@"var" => {
            const mut_tok = try c.addToken(.keyword_var, "var");

            _ = try c.addIdentifier(c.tree.tokSlice(data.decl.name));
            _ = try c.addToken(.colon, ":");
            const type_node = try c.addNode(.{
                .tag = .identifier,
                .main_token = try c.addToken(.identifier, transIntType(ty)),
                .data = undefined,
            });
            _ = try c.addToken(.equal, "=");
            const init_node = if (data.decl.node != .none)
                try renderNode(c, data.decl.node)
            else b: {
                _ = try c.addIdentifier("undefined");
                break :b 0;
            };

            _ = try c.addToken(.semicolon, ";");
            return c.addNode(.{
                .tag = .local_var_decl,
                .main_token = mut_tok,
                .data = .{
                    .lhs = try c.addExtra(std.zig.Ast.Node.LocalVarDecl{
                        .type_node = type_node,
                        .align_node = 0,
                    }),
                    .rhs = init_node,
                },
            });
        },
        .int_literal => {
            c.tmp_buf.items.len = 0;
            try c.tmp_buf.writer().print("{d}", .{data.int});
            return try c.addNode(.{
                .tag = .number_literal,
                .main_token = try c.addToken(.number_literal, c.tmp_buf.items),
                .data = undefined,
            });
        },
        else => {
            std.debug.print("\nunknown node tag type:{s}\n", .{@tagName(tag)});
            return 0;
        },
    }
}

//fn transIntType(ty: aro.Type) []const u8 {
fn transIntType(ty: anytype) []const u8 {
    switch (ty.specifier) {
        .char => return "i8",
        .int => return "c_int",
        else => unreachable,
    }
}

const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const Stream = @import("Stream.zig");
const isa = @import("isa.zig");
const Insn = isa.Insn;
const Program = isa.Program;
const optimize = @import("optimize.zig");

pub const Context = struct {
    file_path: []const u8,
    flags: Flags = Flags.initEmpty(),

    const Flags = std.enums.EnumSet(Flag);
    const Flag = enum { print_errors };

    pub fn addError(ctx: *Context, stream: *Stream, rule: []const u8, err: anyerror) void {
        if (!ctx.flags.contains(.print_errors)) return;
        var line: usize = 1;
        var col: usize = 1;
        var line_start: usize = 0;
        for (stream.input[0..stream.index], 0..) |c, i| {
            const is_nl = c == '\n';
            line += @boolToInt(is_nl);
            if (is_nl) {
                line_start = i + 1;
                col = 1;
            } else col += 1;
        }
        var line_end = stream.index;
        while (line_end < stream.input.len) : (line_end += 1) {
            const c = stream.input[line_end];
            if (c == '\n') break;
        }
        std.debug.print("{s}:{}:{}: rule '{s}' error.{s}\n", .{ ctx.file_path, line, col, rule, @errorName(err) });
        std.debug.print("{s}\n", .{stream.input[line_start..line_end]});
        for (0..col) |_| std.debug.print(" ", .{});
        std.debug.print("^\n", .{});
    }
};

inline fn matchString(expected: []const u8, actual: []const u8) bool {
    // TODO optimize
    return mem.eql(u8, expected, actual);
}

pub const Charset = std.StaticBitSet(256);

pub const CharsetFmt = struct {
    set: Charset,

    pub fn init(set: Charset) CharsetFmt {
        return .{ .set = set };
    }
    pub fn format(setfmt: CharsetFmt, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;
        _ = fmt;
        var iter = setfmt.set.iterator(.{});
        _ = try writer.write("[");
        while (iter.next()) |item|
            try writer.print("{c}", .{@intCast(u8, item)});
        _ = try writer.write("]");
    }
};

pub const Rule = struct { []const u8, Pattern };

pub const Pattern = union(enum) {
    /// represents an alt stored in a slice.
    alt_slice: Slice,
    /// represents a seq stored in a slice.
    seq_slice: Slice,
    /// the binary operator for alternation.
    alt: Lr,
    /// the binary operator for sequences.
    seq: Lr,
    /// the operator for the Kleene star.
    star: Ptr,
    /// the operator for the Kleene plus.
    plus: Ptr,
    /// the operator for making a pattern optional.
    optional: Ptr,
    /// the '!' predicate.
    negative: Ptr,
    /// the '&' predicate.
    positive: Ptr,
    // not: Ptr,
    /// marks a pattern to be captured with a certain ID.
    cap: PattId,
    no_cap: Ptr,
    /// marks a pattern to be memoized with a certain ID.
    memo: PattId,
    /// marks a pattern to be checked by a certain checker.
    check: struct {
        patt: Ptr,
        checker: isa.Checker,
        id: u32,
        flag: u32,
    },
    /// represents a grammar of non-terminals and their associated
    /// patterns. The Grammar must also have an entry non-terminal.
    grammar: struct { rules: RuleMap, start: []const u8 },
    /// represents a search for a certain pattern.
    search: Ptr,
    /// represents the repetition of a pattern a constant number of times.
    repeat: struct { patt: Ptr, n: usize },
    /// a character set.
    class: Charset,
    char_fn: *const fn (u8) bool,
    /// a literal string.
    literal: []const u8,
    /// represents the use of a non-terminal. If this non-terminal is
    /// inlined during compilation, the `inlined` field will point to the pattern
    /// that is inlined.
    non_term: struct { name: []const u8, inlined: ?Ptr = null },
    /// matches any byte a constant number of times.
    dot: u8,
    /// a pattern that fails with a certain error message.
    err: struct { message: []const u8, recover: Ptr },
    /// a node that performs a zero-width assertion.
    empty_op,
    /// represents the empty pattern.
    empty,
    escape: struct { patt: Ptr, escapeFn: EscapeFn },
    /// represents a node that hasn't been initialized. this is an
    /// implementation detail chosen to avoid optional pointers.
    null,

    const Self = @This();
    pub const Ptr = *Pattern;
    pub const Slice = []Pattern;
    pub const Tag = std.meta.Tag(Pattern);
    /// map from rule name to Pattern
    pub const RuleMap = std.StringHashMapUnmanaged(Pattern);
    pub const Lr = struct { left: Ptr, right: Ptr };
    pub const PattId = struct { patt: Ptr, id: i32 };

    pub fn match(pat: Self, stream: *Stream, ctx: *Context) !void {
        switch (pat) {
            .class => |class| {
                const actual = stream.readByte() catch
                    return error.ParseFailure;

                if (!class.isSet(actual)) {
                    stream.index -= 1;
                    return error.ParseFailure;
                }

                try stream.writeByte(actual);
            },
            .literal => |str| {
                const index = stream.index;
                const actual = stream.read(str.len) catch
                    return error.ParseFailure;

                if (!matchString(str, actual)) {
                    stream.index = index;
                    return error.ParseFailure;
                }

                _ = try stream.write(str);
            },
            .char_fn => |charFn| {
                const c = stream.readByte() catch
                    return error.ParseFailure;

                if (!charFn(c)) {
                    stream.index -= 1;
                    return error.ParseFailure;
                }

                try stream.writeByte(c);
            },
            .alt_slice => |alt| {
                const state = stream.checkpoint();
                for (alt) |pattern| {
                    if (pattern.match(stream, ctx)) |_| return else |_| {}
                    stream.restore(state);
                }
                return error.ParseFailure;
            },
            .seq_slice => |seq| {
                // std.log.debug("Group {s}", .{rule_name});
                const state = stream.checkpoint();
                errdefer stream.restore(state);
                for (seq) |pattern|
                    pattern.match(stream, ctx) catch
                        return error.ParseFailure;
            },
            .repeat => |r| {
                for (0..r.n) |_|
                    try r.patt.match(stream, ctx);

                while (true) {
                    const state = stream.checkpoint();
                    r.patt.match(stream, ctx) catch {
                        stream.restore(state);
                        break;
                    };
                }
            },
            .negative => |negative| {
                const state = stream.checkpoint();
                defer stream.restore(state);

                if (negative.match(stream, ctx)) |_|
                    return error.ParseFailure
                else |_| {}
            },
            .positive => |positive| {
                const state = stream.checkpoint();
                defer stream.restore(state);

                positive.match(stream, ctx) catch
                    return error.ParseFailure;
            },
            // .not => |not| {
            //     const state = stream.checkpoint();
            //     errdefer stream.restore(state);

            //     if (not.match(stream, ctx)) |_|
            //         return error.ParseFailure
            //     else |_| {}
            // },
            .optional => |opt| {
                opt.match(stream, ctx) catch {};
            },
            .search => |search| {
                const state = stream.checkpoint();
                while (stream.index < stream.input.len) : (stream.index += 1) {
                    stream.output.pos = state.output_pos;
                    if (search.match(stream, ctx)) |_| {
                        return;
                    } else |_| {}
                }
                stream.restore(state);
                return error.ParseFailure;
            },
            .dot => |n| {
                const s = stream.read(n) catch
                    return error.ParseFailure;
                _ = try stream.write(s);
            },
            .escape => |esc| {
                const index = stream.index;
                const flags = stream.flags;
                errdefer stream.flags = flags;
                stream.flags.insert(.suppress_output);
                try esc.patt.match(stream, ctx);
                stream.flags = flags;
                try esc.escapeFn(stream.input[index..], stream);
            },
            .no_cap => |patt| {
                const flags = stream.flags;
                defer stream.flags = flags;
                stream.flags.insert(.suppress_output);
                try patt.match(stream, ctx);
            },
            .star => |patt| {
                while (true) {
                    const state = stream.checkpoint();
                    patt.match(stream, ctx) catch {
                        stream.restore(state);
                        break;
                    };
                }
            },
            .plus => |patt| {
                try patt.match(stream, ctx);

                while (true) {
                    const state = stream.checkpoint();
                    patt.match(stream, ctx) catch {
                        stream.restore(state);
                        break;
                    };
                }
            },
            else => std.debug.panic("TODO {s}", .{@tagName(pat)}),
        }
    }

    pub fn get(p: Ptr) Ptr {
        return optimize.get(p);
    }

    var _null: Pattern = .null;
    const null_ptr = &_null;

    // Nodes with trees larger than this size will not be inlined.
    const inline_threshold = 100;

    fn inline_(allocator: mem.Allocator, p: Pattern) !bool {
        assert(p == .grammar);
        const g = p.grammar;
        const Sizes = std.StringHashMap(usize);
        var sizes = Sizes.init(allocator);
        defer sizes.deinit();
        const Leaves = std.StringHashMap(void);
        var leaves = Leaves.init(allocator);
        defer leaves.deinit();

        var iter = g.rules.iterator();
        while (iter.next()) |e| {
            const n = e.key_ptr.*;
            const sub = e.value_ptr;

            var size: usize = 0;
            var leaf = true;
            const W = struct {
                leaf: *bool,
                size: *usize,
                fn walk(w: *@This(), pat: Ptr) !void {
                    // std.log.debug("walk {s} {} {}", .{ @tagName(pat.*), @enumToInt(pat.*), @enumToInt(Pattern.Tag.memo) });
                    if (pat.* == .non_term and pat.non_term.inlined == null)
                        w.leaf.* = false;
                    w.size.* += 1;
                }
            };
            var w = W{ .leaf = &leaf, .size = &size };
            try walk(sub, true, *W, &w);
            try sizes.put(n, size);
            if (leaf)
                try leaves.put(n, {});
        }

        var didInline = false;
        const W = struct {
            sizes: Sizes,
            leaves: Leaves,
            didInline: *bool,
            rules: RuleMap,
            fn walk(w: *@This(), pat: Ptr) !void {
                if (pat.* == .non_term and pat.non_term.inlined == null) {
                    // We only inline nodes if they are small enough and don't use
                    // any non-terminals themselves.
                    const name = pat.non_term.name;
                    const sz = w.sizes.get(name) orelse return;
                    if (sz < inline_threshold) {
                        _ = w.leaves.get(name) orelse return;
                        w.didInline.* = true;
                        pat.non_term.inlined = w.rules.getPtr(name);
                    }
                }
            }
        };
        var w = W{ .sizes = sizes, .leaves = leaves, .didInline = &didInline, .rules = g.rules };

        var pmut = p;
        try walk(&pmut, true, *W, &w);
        return didInline;
    }

    pub fn compileAndOptimize(p: Pattern, allocator: mem.Allocator) !Program {
        var c = try p.compile(allocator);
        try optimize.optimize(allocator, &c);
        return c;
    }

    pub fn compile(p: Pattern, allocator: mem.Allocator) error{ OutOfMemory, NotFound, InvalidLiteral }!Program {
        std.log.debug("compile {s}", .{@tagName(p)});
        switch (p) {
            .grammar => |n| {
                while (try inline_(allocator, p)) {}
                const Used = std.StringHashMap(void);
                var used = Used.init(allocator);
                defer used.deinit();
                var iter = n.rules.iterator();
                while (iter.next()) |e| {
                    const v = e.value_ptr;
                    const W = struct {
                        used: *Used,
                        fn walk(w: @This(), pat: Ptr) !void {
                            // std.log.debug("walk {s} {} {}", .{ @tagName(pat.*), @enumToInt(pat.*), @enumToInt(Pattern.Tag.memo) });
                            if (pat.* == .non_term) {
                                if (pat.non_term.inlined == null)
                                    try w.used.put(pat.non_term.name, {});
                            }
                        }
                    };
                    var w = W{ .used = &used };
                    try walk(v, true, W, w);
                }

                if (used.count() == 0)
                    return n.rules.get(n.start).?.compile(allocator);

                var code = Program{};
                const lend = isa.Label.init();
                try code.appendSlice(allocator, &.{
                    Insn.init(.open_call, n.start),
                    Insn.init(.jump, lend),
                });

                var labels = std.StringHashMap(isa.Label).init(allocator);
                defer labels.deinit();
                iter.index = 0;
                while (iter.next()) |e| {
                    const k = e.key_ptr.*;
                    const v = e.value_ptr.*;
                    // std.log.debug("grammar compile() key={s}", .{k});
                    if (!mem.eql(u8, k, n.start) and !used.contains(k))
                        continue;
                    const label = isa.Label.init();
                    try labels.put(k, label);
                    var f = try v.compile(allocator);
                    defer f.deinit(allocator);
                    try code.append(allocator, label.toInsn());
                    try code.appendSlice(allocator, f.items);
                    try code.append(allocator, isa.Insn.init(.ret, {}));
                }

                // resolve calls to openCall and do tail call optimization
                for (0..code.items.len) |i| {
                    const insn = code.items[i];
                    if (insn == .open_call) {
                        const name = insn.open_call;
                        const lbl = labels.get(name) orelse
                            return isa.programFrom(allocator, Insn.init(.not_found_error, name));

                        // replace this placeholder instruction with a normal call
                        var replace = isa.Insn.init(.call, lbl);
                        // if a call is immediately followed by a return, optimize to
                        // a jump for tail call optimization.
                        if (optimize.nextInsn(code.items[i + 1 ..])) |next| {
                            switch (next) {
                                .ret => {
                                    replace = isa.Insn.init(.jump, lbl);
                                    // remove the return instruction if there is no label referring to it
                                    const ret_hl = optimize.nextInsnLabel(code.items[i + 1 ..]);
                                    const had_label = ret_hl[1];
                                    if (!had_label) {
                                        code.items[i + 1 + ret_hl[0]] = .nop;
                                    }
                                },
                                else => {},
                            }

                            // perform the replacement of the opencall by either a call or jump
                            code.items[i] = replace;
                        }
                    }
                }

                try code.append(allocator, lend.toInsn());

                return code;
            },
            .alt_slice, .seq_slice => unreachable,
            .seq => |n| {
                var l = try n.left.get().compile(allocator);
                errdefer l.deinit(allocator);
                var r = try n.right.get().compile(allocator);
                defer r.deinit(allocator);
                try l.appendSlice(allocator, r.items);
                return l;
            },
            .non_term => |n| {
                if (n.inlined) |sp| return sp.compile(allocator);
                return isa.programFrom(allocator, Insn.init(.open_call, n.name));
            },

            .alt => |n| {
                // optimization: if Left and Right are charsets/single chars, return the union
                if (n.left.* != .empty and n.right.* != .empty) {
                    if (optimize.combine(n.left.get(), n.right.get())) |set| {
                        return isa.programFrom(allocator, Insn.init(.set, set));
                    }
                }

                var l = try n.left.get().compile(allocator);
                defer l.deinit(allocator);
                var r = try n.right.get().compile(allocator);
                defer r.deinit(allocator);

                const l1 = isa.Label.init();
                // optimization: if the right and left nodes are disjoint, we can use
                // NoChoice variants of the head-fail optimization instructions.
                var disjoint = false;
                var testinsn: isa.Insn = undefined;
                blk: {
                    const linsn = optimize.nextInsn(l.items) orelse break :blk;
                    const rinsn = optimize.nextInsn(r.items) orelse break :blk;

                    switch (linsn) {
                        .set => |lt| {
                            switch (rinsn) {
                                .char => |rt| disjoint = !lt.isSet(rt),
                                else => {},
                            }
                            testinsn = .{ .test_set_no_choice = .{ .chars = lt, .lbl = l1 } };
                        },
                        .char => |lt| {
                            switch (rinsn) {
                                .char => |rt| disjoint = lt != rt,
                                .set => |rt| disjoint = !rt.isSet(lt),
                                else => {},
                            }
                            testinsn = .{ .test_char_no_choice = .{ .byte = lt, .lbl = l1 } };
                        },
                        else => {},
                    }
                }

                const l2 = isa.Label.init();
                // std.log.debug("compile(.alt) l1={} l2={}", .{ l1.id, l2.id });
                var code = try Program.initCapacity(allocator, l.items.len + r.items.len + 5);

                if (disjoint) {
                    code.appendAssumeCapacity(testinsn);
                    code.appendSliceAssumeCapacity(l.items[1..]);
                    code.appendAssumeCapacity(Insn.init(.jump, l2));
                } else {
                    code.appendAssumeCapacity(Insn.init(.choice, l1));
                    code.appendSliceAssumeCapacity(l.items);
                    code.appendAssumeCapacity(Insn.init(.commit, l2));
                }
                code.appendAssumeCapacity(l1.toInsn());
                code.appendSliceAssumeCapacity(r.items);
                code.appendAssumeCapacity(l2.toInsn());
                return code;
            },
            .star => |n| {
                switch (n.*) {
                    .class => |nn| {
                        return try isa.programFrom(allocator, Insn.init(.span, nn));
                    },
                    .memo => |nn| {
                        _ = nn;
                        unreachable;
                    },
                    else => {},
                }
                var sub = try n.get().compile(allocator);
                defer sub.deinit(allocator);
                var code = try Program.initCapacity(allocator, sub.items.len + 4);
                var l1 = isa.Label.init();
                var l2 = isa.Label.init();
                try code.append(allocator, Insn.init(.choice, l2));
                try code.append(allocator, l1.toInsn());
                try code.appendSlice(allocator, sub.items);
                try code.append(allocator, Insn.init(.partial_commit, l1));
                try code.append(allocator, l2.toInsn());
                return code;
            },
            .plus => |n| {
                const starp = Pattern{ .star = n.get() };
                var star = try starp.compile(allocator);
                defer star.deinit(allocator);
                var sub = try n.get().compile(allocator);
                defer sub.deinit(allocator);

                var code = try Program.initCapacity(allocator, sub.items.len + star.items.len);
                code.appendSliceAssumeCapacity(sub.items);
                code.appendSliceAssumeCapacity(star.items);
                return code;
            },
            .optional => |n| {
                switch (n.get().*) {
                    .literal => |s| if (s.len == 1) {
                        const l1 = isa.Label.init();
                        return isa.programFromSlice(allocator, &.{
                            Insn.init(.test_char_no_choice, .{ .byte = s[0], .lbl = l1 }),
                            l1.toInsn(),
                        });
                    },
                    .class => |c| {
                        const l1 = isa.Label.init();
                        return isa.programFromSlice(allocator, &.{
                            Insn.init(.test_set_no_choice, .{ .chars = c, .lbl = l1 }),
                            l1.toInsn(),
                        });
                    },
                    else => {},
                }
                const a = Pattern{ .alt = .{
                    .left = n.get(),
                    .right = null_ptr,
                } };
                return a.compile(allocator);
            },
            .negative => |n| {
                var sub = try n.get().compile(allocator);
                defer sub.deinit(allocator);
                const l1 = isa.Label.init();
                var code = try isa.Program.initCapacity(allocator, sub.items.len + 3);
                code.appendAssumeCapacity(Insn.init(.choice, l1));
                code.appendSliceAssumeCapacity(sub.items);
                code.appendAssumeCapacity(Insn.init(.fail_twice, {}));
                code.appendAssumeCapacity(l1.toInsn());
                return code;
            },
            .positive => |n| {
                var sub = try n.get().compile(allocator);
                var code = try isa.Program.initCapacity(allocator, sub.items.len + 5);
                defer sub.deinit(allocator);
                const l1 = isa.Label.init();
                const l2 = isa.Label.init();
                code.appendAssumeCapacity(Insn.init(.choice, l1));
                code.appendSliceAssumeCapacity(sub.items);
                code.appendAssumeCapacity(Insn.init(.back_commit, l2));
                code.appendAssumeCapacity(Insn.init(.label, l1));
                code.appendAssumeCapacity(Insn.init(.fail, {}));
                code.appendAssumeCapacity(Insn.init(.label, l2));
                return code;
            },
            // .not => |n| {
            //     if (true) unreachable;
            //     var sub = try n.get().compile(allocator);
            //     defer sub.deinit(allocator);
            //     const l1 = isa.Label.init();
            //     var code = try isa.Program.initCapacity(allocator, sub.items.len + 3);
            //     code.appendAssumeCapacity(Insn.init(.choice, l1));
            //     code.appendSliceAssumeCapacity(sub.items);
            //     code.appendAssumeCapacity(Insn.init(.fail_twice, {}));
            //     code.appendAssumeCapacity(l1.toInsn());
            //     return code;
            // },
            .cap => |n| {
                _ = n;
                unreachable;
            },
            .no_cap => |n| {
                _ = n;
                unreachable;
            },
            .memo => |n| {
                _ = n;
                unreachable;
            },
            .check => |n| {
                const L1 = isa.Label.init();
                var sub = try n.patt.get().compile(allocator);
                defer sub.deinit(allocator);
                var code = try Program.initCapacity(allocator, sub.items.len + 3);
                code.appendAssumeCapacity(Insn.init(.check_begin, .{
                    .id = n.id,
                    .flag = n.flag,
                }));
                code.appendSliceAssumeCapacity(sub.items);
                code.appendAssumeCapacity(Insn.init(.check_end, n.checker));
                code.appendAssumeCapacity(L1.toInsn());
                return code;
            },
            .search => |n| {
                var set: Charset = undefined;
                var opt = false;

                var sub = try n.get().compile(allocator);
                defer sub.deinit(allocator);

                if (optimize.nextInsn(sub.items)) |next| {
                    switch (next) {
                        .char => |t| {
                            set = Charset.initEmpty();
                            set.set(t);
                            set = set.complement();
                            opt = true;
                        },
                        .set => |t| {
                            // Heuristic: if the set is smaller than 10 chars, it
                            // is unlikely enough to match that we should consume all
                            // chars from the complement before continuing the search.
                            // The number 10 was arbitrarily chosen.
                            if (t.count() < 10) {
                                set = t.complement();
                                opt = true;
                            }
                        },
                        else => {},
                    }
                }

                const rsearch = if (opt)
                    GroupBuf(2, &.{ ZeroOrMore(Set(set)), NonTerm("S") })
                else
                    NonTerm("S");

                const patt = SelectBuf(2, &.{
                    n.get().*,
                    GroupBuf(2, &.{ Any(1), rsearch }),
                });
                var g = try rulesToGrammar(allocator, &.{.{ "S", patt }}, "S");
                defer g.deinit(allocator);
                return g.compile(allocator);
            },
            .repeat => |n| {
                _ = n;
                unreachable;
            },
            .class => |n| {
                return isa.programFrom(allocator, Insn.init(.set, n));
            },
            .char_fn => |n| {
                _ = n;
                unreachable;
            },
            .literal => |n| {
                if (n.len == 0) return error.InvalidLiteral;
                var code = try Program.initCapacity(allocator, n.len);
                for (n) |c|
                    code.appendAssumeCapacity(Insn.init(.char, c));
                return code;
            },
            .dot => |n| {
                return isa.programFrom(allocator, Insn.init(.any, n));
            },
            .err => |n| {
                _ = n;
                unreachable;
            },
            .empty_op => |n| {
                _ = n;
                unreachable;
            },
            .empty, .null => {
                return Program{};
            },
            .escape => |n| {
                _ = n;
                unreachable;
            },
        }
        unreachable;
    }

    // Walk calls fn for every subpattern contained in p. If followInline
    // is true, Walk will walk over inlined patterns as well.
    pub fn walk(p: Ptr, followInline: bool, comptime Walker: type, walker: Walker) error{OutOfMemory}!void {
        try walker.walk(p);
        switch (p.*) {
            .alt_slice => unreachable,
            .seq_slice => unreachable,
            .alt, .seq => |n| {
                try walk(n.left, followInline, Walker, walker);
                try walk(n.right, followInline, Walker, walker);
            },
            .star,
            .plus,
            .optional,
            // .not,
            .negative,
            .positive,
            .no_cap,
            .search,
            => |n| try walk(n, followInline, Walker, walker),
            .cap, .memo => |n| try walk(n.patt, followInline, Walker, walker),
            .check => |n| try walk(n.patt, followInline, Walker, walker),
            .err => |n| try walk(n.recover, followInline, Walker, walker),
            .repeat => |n| try walk(n.patt, followInline, Walker, walker),
            .escape => |n| try walk(n.patt, followInline, Walker, walker),
            .grammar => |n| {
                var iter = n.rules.iterator();
                while (iter.next()) |e|
                    try walk(e.value_ptr, followInline, Walker, walker);
            },
            .non_term => |n| {
                if (n.inlined != null and followInline) {
                    try walk(n.inlined.?, followInline, Walker, walker);
                }
            },
            else => {},
        }
    }

    pub const start_name = "--start--";

    pub fn rulesToGrammar(allocator: mem.Allocator, rules: []const Rule, start: []const u8) !Pattern {
        var rules_map = RuleMap{};
        errdefer rules_map.deinit(allocator);
        for (rules) |kv| {
            try rules_map.putNoClobber(allocator, kv[0], try kv[1].normalize(allocator));
        }
        try rules_map.put(allocator, start_name, .{ .non_term = .{ .name = start } });
        return .{ .grammar = .{ .rules = rules_map, .start = start } };
    }

    /// convert slice nodes to their recursive counterparts (.{alt,seq}_slice => .{alt,seq})
    pub fn normalize(p: Pattern, allocator: mem.Allocator) !Pattern {
        switch (p) {
            .seq_slice => |n| {
                if (n.len == 0) return .empty;
                var acc = try n[0].normalize(allocator);
                for (n[1..]) |item| {
                    var left = try allocator.create(Pattern);
                    left.* = acc;
                    var right = try allocator.create(Pattern);
                    right.* = try item.normalize(allocator);
                    acc = .{ .seq = .{
                        .left = left,
                        .right = right,
                    } };
                }
                return acc;
            },
            .alt_slice => |n| {
                if (n.len == 0) return .empty;
                var acc = try n[n.len - 1].normalize(allocator);

                var i: isize = @bitCast(isize, n.len) - 2;
                while (i >= 0) : (i -= 1) {
                    var left = try allocator.create(Pattern);
                    left.* = try n[@bitCast(usize, i)].normalize(allocator);
                    var right = try allocator.create(Pattern);
                    right.* = acc;
                    acc = .{ .alt = .{
                        .left = left,
                        .right = right,
                    } };
                }
                return acc;
            },
            .alt, .seq => unreachable,
            inline .star,
            .plus,
            .optional,
            .negative,
            .positive,
            // .not,
            .no_cap,
            .search,
            => |n, tag| {
                var nn = try allocator.create(Pattern);
                nn.* = try n.normalize(allocator);
                return @unionInit(Pattern, @tagName(tag), nn);
            },
            inline .repeat, .cap, .memo, .check, .escape => |n, tag| {
                var tmp = p;
                @field(tmp, @tagName(tag)).patt.* = try n.patt.normalize(allocator);
                return tmp;
            },
            .err => |n| {
                var tmp = p;
                tmp.err.recover.* = try n.recover.normalize(allocator);
                return tmp;
            },
            else => {},
        }
        return p;
    }

    pub fn count(p: Pattern) usize {
        return switch (p) {
            .alt_slice => unreachable,
            .seq_slice => unreachable,
            .grammar => unreachable,
            .alt, .seq => |n| blk: {
                const c1 = if (n.left) |l| l.count() else 0;
                const c2 = if (n.right) |r| r.count() else 0;
                break :blk c1 + c2;
            },
            .star,
            .plus,
            .optional,
            .negative,
            .positive,
            .not,
            .no_cap,
            .search,
            => |n| n.count(),
            .cap => |n| n.patt.count(),
            .memo => |n| n.patt.count(),
            .check => |n| n.patt.count(),
            .repeat => |n| n.patt.count(),
            .class => 1,
            .char_fn => 1,
            .literal => 1,
            .non_term => 1,
            .dot => 1,
            .err => |n| n.recover.count(),
            .empty_op => 0,
            .empty => 0,
            .escape => |n| n.patt.count(),
        };
    }

    pub fn deinit(p: *Pattern, allocator: mem.Allocator) void {
        switch (p.*) {
            .alt_slice => unreachable,
            .seq_slice => unreachable,
            .grammar => |*g| {
                var iter = g.rules.iterator();
                while (iter.next()) |e| {
                    e.value_ptr.deinit(allocator);
                }
                g.rules.deinit(allocator);
            },
            .alt, .seq => |n| {
                n.left.deinit(allocator);
                allocator.destroy(n.left);
                n.right.deinit(allocator);
                allocator.destroy(n.right);
            },
            .star,
            .plus,
            .optional,
            .negative,
            .positive,
            // .not,
            .no_cap,
            .search,
            => |n| {
                n.deinit(allocator);
                allocator.destroy(n);
            },
            .cap => |n| n.patt.deinit(allocator),
            .memo => |n| n.patt.deinit(allocator),
            .check => |n| n.patt.deinit(allocator),
            .repeat => |n| n.patt.deinit(allocator),
            .err => |n| n.recover.deinit(allocator),
            .escape => |n| n.patt.deinit(allocator),
            .class,
            .char_fn,
            .literal,
            .non_term,
            .dot,
            .empty_op,
            .empty,
            .null,
            => {},
        }
    }
};

test "Pattern.normalize seq" {
    const rule = Group(&.{
        .{ .non_term = .{ .name = "a" } },
        .{ .non_term = .{ .name = "b" } },
        .{ .non_term = .{ .name = "c" } },
    });
    // |\
    // | c
    // |\
    // a b
    var seq = try rule.normalize(testing.allocator);
    defer seq.deinit(testing.allocator);

    try testing.expect(seq == .seq);
    try testing.expect(seq.seq.left.* != .empty);
    try testing.expectEqual(Pattern.Tag.seq, seq.seq.left.*);
    try testing.expect(seq.seq.right.* != .empty);
    try testing.expectEqual(Pattern.Tag.non_term, seq.seq.right.*);
    try testing.expectEqualStrings("c", seq.seq.right.non_term.name);

    const seq2 = seq.seq.left.*;
    try testing.expect(seq2 == .seq);
    try testing.expect(seq2.seq.left.* != .empty);
    try testing.expect(seq2.seq.left.* == .non_term);
    try testing.expectEqualStrings("a", seq2.seq.left.non_term.name);
    try testing.expect(seq2.seq.right.* != .empty);
    try testing.expectEqual(Pattern.Tag.non_term, seq2.seq.right.*);
    try testing.expectEqualStrings("b", seq2.seq.right.non_term.name);
}

test "Pattern.normalize alt" {
    const rule = Select(&.{
        .{ .non_term = .{ .name = "a" } },
        .{ .non_term = .{ .name = "b" } },
        .{ .non_term = .{ .name = "c" } },
    });
    // |\
    // a |
    //   |\
    //   b c
    var alt = try rule.normalize(testing.allocator);
    defer alt.deinit(testing.allocator);

    try testing.expect(alt == .alt);
    try testing.expect(alt.alt.left.* != .empty);
    try testing.expectEqual(Pattern.Tag.non_term, alt.alt.left.*);
    try testing.expectEqualStrings("a", alt.alt.left.non_term.name);
    try testing.expect(alt.alt.right.* != .empty);
    try testing.expectEqual(Pattern.Tag.alt, alt.alt.right.*);

    const alt2 = alt.alt.right.*;
    try testing.expect(alt2 == .alt);
    try testing.expect(alt2.alt.left.* != .empty);
    try testing.expectEqual(Pattern.Tag.non_term, alt2.alt.left.*);
    try testing.expectEqualStrings("b", alt2.alt.left.non_term.name);
    try testing.expect(alt2.alt.right.* != .empty);
    try testing.expectEqual(Pattern.Tag.non_term, alt2.alt.right.*);
    try testing.expectEqualStrings("c", alt2.alt.right.non_term.name);
}

pub const Error = error{ ParseFailure, NoSpaceLeft };

pub fn Char(c: u8) Pattern {
    var class = Charset.initEmpty();
    class.set(c);
    return .{ .class = class };
}

pub fn CharFn(f: *const fn (u8) bool) Pattern {
    return .{ .char_fn = f };
}

pub fn CharRange(start: u8, end: u8) Pattern {
    var class = Charset.initEmpty();
    class.setRangeValue(.{ .start = start, .end = end + 1 }, true);
    return .{ .class = class };
}

pub fn String(s: []const u8) Pattern {
    assert(s.len > 0);
    return .{ .literal = s };
}

pub inline fn Select(comptime patterns: []const Pattern) Pattern {
    var tmp = patterns[0..patterns.len].*;
    return .{ .alt_slice = &tmp };
}

/// use inplace of Select() when 'patterns' isn't known at comptime
pub inline fn SelectBuf(comptime len: usize, patterns: []const Pattern) Pattern {
    if (patterns.len > len)
        std.debug.panic("len={} < patterns.len={}", .{ len, patterns.len });
    var buf: [len]Pattern = undefined;
    const dest = buf[0..patterns.len];
    @memcpy(dest, patterns);
    return .{ .alt_slice = dest };
}

pub inline fn Group(comptime patterns: []const Pattern) Pattern {
    var tmp = patterns[0..patterns.len].*;
    return .{ .seq_slice = &tmp };
}

/// use inplace of Group() when 'patterns' isn't known at comptime
pub inline fn GroupBuf(comptime len: usize, patterns: []const Pattern) Pattern {
    if (patterns.len > len)
        std.debug.panic("len={} < patterns.len={}", .{ len, patterns.len });
    var buf: [len]Pattern = undefined;
    const dest = buf[0..patterns.len];
    @memcpy(dest, patterns);
    return .{ .seq_slice = dest };
}

pub inline fn Repeat(n: u8, pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .repeat = .{ .n = n, .patt = &tmp } };
}

pub inline fn ZeroOrMore(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .star = &tmp };
}

pub inline fn OneOrMore(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .plus = &tmp };
}

pub inline fn Optional(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .optional = &tmp };
}

pub inline fn Negative(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .negative = &tmp };
}

pub inline fn Positive(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .positive = &tmp };
}

pub fn Any(n: u8) Pattern {
    return .{ .dot = n };
}

pub fn AnyOf(elements: []const u8) Pattern {
    var class = Charset.initEmpty();
    for (elements) |e| class.set(e);
    return .{ .class = class };
}

pub const EscapeFn = *const fn ([]const u8, *Stream) anyerror!void;

pub inline fn Escape(pattern: Pattern, escapeFn: EscapeFn) Pattern {
    var tmp = pattern;
    return .{ .escape = .{ .patt = &tmp, .escapeFn = escapeFn } };
}

// TODO implement. removed to avoid confusion w/ gpeg.Not vn Negative()
// pub inline fn Not(pattern: Pattern) Pattern {
//     var tmp = pattern;
//     return .{ .not = &tmp };
// }

pub inline fn Search(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .search = &tmp };
}

pub const Ignore = NoCapture;
pub inline fn NoCapture(pattern: Pattern) Pattern {
    var tmp = pattern;
    return .{ .no_cap = &tmp };
}

fn validateChecker(comptime C: type) isa.CheckerFn {
    const cinfo = @typeInfo(C);
    if (cinfo != .Pointer)
        @compileError("Expected checker param to be a Pointer. got '" ++ @tagName(cinfo) ++ "'");
    const Child = cinfo.Pointer.child;
    if (!@hasDecl(Child, "check"))
        @compileError("checker param missing pub check() method.");
    if (@TypeOf(Child.check) != isa.CheckerFnT)
        @compileError("checker.check() method must have type " ++ @typeName(isa.CheckerFn));
    return Child.check;
}

// Check marks a pattern to be checked with the given checker.
pub inline fn Check(
    pattern: Pattern,
    checker: anytype,
) Pattern {
    const checker_fn = validateChecker(@TypeOf(checker));
    var tmp = pattern;
    return .{ .check = .{
        .patt = &tmp,
        .checker = .{
            .func = checker_fn,
            .ptr = checker,
        },
        .id = 0,
        .flag = 0,
    } };
}

pub inline fn CheckFlags(
    pattern: Pattern,
    checker: anytype,
    id: u32,
    flag: u32,
) Pattern {
    const checker_fn = validateChecker(@TypeOf(checker));
    var tmp = pattern;
    return .{
        .check = .{
            .patt = &tmp,
            .checker = .{
                .func = checker_fn,
                .ptr = checker,
            },
            .id = id,
            .flag = flag,
        },
    };
}

pub fn Set(set: Charset) Pattern {
    return .{ .class = set };
}

pub fn NonTerm(name: []const u8) Pattern {
    return .{ .non_term = .{ .name = name } };
}

pub fn initCharset(chars: []const u8) Charset {
    var set = Charset.initEmpty();
    for (chars) |c| set.set(c);
    return set;
}

pub fn parse(pat: Pattern, stream: *Stream, ctx: *Context) ![]const u8 {
    const out_pos = stream.output.pos;
    pat.match(stream, ctx) catch |e| {
        ctx.addError(stream, @tagName(pat), e);
        return e;
    };
    return stream.output.buffer[out_pos..stream.output.pos];
}

pub const Iterator = struct {
    pattern: Pattern,
    stream: *Stream,
    ctx: *Context,

    pub fn next(self: *Iterator) !?[]const u8 {
        if (self.stream.eof()) return null;
        return try parse(self.pattern, self.stream, self.ctx);
    }

    pub fn reset(self: *Iterator) void {
        self.stream.index = 0;
        self.stream.output.pos = 0;
    }
    pub fn count(self: *Iterator) !usize {
        var result: usize = 0;
        while (try self.next()) |_| : (result += 1) {}
        return result;
    }
};

pub fn iterator(pattern: Pattern, stream: *Stream, ctx: *Context) Iterator {
    return Iterator{ .pattern = pattern, .stream = stream, .ctx = ctx };
}

pub const SplitIterator = struct {
    pattern: Pattern,
    stream: *Stream,
    ctx: *Context,

    pub fn next(self: *SplitIterator) !?[]const u8 {
        if (self.stream.eof()) return null;
        const index = self.stream.index;
        const result = parse(self.pattern, self.stream, self.ctx) catch {
            self.stream.index = self.stream.input.len;
            return self.stream.input[index..];
        };
        return self.stream.input[index .. self.stream.index - result.len];
    }

    pub fn reset(self: *SplitIterator) void {
        self.stream.index = 0;
        self.stream.output.pos = 0;
    }
};

pub inline fn split(pattern: Pattern, stream: *Stream, ctx: *Context) SplitIterator {
    return SplitIterator{ .pattern = Search(pattern), .stream = stream, .ctx = ctx };
}

const testing = std.testing;

/// returns parse result and remainder. parse result is an error union to allow
/// checking error states
fn doParse(
    input: []const u8,
    output: []u8,
    parser: anytype,
) struct { anyerror![]const u8, []const u8 } {
    var s = Stream.init(input, output);
    var ctx = Context{ .file_path = "<testing>" };
    const err_or_void = parse(parser, &s, &ctx);
    return .{ err_or_void, s.input[s.index..] };
}

fn expectParse(input: []const u8, parser: anytype, expected_result: []const u8) !void {
    var output: [0x100]u8 = undefined;
    const result = doParse(input, &output, parser);
    _ = try result[0];
    try testing.expectEqualStrings(expected_result, result[1]);
}

fn expectFailure(input: []const u8, parser: anytype, err: anyerror) !void {
    var output: [0x100]u8 = undefined;
    const result = doParse(input, &output, parser);
    try testing.expectError(err, result[0]);
    try testing.expectEqualStrings(input, result[1]);
}

test Char {
    const f = Char('f');
    try expectParse("foo", f, "oo");
    try expectParse("f", f, "");
    try expectFailure("", f, error.ParseFailure);
}

const ws = CharFn(&std.ascii.isWhitespace);
test CharFn {
    try expectParse(" ", ws, "");
    try expectParse("\n--", ws, "--");
    try expectFailure("a", ws, error.ParseFailure);
}

test CharRange {
    const az = CharRange('a', 'z');
    try expectParse("a", az, "");
    try expectParse("z--", az, "--");
    try expectFailure(&[_]u8{'a' - 1}, az, error.ParseFailure);
    try expectFailure(&[_]u8{'z' + 1}, az, error.ParseFailure);
}

const foo = String("foo");
const bar = String("bar");
test String {
    try expectParse("foo", foo, "");
    try expectParse("fooba", foo, "ba");
    try expectParse("bar", bar, "");
    try expectParse("bar--", bar, "--");
    try expectFailure("fo", foo, error.ParseFailure);
    try expectFailure("ba", foo, error.ParseFailure);
    try expectFailure("", foo, error.ParseFailure);
}

test Select {
    const foo_bar = Select(&.{ foo, bar });
    try expectParse("foo", foo_bar, "");
    try expectParse("fooba", foo_bar, "ba");
    try expectParse("bar", foo_bar, "");
    try expectParse("bar--", foo_bar, "--");
    try expectFailure("fo", foo_bar, error.ParseFailure);
    try expectFailure("ba", foo_bar, error.ParseFailure);
    try expectFailure("", foo_bar, error.ParseFailure);
}

test Group {
    const foo_bar = Group(&.{ foo, bar });
    try expectParse("foobar", foo_bar, "");
    try expectParse("foobar--", foo_bar, "--");
    try expectFailure("", foo_bar, error.ParseFailure);
    try expectFailure("fo", foo_bar, error.ParseFailure);
    try expectFailure("foo", foo_bar, error.ParseFailure);
    try expectFailure("foob", foo_bar, error.ParseFailure);
    try expectFailure("fooba", foo_bar, error.ParseFailure);
}

test ZeroOrMore {
    const many_ws = ZeroOrMore(ws);
    try expectParse("  \n\r\t--", many_ws, "--");
    try expectParse("--", many_ws, "--");
}

test OneOrMore {
    const some_ws = OneOrMore(ws);
    try expectParse("  \n\r\t--", some_ws, "--");
    try expectFailure("--", some_ws, error.ParseFailure);
    try expectFailure("", some_ws, error.ParseFailure);
}

test Optional {
    const opt_ws = Optional(ws);
    try expectParse("\t--", opt_ws, "--");
    try expectParse("--", opt_ws, "--");
    try expectParse("", opt_ws, "");
}

test Negative {
    const ident = comptime OneOrMore(CharFn(std.ascii.isAlphanumeric));
    const leftarrow = comptime String("<--");
    const p1 = Group(&.{ ident, Negative(leftarrow) });
    try expectParse("foo--", p1, "--");
    try expectFailure("foo<----", p1, error.ParseFailure);
}

test Positive {
    const ident = comptime OneOrMore(CharFn(std.ascii.isAlphanumeric));
    const leftarrow = comptime String("<--");
    const p1 = Group(&.{ ident, Positive(leftarrow) });
    try expectFailure("foo--", p1, error.ParseFailure);
    try expectParse("foo<----", p1, "<----");
}

test Any {
    const any2 = Any(2);
    try expectParse("--", any2, "");
    try expectFailure("", any2, error.ParseFailure);
}

test AnyOf {
    const any2 = AnyOf("abc");
    try expectParse("a--", any2, "--");
    try expectParse("b--", any2, "--");
    try expectParse("c--", any2, "--");
    try expectFailure("", any2, error.ParseFailure);
    try expectFailure("d", any2, error.ParseFailure);
}

// TODO uncomment when Not() is added back
// test Not {
//     const dash = comptime Char('-');
//     const slash = comptime Char('\\');
//     const not_slash_dash = Group(&.{ Not(slash), dash });
//     try expectParse("-", not_slash_dash, "");
//     try expectFailure("\\-", not_slash_dash, error.ParseFailure);
// }

test Search {
    const search = Search(foo);
    try expectParse("afoob", search, "b");
    try expectFailure("afob", search, error.ParseFailure);
}

test split {
    const input = "afoob";
    var output: [input.len]u8 = undefined;
    var s = Stream.init(input, &output);
    var ctx = Context{ .file_path = "<test>" };
    var iter = split(foo, &s, &ctx);
    try testing.expectEqualStrings("a", (try iter.next()).?);
    try testing.expectEqualStrings("b", (try iter.next()).?);
    try testing.expect(try iter.next() == null);
}
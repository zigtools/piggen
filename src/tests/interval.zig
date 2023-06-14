const std = @import("std");
const Array = @import("../memo/interval/lazy/Array.zig");
const lazylogtree = @import("../memo/interval/lazylog/tree.zig");
const lazytree = @import("../memo/interval/lazy/tree.zig");
const Tree = lazylogtree.Tree;

var prng = std.rand.DefaultPrng.init(0);
const rand = prng.random();

fn randrange(max: isize) [2]isize {
    const low = rand.intRangeAtMost(isize, 0, max);
    const high = low + rand.intRangeAtMost(isize, 0, 1000);
    return if (low == high)
        .{ low, low + 1 }
    else
        .{ low, high };
}

fn randint(min: isize, max: isize) isize {
    return rand.intRangeAtMost(isize, 0, max - min) + min;
}

const t = std.testing;
const talloc = t.allocator;

const Op = enum { add, find, remove_and_shift, pos };

test {
    try main();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    // const alloc = std.heap.c_allocator;
    // const alloc = t.allocator;
    var it = Tree{};
    defer it.deinit(alloc);
    var ia = Array{};
    defer ia.deinit(alloc);
    const nops = 300000;
    const maxidx = 10;
    const maxid = 10;
    const maxshamt = 50;

    var pt: lazytree.Value = .none;
    var pa: lazytree.Value = .none;
    var length: isize = 0;
    var haspt: bool = false;
    t.log_level = .debug;

    for (0..nops) |i| {
        const op = rand.enumValue(Op);
        switch (op) {
            .add => {
                const id = rand.intRangeAtMost(u8, 0, maxid);
                const lowhigh = randrange(maxidx);
                const low = lowhigh[0];
                const high = lowhigh[1];
                std.log.debug("=== {} op={s} {}:[{},{}]", .{ i, @tagName(op), id, low, high });

                pt = try it.add(alloc, id, low, high, lazytree.Value.init((lazytree.IValue{ .value = i })));
                pa = try ia.add(alloc, id, low, high, i);
                length = high - low;
                haspt = true;
            },
            .find => {
                const id = rand.intRangeAtMost(usize, 0, maxid);
                const pos = rand.intRangeAtMost(isize, 0, maxidx);
                std.log.debug("=== {} op={s} {}:{}", .{ i, @tagName(op), id, pos });

                const vt = try it.findLargest(alloc, id, pos);
                const va = ia.findLargest(id, pos);

                if (vt == null and va == null)
                    continue;
                std.log.info("i={} vt={?} va={?}", .{ i, vt, va });
                if ((vt == null) != (va == null)) {
                    std.log.err("Find1 ({}, {}): {?} != {?}", .{ id, pos, vt, va });
                    return error.TestUnexpectedResult;
                }
                if (vt.?.ivalue.value != va.?.value) {
                    std.log.err("Find2 ({}, {}): {?} != {?}", .{ id, pos, vt.?.ivalue.value, va.?.value });
                    return error.TestUnexpectedResult;
                }
            },
            .remove_and_shift => {
                const lowhigh = randrange(maxidx);
                const amt = randint(-maxshamt, maxshamt);
                const low = lowhigh[0];
                const high = lowhigh[1];

                if (haspt) {
                    const ptpos = pt.pos();
                    if ((lazytree.Interval{ .low = low, .high = high })
                        .overlaps(ptpos, ptpos + length))
                    {
                        haspt = false;
                    }
                }
                std.log.debug("=== {} op={s} {}:[{},{}]", .{ i, @tagName(op), amt, low, high });
                try it.removeAndShift(alloc, low, high, amt);
                ia.removeAndShift(low, high, amt);
            },
            .pos => {
                std.log.debug("=== {} op={s}", .{ i, @tagName(op) });
                const post = pt.pos();
                const posa = pa.pos();
                if (haspt and post != posa) {
                    std.log.err("i={} {} != {}", .{ i, post, posa });
                    return error.TestUnexpectedResult;
                }
            },
        }
    }
}

const std = @import("std");
const build_options = @import("build_options");

const treez = if (build_options.use_tree_sitter)
    @import("treez")
else
    @import("treez_dummy.zig");

const Self = @This();

pub const FileType = @import("file_type.zig");
const Query = treez.Query;

allocator: std.mem.Allocator,
mutex: ?std.Thread.Mutex,
highlights: std.StringHashMapUnmanaged(*Query) = .{},
injections: std.StringHashMapUnmanaged(*Query) = .{},
ref_count: usize = 1,

pub const QueryType = enum {
    highlights,
    injections,
};

pub const QueryParseError = error{
    InvalidSyntax,
    InvalidNodeType,
    InvalidField,
    InvalidCapture,
    InvalidStructure,
    InvalidLanguage,
};

pub const Error = (error{
    NotFound,
    OutOfMemory,
} || QueryParseError);

pub fn create(allocator: std.mem.Allocator, opts: struct { lock: bool = false }) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .mutex = if (opts.lock) .{} else null,
    };
    return self;
}

pub fn deinit(self: *Self) void {
    self.release_ref_unlocked_and_maybe_destroy();
}

fn add_ref_locked(self: *Self) void {
    std.debug.assert(self.ref_count > 0);
    self.ref_count += 1;
}

fn release_ref_unlocked_and_maybe_destroy(self: *Self) void {
    {
        if (self.mutex) |*mtx| mtx.lock();
        defer if (self.mutex) |*mtx| mtx.unlock();
        self.ref_count -= 1;
        if (self.ref_count > 0) return;
    }

    var iter_highlights = self.highlights.iterator();
    while (iter_highlights.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.destroy();
    }
    var iter_injections = self.injections.iterator();
    while (iter_injections.next()) |p| {
        self.allocator.free(p.key_ptr.*);
        p.value_ptr.*.destroy();
    }
    self.highlights.deinit(self.allocator);
    self.injections.deinit(self.allocator);
    self.allocator.destroy(self);
}

fn ReturnType(comptime query_type: QueryType) type {
    return switch (query_type) {
        .highlights => *Query,
        .injections => ?*Query,
    };
}

fn get_or_add_internal(self: *Self, file_type: *const FileType, comptime query_type: QueryType) Error!ReturnType(query_type) {
    const hash = switch (query_type) {
        .highlights => &self.highlights,
        .injections => &self.injections,
    };

    return if (hash.get(file_type.name)) |query| query else blk: {
        const lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {s}", .{file_type.name});
        const query = try Query.create(lang, switch (query_type) {
            .highlights => file_type.highlights,
            .injections => if (file_type.injections) |injections| injections else return null,
        });
        errdefer query.destroy();
        try hash.put(self.allocator, try self.allocator.dupe(u8, file_type.name), query);
        break :blk query;
    };
}

pub fn pre_load(self: *Self, lang_name: []const u8) Error!void {
    if (self.mutex) |*mtx| mtx.lock();
    defer if (self.mutex) |*mtx| mtx.unlock();
    const file_type = FileType.get_by_name(lang_name) orelse return;
    _ = try self.get_or_add_internal(file_type, .highlights);
    _ = try self.get_or_add_internal(file_type, .injections);
}

pub fn get(self: *Self, file_type: *const FileType, comptime query_type: QueryType) Error!ReturnType(query_type) {
    if (self.mutex) |*mtx| mtx.lock();
    defer if (self.mutex) |*mtx| mtx.unlock();
    const query = try self.get_or_add_internal(file_type, query_type);
    self.add_ref_locked();
    return query;
}

pub fn release(self: *Self, query: *Query, comptime query_type: QueryType) void {
    _ = query;
    _ = query_type;
    self.release_ref_unlocked_and_maybe_destroy();
}

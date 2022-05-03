const std = @import("std");
const testing = std.testing;

pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
    @cInclude("luajit.h");
});

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic functionality" {
    const script =
        \\print("hello from luajit :)\n")
        \\io.flush()
    ;
    const L = c.luaL_newstate();
    c.luaL_openlibs(L);
    _ = c.luaL_loadstring(L, @ptrCast([*c]const u8, script));
    _ = c.lua_pcall(L, 0, c.LUA_MULTRET, 0);
    c.lua_close(L);

    std.log.warn("hi", .{});
}

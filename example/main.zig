const lj = @import("luajit");

const Error = error{
    LuaError,
};

pub fn main() !void {
    const L = lj.c.luaL_newstate();
    lj.c.luaL_openlibs(L);

    if (lj.c.luaL_loadfile(L, "myscript.lua") != 0) return error.LuaError;
    if (lj.c.lua_pcall(L, 0, lj.c.LUA_MULTRET, 0) != 0) return error.LuaError;

    // That's all floks!
    lj.c.lua_close(L);
}

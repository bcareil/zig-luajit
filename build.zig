const std = @import("std");

pub const pkg = std.build.Pkg{
    .name = "luajit",
    .path = .{ .path = thisDir() ++ "/src/main.zig" },
    .dependencies = null,
};

const luajit_src_path = thisDir() ++ "/third_party/luajit/src/";
const ljlib_c: []const []const u8 = &.{
    "lib_base.c",  "lib_math.c", "lib_bit.c", "lib_string.c",
    "lib_table.c", "lib_io.c",   "lib_os.c",  "lib_package.c",
    "lib_debug.c", "lib_jit.c",  "lib_ffi.c", "lib_buffer.c",
};

// NOTE: as opposed to the Makefile, does not include ljlib_c
const ljcore_c: []const []const u8 = &.{
    "lj_assert.c",     "lj_gc.c",        "lj_err.c",      "lj_char.c",
    "lj_bc.c",         "lj_obj.c",       "lj_buf.c",      "lj_str.c",
    "lj_tab.c",        "lj_func.c",      "lj_udata.c",    "lj_meta.c",
    "lj_debug.c",      "lj_prng.c",      "lj_state.c",    "lj_dispatch.c",
    "lj_vmevent.c",    "lj_vmmath.c",    "lj_strscan.c",  "lj_strfmt.c",
    "lj_strfmt_num.c", "lj_serialize.c", "lj_api.c",      "lj_profile.c",
    "lj_lex.c",        "lj_parse.c",     "lj_bcread.c",   "lj_bcwrite.c",
    "lj_load.c",       "lj_ir.c",        "lj_opt_mem.c",  "lj_opt_fold.c",
    "lj_opt_narrow.c", "lj_opt_dce.c",   "lj_opt_loop.c", "lj_opt_split.c",
    "lj_opt_sink.c",   "lj_mcode.c",     "lj_snap.c",     "lj_record.c",
    "lj_crecord.c",    "lj_ffrecord.c",  "lj_asm.c",      "lj_trace.c",
    "lj_gdbjit.c",     "lj_ctype.c",     "lj_cdata.c",    "lj_cconv.c",
    "lj_ccall.c",      "lj_ccallback.c", "lj_carith.c",   "lj_clib.c",
    "lj_cparse.c",     "lj_lib.c",       "lj_alloc.c",    "lib_aux.c",
    "lib_init.c",
};

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const lib = b.addStaticLibrary("zig-luajit", "src/main.zig");
    addLuajit(lib) catch unreachable;
    lib.addIncludeDir(luajit_src_path);
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.install();

    const main_tests = b.addTest("src/main.zig");
    main_tests.setTarget(target);
    main_tests.setBuildMode(mode);
    addLuajit(main_tests) catch unreachable;

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    buildExample(b, target, mode);
}

pub fn buildExample(b: *std.build.Builder, target: std.zig.CrossTarget, mode: std.builtin.Mode) void {
    const exe = b.addExecutable("my-lua-proj", "example/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    // earlier in your build script; you would have
    // const addLuajit = @import("path/to/this/build.zig").addLuajit;
    addLuajit(exe) catch unreachable;

    // run step
    const run_exe = exe.run();
    run_exe.cwd = "./example/";
    const run_step = b.step("run-example", "Run luajit example");
    run_step.dependOn(&run_exe.step);

    // add some tests!
}

/// returns an owned slice
fn generateLjArchOutput(cwd: []const u8, zig_exe: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var zig_cmd = std.ArrayList([]const u8).init(allocator);
    defer zig_cmd.deinit();

    try zig_cmd.append(zig_exe);
    try zig_cmd.append("cc");
    try zig_cmd.append("-E");
    try zig_cmd.append(thisDir() ++ "/third_party/luajit/src/lj_arch.h");
    try zig_cmd.append("-dM");

    var child_proc = try std.ChildProcess.init(zig_cmd.items, allocator);
    defer child_proc.deinit();

    child_proc.cwd = cwd;
    child_proc.stdin_behavior = .Close;
    child_proc.stdout_behavior = .Pipe;
    child_proc.stderr_behavior = .Inherit;

    child_proc.spawn() catch |err| {
        std.log.err("Error spawning {s}: {s}\n", .{ zig_cmd.items[0], @errorName(err) });
        return err;
    };

    return try child_proc.stdout.?.reader().readAllAlloc(allocator, 2 * 1024 * 1024);
}

fn createBuildvmExeStep(builder: *std.build.Builder, host_cflags: []const []const u8) !*std.build.LibExeObjStep {
    const buildvm_c: []const []const u8 = &.{
        luajit_src_path ++ "/host/buildvm.c",
        luajit_src_path ++ "/host/buildvm_asm.c",
        luajit_src_path ++ "/host/buildvm_peobj.c",
        luajit_src_path ++ "/host/buildvm_lib.c",
        luajit_src_path ++ "/host/buildvm_fold.c",
    };

    var buildvm_exe = builder.addExecutable("buildvm", null);
    buildvm_exe.addIncludeDir(luajit_src_path);
    buildvm_exe.addCSourceFiles(buildvm_c, host_cflags);
    buildvm_exe.linkSystemLibrary("m");
    buildvm_exe.linkLibC();
    buildvm_exe.setBuildMode(.ReleaseSmall);
    buildvm_exe.setTarget(std.zig.CrossTarget.fromTarget(builder.host.target));
    return buildvm_exe;
}

fn createBuildvmGenStep(builder: *std.build.Builder, buildvm_exe: *std.build.LibExeObjStep, target_os_tag: std.Target.Os.Tag) !*std.build.Step {

    // we don't really need the log, just a way to conviniently
    // aggregate all generated targets behind a single step to
    // depend on
    var buildvm_gen_step = builder.addLog("luajit: buildvm gen done\n", .{});

    // those targets all build the same
    const simple_targets: []const []const u8 = &.{
        "bcdef", "ffdef", "libdef", "recdef",
    };

    inline for (simple_targets) |t| {
        const target = "lj_" ++ t ++ ".h";
        const buildvm_gen_simple = buildvm_exe.run();
        buildvm_gen_simple.cwd = luajit_src_path;
        buildvm_gen_simple.addArgs(&.{
            "-m", t, "-o", target,
        });
        buildvm_gen_simple.addArgs(ljlib_c);
        buildvm_gen_step.step.dependOn(&buildvm_gen_simple.step);
    }

    // remains 3 target that require custom handling:
    // * folddef
    // * vmdef
    // * a platform dependent one

    { // folddef
        var buildvm_gen_folddef = buildvm_exe.run();
        buildvm_gen_folddef.cwd = luajit_src_path;
        buildvm_gen_folddef.addArgs(&.{
            "-m", "folddef", "-o", "lj_folddef.h", "lj_opt_fold.c",
        });
        buildvm_gen_step.step.dependOn(&buildvm_gen_folddef.step);
    }

    { // vmdef
        var buildvm_gen_vmdef = buildvm_exe.run();
        buildvm_gen_vmdef.cwd = luajit_src_path;
        buildvm_gen_vmdef.addArgs(&.{
            "-m", "vmdef", "-o", "jit/vmdef.lua",
        });
        buildvm_gen_vmdef.addArgs(ljlib_c);
        buildvm_gen_step.step.dependOn(&buildvm_gen_vmdef.step);
    }

    { // platform dependent
        const mode = blk: {
            switch (target_os_tag) {
                .macos, .ios => break :blk "machasm",
                .windows => break :blk "peobj",
                else => break :blk "elfasm",
            }
        };
        const target = blk: {
            switch (target_os_tag) {
                .windows => break :blk "lj_vm.o",
                else => break :blk "lj_vm.S",
            }
        };
        var buildvm_gen_ljvm = buildvm_exe.run();
        buildvm_gen_ljvm.cwd = luajit_src_path;
        buildvm_gen_ljvm.addArgs(&.{
            "-m", mode, "-o", target,
        });
        buildvm_gen_step.step.dependOn(&buildvm_gen_ljvm.step);
    }
    return &buildvm_gen_step.step;
}

pub fn addLuajit(exe: *std.build.LibExeObjStep) !void {
    const allocator = exe.builder.allocator;
    const cwd = exe.builder.build_root;

    const target_os_tag = exe.target.os_tag orelse exe.builder.host.target.os.tag;
    const target_arch = exe.target.cpu_arch orelse exe.builder.host.target.cpu.arch;

    var stdout = try generateLjArchOutput(cwd, exe.builder.zig_exe, exe.builder.allocator);
    defer allocator.destroy(stdout.ptr);

    var minilua_flags = std.ArrayList([]const u8).init(allocator);
    defer minilua_flags.deinit();

    // disable UB-san as minilua relies way too much on them
    // NOTE: we could replace minilua with other interpreter
    try minilua_flags.append("-fno-sanitize=undefined");

    // TARGET_ARCH from target cpu arch
    // NOTE: TARGET_ARCH ends up containing many things but we can discriminate
    // them in three categories:
    // - target cpu arch
    // - target os related (though there is only things for PS3 here, that we
    //   do not support)
    // - features related to the target platform
    switch (target_arch) {
        .aarch64_be => {
            try minilua_flags.append("-D__AARCH64EB__=1");
        },
        .powerpc => {
            try minilua_flags.append("-DLJ_ARCH_ENDIAN=LUAJIT_BE");
        },
        .powerpcle => {
            try minilua_flags.append("-DLJ_ARCH_ENDIAN=LUAJIT_LE");
        },
        .mipsel, .mips64el => {
            try minilua_flags.append("-D__MIPSEL__=1");
        },
        else => {},
    }

    // TARGET_LJARCH
    const luajit_arch_name = blk: {
        switch (target_arch) {
            .arm, .mips, .mips64, .mipsel, .mips64el => {
                break :blk @tagName(target_arch);
            },
            // other arch have different names for luajit
            .aarch64, .aarch64_be => {
                break :blk "arm64";
            },
            .i386 => {
                break :blk "x86";
            },
            .x86_64 => {
                break :blk "x64";
            },
            .powerpc, .powerpcle => {
                break :blk "ppc";
            },
            // every other arch are not supported
            else => {
                return error.UnsupportedCpuArchitecture;
            },
        }
    };
    var minilua_luajit_target = try std.fmt.allocPrint(allocator, "-DLUAJIT_TARGET=LUAJIT_ARCH_{s}", .{luajit_arch_name});
    defer allocator.free(minilua_luajit_target);
    try minilua_flags.append(minilua_luajit_target);

    // CCOPT_$arch
    switch (target_arch) {
        .i386 => {
            try minilua_flags.append("-march=i686");
            try minilua_flags.append("-msse");
            try minilua_flags.append("-msse2");
            try minilua_flags.append("-mfpmath=sse");
        },
        // No specific flags for other platforms by default
        else => {},
    }

    var dasm_aflags = std.ArrayList([]const u8).init(allocator);
    defer dasm_aflags.deinit();

    if (std.mem.indexOf(u8, stdout, "LJ_LE 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("ENDIAN_LE");
    } else {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("ENDIAN_BE");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_ARCH_BITS 64")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("P64");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_HASJIT 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("JIT");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_HASFFI 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("FFI");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_DUALNUM 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("DUALNUM");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_ARCH_HASFPU 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("FPU");
        try minilua_flags.append("-DLJ_ARCH_HASFPU=1");
    } else {
        try minilua_flags.append("-DLJ_ARCH_HASFPU=0");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_ABI_SOFTFP 1")) |_| {
        try minilua_flags.append("-DLJ_ABI_SOFTFP=1");
    } else {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("HFABI");
        try minilua_flags.append("-DLJ_ABI_SOFTFP=0");
    }
    if (std.mem.indexOf(u8, stdout, "LJ_NO_UNWIND 1")) |_| {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("NO_UNWIND");
        try minilua_flags.append("-DLUAJIT_NO_UNWIND");
    }

    const version_define = "LJ_ARCH_VERSION ";
    const version = blk: {
        var vs: []const u8 = "";
        if (std.mem.indexOf(u8, stdout, version_define)) |i| {
            const version_start = i + version_define.len;
            if (std.mem.indexOfPosLinear(u8, stdout, version_start, "\n")) |version_end| {
                vs = stdout[version_start..version_end];
            }
        }
        break :blk try std.fmt.allocPrint(allocator, "VER={s}", .{vs});
    };
    defer allocator.free(version);

    try dasm_aflags.append("-D");
    try dasm_aflags.append(version);

    if (target_os_tag == .windows) {
        try dasm_aflags.append("-D");
        try dasm_aflags.append("WIN");
    }

    var dasm_arch = luajit_arch_name;
    if (target_arch == .aarch64) {
        // need to rename aarch64 to arm64 to match the vm_<arch>.dasc filename
        dasm_arch = "arm64";
    }
    if (target_arch == .x86_64) {
        if (std.mem.indexOf(u8, stdout, "LJ_FR2 1")) |_| {} else {
            dasm_arch = "x86";
        }
    } else if (target_arch == .arm) {
        if (target_os_tag == .ios) {
            try dasm_aflags.append("-D");
            try dasm_aflags.append("IOS");
        }
    } else {
        if (std.mem.indexOf(u8, stdout, "LJ_TARGET_MIPSR6 ")) |_| {
            try dasm_aflags.append("-D");
            try dasm_aflags.append("MIPSR6");
        }
        if (target_arch == .powerpc) {
            if (std.mem.indexOf(u8, stdout, "LJ_ARCH_SQRT 1")) |_| {
                try dasm_aflags.append("-D");
                try dasm_aflags.append("SQRT");
            }
            if (std.mem.indexOf(u8, stdout, "LJ_ARCH_ROUND 1")) |_| {
                try dasm_aflags.append("-D");
                try dasm_aflags.append("ROUND");
            }
            if (std.mem.indexOf(u8, stdout, "LJ_ARCH_PPC32ON64 1")) |_| {
                try dasm_aflags.append("-D");
                try dasm_aflags.append("GPR64");
            }
            // .ps3 not available (has .ps4 though)
            //if (target_os_tag == .ps3) {
            //    try dasm_aflags.append("-D");
            //    try dasm_aflags.append("PPE");
            //    try dasm_aflags.append("-D");
            //    try dasm_aflags.append("TOC");
            //}
        }
    }

    try dasm_aflags.append("-o");
    try dasm_aflags.append("host/buildvm_arch.h");

    var dasm_dasc = try std.fmt.allocPrint(allocator, "vm_{s}.dasc", .{dasm_arch});
    defer allocator.free(dasm_dasc);

    try dasm_aflags.append(dasm_dasc);

    // compile minilua for the host machine, will be needed to generate various
    // files before the compilation of luajit
    var minilua_exe = exe.builder.addExecutable("minilua", null);
    minilua_exe.addCSourceFile(luajit_src_path ++ "/host/minilua.c", minilua_flags.items);
    minilua_exe.linkSystemLibrary("m");
    minilua_exe.linkLibC();
    minilua_exe.setBuildMode(.ReleaseSmall);
    minilua_exe.setTarget(std.zig.CrossTarget.fromTarget(exe.builder.host.target));
    const minilua_run = minilua_exe.run();

    var minilua_cwd = try std.fmt.allocPrint(allocator, "{s}/third_party/luajit/src", .{cwd});
    minilua_run.cwd = minilua_cwd;
    minilua_run.addArg("../dynasm/dynasm.lua");
    minilua_run.addArgs(dasm_aflags.items);

    var buildvm_exe = try createBuildvmExeStep(exe.builder, minilua_flags.items);
    buildvm_exe.step.dependOn(&minilua_run.step);

    var buildvm_gen_step = try createBuildvmGenStep(exe.builder, buildvm_exe, target_os_tag);

    var luajit_sys_libs = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer luajit_sys_libs.deinit();
    var luajit_flags = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer luajit_flags.deinit();

    try luajit_flags.append("-fno-sanitize=undefined");
    try luajit_flags.append("-O2");
    try luajit_flags.append("-fomit-frame-pointer");

    try luajit_sys_libs.append("m");

    switch (target_os_tag) {
        .freebsd => try luajit_sys_libs.append("dl"),
        .linux => {
            try luajit_sys_libs.append("dl");
            try luajit_sys_libs.append("unwind");
            try luajit_flags.append("-funwind-tables");
            try luajit_flags.append("-DLUAJIT_UNWIND_EXTERNAL");
        },
        // NOTE: PS3 would require pthread but it's not supported by zig
        else => {},
    }

    var luajit_src = try std.ArrayList([]const u8).initCapacity(allocator, ljlib_c.len + ljcore_c.len);
    inline for (ljlib_c) |c| {
        try luajit_src.append(luajit_src_path ++ c);
    }
    inline for (ljcore_c) |c| {
        try luajit_src.append(luajit_src_path ++ c);
    }

    var luajit_lib = exe.builder.addStaticLibrary("luajit", null);
    luajit_lib.step.dependOn(buildvm_gen_step);
    luajit_lib.linkLibC();
    luajit_lib.addCSourceFiles(luajit_src.items, luajit_flags.items);
    if (target_os_tag == .windows) {
        luajit_lib.addObjectFile(luajit_src_path ++ "/lj_vm.o");
    } else {
        luajit_lib.addAssemblyFile(luajit_src_path ++ "/lj_vm.S");
    }

    exe.linkLibrary(luajit_lib);
    for (luajit_sys_libs.items) |l| {
        exe.linkSystemLibrary(l);
    }

    exe.addIncludeDir(luajit_src_path);

    exe.addPackage(pkg);
}

---
title: L.E.V.Y
abstract: |
    A game
...

# Progress

## Disparity Engine

- [x] ECS
- [ ] collision system
  - [ ] backed collision tree for static

## Game mechanics

# Introduction

    lang: zig esc: none file: src/lib.zig
    -------------------------------------

    pub const aecs = @import("aecs.zig");
    pub const sort = @import("sort.zig");
    pub const geometry = @import("geometry.zig");
    // pub const kd = @import("kd.zig");

    comptime {
        _ = aecs;
        _ = sort;
        _ = geometry;
        // _ = kd;
    }

# Building

    lang: zig esc: none file: build.zig
    -----------------------------------

    const std = @import("std");

    pub fn build(b: *std.build.Builder) void {
        const exe = b.addExecutable("levy", "src/main.zig");
        exe.single_threaded = true;
        exe.addCSourceFiles(&.{
            "vendor/raylib/src/rcore.c",
            "vendor/raylib/src/rmodels.c",
            "vendor/raylib/src/raudio.c",
            "vendor/raylib/src/rglfw.c",
            "vendor/raylib/src/rshapes.c",
            "vendor/raylib/src/rtext.c",
            "vendor/raylib/src/rtextures.c",
            "vendor/raylib/src/utils.c",
        }, &.{
            "-std=c99",
            "-DPLATFORM=DESKTOP",
            "-DPLATFORM_DESKTOP",
            "-DGRAPHICS=GRAPHICS_API_OPENGL_33",
            "-D_DEFAULT_SOURCE",
            "-Iraylib/src",
            "-Iraylib/src/external/glfw/include",
            "-Iraylib/src/external/glfw/deps",
            "-fno-sanitize=undefined",
        });
        exe.addIncludeDir("vendor/raylib/src");
        exe.linkSystemLibrary("X11");
        exe.linkSystemLibrary("gl");
        exe.linkSystemLibrary("m");
        exe.linkSystemLibrary("pthread");
        exe.linkSystemLibrary("dl");
        exe.linkSystemLibrary("rt");
        exe.linkLibC();
        exe.install();

        const run = exe.run();
        run.step.dependOn(b.getInstallStep());
        if (b.args) |args| run.addArgs(args);

        const lib = b.addTest("src/lib.zig");

        const run_step = b.step("run", "run the game");
        run_step.dependOn(&run.step);

        const test_step = b.step("test", "run unit tests");
        test_step.dependOn(&lib.step);
    }

# Map

![Blocks](uml/img/map.png)

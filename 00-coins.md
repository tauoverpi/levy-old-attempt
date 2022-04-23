---
title: L.E.V.Y - coins
...

    lang: zig esc: none file: src/main.zig
    --------------------------------------

    const std = @import("std");
    const lib = @import("lib.zig");
    const raylib = @cImport(@cInclude("raylib.h"));
    const math = std.math;

    const Array = std.MultiArrayList;
    const ArrayList = std.ArrayListUnmanaged;
    const Model = lib.aecs.Model(Data);
    const Archetype = Model.Archetype;
    const EntityId = lib.aecs.EntityId;
    const Allocator = std.mem.Allocator;

    const Box2D = lib.geometry.Box2D;
    const Point2D = lib.geometry.Point2D;
    const Vector2D = lib.geometry.Vector2D;

    const Choice = union(enum) {
        idle,
        goto: Point2D,
    };

    const Data = struct {
        position: Point2D,
        position_next: Point2D,
        velocity: Vector2D,
        box: Box2D,
        coin: void,
        input: void,
        ai: Choice,
    };

    const width = 720;
    const height = 480;

    pub fn main() anyerror!void {
        raylib.InitWindow(width, height, "L.E.V.Y");
        defer raylib.CloseWindow();

        const gpa = std.heap.c_allocator;

        var game: Model = .{};
        var systems: Systems = .{};

        var generator = std.rand.DefaultPrng.init(0xdeadbeefcafebabe);
        const rng = generator.random();

        _ = try game.insert(gpa, .{}, template.Player, .{
            .position = .{ .x = width / 2, .y = height / 2 },
            .position_next = .{ .x = width / 2, .y = height / 2 },
        });

        {
            var index: u32 = 0;
            while (index < 10) : (index += 1) {
                const x = 5 + rng.intRangeLessThan(i32, 0, width - 20);
                const y = 5 + rng.intRangeLessThan(i32, 0, height - 20);
                const point = .{ .x = @intToFloat(f32, x), .y = @intToFloat(f32, y) };

                _ = try game.insert(gpa, .{}, template.Coin, .{
                    .position = point,
                });
            }
        }

        raylib.SetTargetFPS(60);

        while (!raylib.WindowShouldClose()) {
            systems.input.key.set(.up, raylib.IsKeyDown(raylib.KEY_UP));
            systems.input.key.set(.down, raylib.IsKeyDown(raylib.KEY_DOWN));
            systems.input.key.set(.left, raylib.IsKeyDown(raylib.KEY_LEFT));
            systems.input.key.set(.right, raylib.IsKeyDown(raylib.KEY_RIGHT));

            try systems.update(gpa, &game);

            raylib.BeginDrawing();
            raylib.ClearBackground(raylib.RAYWHITE);
            defer raylib.EndDrawing();

            for (systems.render.scene.items) |item| {
                const rect: raylib.Rectangle = .{
                    .x = item.x,
                    .y = item.y,
                    .width = 10,
                    .height = 10,
                };

                raylib.DrawRectangleRec(rect, raylib.BLACK);
            }
        }
    }

    const template = struct {
        pub const Player = struct {
            input: void = {},
            position: Point2D,
            position_next: Point2D,
            box: Box2D = .{
                .min = .{ .x = 0, .y = 0 },
                .max = .{ .x = 5, .y = 5 },
            },
            velocity: Vector2D = .{
                .x = 0,
                .y = 0,
            },
        };

        pub const Coin = struct {
            position: Point2D,
            coin: void = {},
        };
    };

    const Systems = struct {
        input: Input = .{},
        movement: Movement = .{},
        collision: Collision = .{},
        apply_movement: ApplyMovement = .{},
        render: Render = .{},
        ai: ArtificialIntelligence = .{},

        const Tag = Model.Archetype.Tag;

        pub fn update(self: *Systems, gpa: Allocator, model: *Model) !void {
            var err: anyerror!void = {};
            inline for (std.meta.fields(Systems)) |field| {
                err = @field(self, field.name).update(gpa, model);
                try err;
            }
        }

        pub const Movement = struct {
            delta: f32 = 1,

            pub const inputs = Archetype.init(&.{
                .position_next,
                .velocity,
            });

            pub fn update(
                self: *Movement,
                _: Allocator,
                model: *Model,
            ) !void {
                const delta = self.delta;

                var it = model.query(inputs);

                while (it.next()) |entry| {
                    const array = entry.arrays(inputs);

                    const p = array.position_next;
                    const v = array.velocity;

                    for (entry.bucket.entities.items) |_, index| {
                        p[index] = .{
                            .x = v[index].x * delta + p[index].x,
                            .y = v[index].y * delta + p[index].y,
                        };
                    }
                }
            }

        };

        pub const ApplyMovement = struct {
            pub const inputs = Archetype.init(&.{
                .position,
                .position_next,
            });

            pub fn update(
                self: *ApplyMovement,
                _: Allocator,
                model: *Model,
            ) !void {
                _ = self;
                var it = model.query(inputs);

                while (it.next()) |entry| {
                    const array = entry.arrays(inputs);

                    const p = array.position;
                    const d = array.position_next;

                    for (entry.bucket.entities.items) |_, index| {
                        p[index] = .{
                            .x = d[index].x,
                            .y = d[index].y,
                        };
                    }
                }
            }
        };

        pub const Input = struct {
            key: Key = .{},

            pub const Key = struct {
                up: u8 = 0,
                down: u8 = 0,
                left: u8 = 0,
                right: u8 = 0,

                const Tag = enum {
                    up,
                    down,
                    left,
                    right,
                };

                pub fn set(self: *Key, comptime key: Key.Tag, state: bool) void {
                    @field(self, @tagName(key)) <<= 1;
                    @field(self, @tagName(key)) |= @boolToInt(state);
                }
            };

            pub const inputs = Archetype.init(&.{
                .input,
            });

            pub fn update(self: *Input, _: Allocator, model: *Model) !void {
                var it = model.query(inputs);

                while (it.next()) |entry| {
                    if (entry.get(.velocity)) |velocity| {
                        var x: f32 = 0;
                        var y: f32 = 0;

                        if (self.key.up & 1 == 1) y -= 2;
                        if (self.key.down & 1 == 1) y += 2;
                        if (self.key.left & 1 == 1) x -= 2;
                        if (self.key.right & 1 == 1) x += 2;

                        for (entry.bucket.entities.items) |_, index| {
                            velocity[index] = .{ .x = x, .y = y };
                        }
                    }
                }
            }
        };

        pub const Collision = struct {
            pub const inputs = Archetype.init(&.{
                .position,
                .box,
            });

            pub fn update(
                self: *Collision,
                gpa: Allocator,
                model: *Model,
            ) !void {
                _ = self;
                _ = gpa;
                _ = model;
            }
        };

        pub const ArtificialIntelligence = struct {
            pub const inputs = Archetype.init(&.{
                .ai,
            });

            // state machine

            pub fn update(
                self: *ArtificialIntelligence,
                gpa: Allocator,
                model: *Model,
            ) !void {
                var it = model.query(inputs);
                _ = self;
                _ = gpa;

                while (it.next()) |entry| {
                    _ = entry;
                }
            }
        };

        pub const Render = struct {
            scene: ArrayList(Object) = .{},

            pub const inputs = Archetype.init(&.{
                .position,
            });

            pub const Object = struct {
                x: f32,
                y: f32,
                z: f32,
            };

            pub fn update(
                self: *Render,
                gpa: Allocator,
                model: *Model,
            ) !void {
                self.scene.clearRetainingCapacity();

                var it = model.query(inputs);

                while (it.next()) |entry| {
                    const array = entry.arrays(inputs);

                    const z: f32 = if (entry.type.has(.coin)) 1 else 0;

                    try self.scene.ensureUnusedCapacity(gpa, array.position.len);

                    for (entry.bucket.entities.items) |_, index| {
                        self.scene.appendAssumeCapacity(.{
                            .x = array.position[index].x,
                            .y = array.position[index].y,
                            .z = z,
                        });
                    }
                }
            }
        };
    };



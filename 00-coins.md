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
    const EntityId = lib.aecs.EntityId;
    const Allocator = std.mem.Allocator;

    const Data = struct {
        position: Point2D,
        position_next: Point2D,
        velocity: Vector2D,
        shape: Circle2D,
        coin: void,
        input: void,

        pub const Point2D = struct { x: i32, y: i32 };
        pub const Vector2D = struct { x: i32, y: i32 };
        pub const Circle2D = struct { r: i32 };
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
                const point = .{ .x = x, .y = y };

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

            try game.step(gpa, &systems);

            raylib.BeginDrawing();
            raylib.ClearBackground(raylib.RAYWHITE);
            defer raylib.EndDrawing();

            for (systems.render.scene.items) |item| {
                const rect: raylib.Rectangle = .{
                    .x = math.lossyCast(f32, item.x),
                    .y = math.lossyCast(f32, item.y),
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
            position: Data.Point2D,
            position_next: Data.Point2D,
            shape: Data.Circle2D = .{
                .r = 5,
            },
            velocity: Data.Vector2D = .{
                .x = 0,
                .y = 0,
            },
        };

        pub const Coin = struct {
            position: Data.Point2D,
            coin: void = {},
        };
    };

    const Systems = struct {
        input: Input = .{},
        movement: Movement = .{},
        collision: Collision = .{},
        apply_movement: ApplyMovement = .{},
        render: Render = .{},

        const Tag = Model.Archetype.Tag;

        pub const Movement = struct {
            delta: i32 = 1,

            pub const inputs: []const Tag = &.{
                .position_next,
                .velocity,
            };

            pub fn update(
                self: *Movement,
                position: *Array(Data.Point2D),
                velocity: *const Array(Data.Vector2D),
                context: Model.UpdateContext,
            ) !void {
                _ = context;

                const delta = self.delta;
                const x = position.items(.x);
                const y = position.items(.y);
                const vx = velocity.items(.x);
                const vy = velocity.items(.y);

                for (context.entities) |_, index| {
                    x[index] = vx[index] * delta + x[index];
                    y[index] = vy[index] * delta + y[index];
                }
            }

        };

        pub const ApplyMovement = struct {
            pub const inputs: []const Tag = &.{
                .position,
                .position_next,
            };

            pub fn update(
                self: *ApplyMovement,
                position: *Array(Data.Point2D),
                destination: *const Array(Data.Point2D),
                context: Model.UpdateContext,
            ) !void {
                _ = self;
                const x = position.items(.x);
                const y = position.items(.y);
                const dx = destination.items(.x);
                const dy = destination.items(.y);

                for (context.entities) |_, index| {
                    x[index] = dx[index];
                    y[index] = dy[index];
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

            pub const inputs: []const Tag = &.{
                .input,
            };

            pub fn update(self: *Input, context: Model.UpdateContext) !void {
                if (context.get(.velocity)) |velocity| {
                    var x: i32 = 0;
                    var y: i32 = 0;

                    if (self.key.up & 1 == 1) y -= 2;
                    if (self.key.down & 1 == 1) y += 2;
                    if (self.key.left & 1 == 1) x -= 2;
                    if (self.key.right & 1 == 1) x += 2;

                    const vx = velocity.items(.x);
                    const vy = velocity.items(.y);

                    for (context.entities) |_, index| {
                        vx[index] = x;
                        vy[index] = y;
                    }
                }
            }
        };

        pub const Collision = struct {
            pub const Object = struct {
                position: Data.Point2D,
                shape: Data.Circle2D,
                id: EntityId,
            };

            pub const inputs: []const Tag = &.{
                .position,
                .shape,
            };

            pub fn begin(self: *Collision, context: Model.BeginContext) !void {
                _ = context;
                _ = self;
                //self.quad.shrinkRetainingCapacity(0);
            }

            pub fn update(
                self: *Collision,
                position: *const Array(Data.Point2D),
                shape: *const Array(Data.Circle2D),
                context: Model.UpdateContext,
            ) !void {
                for (context.entities) |id, index| {
                    _ = self;
                    _ = position;
                    _ = shape;
                    _ = id;
                    _ = index;
                }
            }
        };

        pub const Render = struct {
            scene: ArrayList(Object) = .{},

            pub const inputs: []const Tag = &.{
                .position,
            };

            pub const Object = struct {
                x: i32,
                y: i32,
                z: i32,
            };

            pub fn begin(self: *Render, context: Model.BeginContext) !void {
                _ = context;
                self.scene.clearRetainingCapacity();
            }

            pub fn update(
                self: *Render,
                position: *const Array(Data.Point2D),
                context: Model.UpdateContext,
            ) !void {
                const x = position.items(.x);
                const y = position.items(.y);
                const z: i32 = if (context.type.has(.coin)) 1 else 0;

                try self.scene.ensureUnusedCapacity(context.gpa, position.len);

                for (context.entities) |_, index| {
                    self.scene.appendAssumeCapacity(.{
                        .x = x[index],
                        .y = y[index],
                        .z = z,
                    });
                }
            }

            pub fn end(self: *Render, context: Model.EndContext) !void {
                // TODO: sort the shit
                _ = self;
                _ = context;
            }
        };
    };



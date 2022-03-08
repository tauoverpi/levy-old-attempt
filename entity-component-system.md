---
title: Archetype Entity Component Systems
header-includes: |
  \newcommand{\hidden}[1]{}
  <style>
    .codeblock-tag {
        text-align: center;
        text-decoration: underline;
    }
  </style>
abstract: |
    We define an entity-component-system with archetype storage with compile-time specialization.
...

    lang: zig esc: [[]] file: src/aecs.zig
    --------------------------------------

    const std = @import("std");
    const math = std.math;
    const meta = std.meta;
    const assert = std.debug.assert;

    const Allocator = std.mem.Allocator;

    [[An entity manager system with entity reclimation]]
    [[Definition of an entity component store]]
    [[The archetype storage container]]
    [[Testing]]

# Entity

![Entity overview](uml/img/aecs-entity.png)

\hidden{

    lang: uml esc: none file: uml/aecs-entity.uml
    ---------------------------------------------

    @startuml img/aecs-entity.png

    graph G {
        layout=dot
        concentrate=false

        node[shape=rectangle]

        player
        cart
        waypoint
        npc
        bullet
        light

        subgraph cluster_0 {
            label="components"
            color="#aaaaaa"

            position
            velocity
            acceleration
            orientation
            mass
            health
            mana
            joystick
            planner
            intensity
        }

        player -- position, velocity, acceleration, orientation, mass, health, mana, joystick
        cart -- position, velocity, acceleration, orientation, mass
        waypoint -- position
        position, velocity, acceleration, orientation, mass, health, mana, planner -- npc
        position, velocity, acceleration -- bullet
        position, orientation, intensity -- light
    }

    @enduml

}


Entity identifiers are represented by 32-bit integers dealt out by an `EntityManager` responsible for generating
new identifiers as needed and reusing old identifiers returned to the manager.

    lang: zig esc: none tag: #An entity manager system with entity reclimation
    --------------------------------------------------------------------------

    pub const EntityId = enum(u32) { _ };
    pub const EntityManager = struct {
        index: u32 = 0,
        dead: std.ArrayListUnmanaged(EntityId) = .{},

        pub fn new(self: *EntityManager, gpa: Allocator) Allocator.Error!EntityId {
            if (self.dead.popOrNull()) |id| return id;

            if (self.index == math.maxInt(u32)) {
                return error.OutOfMemory;
            } else {
                try self.dead.ensureTotalCapacity(gpa, self.index + 1);
                defer self.index += 1;
                return @intToEnum(EntityId, self.index);
            }
        }

        pub fn delete(self: *EntityManager, id: EntityId) void {
            self.dead.appendAssumeCapacity(id);
        }

        pub fn deinit(self: *EntityManager, gpa: Allocator) void {
            self.dead.deinit(gpa);
        }
    };

# Archetype

Each entity within the database has a shape given by the combination of it's components called an `Archetype`. Within
the database, this is represented as an unsigned integer used as a bitmap where each bit corresponds to the presence
of one of the components.

    lang: zig esc: [[]] tag: #Archetype representation
    --------------------------------------------------

    pub const Archetype = enum(Int) {
        empty,
        _,

        pub const Tag = meta.FieldEnum(T);
        pub const len = meta.fields(T).len;

        /// Backing integer of the archtype type
        pub const Int = meta.Int(.unsigned, len);

        pub fn init(tags: []const Tag) Archetype {
            var self: Archetype = .empty;

            for (tags) |tag| self = self.with(tag);

            return self;
        }

        [[Deriving archetypes]]
        [[Archetypes without data]]
        [[Recovering component indices from Archetypes]]
        [[Archetype membership and subtypes]]
    };

## Subtypes and membership

    lang: zig esc: none tag: #Archetype membership and subtypes
    -----------------------------------------------------------

    pub fn has(self: Archetype, tag: Tag) bool {
        const bit = @as(Int, 1) << @enumToInt(tag);
        return @enumToInt(self) & bit != 0;
    }

    /// Check if the given archetype is a supertype of the other archtype.
    pub fn contains(self: Archetype, other: Archetype) bool {
        return self.intersection(other) == other;
    }

## Deriving archetypes

    lang: zig esc: none tag: #Deriving archetypes
    ---------------------------------------------

    /// Construct a new archetype with the given tag included in the set of active components
    pub fn with(self: Archetype, tag: Tag) Archetype {
        const bit = @as(Int, 1) << @enumToInt(tag);
        return @intToEnum(Archetype, @enumToInt(self) | bit);
    }

    /// Construct a new archetype without the given tag included in the set of active components
    pub fn without(self: Archetype, tag: Tag) void {
        const mask = ~(@as(Int, 1) << @enumToInt(tag));
        return @intToEnum(Archetype, mask & @enumToInt(self));
    }

    /// Construct the union of two archetypes
    pub fn merge(self: Archetype, other: Archetype) Archetype {
        return @intToEnum(Archetype, @enumToInt(self) | @enumToInt(other));
    }

    /// Construct the intersection of two archetypes
    pub fn intersection(self: Archetype, other: Archetype) Archetype {
        return @intToEnum(Archetype, @enumToInt(self) & @enumToInt(other));
    }

    /// Construct the difference of two archetypes
    pub fn difference(self: Archetype, other: Archetype) Archetype {
        return @intToEnum(Archetype, @enumToInt(self) & ~@enumToInt(other));
    }

## Void components

Components without any associated data become tags which can be matched by systems while not needing an in-memory
representation. To handle this properly in functions which rely on the number of bits present for allocation and
indexing, a mask is constructed such that void components can be ignored.

    lang: zig esc: none tag: #Archetypes without data
    -------------------------------------------------

    /// An archetype consisting of all void components
    pub const void_bits = blk: {
        var archetype: Archetype = .empty;

        for (meta.fields(T)) |field| if (field.field_type == void) {
            const tag = @field(Tag, field.name);
            archetype = archetype.with(tag);
        };

        break :blk archetype;
    };

## Component indices

![Relation between bits within an archetype and component positions](uml/img/aecs-component-indices.png)

\hidden{

    lang: uml esc: none file: uml/aecs-component-indices.uml
    --------------------------------------------------------

    @startuml img/aecs-component-indices.png
    ditaa

                archetype
    +-------------------------------+
    | 0 | 0 | 1 | 0 | 1 | 1 | 0 | 1 |
    +---------+-------+---+-------+-+       storage layout
              |       |   |       |    +------------------------+
              |       |   |       +--->| Position component     |
              |       |   |            +------------------------+
              |       |   +----------->| Velocity component     |
              |       |                +------------------------+
              |       +--------------->| Acceleration component |
              |                        +------------------------+
              +----------------------->| Mass component         |
                                       +------------------------+

    @enduml

}

Archetypes encode the offset of each component within component storage by the number of set bits preceding the
bit-index of the component of interest while ignoring components which aren't present. Since an Archetype may have
components without associated data, the set must not contain any of those components and thus the difference is
taken between the set and that of all void components.

    lang: zig esc: none tag: #Recovering component indices from Archetypes
    ----------------------------------------------------------------------

    /// Get the index of a component with the given archetype
    pub fn index(self: Archetype, tag: Tag) u16 {
        const this = self.difference(void_bits);
        assert(this.with(tag) == this);
        const max: Int = math.maxInt(Int);
        const mask = ~(max << @enumToInt(tag));
        return @popCount(Int, @enumToInt(this) & mask);
    }

    /// Get the possible index of a component with the given archetype
    pub fn indexOf(self: Archetype, tag: Tag) ?u16 {
        if (self.difference(void_bits).with(tag) != self) return null;
        return self.index(tag);
    }

    pub fn count(self: Archetype) u16 {
        return @popCount(Int, @enumToInt(self.difference(void_bits)));
    }

In combination with an index, archetypes are used to locate which bucket an entity belongs to

    lang: zig esc: none tag: #Entity pointer
    ----------------------------------------

    /// Pointer to the physical location of the entity
    pub const Pointer = struct {
        /// Index at which the entity resides within the archetype bucket
        index: u32,
        /// Archetype bucket which the entity resides within
        type: Archetype,
    };

## Database

    lang: zig esc: [[]] tag: #Definition of an entity component store
    -----------------------------------------------------------------

    /// Construct a new database for the given data model
    pub fn Model(comptime T: type) type {
        return struct {
            manager: EntityManager = .{},
            entities: std.AutoHashMapUnmanaged(EntityId, Pointer) = .{},
            archetypes: std.AutoHashMapUnmanaged(Archetype, Storage) = .{},

            const Self = @This();

            [[Archetype representation]]
            [[Entity pointer]]
            [[Adding new entities]]
            [[Updating/adding components to entities]]
            [[Removing components from entities]]
            [[Deleting entities]]
            [[Running systems]]

            pub fn deinit(self: *Self, gpa: Allocator) void {
                self.manager.deinit(gpa);
                self.entities.deinit(gpa);

                var it = self.archetypes.iterator();
                while (it.next()) |bucket| bucket.value_ptr.deinit(gpa);

                self.archetypes.deinit(gpa);
            }
        };
    }

## Component storage

![Archetype storage overview](uml/img/aecs-component-storage.png)

\hidden{

    lang: uml esc: none file: uml/aecs-component-storage.uml
    --------------------------------------------------------

    @startuml img/aecs-component-storage.png
    ditaa

    +--------+ key to  +-------------------+   index to
    | Entity +-------->| archetype | index +-------------+
    +--------+         +-+-----------------+             |
                         |                               |
                         |                               v packed data (SoA)
        reference to     |                    +-------------------------+
       +-----------------+                    | x0 | x1 | x2 | ... | xn |
       |               component      +-------+-------------------------+
       |     contains  +----------+   |       | y0 | y1 | y2 | ... | yn |
       |    +--------->| Velocity +---+       +-------------------------+
       |    |          +----------+                        packed data (SoA)
       v    |                                 +-------------------------+
    +-------+-+ contains    +----------+      | x0 | x1 | x2 | ... | xn |
    | Storage +------------>| Position +------+-------------------------+
    +-------+-+             +----------+      | y0 | y1 | y2 | ... | yn |
            |                                 +-------------------------+
            | contains +--------------+                    packed data (SoA)
            +--------->| Acceleration +--+    +-------------------------+
                       +--------------+  |    | x0 | x1 | x2 | ... | xn |
                                         +----+-------------------------+
                                              | y0 | y1 | y2 | ... | yn |
                                              +-------------------------+

    @enduml

}

    lang: zig esc: none tag: #The archetype storage container
    ---------------------------------------------------------

    pub const Storage = struct {
        len: u32 = 0,
        entities: std.ArrayListUnmanaged(EntityId) = .{},
        components: []Erased = &.{},

        /// Erased component pointer used when the type cannot be calculated at compile-time.
        pub const Erased = struct {
            base: *Interface,
            vtable: *const VTable,
            hash: u64,

            pub const Interface = opaque{};

            pub const VTable = struct {
                resize: fn(self: *Interface, gpa: Allocator, new_size: usize) Allocator.Error!void,
                shrink: fn(self: *Interface, new_size: usize) void,
                remove: fn(self: *Interface, index: u32) void,
                deinit: fn(self: *Interface, gpa: Allocator) void,
            };

            pub fn cast(self: Erased, comptime T: type) *Component(T) {
                const C = Component(T);
                assert(self.hash == C.hash);
                return @ptrCast(*C, @alignCast(@alignOf(C), self.base));
            }
        };

        pub fn reserve(self: *Storage, gpa: Allocator, key: EntityId) Allocator.Error!void {
            var index: u32 = 0;

            try self.entities.append(gpa, key);
            errdefer _ = self.entities.pop();

            errdefer for (self.components) |erased| erased.vtable.shrink(erased.base, self.len);
            for (self.components) |erased, reached| {
                try erased.vtable.resize(erased.base, gpa, self.len + 1);
                index = @intCast(u32, reached);
            }

            self.len += 1;
        }

        pub fn remove(self: *Storage, index: u32) ?EntityId {
            const last = index + 1 == self.len;

            for (self.components) |erased| {
                _ = erased.vtable.remove(erased.base, index);
            }

            _ = self.entities.swapRemove(index);
            self.len -= 1;

            return if (last) null else self.entities.items[index];
        }

        pub fn deinit(self: *Storage, gpa: Allocator) void {
            self.entities.deinit(gpa);

            for (self.components) |erased| {
                erased.vtable.deinit(erased.base, gpa);
            }

            gpa.free(self.components);
        }
    };

    pub fn Component(comptime T: type) type {
        if (@sizeOf(T) == 0) {
            @compileError("tried to construct a container for a 0-bit type " ++ @typeName(T));
        }
        return struct {
            data: std.MultiArrayList(T) = .{},

            pub const hash = std.hash.Wyhash.hash(0xdeadbeefcafebabe, @typeName(T));

            const vtable: Storage.Erased.VTable = .{
                .resize = resize,
                .shrink = shrink,
                .remove = remove,
                .deinit = deinit,
            };

            const Self = @This();

            pub fn interface(self: *Self) Storage.Erased {
                return .{
                    .base = @ptrCast(*Storage.Erased.Interface, self),
                    .vtable = &vtable,
                    .hash = hash,
                };
            }

            pub fn create(gpa: Allocator) Allocator.Error!*Self {
                const self = try gpa.create(Self);
                self.data = .{};
                return self;
            }

            fn resize(this: *Storage.Erased.Interface, gpa: Allocator, new_size: usize) Allocator.Error!void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                try self.data.ensureTotalCapacity(gpa, new_size);
                self.data.len = new_size;
            }

            fn shrink(this: *Storage.Erased.Interface, new_size: usize) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                self.data.shrinkRetainingCapacity(new_size);
            }

            fn remove(this: *Storage.Erased.Interface, index: u32) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                self.data.swapRemove(index);
            }

            fn deinit(this: *Storage.Erased.Interface, gpa: Allocator) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                self.data.deinit(gpa);
                gpa.destroy(self);
            }
        };
    }

### Inserting new entities

    lang: zig esc: none tag: #Adding new entities
    ---------------------------------------------

    pub fn insert(
        self: *Self,
        gpa: Allocator,
        comptime V: type,
        values: V,
    ) Allocator.Error!EntityId {
        const id = try self.manager.new(gpa);
        errdefer self.manager.delete(id);

        try self.entities.putNoClobber(gpa, id, .{
            .index = math.maxInt(u32),
            .type = .empty,
        });

        try self.update(gpa, id, V, values);

        return id;
    }

### Updating and adding entities

    lang: zig esc: none tag: #Updating/adding components to entities
    ----------------------------------------------------------------

    pub fn update(
        self: *Self,
        gpa: Allocator,
        key: EntityId,
        comptime V: type,
        values: V,
    ) Allocator.Error!void {
        const info = @typeInfo(V).Struct;
        const entity = self.entities.getPtr(key).?; // update

        comptime var computed_archetype: Archetype = .empty;
        comptime for (info.fields) |field| {
            const tag = @field(Archetype.Tag, field.name);
            computed_archetype = computed_archetype.with(tag);

            const Data = meta.fieldInfo(T, tag).field_type;
            if (field.field_type != Data) {
                const message = std.fmt.comptimePrint(
                    \\the given field {s}: {s} does not match the expected type {s}"
                , .{
                    field.name,
                    @typeName(field.field_type),
                    @typeName(Data),
                });

                @compileError(message);
            }
        };

        const archetype = entity.type.merge(computed_archetype);

        const bucket = self.archetypes.getPtr(archetype) orelse
            try self.createArchetype(gpa, archetype);

        if (entity.type != archetype) {
            const new_index = bucket.len;
            try bucket.reserve(gpa, key);
            errdefer bucket.shrink(key);

            if (entity.type != .empty) {
                const old_bucket = self.archetypes.getPtr(entity.type) orelse {
                    @panic("old entity archetype doesn't exist!");
                };

                self.migrateEntity(
                    bucket,
                    archetype,
                    entity.*,
                    old_bucket,
                );
            }

            entity.type = archetype;
            entity.index = new_index;

            inline for (info.fields) |field| if (field.field_type != void) {
                const tag = @field(Archetype.Tag, field.name);
                const Data = meta.fieldInfo(T, tag).field_type;
                const erased = bucket.components[archetype.index(tag)];
                const component = erased.cast(Data);
                const value = @field(values, field.name);

                component.data.set(new_index, value);
            };
        } else {
            inline for (info.fields) |field| if (field.field_type != void) {
                const tag = @field(Archetype.Tag, field.name);
                const Data = meta.fieldInfo(T, tag).field_type;
                const erased = bucket.components[archetype.index(tag)];
                const component = erased.cast(Data);
                const value = @field(values, field.name);

                component.data.set(entity.index, value);
            };
        }
    }

## Migrating entities between archetypes

![Moving an entity from one bucket to another](uml/img/aecs-migrating-entitites.png)

\hidden{

    lang: uml esc: none file: uml/aecs-migrating-entitites.uml
    ----------------------------------------------------------

    @startuml img/aecs-migrating-entitites.png
    ditaa

           old archetype                                 replaces
    +---------------------------+                        +-----+
    | 0 | 0 | 0 | 1 | 1 | 0 | 1 |                        |     |
    +-------------+---+-------+-+                        v     |
                  |   |       |      +---------------+------+--+-+
                  |   |       +----->| p0 | p1 | ... | pn-1 | pn |
                  |   |              +---------------+------+----+
                  |   +------------->| v0 | v1 | ... | vn-1 | pn |
                  |                  +---------------+------+----+
                  +----------------->| a0 | a1 | ... | an-1 | an |
                                     +---------------+--+---+----+
           new archetype                                |
    +---------------------------+                       +----+ moves to
    | 0 | 1 | 0 | 1 | 1 | 0 | 1 |                            |
    +-----+-------+---+-------+-+                            v
          |       |   |       |      +--------------------+------+
          |       |   |       +----->| p0 | p1 | ... | pn | pn+1 |
          |       |   |              +--------------------+------+
          |       |   +------------->| v0 | v1 | ... | vn | vn+1 |
          |       |                  +--------------------+------+
          |       +----------------->| a0 | a1 | ... | an | an+1 |
          |                          +--------------------+------+
          +------------------------->| m0 | m1 | ... | mn | mn+1 |
                                     +--------------------+------+

    @enduml

}

    lang: zig esc: none tag: #Updating/adding components to entities
    ----------------------------------------------------------------

    fn migrateEntity(
        self: *Self,
        bucket: *Storage,
        archetype: Archetype,
        entity: Pointer,
        old_bucket: *Storage,
    ) void {
        if (archetype != .empty) {
            inline for (meta.fields(T)) |field, i| if (field.field_type != void) {
                const tag = @intToEnum(Archetype.Tag, i);
                if (archetype.has(tag) and entity.type.has(tag)) {
                    const old_component = old_bucket.components[entity.type.index(tag)];
                    const value = old_component.cast(field.field_type).data.get(entity.index);
                    const com = bucket.components[archetype.index(tag)];
                    const component = com.cast(field.field_type);
                    component.data.set(component.data.len - 1, value);
                }
            };
        }

        if (old_bucket.remove(entity.index)) |moved_key| {
            const moved = self.entities.getPtr(moved_key).?; // 404
            moved.index = entity.index;
        }
    }

    fn createArchetype(self: *Self, gpa: Allocator, archetype: Archetype) Allocator.Error!*Storage {
        const entry = try self.archetypes.getOrPut(gpa, archetype);
        errdefer _ = self.archetypes.remove(archetype);

        assert(!entry.found_existing);

        const bucket = entry.value_ptr;

        bucket.* = .{};

        bucket.components = try gpa.alloc(Storage.Erased, archetype.count());
        errdefer gpa.free(bucket.components);

        var position: u16 = 0;
        inline for (meta.fields(T)) |field, index| if (field.field_type != void) {
            const tag = @intToEnum(Archetype.Tag, index);
            if (archetype.has(tag)) {
                const com = try Component(field.field_type).create(gpa);
                com.* = .{};
                bucket.components[position] = com.interface();
                position += 1;
            }
        };

        return bucket;
    }

### Removing entities

![Removing a component from an entity](uml/img/aecs-removing-components.png)

\hidden{

    lang: uml esc: none file: uml/aecs-removing-components.uml
    ----------------------------------------------------------

    @startuml img/aecs-removing-components.png
    ditaa

           old archetype                                replaces
    +---------------------------+                       +------+
    | 0 | 1 | 0 | 1 | 1 | 0 | 1 |                       |      |
    +-----+-------+---+-------+-+                       v      |
          |       |   |       |      +---------------+------+--+-+
          |       |   |       +----->| p0 | p1 | ... | pn-1 | pn |
          |       |   |              +---------------+------+----+
          |       |   +------------->| v0 | v1 | ... | vn-1 | vn |
          |       |                  +---------------+------+----+
          |       +----------------->| a0 | a1 | ... | an-1 | an |
          |                          +---------------+------+----+
          +------------------------->| m0 | m1 | ... | mn-1 | mn |
                                     +---------------+------+----+
                                                        |
           new archetype                                |
    +---------------------------+                       +-----+ moves to
    | 0 | 0 | 0 | 1 | 1 | 0 | 1 |                             |
    +-------------+---+-------+-+                             v
                  |   |       |      +---------------+----+------+
                  |   |       +----->| p0 | p1 | ... | pn | pn+1 |
                  |   |              +---------------+----+------+
                  |   +------------->| v0 | v1 | ... | vn | pn+1 |
                  |                  +---------------+----+------+
                  +----------------->| a0 | a1 | ... | an | an+1 |
                                     +---------------+----+------+

    @enduml

}

    lang: zig esc: none tag: #Removing components from entities
    -----------------------------------------------------------

    pub fn remove(
        self: *Self,
        gpa: Allocator,
        key: EntityId,
        tags: Archetype,
    ) !void {
        const entity = self.entities.getPtr(key).?; // remove
        const archetype = entity.type.difference(tags);

        if (archetype != entity.type) {
            const old_bucket = self.archetypes.getPtr(entity.type).?; // remove
            const bucket = self.archetypes.getPtr(archetype) orelse
                try self.createArchetype(gpa, archetype);

            const new_index = bucket.len;
            try bucket.reserve(gpa, key);
            errdefer bucket.shrink(key);

            if (entity.type != .empty) {
                self.migrateEntity(
                    bucket,
                    archetype,
                    entity.*,
                    old_bucket,
                );
            }

            entity.index = new_index;
            entity.type = archetype;
        }
    }

### Deleting entities

![](uml/img/aecs-removing-entitites.png)

\hidden{

    lang: uml esc: none file: uml/aecs-removing-entitites.uml
    ---------------------------------------------------------

    @startuml img/aecs-removing-entitites.png
    ditaa

           old archetype                                 replaces
    +---------------------------+                        +-----+
    | 0 | 0 | 0 | 1 | 1 | 0 | 1 |                        |     |
    +-------------+---+-------+-+                        v     |
                  |   |       |      +---------------+------+--+-+
                  |   |       +----->| p0 | p1 | ... | pn-1 | pn |
                  |   |              +---------------+------+----+
                  |   +------------->| v0 | v1 | ... | vn-1 | pn |
                  |                  +---------------+------+----+
                  +----------------->| g0 | g1 | ... | gn-1 | vn |
                                     +---------------+--+---+----+

    @enduml

}

    lang: zig esc: none tag: #Deleting entities
    -------------------------------------------

    pub fn delete(self: *Self, key: EntityId) void {
        self.manager.delete(key);

        const entry = self.entities.fetchRemove(key).?; // delete
        const bucket = self.archetypes.getPtr(entry.value.type).?; // delete

        if (bucket.remove(entry.value.index)) |moved_key| {
            const moved = self.entities.getPtr(moved_key).?; // 404
            moved.index = entry.value.index;
        }
    }

## Running systems

Evaluating systems involves traversing all buckets containing

    lang: zig esc: none tag: #Running systems
    -----------------------------------------

    pub const BeginContext = struct {
        gpa: Allocator,
        arena: Allocator,
        model: *Self,
    };

    pub const UpdateContext = struct {
        gpa: Allocator,
        arena: Allocator,
        model: *Self,
        entities: []const EntityId,
        type: Archetype,
    };

    pub const EndContext = struct {
        gpa: Allocator,
        arena: Allocator,
        model: *Self,
    };

    pub fn step(self: *Self, gpa: Allocator, systems: anytype) !void {
        const info = @typeInfo(meta.Child(@TypeOf(systems))).Struct;

        var ret: anyerror!void = {};

        var frame_allocator = std.heap.ArenaAllocator.init(gpa);
        defer frame_allocator.deinit();

        const arena = frame_allocator.allocator();

        inline for (info.fields) |field| {
            const function = field.field_type.update;
            const system = &@field(systems, field.name);
            const System = meta.Child(@TypeOf(system));
            const Tuple = meta.ArgsTuple(@TypeOf(function));
            const inputs = field.field_type.inputs;
            const shape = Archetype.init(inputs);

            if (@hasDecl(System, "begin")) {
                try system.begin(.{
                    .gpa = gpa,
                    .arena = arena,
                    .model = self,
                });
            }

            var it = self.archetypes.iterator();
            while (it.next()) |entry| {
                const archetype = entry.key_ptr.*;
                const bucket = entry.value_ptr;
                if (archetype.contains(shape)) {
                    if (bucket.len == 0) continue;

                    const components = bucket.components;

                    const context: UpdateContext = .{
                        .gpa = gpa,
                        .arena = arena,
                        .model = self,
                        .entities = bucket.entities.items,
                        .type = archetype,
                    };

                    var tuple: Tuple = undefined;
                    tuple[0] = system;

                    comptime var parameter: comptime_int = 1;
                    inline for (inputs) |tag| {
                        const Type = meta.fieldInfo(T, tag).field_type;
                        if (Type != void) {
                            const i = archetype.index(tag);
                            const component = &components[i].cast(Type).data;
                            tuple[parameter] = component;
                            parameter += 1;
                        }
                    }

                    tuple[parameter] = context;
                    const options = .{};
                    ret = @call(options, function, tuple);
                }

                try ret;
            }

            if (@hasDecl(System, "end")) {
                try system.end(.{
                    .gpa = gpa,
                    .arena = arena,
                    .model = self,
                });
            }
        }
    }

# Tests

    lang: zig esc: none tag: #Testing
    ---------------------------------

    test {
        const Data = struct {
            health: Health,

            pub const Health = struct { hp: u32 };
        };

        const Database = Model(Data);

        const gpa = std.testing.allocator;
        var systems: struct {
            example: struct {
                pub const inputs: []const Database.Archetype.Tag = &.{
                    .health,
                };

                pub fn update(
                    self: *@This(),
                    health: *std.MultiArrayList(Data.Health),
                    context: Database.UpdateContext,
                ) !void {
                    _ = self;
                    _ = context;
                    const hp = health.items(.hp);
                    for (hp) |*value| {
                        value.* = 1;
                    }
                }
            } = .{},
        } = .{};

        var game: Database = .{};
        defer game.deinit(gpa);

        const player = try game.insert(gpa, Data, .{ .health = .{ .hp = 100 } });
        defer game.delete(player);

        try game.remove(gpa, player, Database.Archetype.init(&.{.health}));

        try game.step(gpa, &systems);
    }

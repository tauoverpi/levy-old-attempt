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
...

    lang: zig esc: [[]] file: src/aecs.zig
    --------------------------------------

    const std = @import("std");
    const math = std.math;
    const meta = std.meta;
    const testing = std.testing;
    const assert = std.debug.assert;
    const is_debug = @import("builtin").mode == .Debug;

    const Allocator = std.mem.Allocator;

    [[AECS - An entity manager system with entity reclimation]]
    [[AECS - Definition of an entity component store]]
    [[AECS - The archetype storage container]]
    [[AECS - Component arrays]]
    [[AECS - Testing]]

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

Entities are represented as 32-bit integers identifiers which may be present as a key in component tables. To ensure
uniqueness, an `EntityManager` is used to safely generate new entities on demand and destroy (recycle) old entities no
longer in use within the database.

    lang: zig esc: none tag: #AECS - An entity manager system with entity reclimation
    ---------------------------------------------------------------------------------

    pub const EntityId = enum(u32) { _ };
    pub const Role = enum(u32) { none, _ };
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

This is done by creating a stack with capacity for all currently allocated entities which, when entities are returned,
is used to reissue entity identifiers under the assumption that components and other structures outside the database no
longer refer to the entity once it's been destroyed.

# Archetype

Each entity within the database has a shape given by the combination of it's components called an `Archetype`. The
`Archetype` is represented as a bitset with each bit corresponding to the presence of a component.

    lang: zig esc: [[]] tag: #AECS - Archetype representation
    ---------------------------------------------------------

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

        [[AECS - Deriving archetypes]]
        [[AECS - Archetypes without data]]
        [[AECS - Recovering component indices from Archetypes]]
        [[AECS - Archetype membership and subtypes]]
    };

## Subtypes and membership

    lang: zig esc: none tag: #AECS - Archetype membership and subtypes
    ------------------------------------------------------------------

    pub fn has(self: Archetype, tag: Tag) bool {
        const bit = @as(Int, 1) << @enumToInt(tag);
        return @enumToInt(self) & bit != 0;
    }

    /// Check if the given archetype is a supertype of the other archtype.
    pub fn contains(self: Archetype, other: Archetype) bool {
        return self.intersection(other) == other;
    }

    pub fn iterator(self: Archetype) Archetype.Iterator {
        return .{ .type = self };
    }

    pub const Iterator = struct {
        type: Archetype,

        pub fn next(self: *Archetype.Iterator) ?Tag {
            const int = @enumToInt(self.type);

            if (int == 0) return null;

            const tag = @intToEnum(Tag, @ctz(Int, int));

            self.type = self.type.without(tag);

            return tag;
        }
    };

## Deriving archetypes

    lang: zig esc: none tag: #AECS - Deriving archetypes
    ----------------------------------------------------

    /// Construct a new archetype with the given tag included in the set of active components
    pub fn with(self: Archetype, tag: Tag) Archetype {
        const bit = @as(Int, 1) << @enumToInt(tag);
        return @intToEnum(Archetype, @enumToInt(self) | bit);
    }

    /// Construct a new archetype without the given tag included in the set of active components
    pub fn without(self: Archetype, tag: Tag) Archetype {
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

    lang: zig esc: none tag: #AECS - Archetypes without data
    --------------------------------------------------------

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

    lang: zig esc: none tag: #AECS - Recovering component indices from Archetypes
    -----------------------------------------------------------------------------

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
        const this = self.difference(void_bits);
        if (this.with(tag) != this) return null;
        return self.index(tag);
    }

    pub fn count(self: Archetype) u16 {
        return @popCount(Int, @enumToInt(self.difference(void_bits)));
    }

In combination with an index, archetypes are used to locate which bucket an entity belongs to:

    lang: zig esc: none tag: #AECS - Entity pointer
    -----------------------------------------------

    pub const PointerList = std.ArrayListUnmanaged(Pointer);
    pub const Pointer = struct {
        /// Index at which the entity resides within the archetype bucket
        index: u32,
        /// Archetype bucket which the entity resides within
        type: Archetype,
        /// Component which registered this entity, if none then this will be null
        component: ?Archetype.Tag = null,
        /// Role which the entity plays
        role: Role = .none,
    };

.

    lang: zig esc: none tag: #AECS - Entity pointer
    -----------------------------------------------

    pub const Key = struct {
        id: EntityId,
        component: ?Archetype.Tag = null,
        role: Role = .none,

        pub fn getIndex(self: Key, items: []const Pointer) ?u32 {
            if (self.component) |component| {
                for (items) |item, index| {
                    if (item.component != null and item.component.? == component and item.role == self.role) {
                        return @intCast(u32, index);
                    }
                }
            } else {
                for (items) |item, index| {
                    if (item.component == null and item.role == self.role) {
                        return @intCast(u32, index);
                    }
                }
            }

            return null;
        }
    };

# Database

    lang: zig esc: [[]] tag: #AECS - Definition of an entity component store
    ------------------------------------------------------------------------

    /// Construct a new database for the given data model
    pub fn Model(comptime T: type) type {
        return struct {
            manager: EntityManager = .{},
            entities: EntityMap = .{},
            archetypes: BucketMap = .{},

            const EntityMap = std.AutoHashMapUnmanaged(EntityId, PointerList);
            const BucketMap = std.AutoHashMapUnmanaged(Archetype, Bucket);

            const Self = @This();

            [[AECS - Archetype representation]]
            [[AECS - Entity pointer]]
            [[AECS - Adding new entities]]
            [[AECS - Updating/adding components to entities]]
            [[AECS - Removing components from entities]]
            [[AECS - Deleting entities]]
            [[AECS - Querying archetypes]]

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
        reference to     |                      +-------------------------+
       +-----------------+                      | x0 | x1 | x2 | ... | xn |
       |               component        +-------+-------------------------+
       |     contains  +------------+   |       | y0 | y1 | y2 | ... | yn |
       |    +--------->| Velocity2D +---+       +-------------------------+
       |    |          +------------+                        packed data (SoA)
       v    |                                   +-------------------------+
    +-------+-+ contains    +------------+      | x0 | x1 | x2 | ... | xn |
    | Storage +------------>| Position2D +------+-------------------------+
    +-------+-+             +------------+      | y0 | y1 | y2 | ... | yn |
            |                                   +-------------------------+
            | contains +----------------+                    packed data (SoA)
            +--------->| Acceleration2D +--+    +-------------------------+
                       +----------------+  |    | x0 | x1 | x2 | ... | xn |
                                           +----+-------------------------+
                                                | y0 | y1 | y2 | ... | yn |
                                                +-------------------------+

    @enduml

}

Archetype storage consists of a slice of type-erased pointers to component arrays, a cached length, and a list of
entity identifiers at positions specified within the entity lookup table such that it's possible to tell which entity
each item belongs to while looping over component arrays. The position of the entity and the signature of the component
are used to find the entity pointer belonging to and entity registered within this container such that it's possible to
modify or remove individual entries.

    lang: zig esc: none tag: #AECS - The archetype storage container
    ----------------------------------------------------------------

    pub const Bucket = struct {
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

        pub fn reserve(self: *Bucket, gpa: Allocator, key: EntityId) Allocator.Error!void {
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

        pub fn remove(self: *Bucket, index: u32) ?EntityId {
            const last = index + 1 == self.len;

            for (self.components) |erased| {
                _ = erased.vtable.remove(erased.base, index);
            }

            _ = self.entities.swapRemove(index);
            self.len -= 1;

            return if (last) null else self.entities.items[index];
        }

        pub fn deinit(self: *Bucket, gpa: Allocator) void {
            self.entities.deinit(gpa);

            for (self.components) |erased| {
                erased.vtable.deinit(erased.base, gpa);
            }

            gpa.free(self.components);
        }
    };

Component arrays make use of ArrayList from the standard library.

    lang: zig esc: none tag: #AECS - Component arrays
    -------------------------------------------------

    pub fn Component(comptime T: type) type {
        if (@sizeOf(T) == 0) {
            @compileError("tried to construct a container for a 0-bit type " ++ @typeName(T));
        }
        return struct {
            data: std.ArrayListUnmanaged(T) = .{},

            pub const hash = std.hash.Wyhash.hash(0xdeadbeefcafebabe, @typeName(T));

            const vtable: Bucket.Erased.VTable = .{
                .resize = resize,
                .shrink = shrink,
                .remove = remove,
                .deinit = deinit,
            };

            const Self = @This();

            pub fn interface(self: *Self) Bucket.Erased {
                return .{
                    .base = @ptrCast(*Bucket.Erased.Interface, self),
                    .vtable = &vtable,
                    .hash = hash,
                };
            }

            pub fn create(gpa: Allocator) Allocator.Error!*Self {
                const self = try gpa.create(Self);
                self.data = .{};
                return self;
            }

            fn resize(this: *Bucket.Erased.Interface, gpa: Allocator, new_size: usize) Allocator.Error!void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                try self.data.ensureTotalCapacity(gpa, new_size);
                self.data.items.len = new_size;
            }

            fn shrink(this: *Bucket.Erased.Interface, new_size: usize) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                self.data.shrinkRetainingCapacity(new_size);
            }

            fn remove(this: *Bucket.Erased.Interface, index: u32) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                _ = self.data.swapRemove(index);
            }

            fn deinit(this: *Bucket.Erased.Interface, gpa: Allocator) void {
                const self = @ptrCast(*Self, @alignCast(@alignOf(Self), this));
                self.data.deinit(gpa);
                gpa.destroy(self);
            }
        };
    }

### Inserting new entities

    lang: zig esc: none tag: #AECS - Adding new entities
    ----------------------------------------------------

    pub const ComponentRole = struct {
        component: ?Archetype.Tag = null,
        role: Role = .none,
    };

    pub fn insert(
        self: *Self,
        gpa: Allocator,
        key: ComponentRole,
        comptime V: type,
        values: V,
    ) Allocator.Error!Key {
        const id = try self.manager.new(gpa);
        errdefer self.manager.delete(id);

        var list: PointerList = .{};
        try list.append(gpa, .{
            .index = math.maxInt(u32),
            .type = .empty,
            .component = key.component,
            .role = key.role,
        });
        errdefer list.deinit(gpa);

        try self.entities.putNoClobber(gpa, id, list);
        errdefer _ = self.entities.remove(id);

        try self.update(gpa, .{ .id = id }, V, values);

        return Key{ .id = id, .component = key.component, .role = key.role };
    }

    pub fn new(
        self: *Self,
        gpa: Allocator,
    ) error{OutOfMemory}!EntityId {
        const id = try self.manager.new(gpa);
        errdefer self.manager.delete(id);

        try self.entities.putNoClobber(gpa, id, .{});

        return id;
    }

    pub fn extend(
        self: *Self,
        gpa: Allocator,
        key: Key,
        comptime V: type,
        values: V,
    ) Allocator.Error!void {
        const entity = self.entities.getPtr(key.id).?; // extend

        if (is_debug) assert(key.getIndex(entity.items) == null);

        try entity.append(.{
            .index = math.maxInt(u32),
            .type = .empty,
            .component = key.component,
            .role = key.role,
        });
        errdefer entity.shrinkRetainingCapacity(entity.items.len - 1);

        try self.update(gpa, key, V, values);
    }

### Updating and adding entities

    lang: zig esc: none tag: #AECS - Updating/adding components to entities
    -----------------------------------------------------------------------

    pub fn update(
        self: *Self,
        gpa: Allocator,
        key: Key,
        comptime V: type,
        values: V,
    ) Allocator.Error!void {
        const info = @typeInfo(V).Struct;
        const list = self.entities.getPtr(key.id).?; // update
        const index = key.getIndex(list.items).?; // update
        const entity = &list.items[index];

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
            try bucket.reserve(gpa, key.id);
            errdefer bucket.shrink(new_index);

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

                component.data.items[new_index] = value;
            };
        } else {
            inline for (info.fields) |field| if (field.field_type != void) {
                const tag = @field(Archetype.Tag, field.name);
                const Data = meta.fieldInfo(T, tag).field_type;
                const erased = bucket.components[archetype.index(tag)];
                const component = erased.cast(Data);
                const value = @field(values, field.name);

                component.data.items[entity.index] = value;
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

    lang: zig esc: none tag: #AECS - Updating/adding components to entities
    -----------------------------------------------------------------------

    fn migrateEntity(
        self: *Self,
        bucket: *Bucket,
        archetype: Archetype,
        entity: Pointer,
        old_bucket: *Bucket,
    ) void {
        if (archetype != .empty) {
            inline for (meta.fields(T)) |field, i| if (field.field_type != void) {
                const tag = @intToEnum(Archetype.Tag, i);
                if (archetype.has(tag) and entity.type.has(tag)) {
                    const old_component = old_bucket.components[entity.type.index(tag)];
                    const value = old_component.cast(field.field_type).data.items[entity.index];
                    const erased = bucket.components[archetype.index(tag)];
                    const component = erased.cast(field.field_type);
                    component.data.items[component.data.items.len - 1] = value;
                }
            };
        }

        if (old_bucket.remove(entity.index)) |moved_key| {
            const old_index = old_bucket.len;
            const moved = self.entities.getPtr(moved_key).?; // 404

            for (moved.items) |*item| {
                if (item.index == old_index and item.type == entity.type) {
                    item.index = entity.index;
                    break;
                }
            }
        }
    }

    fn createArchetype(self: *Self, gpa: Allocator, archetype: Archetype) Allocator.Error!*Bucket{
        const entry = try self.archetypes.getOrPut(gpa, archetype);
        errdefer _ = self.archetypes.remove(archetype);

        assert(!entry.found_existing);

        const bucket = entry.value_ptr;

        bucket.* = .{};

        bucket.components = try gpa.alloc(Bucket.Erased, archetype.count());
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

           old archetype                                 replaces
    +---------------------------+                        +-----+
    | 0 | 1 | 0 | 1 | 1 | 0 | 1 |                        |     |
    +-----+-------+---+-------+-+                        v     |
          |       |   |       |      +---------------+------+--+-+
          |       |   |       +----->| p0 | p1 | ... | pn-1 | pn |
          |       |   |              +---------------+------+----+
          |       |   +------------->| v0 | v1 | ... | vn-1 | vn |
          |       |                  +---------------+------+----+
          |       +----------------->| a0 | a1 | ... | an-1 | an |
          |                          +---------------+------+----+
          +------------------------->| m0 | m1 | ... | mn-1 | mn |
                                     +---------------+--+---+----+
                                                        |
           new archetype                                |
    +---------------------------+                       +-----+ moves to
    | 0 | 0 | 0 | 1 | 1 | 0 | 1 |                             |
    +-------------+---+-------+-+                             v
                  |   |       |      +--------------------+------+
                  |   |       +----->| p0 | p1 | ... | pn | pn+1 |
                  |   |              +--------------------+------+
                  |   +------------->| v0 | v1 | ... | vn | vn+1 |
                  |                  +--------------------+------+
                  +----------------->| a0 | a1 | ... | an | an+1 |
                                     +--------------------+------+

    @enduml

}

    lang: zig esc: none tag: #AECS - Removing components from entities
    ------------------------------------------------------------------

    pub fn remove(
        self: *Self,
        gpa: Allocator,
        key: Key,
        tags: Archetype,
    ) !void {
        const list = self.entities.getPtr(key.id).?; // remove
        const index = key.getIndex(list.items).?; // remove
        const entity = &list.items[index];
        const archetype = entity.type.difference(tags);

        if (archetype != entity.type) {
            const old_bucket = self.archetypes.getPtr(entity.type).?; // remove
            const bucket = self.archetypes.getPtr(archetype) orelse
                try self.createArchetype(gpa, archetype);

            const new_index = bucket.len;
            try bucket.reserve(gpa, key.id);
            errdefer bucket.shrink(new_index);

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

    lang: zig esc: none tag: #AECS - Deleting entities
    --------------------------------------------------

    pub fn deleteKey(self: *Self, key: Key) void {
        const list = self.entities.getPtr(key.id).?; // delete key
        const index = key.getIndex(list.items).?; // delete key
        const entity = list.swapRemove(index);
        const bucket = self.archetypes.getPtr(entity.type);

        if (bucket.remove(entity.index)) |moved_key| {
            const old_index = bucket.len;
            const moved = self.entities.getPtr(moved_key).?; // 404

            for (moved.items) |*item| {
                if (item.index == old_index and item.type == entity.type) {
                    item.index = entity.index;
                    break;
                }
            }
        }
    }

    pub fn delete(self: *Self, gpa: Allocator, key: EntityId) void {
        self.manager.delete(key);

        var entry = self.entities.fetchRemove(key).?; // delete
        defer entry.value.deinit(gpa);

        for (entry.value.items) |entity| {
            const bucket = self.archetypes.getPtr(entity.type).?; // delete

            if (bucket.remove(entity.index)) |moved_key| {
                const old_index = bucket.len;
                const moved = self.entities.getPtr(moved_key).?; // 404

                for (moved.items) |*item| {
                    if (item.index == old_index and item.type == entity.type) {
                        item.index = entity.index;
                        break;
                    }
                }
            }
        }
    }

## Querying archetypes

    lang: zig esc: [[]] tag: #AECS - Querying archetypes
    ----------------------------------------------------

    pub fn query(self: *Self, shape: Archetype) Iterator {
        return .{ .type = shape, .it = self.archetypes.iterator() };
    }

    pub const Iterator = struct {
        type: Archetype,
        it: BucketMap.Iterator,

        pub const Entry = struct {
            bucket: *Bucket,
            type: Archetype,

            [[AECS - Getting component arrays from query results]]
        };

        pub fn next(self: *Iterator) ?Entry {
            var bucket = self.it.next() orelse return null;

            while (!bucket.key_ptr.contains(self.type)) {
                bucket = self.it.next() orelse return null;
            }

            return Entry{
                .bucket = bucket.value_ptr,
                .type = bucket.key_ptr.*,
            };
        }
    };

### Getting component arrays from query results

    lang: zig esc: none tag: #AECS - Getting component arrays from query results
    ----------------------------------------------------------------------------

    pub fn Arrays(comptime tags: Archetype) type {
        var fields: [tags.count()]std.builtin.Type.StructField = undefined;

        var it = tags.difference(Archetype.void_bits).iterator();
        var index: u32 = 0;
        while (it.next()) |tag| : (index += 1) {
            const Slice = []meta.fieldInfo(T, tag).field_type;
            fields[index] = .{
                .name = @tagName(tag),
                .field_type = Slice,
                .alignment = @alignOf(Slice),
                .default_value = null,
                .is_comptime = false,
            };
        }

        return @Type(.{ .Struct = .{
            .layout = .Auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = false,
        } });
    }

where

    lang: zig esc: none tag: #AECS - Getting component arrays from query results
    ----------------------------------------------------------------------------

    pub fn arrays(self: Entry, comptime tags: Archetype) Arrays(tags) {
        var r: Arrays(tags) = undefined;
        const ty = comptime tags.difference(Archetype.void_bits);
        if (!self.type.contains(ty)) {
            if (is_debug) {
                var it = ty.iterator();
                while (it.next()) |tag| {
                    if (!self.type.has(tag)) {
                        std.debug.print("bucket missing requested tag {}\n", .{tag});
                    }
                }

                @panic("invalid request for tags not present within the bucket");
            }
        }

        inline for (meta.fields(Archetype.Tag)) |field| {
            const tag = @field(Archetype.Tag, field.name);
            if (comptime ty.has(tag)) {
                const index = self.type.index(tag);
                const Data = meta.fieldInfo(T, tag).field_type;
                @field(r, field.name) = self.bucket.components[index].cast(Data).data.items;
            }
        }

        return r;
    }

    pub fn get(
        self: Entry,
        comptime tag: Archetype.Tag,
    ) ?[](meta.fieldInfo(T, tag).field_type) {
        const Data = meta.fieldInfo(T, tag).field_type;
        if (self.type.indexOf(tag)) |index| {
            return self.bucket.components[index].cast(Data).data.items;
        } else return null;
    }

# Examples

    lang: zig esc: none tag: #AECS - Testing
    ----------------------------------------

    test {
        const Data = struct {
            health: Health,

            pub const Health = struct { hp: u32 };
        };

        const Database = Model(Data);

        const gpa = std.testing.allocator;
        const System = struct {
            const inputs = Database.Archetype.init(&.{.health});

            pub fn update(self: *@This(), db: *Database) void {
                _ = self;
                var it = db.query(inputs);

                while (it.next()) |entry| {
                    const array = entry.arrays(inputs);
                    for (array.health) |*value| value.hp = 1;
                }
            }
        };

        var system: System = .{};

        var game: Database = .{};
        defer game.deinit(gpa);

        const player = try game.insert(gpa, .{}, Data, .{ .health = .{ .hp = 100 } });
        defer game.delete(gpa, player.id);

        system.update(&game);
        try game.remove(gpa, player, Database.Archetype.init(&.{.health}));
        system.update(&game);
    }

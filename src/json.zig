const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;

const json = std.json;
const ObjectMap = json.ObjectMap;
const Value = json.Value;

const assert = std.debug.assert;
const panic = std.debug.panic;

pub const Schema = union(enum) {
    int: Integer,
    number: Float,
    boolean: Boolean,
    string: String,
    @"enum": Enum,
    object: Object,
    array: Array,
    @"$ref": Ref,
    compound: Compound,

    pub fn toJson(self: *const Schema, ctx: *Schema.Context) Allocator.Error!json.Value {
        return switch (self.*) {
            .int => |i| i.toJson(ctx),
            .number => |n| n.toJson(ctx),
            .boolean => |b| b.toJson(ctx),
            .string => |s| s.toJson(ctx),
            .@"enum" => |e| e.toJson(ctx),
            .object => |o| o.toJson(ctx),
            .array => |a| a.toJson(ctx),
            .@"$ref" => |r| r.toJson(ctx),
            .compound => |c| c.toJson(ctx),
        };
    }

    pub fn common(self: *Schema) *Common {
        return switch (self.*) {
            .int => &self.int.common,
            .number => &self.number.common,
            .boolean => &self.boolean.common,
            .string => &self.string.common,
            .@"enum" => &self.@"enum".common,
            .object => &self.object.common,
            .array => &self.array.common,
            .@"$ref" => &self.@"$ref".common,
            .compound => &self.compound.common,
        };
    }

    const Draft = enum {
        v7,
        fn uri(self: Draft) [:0]const u8 {
            return switch (self) {
                .v7 => "https://json-schema.org/draft-07/schema#",
            };
        }
    };

    pub const Context = struct {
        draft: Draft = .v7,
        definitions: std.StringHashMapUnmanaged(Schema) = .{},
        typemap: std.StringHashMapUnmanaged([]const u8) = .{},
        allocator: Allocator,

        pub fn init(allocator: Allocator) Schema.Context {
            return Schema.Context{
                .allocator = allocator,
            };
        }

        pub fn object(self: *const Context, num_properties: u32) !Schema.Object {
            var obj: Schema.Object = .{};
            try obj.properties.ensureTotalCapacity(self.allocator, num_properties);
            return obj;
        }
        pub fn array(self: *const Context, item: Schema) !Schema {
            const item_schema = try self.allocator.create(Schema);
            item_schema.* = item;
            return Array.schema(item_schema);
        }
        pub fn tuple(self: *const Context, prefix_items: anytype) !Schema {
            var arr = Array{};
            var items = try self.allocator.alloc(Schema, prefix_items.len);
            for (0..prefix_items.len) |i| {
                items[i] = prefix_items[i];
            }
            items.len = prefix_items.len;

            arr.prefixItems = items;
            return .{ .array = arr };
        }
        pub fn oneOf(self: *const Context, schemas: []const Schema) !Schema {
            return Compound.oneOf(try self.allocator.dupe(Schema, schemas));
        }
        pub fn allOf(self: *const Context, schemas: []const Schema) !Schema {
            return Compound.allOf(try self.allocator.dupe(Schema, schemas));
        }
        pub fn anyOf(self: *const Context, schemas: []const Schema) !Schema {
            return Compound.anyOf(try self.allocator.dupe(Schema, schemas));
        }
        pub fn @"enum"(self: *const Context, variants: []const []const u8) !Schema {
            return Enum.schema(try self.allocator.dupe([]const u8, variants));
        }

        pub fn toJson(self: *Schema.Context, root: Schema) Allocator.Error!json.Value {
            var schema = try root.toJson(self);
            if (schema == .object) {
                var obj = &schema.object;
                try obj.put("$schema", .{ .string = self.draft.uri() });
                if (self.definitions.count() > 0) {
                    var definitions = self.jsonObject();
                    var it = self.definitions.iterator();
                    while (it.next()) |entry| {
                        const key = entry.key_ptr.*;
                        const def_schema = entry.value_ptr.*;
                        try definitions.put(key, try def_schema.toJson(self));
                    }
                    try obj.put("definitions", .{ .object = definitions });
                }
            }
            return schema;
        }

        pub fn toValue(ctx: *Schema.Context, value: anytype) Allocator.Error!?Value {
            return toValueT(@TypeOf(value), value, ctx);
        }

        pub fn addSchema(ctx: *Schema.Context, T: type) Allocator.Error!*Schema {
            // force declaration insertion here instead of genSchemaImpl to make
            // sure schema gets inserted into declaration map. genSchemaImpl only
            // adds container types.
            const schema = try ctx.genSchemaImpl(T, false, false);
            const ent = try ctx.addDefinition(@typeName(T), schema);
            // ent.schema is ptr to copied `schema` in declaration map
            assert(std.meta.activeTag(schema) == std.meta.activeTag(ent.schema.*));

            return ent.schema;
        }

        pub fn genSchema(ctx: *Schema.Context, T: type) Allocator.Error!Schema {
            return genSchemaImpl(ctx, T, false, false);
        }

        pub fn genSchemaInner(ctx: *Schema.Context, T: type) Allocator.Error!Schema {
            return genSchemaImpl(ctx, T, false, true);
        }

        fn genSchemaImpl(
            ctx: *Schema.Context,
            T: type,
            add_def: bool,
            comptime force_codegen: bool,
        ) Allocator.Error!Schema {
            const typename = @typeName(T);
            if (try ctx.getRef(T)) |ref_| return ref_;

            const info = @typeInfo(T);
            return switch (info) {
                .comptime_int => Schema{ .int = .{} },
                .int => |i| Integer.schema(
                    if (i.signedness == .unsigned) 0 else null,
                    std.math.maxInt(T),
                ),
                .float, .comptime_float => Schema{ .number = .{} },
                .bool => Schema{ .boolean = .{} },
                .@"struct" => |s| @"struct": {
                    const schema = if (@hasDecl(T, "jsonSchema") and !force_codegen) try T.jsonSchema(ctx) else blk: {
                        if (s.is_tuple) @compileError("todo: tuples");

                        var properties: Schema.Object.Properties = .{};
                        try properties.ensureUnusedCapacity(ctx.allocator, s.fields.len);
                        var required = try std.ArrayListUnmanaged([]const u8).initCapacity(ctx.allocator, s.fields.len);

                        inline for (s.fields) |field| {
                            const fieldInfo = @typeInfo(field.type);
                            const FieldType = if (fieldInfo != .optional) brk: {
                                if (field.default_value_ptr == null)
                                    required.appendAssumeCapacity(field.name);
                                break :brk field.type;
                            } else fieldInfo.optional.child;

                            if (FieldType != anyopaque and FieldType != *anyopaque) {
                                var field_schema = try ctx.genSchemaImpl(FieldType, true, false);
                                if (field.defaultValue()) |default| {
                                    field_schema.common().default = try ctx.toValue(default);
                                }
                                try properties.put(ctx.allocator, field.name, field_schema);
                            }
                        }

                        break :blk Schema{ .object = .{
                            .common = .{},
                            .properties = properties,
                            .required = required.items,
                        } };
                    };

                    break :@"struct" ctx.maybeAddDefinition(add_def, typename, schema);
                },
                .@"enum" => |e| @"enum": {
                    const schema = if (@hasDecl(T, "jsonSchema") and !force_codegen) try T.jsonSchema(ctx) else blk: {
                        const fields = try ctx.allocator.alloc([]const u8, e.fields.len);
                        inline for (0..e.fields.len) |i| {
                            fields[i] = try ctx.allocator.dupe(u8, e.fields[i].name);
                        }
                        break :blk Schema{
                            .@"enum" = .{ .common = .{}, .@"enum" = fields },
                        };
                    };
                    break :@"enum" ctx.maybeAddDefinition(add_def, typename, schema);
                },
                .array => |arr| if (arr.child == u8)
                    Schema{ .string = .{} }
                else
                    ctx.array(try ctx.genSchemaImpl(arr.child, true, false)),
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8)
                        Schema{ .string = .{} }
                    else
                        ctx.array(try ctx.genSchemaImpl(ptr.child, true, false)),
                    else => @compileError("todo: " ++ @typeName(T)),
                },
                .optional => |o| ctx.genSchema(o.child),
                .undefined, .null, .void, .noreturn => |t| {
                    @compileError("Cannot generate a json schema from type " ++ @tagName(t));
                },
                else => @compileError("todo: " ++ @typeName(T)),
            };
        }

        fn maybeAddDefinition(self: *Context, add_def: bool, comptime typename: []const u8, schema: Schema) !Schema {
            return if (add_def and schema != .@"$ref")
                (try self.addDefinition(typename, schema)).ref
            else
                schema;
        }

        const DefinitionSchema = struct {
            ref: Schema,
            schema: *Schema,
        };
        fn addDefinition(self: *Context, name: []const u8, schema_: Schema) Allocator.Error!DefinitionSchema {
            var schema = schema_;
            const key = if (schema.common().@"$id") |id| brk: {
                try self.typemap.put(self.allocator, name, id);
                break :brk id;
            } else name;
            const entry = try self.definitions.getOrPut(self.allocator, key);
            if (entry.found_existing) panic("duplicate schema definition under key '{s}'", .{key});
            entry.value_ptr.* = schema;
            return .{
                .ref = try Ref.definition(self.allocator, key),
                .schema = entry.value_ptr,
            };
        }

        pub fn ref(self: *Context, T: type) !Schema {
            const typename = @typeName(T);
            if (self.typemap.get(typename)) |id| {
                return Ref.definition(self.allocator, id);
            }
            if (self.definitions.getPtr(typename)) |_| {
                return Ref.definition(self.allocator, typename);
            }
            var def = try self.genSchemaImpl(T, false, false);
            if (def == .@"$ref") {
                var uri = def.@"$ref".uri;
                if (mem.startsWith(u8, uri, Ref.definitions)) {
                    uri = uri[Ref.definitions.len..];
                }
                try self.typemap.put(self.allocator, typename, uri);
                return def;
            }
            const key = if (def.common().@"$id") |id| id else typename;
            try self.typemap.put(self.allocator, typename, key);
            try self.definitions.put(self.allocator, key, def);
            return Ref.definition(self.allocator, key);
        }

        fn getRef(self: *Context, T: type) !?Schema {
            const typename = @typeName(T);
            const key: []const u8 = self.typemap.get(typename) orelse if (self.definitions.getPtr(typename)) |_| typename else return null;
            return try Ref.definition(self.allocator, key);
        }

        fn jsonObject(self: *Context) ObjectMap {
            return ObjectMap.init(self.allocator);
        }
        fn objectSized(self: *Context, len: usize) Allocator.Error!ObjectMap {
            var obj = ObjectMap.init(self.allocator);
            try obj.ensureUnusedCapacity(len);
            return obj;
        }
        pub fn jsonArray(self: *Context, len: usize) Allocator.Error!json.Array {
            var arr = json.Array.init(self.allocator);
            try arr.ensureTotalCapacityPrecise(len);
            return arr;
        }
    };

    pub const Root = struct {
        common: Common = .{},
        root: Schema = .{ .object = .{} },
    };

    const Common = struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        @"$id": ?[]const u8 = null,
        default: ?Value = null,
        examples: [][]const u8 = &[_][]const u8{},
        extraValues: std.StringHashMapUnmanaged(Value) = .{},

        pub inline fn withTitle(self: *Common, title: []const u8) *Common {
            self.title = title;
            return self;
        }
        pub inline fn withDescription(self: *Common, description: []const u8) *Common {
            self.description = description;
            return self;
        }

        fn toJson(self: *const Common, value: *ObjectMap) Allocator.Error!void {
            if (self.title) |title| try value.put("title", .{ .string = title });
            if (self.description) |desc| try value.put("description", .{ .string = desc });
            if (self.default) |def| try value.put("default", def);
            if (self.examples.len > 0) {
                const ex = try value.getOrPut("examples");
                assert(!ex.found_existing);
                var arr = json.Array.init(value.allocator);
                try arr.ensureTotalCapacityPrecise(self.examples.len);
                for (self.examples) |example| {
                    arr.appendAssumeCapacity(.{ .string = example });
                }
                ex.value_ptr.* = .{ .array = arr };
            }

            var it = self.extraValues.iterator();
            try value.ensureUnusedCapacity(self.extraValues.count());
            while (it.next()) |entry| {
                try value.put(entry.key_ptr.*, entry.value_ptr.*);
            }
        }
    };

    pub const Integer = Number(i64);
    pub const Float = Number(f32);
    fn Number(Num: type) type {
        // todo: exclusive minimum/maximum
        return struct {
            common: Common = .{},
            min: ?Num = null,
            max: ?Num = null,

            pub fn schema(min: ?Num, max: ?Num) Schema {
                return switch (@typeInfo(Num)) {
                    .int, .comptime_int => Schema{ .int = .{ .min = min, .max = max } },
                    .float, .comptime_float => Schema{ .number = .{ .min = min, .max = max } },
                    else => unreachable,
                };
            }

            fn toJson(self: *const @This(), ctx: *Schema.Context) Allocator.Error!json.Value {
                var value = ctx.jsonObject();
                switch (@typeInfo(Num)) {
                    .int, .comptime_int => {
                        try value.put("type", Value{ .string = "integer" });
                        if (self.min) |min| try value.put("minimum", Value{ .integer = @intCast(min) });
                        if (self.max) |max| try value.put("maximum", Value{ .integer = @intCast(max) });
                    },
                    .float, .comptime_float => {
                        try value.put("type", Value{ .string = "number" });
                        if (self.min) |min| try value.put("minimum", Value{ .float = @floatCast(min) });
                        if (self.max) |max| try value.put("maximum", Value{ .float = @floatCast(max) });
                    },
                    else => unreachable,
                }

                return .{ .object = value };
            }
        };
    }

    pub const Boolean = struct {
        common: Common = .{},

        pub fn schema() Schema {
            return Schema{ .boolean = .{} };
        }

        fn toJson(self: *const Boolean, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("type", Value{ .string = "boolean" });
            try self.common.toJson(&value);

            return .{ .object = value };
        }
    };

    pub const String = struct {
        common: Common = .{},
        minLength: ?u32 = null,
        maxLength: ?u32 = null,
        pattern: ?[]const u8 = null,
        format: ?Format = null,

        /// https://json-schema.org/understanding-json-schema/reference/type#built-in-formats
        const Format = enum {
            @"date-time",
            date,
            time,
            duration,

            email,
            @"idn-email",
            hostname,
            @"idn-hostname",

            ipv4,
            ipv6,

            // resource identifiers
            uuid,
            uri,
            @"uri-reference",
            iri,
            @"iri-reference",
            @"uri-template",

            // json
            @"json-pointer",
            @"relative-json-pointer",

            regex,
        };

        pub fn schema() Schema {
            return Schema{ .string = .{} };
        }

        fn toJson(self: *const String, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("type", .{ .string = "string" });
            try self.common.toJson(&value);
            if (self.minLength) |min| try value.put("minLength", .{ .integer = min });
            if (self.maxLength) |max| try value.put("maxLength", .{ .integer = max });
            if (self.pattern) |pattern| try value.put("pattern", .{ .string = pattern });
            if (self.format) |format| try value.put("format", .{ .string = @tagName(format) });

            return .{ .object = value };
        }
    };

    pub const Enum = struct {
        common: Common = .{},
        @"enum": []const []const u8,

        pub fn schema(variants: []const []const u8) Schema {
            return Schema{ .@"enum" = .{ .@"enum" = variants } };
        }

        fn toJson(self: *const Enum, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("type", .{ .string = "string" });
            try value.put("enum", try ctx.toValue(self.@"enum") orelse unreachable);
            try self.common.toJson(&value);

            return .{ .object = value };
        }
    };

    pub const Array = struct {
        common: Common = .{},
        items: ?*Schema = null,
        prefixItems: ?[]const Schema = null,

        pub fn schema(items: *Schema) Schema {
            return Schema{ .array = .{ .items = items } };
        }

        fn toJson(self: *const Array, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("type", .{ .string = "array" });
            try self.common.toJson(&value);
            if (self.items) |items| {
                try value.put("items", try items.toJson(ctx));
            }
            if (self.prefixItems) |prefix| {
                var arr = try ctx.jsonArray(prefix.len);
                for (prefix) |item| {
                    const item_value = try item.toJson(ctx);
                    arr.appendAssumeCapacity(item_value);
                }
                try value.put("prefixItems", .{ .array = arr });
            }

            return .{ .object = value };
        }
    };

    pub const Object = struct {
        common: Common = .{},
        properties: Properties = .{},
        required: []const []const u8 = &[_][]const u8{},

        const Properties = std.StringHashMapUnmanaged(Schema);

        pub fn schema() Schema {
            return Schema{ .object = .{} };
        }

        fn toJson(self: *const Object, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("type", .{ .string = "object" });
            try self.common.toJson(&value);

            var properties = try ctx.objectSized(self.properties.count());
            var it = self.properties.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                try properties.put(key, try entry.value_ptr.toJson(ctx));
            }
            try value.put("properties", .{ .object = properties });

            if (self.required.len > 0) {
                var arr = try ctx.jsonArray(self.required.len);
                for (self.required) |name| {
                    arr.appendAssumeCapacity(.{ .string = name });
                }
                try value.put("required", .{ .array = arr });
            }

            return .{ .object = value };
        }

        pub fn isRequired(self: *const Object, property: []const u8) bool {
            for (self.required) |required_prop| {
                if (mem.eql(u8, property, required_prop)) {
                    return true;
                }
            }
            return false;
        }
    };

    pub const Ref = struct {
        common: Common = .{},
        uri: []const u8,

        const definitions = "#/definitions/";
        fn definition(allocator: Allocator, relative_uri: []const u8) Allocator.Error!Schema {
            const uri = if (@inComptime())
                definitions ++ relative_uri
            else
                try fmt.allocPrint(allocator, definitions ++ "{s}", .{relative_uri});
            return .{ .@"$ref" = Ref{ .uri = uri } };
        }

        pub fn resolve(self: *const Ref, ctx: *Schema.Context) *Schema {
            if (mem.startsWith(u8, self.uri, definitions)) {
                const key = self.uri[definitions.len..];
                return ctx.definitions.getPtr(key) orelse @panic("could not resolve reference");
            }
            // @panic("todo");
            return undefined;
        }

        fn toJson(self: *const Ref, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try value.put("$ref", .{ .string = self.uri });
            try self.common.toJson(&value);
            return .{ .object = value };
        }
    };

    pub const Compound = struct {
        common: Common = .{},
        kind: Kind,
        const Kind = union(enum) {
            all_of: []const Schema,
            any_of: []const Schema,
            one_of: []const Schema,
        };

        pub fn oneOf(schemas: []const Schema) Schema {
            return Schema{ .compound = .{ .kind = .{ .one_of = schemas } } };
        }
        pub fn allOf(schemas: []const Schema) Schema {
            return Schema{ .compound = .{ .kind = .{ .all_of = schemas } } };
        }
        pub fn anyOf(schemas: []const Schema) Schema {
            return Schema{ .compound = .{ .kind = .{ .any_of = schemas } } };
        }

        fn toJson(self: *const Compound, ctx: *Schema.Context) Allocator.Error!json.Value {
            var value = ctx.jsonObject();
            try self.common.toJson(&value);
            const key: []const u8, const schemalist = switch (self.kind) {
                .all_of => |l| .{ "allOf", l },
                .any_of => |l| .{ "anyOf", l },
                .one_of => |l| .{ "oneOf", l },
            };
            var arr = try ctx.jsonArray(schemalist.len);
            for (schemalist) |schema| {
                const schema_value = try schema.toJson(ctx);
                arr.appendAssumeCapacity(schema_value);
            }
            try value.put(key, .{ .array = arr });
            return .{ .object = value };
        }
    };
};

fn toValueT(T: type, value: T, ctx: *Schema.Context) Allocator.Error!?Value {
    const info = @typeInfo(T);
    return switch (info) {
        .comptime_int, .int => Value{ .integer = value },
        .comptime_float, .float => Value{ .float = value },
        .bool => Value{ .bool = value },
        .null => Value{ .null = .{} },
        .@"struct" => |s| obj: {
            var obj = try ctx.objectSized(s.fields.len);
            inline for (s.fields) |field| {
                const field_value: Value = switch (field.type) {
                    *anyopaque => .{ .bool = true },
                    else => try toValueT(field.type, @field(value, field.name), ctx) orelse return null,
                };
                try obj.put(field.name, field_value);
            }
            break :obj Value{ .object = obj };
        },
        .array => |array| array: {
            var arr = try ctx.jsonArray(array.len);
            for (array) |item| {
                try arr.appendAssumeCapacity(try toValueT(
                    array.child,
                    item,
                    ctx,
                ));
            }
            break :array Value{ .array = arr };
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) Value{ .string = value } else array: {
                var arr = try ctx.jsonArray(value.len);
                for (value) |item| {
                    arr.appendAssumeCapacity(try toValueT(
                        ptr.child,
                        item,
                        ctx,
                    ) orelse return null);
                }
                break :array Value{ .array = arr };
            },
            .one => toValueT(ptr.child, value.*, ctx),
            else => @panic("todo: " ++ @typeName(T)),
        },
        .optional => |o| toValueT(o.child, value, ctx),
        .undefined, .void, .noreturn => |t| {
            @compileError("Cannot generate a json value from type " ++ @tagName(t));
        },
        else => null,
    };
}

test {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const Config = @import("linter/Config.zig");
    var ctx = Schema.Context.init(allocator);
    const root = try ctx.genSchema(Config);

    _ = try ctx.toJson(root);
}

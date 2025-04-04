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
    int: Number(i32),
    number: Number(f32),
    boolean: Boolean,
    string: String,
    @"enum": Enum,
    object: Object,
    array: Array,
    @"$ref": Ref,
    compound: Compound,

    pub fn oneOf(schemas: []const Schema) Schema {
        return Schema{ .compound = .{
            .kind = .{ .one_of = schemas },
        } };
    }

    pub fn toJson(self: *const Schema, ctx: *Schema.Root) Allocator.Error!json.Value {
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

    fn common(self: *Schema) *Common {
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

    const Common = struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        @"$id": ?[]const u8 = null,
        default: ?Value = null,
        examples: [][]const u8 = &[_][]const u8{},
        extraValues: std.StringHashMapUnmanaged(Value) = .{},

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

    pub const Root = struct {
        common: Common = .{},
        root: Schema,
        definitions: std.StringHashMapUnmanaged(Schema) = .{},
        typemap: std.StringHashMapUnmanaged([]const u8) = .{},
        allocator: Allocator,

        pub fn init(allocator: Allocator) Schema.Root {
            return Schema.Root{
                .allocator = allocator,
                .root = Schema{ .object = .{} },
            };
        }

        pub fn from(T: type, allocator: Allocator) Allocator.Error!Schema.Root {
            var ctx = Schema.Root{
                .allocator = allocator,
                .root = undefined,
            };
            const root_schema = try genSchemaImpl(&ctx, T, false);
            ctx.root = root_schema;
            return ctx;
        }

        pub fn toJson(self: *Schema.Root) Allocator.Error!json.Value {
            var schema = try self.root.toJson(self);
            if (schema == .object) {
                var obj = &schema.object;
                try obj.put("$schema", .{ .string = "https://json-schema.org/draft-07/schema#" });
                if (self.definitions.count() > 0) {
                    var definitions = self.object();
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

        pub fn addSchema(ctx: *Schema.Root, T: type) Allocator.Error!Schema {
            const schema = try ctx.genSchemaImpl(T, false);
            _ = try ctx.addDefinition(@typeName(T), schema);
            return schema;
        }

        pub fn genSchema(ctx: *Schema.Root, T: type) Allocator.Error!Schema {
            return genSchemaImpl(ctx, T, false);
        }

        fn genSchemaImpl(ctx: *Schema.Root, T: type, add_def: bool) Allocator.Error!Schema {
            const typename = @typeName(T);
            if (try ctx.getRef(T)) |ref_| return ref_;

            const info = @typeInfo(T);
            return switch (info) {
                .comptime_int, .int => Schema{ .int = .{} },
                .comptime_float, .float => Schema{ .number = .{} },
                .bool => Schema{ .boolean = .{} },
                .@"struct" => |s| @"struct": {
                    const schema = if (@hasDecl(T, "jsonSchema")) try T.jsonSchema(ctx) else blk: {
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
                                var field_schema = try ctx.genSchemaImpl(FieldType, true);
                                if (field.defaultValue()) |default| {
                                    const F = @TypeOf(default);
                                    field_schema.common().default = try toValue(F, default, ctx);
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
                    const schema = if (@hasDecl(T, "jsonSchema")) try T.jsonSchema(ctx) else blk: {
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
                    Schema{ .array = .{} }, // todo
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8)
                        Schema{ .string = .{} }
                    else arr: {
                        const items_schema = try ctx.allocator.create(Schema);
                        items_schema.* = try ctx.genSchemaImpl(ptr.child, true);
                        break :arr Schema{ .array = .{ .items = items_schema } };
                    },
                    else => @compileError("todo: " ++ @typeName(T)),
                },
                .optional => |o| ctx.genSchema(o.child),
                .undefined, .null, .void, .noreturn => |t| {
                    @compileError("Cannot generate a json schema from type " ++ @tagName(t));
                },
                else => @compileError("todo: " ++ @typeName(T)),
            };
        }

        fn maybeAddDefinition(self: *Root, add_def: bool, comptime typename: []const u8, schema: Schema) !Schema {
            return if (add_def and schema != .@"$ref")
                self.addDefinition(typename, schema)
            else
                schema;
        }

        fn addDefinition(self: *Root, name: []const u8, schema_: Schema) Allocator.Error!Schema {
            var schema = schema_;
            const key = if (schema.common().@"$id") |id| brk: {
                try self.typemap.put(self.allocator, name, id);
                break :brk id;
            } else name;
            const uri = try fmt.allocPrint(self.allocator, Ref.definitions ++ "{s}", .{key});
            const entry = try self.definitions.getOrPut(self.allocator, key);
            if (entry.found_existing) panic("duplicate schema definition under key '{s}'", .{key});
            entry.value_ptr.* = schema;
            return Schema{ .@"$ref" = .{ .uri = uri } };
        }

        pub fn ref(self: *Root, T: type) !Schema {
            const typename = @typeName(T);
            if (self.typemap.get(typename)) |id| {
                return Ref.definition(self.allocator, id);
            }
            if (self.definitions.getPtr(typename)) |_| {
                return Ref.definition(self.allocator, typename);
            }
            var def = try self.genSchemaImpl(T, false);
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

        fn getRef(self: *Root, T: type) !?Schema {
            const typename = @typeName(T);
            const key: []const u8 = self.typemap.get(typename) orelse if (self.definitions.getPtr(typename)) |_| typename else return null;
            return try Ref.definition(self.allocator, key);
        }

        fn object(self: *Root) ObjectMap {
            return ObjectMap.init(self.allocator);
        }

        fn objectSized(self: *Root, len: usize) Allocator.Error!ObjectMap {
            var obj = ObjectMap.init(self.allocator);
            try obj.ensureUnusedCapacity(len);
            return obj;
        }

        fn array(self: *Root, len: usize) Allocator.Error!json.Array {
            var arr = json.Array.init(self.allocator);
            try arr.ensureTotalCapacityPrecise(len);
            return arr;
        }
    };

    pub fn Number(Num: type) type {
        // todo: exclusive minimum/maximum
        return struct {
            common: Common = .{},
            min: ?Num = null,
            max: ?Num = null,

            fn toJson(self: *const @This(), ctx: *Schema.Root) Allocator.Error!json.Value {
                var value = ctx.object();
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
        fn toJson(self: *const Boolean, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
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

        fn toJson(self: *const String, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
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

        fn toJson(self: *const Enum, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
            try value.put("type", .{ .string = "enum" });
            try self.common.toJson(&value);

            return .{ .object = value };
        }
    };

    pub const Array = struct {
        common: Common = .{},
        items: ?*Schema = null,

        fn toJson(self: *const Array, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
            try value.put("type", .{ .string = "array" });
            try self.common.toJson(&value);
            if (self.items) |items| {
                try value.put("items", try items.toJson(ctx));
            }

            return .{ .object = value };
        }
    };

    pub const Object = struct {
        common: Common = .{},
        properties: Properties = .{},
        required: []const []const u8 = &[_][]const u8{},

        const Properties = std.StringHashMapUnmanaged(Schema);

        fn toJson(self: *const Object, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
            try value.put("type", .{ .string = "object" });
            try self.common.toJson(&value);

            var properties = try ctx.objectSized(self.properties.count());
            var it = self.properties.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const schema = entry.value_ptr.*;
                try properties.put(key, try schema.toJson(ctx));
            }
            try value.put("properties", .{ .object = properties });

            if (self.required.len > 0) {
                var arr = try ctx.array(self.required.len);
                for (self.required) |name| {
                    arr.appendAssumeCapacity(.{ .string = name });
                }
                try value.put("required", .{ .array = arr });
            }

            return .{ .object = value };
        }
    };

    pub const Ref = struct {
        common: Common = .{},
        uri: []const u8,

        const definitions = "#/definitions/";
        fn definition(allocator: Allocator, name: []const u8) Allocator.Error!Schema {
            const uri = if (@inComptime())
                definitions ++ name
            else
                try fmt.allocPrint(allocator, definitions ++ "{s}", .{name});
            return .{ .@"$ref" = Ref{ .uri = uri } };
        }

        fn toJson(self: *const Ref, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
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

        pub fn toJson(self: *const Compound, ctx: *Schema.Root) Allocator.Error!json.Value {
            var value = ctx.object();
            try self.common.toJson(&value);
            const key: []const u8, const schemalist = switch (self.kind) {
                .all_of => |l| .{ "allOf", l },
                .any_of => |l| .{ "anyOf", l },
                .one_of => |l| .{ "oneOf", l },
            };
            var arr = try ctx.array(schemalist.len);
            for (schemalist) |schema| {
                const schema_value = try schema.toJson(ctx);
                arr.appendAssumeCapacity(schema_value);
            }
            try value.put(key, .{ .array = arr });
            return .{ .object = value };
        }
    };
};

fn toValue(T: type, value: T, ctx: *Schema.Root) Allocator.Error!?Value {
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
                    else => try toValue(field.type, @field(value, field.name), ctx) orelse return null,
                };
                try obj.put(field.name, field_value);
            }
            break :obj Value{ .object = obj };
        },
        .array => |array| array: {
            var arr = try ctx.array(array.len);
            for (array) |item| {
                try arr.appendAssumeCapacity(try toValue(
                    array.child,
                    item,
                    ctx,
                ));
            }
            break :array Value{ .array = arr };
        },
        .pointer => |ptr| switch (ptr.size) {
            .slice => if (ptr.child == u8) Value{ .string = value } else array: {
                var arr = try ctx.array(value.len);
                for (value) |item| {
                    arr.appendAssumeCapacity(try toValue(
                        ptr.child,
                        item,
                        ctx,
                    ) orelse return null);
                }
                break :array Value{ .array = arr };
            },
            .one => toValue(ptr.child, value.*, ctx),
            else => @panic("todo: " ++ @typeName(T)),
        },
        .optional => |o| toValue(o.child, value, ctx),
        // .@"enum" =>
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
    var schema = try Schema.Root.from(Config, allocator);

    const j = try schema.toJson();
    j.dump();
}

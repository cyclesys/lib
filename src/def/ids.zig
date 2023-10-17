pub const TypeId = packed struct(u64) {
    scheme: u16,
    name: u16,
    version: u16,
    _padding: u16 = 0,
};

pub const SourceId = packed struct(u64) {
    scheme: u16,
    name: u16,
    object: u32,
};

pub const ObjectId = packed struct(u128) {
    type: TypeId,
    source: SourceId,
};

pub const TypeIdInt = u64;
pub const TypeId = packed struct(TypeIdInt) {
    scheme: u16,
    name: u16,
    version: u16,
    _padding: u16 = 0,
};

pub const SourceIdInt = u64;
pub const SourceId = packed struct(SourceIdInt) {
    scheme: u16,
    name: u16,
    object: u32,
};

pub const ObjectIdInt = u128;
pub const ObjectId = packed struct(ObjectIdInt) {
    type: TypeId,
    source: SourceId,
};

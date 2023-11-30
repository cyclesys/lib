pub const ObjectIdInt = u128;
pub const ObjectId = packed struct(ObjectIdInt) {
    type: SchemeId,
    source: SchemeId,
};

pub const SchemeIdInt = u64;
pub const SchemeId = packed struct(SchemeIdInt) {
    scheme: u16,
    path: u16,
    value: u32,
};

pub const SourceIdInt = u32;
pub const SourceId = packed struct(SourceIdInt) {
    scheme: u16,
    name: u16,
};

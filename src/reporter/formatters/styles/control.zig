const std = @import("std");
pub const ControlSequenceInputs = struct {
    char: ControlChar = .esc,
    mode: ?Mode = null,
};
/// Control characters. First part of an ANSI control sequence.
///
/// ## References
/// - [Unicode Standard, v16](https://www.unicode.org/charts/PDF/U0000.pdf)
/// - [ECMA-35](https://www.ecma-international.org/wp-content/uploads/ECMA-35_6th_edition_december_1994.pdf)
/// - [this GitHub gist](https://gist.github.com/fnky/458719343aabd01cfb17a3a4f7296797)
const ControlChar = enum(u8) {
    /// 0x00. Null character.
    null,
    /// 0x01. Start of Heading.
    soh,
    /// 0x02. Start of Text.
    stx,
    /// 0x03. End of Text.
    etx,
    /// 0x04. End of Transmission.
    eot,
    /// 0x05. Enquiry.
    enq,
    /// 0x06. Acknowledge.
    ack,
    /// 0x07. Bell.
    bel,
    /// 0x08. Backspace.
    backspace,
    /// 0x09. Horizontal Tab.
    tab,
    /// 0x0A. Line Feed.
    lf,
    /// 0x0B. Vertical Tab.
    vtab,
    /// 0x0C. Form Feed.
    form_feed,
    /// 0x0D. Carriage Return.
    cr,
    /// 0x0E. Shift Out.
    so,
    /// 0x0F. Shift In.
    si,
    /// 0x10. Data Link Escape.
    dle,
    /// 0x11. Device Control 1.
    ///
    /// Also known as XON.
    /// This character is used to resume the transmission of data.
    dc1,
    /// 0x12. Device Control 2.
    ///
    /// Also known as XOFF.
    /// This character is used to stop the transmission of data.
    dc2,
    /// 0x13. Device Control 3.
    ///
    /// Also known as XOFF.
    /// This character is used to stop the transmission of data.
    dc3,
    /// 0x14. Device Control 4.
    ///
    /// This character is used to resume the transmission of data.
    dc4,
    /// 0x15. Negative Acknowledge.
    nak,
    /// 0x16. Synchronous Idle.
    syn,
    /// 0x17. End of Transmission Block.
    etb,
    /// 0x18. Cancel.
    can,
    /// 0x19. End of Medium.
    em,
    /// 0x1A. Substitute.
    ///
    /// This character is used to replace a character that is determined to be
    /// invalid or a control character.  It is used to indicate that the
    /// character that should have been in this position is invalid and should
    /// be ignored.
    sub,
    /// 0x1B. Escape.
    ///
    /// Introduces an escape sequence.
    esc,
    /// 0x1C. File Separator.
    ///
    /// This character is used to separate and delimit files.
    /// It is used to indicate the end of a file or the end of a data stream.
    fs,
    /// 0x1D. Group Separator.
    ///
    /// This character is used to separate and delimit groups of data.
    /// It is used to indicate the end of a group of data or the end of a
    /// sub-stream within a data stream.
    gs,
    /// 0x1E. Record Separator.
    ///
    /// This character is used to separate and delimit records.
    /// It is used to indicate the end of a record or the end of a line of data.
    rs,
    /// 0x1F. Unit Separator.
    ///
    /// This character is used to separate and delimit units of data.
    /// It is used to indicate the end of a unit of data or the end of a field
    us,
    /// 0x7F. Delete.
    ///
    /// This character is used to delete a character or a control character.
    /// It is used to indicate that the character that should have been in this
    del,

    pub fn str(c: ControlChar) []const u8 {
        switch (c) {
            .null => "\x00",
            .soh => "\x01",
            .stx => "\x02",
            .etx => "\x03",
            .eot => "\x04",
            .enq => "\x05",
            .ack => "\x06",
            .bel => "\x07",
            .backspace => "\x08",
            .tab => "\x09",
            .lf => "\x0A",
            .vtab => "\x0B",
            .form_feed => "\x0C",
            .cr => "\x0D",
            .so => "\x0E",
            .si => "\x0F",
            .dle => "\x10",
            .dc1 => "\x11",
            .dc2 => "\x12",
            .dc3 => "\x13",
            .dc4 => "\x14",
            .nak => "\x15",
            .syn => "\x16",
            .etb => "\x17",
            .can => "\x18",
            .em => "\x19",
            .sub => "\x1A",
            .esc => "\x1B",
            .fs => "\x1C",
            .gs => "\x1D",
            .rs => "\x1E",
            .us => "\x1F",
            .del => "\x7F",
        }
    }
};

pub const Mode = enum {
    graphic,
    screen,

    pub fn char(mode: Mode) u8 {
        return switch (mode) {
            .graphic => 'm',
            .screen => 'h',
        };
    }

    pub fn str(mode: Mode) []const u8 {
        return switch (mode) {
            .graphic => "m",
            .screen => "h",
        };
    }

    test char {
        try std.testing.expectEqual(Mode.char(.graphic), 'm');
        try std.testing.expectEqual(Mode.char(.screen), 'h');
    }
};
const GraphicsCode = enum {};
const ScreenCode = enum {};
pub const FunctionCode = union(Mode) {
    color: GraphicsCode,
    screen: ScreenCode,
};

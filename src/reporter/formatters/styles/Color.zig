/// A trait for describing a type which can be used with [`FgColorDisplay`] or
/// [`BgColorDisplay`]
// pub trait Color {
//     /// The ANSI format code for setting this color as the foreground
//     const ANSI_FG: &'static str;

//     /// The ANSI format code for setting this color as the background
//     const ANSI_BG: &'static str;

//     /// The raw ANSI format for settings this color as the foreground without the ANSI
//     /// delimiters ("\x1b" and "m")
//     const RAW_ANSI_FG: &'static str;

//     /// The raw ANSI format for settings this color as the background without the ANSI
//     /// delimiters ("\x1b" and "m")
//     const RAW_ANSI_BG: &'static str;
pub fn Color(comptime foreground: staticString, comptime background: staticString) type {
    return struct {
        pub inline fn fgRaw() staticString {
            return foreground;
        }
        pub inline fn bgRaw() staticString {
            return background;
        }
        pub inline fn fg() staticString {
            return "\x1b[38;5;" ++ foreground ++ "m";
        }
        pub inline fn bg() staticString {
            return "\x1b[48;5;" ++ background ++ "m";
        }
    };
}
// pub const Color = struct {
//     /// The ANSI format code for setting this color as the foreground
//     ansi_fg: staticString
//     /// The ANSI format code for setting this color as the background
//     ansi_bg: staticString,
//     raw_ansi_ft: staticString,
//     raw_ansi_bg: staticString,
// };

const staticString = []const u8;

characters: ThemeCharacters,
styles: ThemeStyles,

/// ASCII-art-based graphical drawing, with ANSI styling.
pub fn ascii() GraphicalTheme {
    return .{
        .characters = ThemeCharacters.ascii(),
        .styles = ThemeStyles.ansi(),
    };
}

/// Graphical theme that draws using both ansi colors and unicode
/// characters.
///
/// Note that full rgb colors aren't enabled by default because they're
/// an accessibility hazard, especially in the context of terminal themes
/// that can change the background color and make hardcoded colors illegible.
/// Such themes typically remap ansi codes properly, treating them more
/// like CSS classes than specific colors.
pub fn unicode() GraphicalTheme {
    return .{
        .characters = ThemeCharacters.unicode(),
        .styles = ThemeStyles.ansi(),
    };
}

/// Graphical theme that draws in monochrome, while still using unicode
/// characters.
pub fn unicodeNoColor() GraphicalTheme {
    return .{
        .characters = ThemeCharacters.unicode(),
        .styles = ThemeStyles.none(),
    };
}

/// A "basic" graphical theme that skips colors and unicode characters and
/// just does monochrome ascii art. If you want a completely non-graphical
/// rendering of your [`Diagnostic`](crate::Diagnostic)s, check out
/// [`NarratableReportHandler`](crate::NarratableReportHandler), or write
/// your own [`ReportHandler`](crate::ReportHandler)
pub fn none() GraphicalTheme {
    return .{
        .characters = ThemeCharacters.ascii(),
        .styles = ThemeStyles.none(),
    };
}

/// Copied from [miette's `ThemeStyles`](https://github.com/zkat/miette/blob/5f441d011560a091fe5d6a6cdb05f09acf622d36/src/handlers/theme.rs#L109)
pub const ThemeStyles = struct {
    /// Style to apply to things highlighted as "error".
    err: Chameleon,
    /// Style to apply to things highlighted as "warning".
    warning: Chameleon,
    /// Style to apply to things highlighted as "advice".
    advice: Chameleon,
    /// Style to apply to the help text.
    help: Chameleon,
    /// Style to apply to filenames/links/URLs.
    link: Chameleon,
    /// Style to apply to line numbers.
    linum: Chameleon,
    emphasize: Chameleon,
    /// Styles to cycle through (using `.iter().cycle()`), to render the lines
    /// and text for diagnostic highlights.
    highlights: [3]Chameleon,

    /// Nice RGB colors.
    /// [Credit](http://terminal.sexy/#FRUV0NDQFRUVrEFCkKlZ9L91ap-1qnWfdbWq0NDQUFBQrEFCkKlZ9L91ap-1qnWfdbWq9fX1).
    pub fn rgb() ThemeStyles {
        comptime var c = Chameleon{};
        return .{
            .err = c.rgb(255, 30, 30).createPreset(),
            .warning = c.rgb(244, 191, 117).createPreset(),
            .advice = c.rgb(106, 159, 181).createPreset(),
            .help = c.rgb(106, 159, 181).createPreset(),
            .link = c.rgb(92, 157, 255).underline().bold().createPreset(),
            .linum = c.dim().createPreset(),
            .emphasize = c.bold().createPreset(),
            .highlights = [_]Chameleon{
                c.rgb(246, 87, 248).createPreset(),
                c.rgb(30, 201, 212).createPreset(),
                c.rgb(145, 246, 111).createPreset(),
            },
        };
    }

    /// ANSI color-based styles.
    pub fn ansi() ThemeStyles {
        comptime var c = Chameleon{};
        return .{
            .err = c.red().createPreset(),
            .warning = c.yellow().createPreset(),
            .advice = c.cyan().createPreset(),
            .help = c.cyan().createPreset(),
            .link = c.cyan().underline().bold().createPreset(),
            .linum = c.dim().createPreset(),
            .emphasize = c.bold().createPreset(),
            .highlights = [_]Chameleon{
                c.magenta().bold().createPreset(),
                c.yellow().bold().createPreset(),
                c.green().bold().createPreset(),
            },
        };
    }

    pub fn none() ThemeStyles {
        comptime var c = Chameleon{};
        const empty = c.createPreset();
        return .{
            .err = empty,
            .warning = empty,
            .advice = empty,
            .help = empty,
            .link = empty,
            .linum = empty,
            .emphasize = empty,
            .highlights = [_]Chameleon{ empty, empty, empty },
        };
    }
};

const char = []const u8;

/// Copied from [miette's `ThemeCharacters`](https://github.com/zkat/miette/blob/5f441d011560a091fe5d6a6cdb05f09acf622d36/src/handlers/theme.rs#L197)
pub const ThemeCharacters = struct {
    hbar: char,
    vbar: char,
    xbar: char,
    vbar_break: char,

    uarrow: char,
    rarrow: char,

    ltop: char,
    mtop: char,
    rtop: char,
    lbot: char,
    rbot: char,
    mbot: char,

    /// e.g. `[`
    lbox: char,
    /// e.g. `]`
    rbox: char,

    lcross: char,
    rcross: char,

    underbar: char,
    underline: char,

    /// must be static
    err: []const u8,
    /// must be static
    warning: []const u8,
    /// must be static
    advice: []const u8,

    /// Fancy unicode-based graphical elements.
    pub fn unicode() ThemeCharacters {
        return .{
            .hbar = "─",
            .vbar = "│",
            .xbar = "┼",
            .vbar_break = "·",
            .uarrow = "▲",
            .rarrow = "▶",
            .ltop = "╭",
            .mtop = "┬",
            .rtop = "╮",
            .lbot = "╰",
            .mbot = "┴",
            .rbot = "╯",
            .lbox = "[",
            .rbox = "]",
            .lcross = "├",
            .rcross = "┤",
            .underbar = "┬",
            .underline = "─",
            .err = "𝙭",
            .warning = "⚠",
            .advice = "☞",
        };
    }

    /// Emoji-heavy unicode characters.
    pub fn emoji() ThemeCharacters {
        return .{
            .hbar = "─",
            .vbar = "│",
            .xbar = "┼",
            .vbar_break = "·",
            .uarrow = "▲",
            .rarrow = "▶",
            .ltop = "╭",
            .mtop = "┬",
            .rtop = "╮",
            .lbot = "╰",
            .mbot = "┴",
            .rbot = "╯",
            .lbox = "[",
            .rbox = "]",
            .lcross = "├",
            .rcross = "┤",
            .underbar = "┬",
            .underline = "─",
            .err = "💥",
            .warning = "⚠️",
            .advice = "💡",
        };
    }

    /// ASCII-art-based graphical elements. Works well on older terminals.
    pub fn ascii() ThemeCharacters {
        return .{
            .hbar = "-",
            .vbar = "|",
            .xbar = "+",
            .vbar_break = ":",
            .uarrow = "^",
            .rarrow = ">",
            .ltop = ",",
            .mtop = "v",
            .rtop = ".",
            .lbot = "`",
            .mbot = "^",
            .rbot = "'",
            .lbox = "[",
            .rbox = "]",
            .lcross = "|",
            .rcross = "|",
            .underbar = "|",
            .underline = "^",
            .err = "x",
            .warning = "!",
            .advice = ">",
        };
    }
};

const GraphicalTheme = @This();

pub const Chameleon = @import("chameleon").ComptimeChameleon;

//! The launcher calculator: a small expression evaluator and unit converter,
//! dependency-free.
//!
//! Expressions: `+ - * / % ^` (also `×`, `÷`, `−`, `**`), parentheses, unary
//! minus, decimals and exponents (`1.5e3`), implicit multiplication (`2pi`,
//! `3(4+1)`), functions `sqrt abs ln log sin cos tan round floor ceil`
//! (radians; `log` is base 10) and constants `pi`, `e`. `^` binds tighter
//! than unary minus and is right-associative (`-2^2 = -4`, `2^3^2 = 512`).
//!
//! Conversions: `<number> <unit> in|to|as <unit>` for length, mass,
//! temperature, data and time. Currency is not converted: rates are never
//! fetched silently (spec), so currency queries give
//! [`CalcError::CurrencyUnsupported`].

use std::fmt;

/// Why an input is not a calculation.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum CalcError {
    /// Nothing to evaluate.
    #[error("empty expression")]
    Empty,
    /// Malformed expression; the byte offset where parsing stopped.
    #[error("syntax error at {0}")]
    Syntax(usize),
    /// An identifier that is neither a function nor a constant.
    #[error("unknown name ‘{0}’")]
    UnknownName(String),
    /// Division or modulo by zero.
    #[error("division by zero")]
    DivisionByZero,
    /// The result is not a finite real number (`sqrt(-1)`, overflow).
    #[error("result is not a finite number")]
    Domain,
    /// A unit name that is not in the table.
    #[error("unknown unit ‘{0}’")]
    UnknownUnit(String),
    /// Units of different kinds (`km in kg`).
    #[error("cannot convert {0} to {1}")]
    IncompatibleUnits(String, String),
    /// Currency conversion needs cached rates, which are not available.
    #[error("currency conversion needs cached exchange rates")]
    CurrencyUnsupported,
}

/// A calculator answer for the launcher.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalcAnswer {
    /// What to show (`"1024"`, `"3.106855961 mi"`).
    pub display: String,
    /// What Enter copies (the bare number).
    pub value: String,
}

/// The calculator result for launcher text, or `None` when the text is not a
/// calculation. Without a leading `=`, plain expressions need an operator or
/// a parenthesis (so `7zip`, `e2` or `42` stay app searches); conversions are
/// recognised by their `in`/`to`/`as` shape.
pub fn answer(text: &str) -> Option<CalcAnswer> {
    let text = text.trim();
    let (explicit, body) = match text.strip_prefix('=') {
        Some(rest) => (true, rest.trim()),
        None => (false, text),
    };
    if body.is_empty()
        || !body
            .bytes()
            .any(|b| b.is_ascii_digit() || b.is_ascii_alphabetic())
    {
        return None;
    }
    if let Some(conv) = convert(body) {
        let (value, unit) = conv.ok()?;
        let v = format_number(value);
        return Some(CalcAnswer {
            display: format!("{v} {}", unit.symbol),
            value: v,
        });
    }
    if !explicit {
        let has_op = body.contains(['+', '-', '*', '/', '%', '^', '(', '×', '÷', '−']);
        if !has_op || !body.bytes().any(|b| b.is_ascii_digit()) {
            return None;
        }
    }
    let v = format_number(eval(body).ok()?);
    if !explicit && v == body {
        return None; // "-5" is not worth a result row
    }
    Some(CalcAnswer {
        display: v.clone(),
        value: v,
    })
}

/// Evaluates an expression.
pub fn eval(input: &str) -> Result<f64, CalcError> {
    let tokens = tokenize(input)?;
    if tokens.is_empty() {
        return Err(CalcError::Empty);
    }
    let mut p = Parser { tokens, pos: 0 };
    let v = p.expr()?;
    if let Some(t) = p.tokens.get(p.pos) {
        return Err(CalcError::Syntax(t.at));
    }
    finite(v)
}

/// Formats a number for display: integers up to 2^53 exactly, everything
/// else with at most 10 significant digits, trailing zeros trimmed, and
/// scientific notation below 1e-9 or from 1e15.
pub fn format_number(x: f64) -> String {
    if x == 0.0 || !x.is_finite() {
        return if x.is_nan() {
            "NaN".into()
        } else if x == 0.0 {
            "0".into()
        } else {
            x.to_string()
        };
    }
    let abs = x.abs();
    if abs < 9_007_199_254_740_992.0 && x.fract() == 0.0 && abs < 1e15 {
        return format!("{x:.0}");
    }
    if !(1e-9..1e15).contains(&abs) {
        let s = format!("{x:.9e}");
        let (mant, exp) = s.split_once('e').unwrap_or((&s, "0"));
        return format!("{}e{exp}", trim_zeros(mant));
    }
    let mag = abs.log10().floor() as i32;
    let decimals = usize::try_from(9 - mag).unwrap_or(0);
    let s = format!("{x:.decimals$}");
    let s = trim_zeros(&s);
    if s == "-0" { "0".into() } else { s.to_owned() }
}

fn trim_zeros(s: &str) -> &str {
    if s.contains('.') {
        s.trim_end_matches('0').trim_end_matches('.')
    } else {
        s
    }
}

fn finite(v: f64) -> Result<f64, CalcError> {
    if v.is_finite() {
        Ok(v)
    } else {
        Err(CalcError::Domain)
    }
}

// ---- tokenizer -------------------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
enum Tok {
    Num(f64),
    Ident(String),
    Op(char),
    LParen,
    RParen,
}

#[derive(Debug, Clone)]
struct Token {
    tok: Tok,
    at: usize,
}

fn tokenize(s: &str) -> Result<Vec<Token>, CalcError> {
    let mut out = Vec::new();
    let b = s.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        let at = i;
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if c.is_ascii_digit() || (c == b'.' && b.get(i + 1).is_some_and(u8::is_ascii_digit)) {
            while i < b.len() && (b[i].is_ascii_digit() || b[i] == b'.') {
                i += 1;
            }
            // exponent only when digits follow: `2e` stays 2·e
            if i < b.len() && (b[i] == b'e' || b[i] == b'E') {
                let mut j = i + 1;
                if j < b.len() && (b[j] == b'+' || b[j] == b'-') {
                    j += 1;
                }
                if j < b.len() && b[j].is_ascii_digit() {
                    while j < b.len() && b[j].is_ascii_digit() {
                        j += 1;
                    }
                    i = j;
                }
            }
            let v: f64 = s[at..i].parse().map_err(|_| CalcError::Syntax(at))?;
            out.push(Token {
                tok: Tok::Num(v),
                at,
            });
            continue;
        }
        if c.is_ascii_alphabetic() {
            while i < b.len() && b[i].is_ascii_alphabetic() {
                i += 1;
            }
            out.push(Token {
                tok: Tok::Ident(s[at..i].to_ascii_lowercase()),
                at,
            });
            continue;
        }
        let ch = s[i..].chars().next().ok_or(CalcError::Syntax(at))?;
        i += ch.len_utf8();
        let tok = match ch {
            '+' => Tok::Op('+'),
            '-' | '−' => Tok::Op('-'),
            '*' if b.get(i) == Some(&b'*') => {
                i += 1;
                Tok::Op('^')
            }
            '*' | '×' | '·' => Tok::Op('*'),
            '/' | '÷' => Tok::Op('/'),
            '%' => Tok::Op('%'),
            '^' => Tok::Op('^'),
            '(' => Tok::LParen,
            ')' => Tok::RParen,
            'π' => Tok::Ident("pi".into()),
            _ => return Err(CalcError::Syntax(at)),
        };
        out.push(Token { tok, at });
    }
    Ok(out)
}

// ---- parser ----------------------------------------------------------------

struct Parser {
    tokens: Vec<Token>,
    pos: usize,
}

impl Parser {
    fn peek(&self) -> Option<&Tok> {
        self.tokens.get(self.pos).map(|t| &t.tok)
    }

    fn here(&self) -> usize {
        self.tokens
            .get(self.pos)
            .or(self.tokens.last())
            .map_or(0, |t| t.at)
    }

    fn eat_op(&mut self, ops: &[char]) -> Option<char> {
        match self.peek() {
            Some(Tok::Op(c)) if ops.contains(c) => {
                let c = *c;
                self.pos += 1;
                Some(c)
            }
            _ => None,
        }
    }

    fn expr(&mut self) -> Result<f64, CalcError> {
        let mut v = self.term()?;
        while let Some(op) = self.eat_op(&['+', '-']) {
            let r = self.term()?;
            v = if op == '+' { v + r } else { v - r };
        }
        Ok(v)
    }

    fn term(&mut self) -> Result<f64, CalcError> {
        let mut v = self.unary()?;
        loop {
            if let Some(op) = self.eat_op(&['*', '/', '%']) {
                let r = self.unary()?;
                v = match op {
                    '*' => v * r,
                    _ if r == 0.0 => return Err(CalcError::DivisionByZero),
                    '/' => v / r,
                    _ => v % r,
                };
            } else if matches!(self.peek(), Some(Tok::Num(_) | Tok::Ident(_) | Tok::LParen)) {
                // implicit multiplication: 2pi, 3(4+1), (1+2)(3)
                v *= self.power()?;
            } else {
                return Ok(v);
            }
        }
    }

    fn unary(&mut self) -> Result<f64, CalcError> {
        match self.eat_op(&['-', '+']) {
            Some('-') => Ok(-self.unary()?),
            Some(_) => self.unary(),
            None => self.power(),
        }
    }

    fn power(&mut self) -> Result<f64, CalcError> {
        let base = self.primary()?;
        if self.eat_op(&['^']).is_some() {
            let exp = self.unary()?; // right-assoc; allows 2^-1
            return finite(base.powf(exp));
        }
        Ok(base)
    }

    fn primary(&mut self) -> Result<f64, CalcError> {
        let at = self.here();
        let Some(tok) = self.tokens.get(self.pos).map(|t| t.tok.clone()) else {
            return Err(CalcError::Syntax(at));
        };
        self.pos += 1;
        match tok {
            Tok::Num(v) => Ok(v),
            Tok::LParen => {
                let v = self.expr()?;
                if self.peek() == Some(&Tok::RParen) {
                    self.pos += 1;
                    Ok(v)
                } else {
                    Err(CalcError::Syntax(self.here()))
                }
            }
            Tok::Ident(name) => match name.as_str() {
                "pi" => Ok(std::f64::consts::PI),
                "e" => Ok(std::f64::consts::E),
                _ => {
                    let f = function(&name).ok_or(CalcError::UnknownName(name))?;
                    let arg = self.power()?;
                    finite(f(arg))
                }
            },
            Tok::Op(_) | Tok::RParen => Err(CalcError::Syntax(at)),
        }
    }
}

fn snap(v: f64) -> f64 {
    if v.abs() < 1e-15 { 0.0 } else { v }
}

fn function(name: &str) -> Option<fn(f64) -> f64> {
    Some(match name {
        "sqrt" => f64::sqrt,
        "abs" => f64::abs,
        "ln" => f64::ln,
        "log" => f64::log10,
        "sin" => |x: f64| snap(x.sin()),
        "cos" => |x: f64| snap(x.cos()),
        "tan" => |x: f64| snap(x.tan()),
        "round" => f64::round,
        "floor" => f64::floor,
        "ceil" => f64::ceil,
        _ => return None,
    })
}

// ---- units -----------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Dim {
    Length,
    Mass,
    Temperature,
    Data,
    Time,
}

impl fmt::Display for Dim {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Length => "length",
            Self::Mass => "mass",
            Self::Temperature => "temperature",
            Self::Data => "data size",
            Self::Time => "time",
        })
    }
}

/// A unit: `value_in_base = value * factor + offset`.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Unit {
    symbol: &'static str,
    dim: Dim,
    factor: f64,
    offset: f64,
}

const fn u(symbol: &'static str, dim: Dim, factor: f64) -> Unit {
    Unit {
        symbol,
        dim,
        factor,
        offset: 0.0,
    }
}

/// `(names, unit)`; names are lowercase.
const UNITS: &[(&[&str], Unit)] = &[
    (
        &[
            "mm",
            "millimeter",
            "millimeters",
            "millimetre",
            "millimetres",
        ],
        u("mm", Dim::Length, 0.001),
    ),
    (
        &[
            "cm",
            "centimeter",
            "centimeters",
            "centimetre",
            "centimetres",
        ],
        u("cm", Dim::Length, 0.01),
    ),
    (
        &["m", "meter", "meters", "metre", "metres"],
        u("m", Dim::Length, 1.0),
    ),
    (
        &["km", "kilometer", "kilometers", "kilometre", "kilometres"],
        u("km", Dim::Length, 1000.0),
    ),
    (
        &["in", "inch", "inches", "\""],
        u("in", Dim::Length, 0.0254),
    ),
    (&["ft", "foot", "feet", "'"], u("ft", Dim::Length, 0.3048)),
    (&["yd", "yard", "yards"], u("yd", Dim::Length, 0.9144)),
    (&["mi", "mile", "miles"], u("mi", Dim::Length, 1609.344)),
    (
        &["mg", "milligram", "milligrams"],
        u("mg", Dim::Mass, 0.001),
    ),
    (&["g", "gram", "grams"], u("g", Dim::Mass, 1.0)),
    (
        &["kg", "kilogram", "kilograms", "kilo", "kilos"],
        u("kg", Dim::Mass, 1000.0),
    ),
    (
        &["lb", "lbs", "pound", "pounds"],
        u("lb", Dim::Mass, 453.592_37),
    ),
    (
        &["oz", "ounce", "ounces"],
        u("oz", Dim::Mass, 28.349_523_125),
    ),
    (
        &["c", "°c", "celsius"],
        Unit {
            symbol: "°C",
            dim: Dim::Temperature,
            factor: 1.0,
            offset: 273.15,
        },
    ),
    (
        &["f", "°f", "fahrenheit"],
        Unit {
            symbol: "°F",
            dim: Dim::Temperature,
            factor: 5.0 / 9.0,
            offset: 273.15 - 32.0 * 5.0 / 9.0,
        },
    ),
    (&["k", "kelvin"], u("K", Dim::Temperature, 1.0)),
    (&["b", "byte", "bytes"], u("B", Dim::Data, 1.0)),
    (&["kb", "kilobyte", "kilobytes"], u("KB", Dim::Data, 1e3)),
    (&["mb", "megabyte", "megabytes"], u("MB", Dim::Data, 1e6)),
    (&["gb", "gigabyte", "gigabytes"], u("GB", Dim::Data, 1e9)),
    (&["tb", "terabyte", "terabytes"], u("TB", Dim::Data, 1e12)),
    (
        &["kib", "kibibyte", "kibibytes"],
        u("KiB", Dim::Data, 1024.0),
    ),
    (
        &["mib", "mebibyte", "mebibytes"],
        u("MiB", Dim::Data, 1_048_576.0),
    ),
    (
        &["gib", "gibibyte", "gibibytes"],
        u("GiB", Dim::Data, 1_073_741_824.0),
    ),
    (
        &["tib", "tebibyte", "tebibytes"],
        u("TiB", Dim::Data, 1_099_511_627_776.0),
    ),
    (
        &["s", "sec", "secs", "second", "seconds"],
        u("s", Dim::Time, 1.0),
    ),
    (
        &["min", "mins", "minute", "minutes"],
        u("min", Dim::Time, 60.0),
    ),
    (
        &["h", "hr", "hrs", "hour", "hours"],
        u("h", Dim::Time, 3600.0),
    ),
    (&["d", "day", "days"], u("day", Dim::Time, 86_400.0)),
    (&["wk", "week", "weeks"], u("week", Dim::Time, 604_800.0)),
];

/// ISO codes recognised only to say "not supported" instead of failing oddly.
const CURRENCIES: &[&str] = &[
    "usd", "eur", "gbp", "jpy", "cny", "inr", "cad", "aud", "chf", "rwf", "kes", "ugx", "tzs",
    "ngn", "zar", "xof", "xaf", "bif", "cdf", "etb", "ghs", "egp", "mad", "brl", "mxn", "rub",
    "try", "krw", "sek", "nok", "dkk", "pln",
];

fn unit(name: &str) -> Result<&'static Unit, CalcError> {
    UNITS
        .iter()
        .find(|(names, _)| names.contains(&name))
        .map(|(_, u)| u)
        .ok_or_else(|| {
            if CURRENCIES.contains(&name) {
                CalcError::CurrencyUnsupported
            } else {
                CalcError::UnknownUnit(name.to_owned())
            }
        })
}

/// Converts `<number> <unit> in|to|as|into <unit>`. `None` when the text does
/// not have that shape; `Some(Err)` for unknown or incompatible units and
/// currency.
fn convert(text: &str) -> Option<Result<(f64, &'static Unit), CalcError>> {
    let lower = text.to_lowercase();
    let words: Vec<&str> = lower.split_whitespace().collect();
    let n = words.len();
    if !(3..=4).contains(&n) || !matches!(words[n - 2], "in" | "to" | "as" | "into") {
        return None;
    }
    let to_name = words[n - 1];
    let (num, from_name) = if n == 4 {
        (words[0], words[1])
    } else {
        // glued: "5km", "-3.5°c", "10'"
        let w = words[0];
        let split = w
            .char_indices()
            .find(|&(i, c)| !(c.is_ascii_digit() || c == '.' || (i == 0 && (c == '-' || c == '+'))))
            .map(|(i, _)| i)?;
        (&w[..split], &w[split..])
    };
    let value: f64 = num.parse().ok().filter(|v: &f64| v.is_finite())?;
    Some(convert_value(value, from_name, to_name))
}

fn convert_value(value: f64, from: &str, to: &str) -> Result<(f64, &'static Unit), CalcError> {
    let f = unit(from)?;
    let t = unit(to)?;
    if f.dim != t.dim {
        return Err(CalcError::IncompatibleUnits(
            f.dim.to_string(),
            t.dim.to_string(),
        ));
    }
    let base = value * f.factor + f.offset;
    Ok((finite((base - t.offset) / t.factor)?, t))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(s: &str) -> f64 {
        eval(s).unwrap_or_else(|e| panic!("{s}: {e}"))
    }

    fn approx(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9 * b.abs().max(1.0)
    }

    #[test]
    fn precedence_and_associativity() {
        assert_eq!(ev("1 + 2 * 3"), 7.0);
        assert_eq!(ev("(1 + 2) * 3"), 9.0);
        assert_eq!(ev("10 - 4 - 3"), 3.0);
        assert_eq!(ev("100 / 10 / 5"), 2.0);
        assert_eq!(ev("2 ^ 3 ^ 2"), 512.0);
        assert_eq!(ev("-2 ^ 2"), -4.0);
        assert_eq!(ev("(-2) ^ 2"), 4.0);
        assert_eq!(ev("2 ^ -1"), 0.5);
        assert_eq!(ev("2**10"), 1024.0);
        assert_eq!(ev("7 % 3"), 1.0);
        assert_eq!(ev("--3"), 3.0);
        assert_eq!(ev("+3 - -3"), 6.0);
        assert_eq!(ev("1.5e3 + .5"), 1500.5);
        assert_eq!(ev("6 ÷ 2 × 3 − 1"), 8.0);
    }

    #[test]
    fn functions_constants_implicit_mul() {
        assert_eq!(ev("sqrt(16)"), 4.0);
        assert_eq!(ev("sqrt 16 + 1"), 5.0);
        assert_eq!(ev("abs(-3)"), 3.0);
        assert!(approx(ev("ln(e)"), 1.0));
        assert_eq!(ev("log(1000)"), 3.0);
        assert_eq!(ev("sin(pi)"), 0.0);
        assert_eq!(ev("cos(0)"), 1.0);
        assert!(approx(ev("tan(pi/4)"), 1.0));
        assert_eq!(ev("round(2.5) + floor(1.9) + ceil(1.1)"), 6.0);
        assert!(approx(ev("2pi"), std::f64::consts::TAU));
        assert_eq!(ev("3(4+1)"), 15.0);
        assert_eq!(ev("(1+2)(3)"), 9.0);
        assert!(approx(ev("2e"), 2.0 * std::f64::consts::E));
        assert!(approx(ev("PI"), std::f64::consts::PI));
    }

    #[test]
    fn errors() {
        assert_eq!(eval(""), Err(CalcError::Empty));
        assert_eq!(eval("1 / 0"), Err(CalcError::DivisionByZero));
        assert_eq!(eval("1 % 0"), Err(CalcError::DivisionByZero));
        assert_eq!(eval("sqrt(-1)"), Err(CalcError::Domain));
        assert_eq!(eval("10^400"), Err(CalcError::Domain));
        assert_eq!(eval("foo(2)"), Err(CalcError::UnknownName("foo".into())));
        assert!(matches!(eval("(1 + 2"), Err(CalcError::Syntax(_))));
        assert!(matches!(eval("1 +"), Err(CalcError::Syntax(_))));
        assert!(matches!(eval("1 2 )"), Err(CalcError::Syntax(_))));
        assert!(matches!(eval("3 $ 4"), Err(CalcError::Syntax(2))));
        assert!(matches!(eval("1..2"), Err(CalcError::Syntax(0))));
    }

    #[test]
    fn formatting() {
        assert_eq!(format_number(1024.0), "1024");
        assert_eq!(format_number(0.1 + 0.2), "0.3");
        assert_eq!(format_number(1.0 / 3.0), "0.3333333333");
        assert_eq!(format_number(2.0 / 3.0 * 100.0), "66.66666667");
        assert_eq!(format_number(-2.5), "-2.5");
        assert_eq!(format_number(2f64.powi(40)), "1099511627776");
        assert_eq!(format_number(1e20), "1e20");
        assert_eq!(format_number(1.23456789012e-12), "1.23456789e-12");
        assert_eq!(format_number(-0.0), "0");
        assert_eq!(format_number(9.999_999_999_9), "10");
        assert_eq!(format_number(std::f64::consts::PI), "3.141592654");
    }

    #[test]
    fn conversions() {
        let c = |s: &str| {
            let (v, u) = convert(s).unwrap().unwrap();
            format!("{} {}", format_number(v), u.symbol)
        };
        assert_eq!(c("5 km in mi"), "3.106855961 mi");
        assert_eq!(c("5km to mi"), "3.106855961 mi");
        assert_eq!(c("12 in in cm"), "30.48 cm");
        assert_eq!(c("1 mile to feet"), "5280 ft");
        assert_eq!(c("1 kg in lb"), "2.204622622 lb");
        assert_eq!(c("16 oz to g"), "453.59237 g");
        assert_eq!(c("100 C to F"), "212 °F");
        assert_eq!(c("-40 f in c"), "-40 °C");
        assert_eq!(c("0 k in c"), "-273.15 °C");
        assert_eq!(c("1 GiB in MB"), "1073.741824 MB");
        assert_eq!(c("1 GB as MiB"), "953.6743164 MiB");
        assert_eq!(c("90 min in h"), "1.5 h");
        assert_eq!(c("2 days in s"), "172800 s");
        assert_eq!(c("3.5 yd into m"), "3.2004 m");
    }

    #[test]
    fn conversion_errors() {
        assert_eq!(
            convert("30 usd in rwf"),
            Some(Err(CalcError::CurrencyUnsupported))
        );
        assert_eq!(
            convert("5 km in kg"),
            Some(Err(CalcError::IncompatibleUnits(
                "length".into(),
                "mass".into()
            )))
        );
        assert_eq!(
            convert("5 parsec in m"),
            Some(Err(CalcError::UnknownUnit("parsec".into())))
        );
        assert_eq!(convert("five km in mi"), None);
        assert_eq!(convert("open folder in files"), None);
        assert_eq!(convert("km in mi"), None);
    }

    #[test]
    fn launcher_answers() {
        let a = |s: &str| answer(s).map(|a| a.display);
        assert_eq!(a("2+2"), Some("4".into()));
        assert_eq!(a("= 2^10"), Some("1024".into()));
        assert_eq!(a("=pi"), Some("3.141592654".into()));
        assert_eq!(a("sqrt(2)"), Some("1.414213562".into()));
        assert_eq!(a("5 km in mi"), Some("3.106855961 mi".into()));
        assert_eq!(answer("5 km in mi").unwrap().value, "3.106855961");
        assert_eq!(a("30 usd in rwf"), None);
        assert_eq!(a("42"), None, "a bare number is not a calculation");
        assert_eq!(a("-5"), None);
        assert_eq!(a("7zip"), None);
        assert_eq!(a("e2"), None);
        assert_eq!(a("pi"), None);
        assert_eq!(a("firefox"), None);
        assert_eq!(a("1/0"), None);
        assert_eq!(a("="), None);
        assert_eq!(a("+"), None);
    }
}

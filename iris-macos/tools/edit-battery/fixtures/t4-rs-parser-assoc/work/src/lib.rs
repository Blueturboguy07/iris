//! calckit — a small integer expression evaluator.
//!
//! Three stages, one per module:
//!
//! * [`tokenizer`] turns source text into [`tokenizer::Token`]s,
//! * [`parser`] turns tokens into a [`parser::Node`] tree that follows the
//!   grammar in README.md,
//! * [`eval`] walks that tree and produces an `i64`.

pub mod eval;
pub mod parser;
pub mod tokenizer;

/// Tokenize, parse and evaluate one expression.
pub fn evaluate(source: &str) -> Result<i64, String> {
    let tokens = tokenizer::tokenize(source)?;
    let tree = parser::parse(&tokens)?;
    eval::eval(&tree)
}

#[cfg(test)]
mod tests {
    use super::evaluate;

    #[test]
    fn evaluates_a_single_number() {
        assert_eq!(evaluate("42"), Ok(42));
    }

    #[test]
    fn evaluates_precedence() {
        assert_eq!(evaluate("2 + 3 * 4"), Ok(14));
        assert_eq!(evaluate("(2 + 3) * 4"), Ok(20));
    }

    #[test]
    fn reports_a_tokenizer_error() {
        assert!(evaluate("2 $ 3").is_err());
    }
}

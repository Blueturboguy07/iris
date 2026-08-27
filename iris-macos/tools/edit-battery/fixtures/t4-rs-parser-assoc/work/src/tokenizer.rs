//! Source text -> tokens.

/// One lexical token.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Token {
    Int(i64),
    Plus,
    Minus,
    Star,
    Slash,
    LParen,
    RParen,
}

/// Split `source` into tokens.
///
/// Whitespace separates tokens and is otherwise ignored. Integer literals
/// are unsigned here; a leading `-` is a separate [`Token::Minus`] and the
/// parser decides whether it is negation or subtraction.
pub fn tokenize(source: &str) -> Result<Vec<Token>, String> {
    let bytes: Vec<char> = source.chars().collect();
    let mut tokens = Vec::new();
    let mut index = 0usize;

    while index < bytes.len() {
        let character = bytes[index];

        if character.is_whitespace() {
            index += 1;
            continue;
        }

        if character.is_ascii_digit() {
            let start = index;
            let mut value: i64 = 0;
            while index < bytes.len() && bytes[index].is_ascii_digit() {
                let digit = bytes[index] as i64 - '0' as i64;
                value = value
                    .checked_mul(10)
                    .and_then(|scaled| scaled.checked_add(digit))
                    .ok_or_else(|| {
                        format!("integer literal at offset {} does not fit in i64", start)
                    })?;
                index += 1;
            }
            tokens.push(Token::Int(value));
            continue;
        }

        let token = match character {
            '+' => Token::Plus,
            '-' => Token::Minus,
            '*' => Token::Star,
            '/' => Token::Slash,
            '(' => Token::LParen,
            ')' => Token::RParen,
            other => {
                return Err(format!(
                    "unexpected character '{}' at offset {}",
                    other, index
                ))
            }
        };
        tokens.push(token);
        index += 1;
    }

    Ok(tokens)
}

#[cfg(test)]
mod tests {
    use super::{tokenize, Token};

    #[test]
    fn tokenizes_a_simple_sum() {
        assert_eq!(
            tokenize("1 + 2"),
            Ok(vec![Token::Int(1), Token::Plus, Token::Int(2)])
        );
    }

    #[test]
    fn tokenizes_multi_digit_numbers() {
        assert_eq!(tokenize("1234"), Ok(vec![Token::Int(1234)]));
    }

    #[test]
    fn tokenizes_parentheses() {
        assert_eq!(
            tokenize("(7)"),
            Ok(vec![Token::LParen, Token::Int(7), Token::RParen])
        );
    }

    #[test]
    fn rejects_an_unknown_character() {
        assert!(tokenize("1 % 2").is_err());
    }
}

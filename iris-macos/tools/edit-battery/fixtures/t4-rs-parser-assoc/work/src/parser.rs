//! Tokens -> syntax tree.
//!
//! The grammar (also in README.md):
//!
//! ```text
//! expr   := term  (("+" | "-") term)*      left associative
//! term   := factor (("*" | "/") factor)*   left associative
//! factor := INT | "-" factor | "(" expr ")"
//! ```
//!
//! Both binary levels are **left associative**, so `a - b - c` must parse as
//! `(a - b) - c` and `a / b / c` as `(a / b) / c`. The tree shape is public
//! API: the formula pretty-printer and the constant folder both walk it and
//! assume a left-leaning spine for runs of equal-precedence operators.

use crate::tokenizer::Token;

/// A binary operator.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Op {
    Add,
    Sub,
    Mul,
    Div,
}

/// A node of the syntax tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Node {
    Int(i64),
    Neg(Box<Node>),
    Bin(Op, Box<Node>, Box<Node>),
}

struct Parser<'tokens> {
    tokens: &'tokens [Token],
    position: usize,
}

/// Parse a whole token stream into one tree.
pub fn parse(tokens: &[Token]) -> Result<Node, String> {
    let mut parser = Parser {
        tokens,
        position: 0,
    };
    let tree = parser.parse_expr()?;
    if parser.position != tokens.len() {
        return Err(format!(
            "unexpected trailing input at token {}",
            parser.position
        ));
    }
    Ok(tree)
}

impl<'tokens> Parser<'tokens> {
    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    fn bump(&mut self) {
        self.position += 1;
    }

    fn additive_op(&self) -> Option<Op> {
        match self.peek() {
            Some(Token::Plus) => Some(Op::Add),
            Some(Token::Minus) => Some(Op::Sub),
            _ => None,
        }
    }

    fn multiplicative_op(&self) -> Option<Op> {
        match self.peek() {
            Some(Token::Star) => Some(Op::Mul),
            Some(Token::Slash) => Some(Op::Div),
            _ => None,
        }
    }

    fn parse_expr(&mut self) -> Result<Node, String> {
        let left = self.parse_term()?;
        if let Some(op) = self.additive_op() {
            self.bump();
            let right = self.parse_expr()?;
            return Ok(Node::Bin(op, Box::new(left), Box::new(right)));
        }
        Ok(left)
    }

    fn parse_term(&mut self) -> Result<Node, String> {
        let left = self.parse_factor()?;
        if let Some(op) = self.multiplicative_op() {
            self.bump();
            let right = self.parse_term()?;
            return Ok(Node::Bin(op, Box::new(left), Box::new(right)));
        }
        Ok(left)
    }

    fn parse_factor(&mut self) -> Result<Node, String> {
        match self.peek().cloned() {
            Some(Token::Int(value)) => {
                self.bump();
                Ok(Node::Int(value))
            }
            Some(Token::Minus) => {
                self.bump();
                let inner = self.parse_factor()?;
                Ok(Node::Neg(Box::new(inner)))
            }
            Some(Token::LParen) => {
                self.bump();
                let inner = self.parse_expr()?;
                match self.peek() {
                    Some(Token::RParen) => {
                        self.bump();
                        Ok(inner)
                    }
                    _ => Err(format!("expected ')' at token {}", self.position)),
                }
            }
            Some(other) => Err(format!(
                "expected a number, '-' or '(' at token {}, found {:?}",
                self.position, other
            )),
            None => Err("unexpected end of input".to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{parse, Node, Op};
    use crate::tokenizer::tokenize;

    fn tree(source: &str) -> Node {
        parse(&tokenize(source).unwrap()).unwrap()
    }

    #[test]
    fn parses_a_number() {
        assert_eq!(tree("7"), Node::Int(7));
    }

    #[test]
    fn parses_unary_minus() {
        assert_eq!(tree("-7"), Node::Neg(Box::new(Node::Int(7))));
    }

    #[test]
    fn multiplication_binds_tighter_than_addition() {
        assert_eq!(
            tree("1 + 2 * 3"),
            Node::Bin(
                Op::Add,
                Box::new(Node::Int(1)),
                Box::new(Node::Bin(
                    Op::Mul,
                    Box::new(Node::Int(2)),
                    Box::new(Node::Int(3))
                ))
            )
        );
    }

    #[test]
    fn parentheses_override_precedence() {
        assert_eq!(
            tree("(1 + 2) * 3"),
            Node::Bin(
                Op::Mul,
                Box::new(Node::Bin(
                    Op::Add,
                    Box::new(Node::Int(1)),
                    Box::new(Node::Int(2))
                )),
                Box::new(Node::Int(3))
            )
        );
    }

    #[test]
    fn rejects_trailing_input() {
        assert!(parse(&tokenize("1 2").unwrap()).is_err());
    }

    #[test]
    fn rejects_an_unclosed_paren() {
        assert!(parse(&tokenize("(1 + 2").unwrap()).is_err());
    }
}

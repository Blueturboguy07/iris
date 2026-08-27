//! Syntax tree -> value.
//!
//! Every arithmetic step is checked: overflow is an error, not a wrap, and
//! division by zero is an error rather than a panic. Division truncates
//! toward zero, matching Rust's own `i64` division.

use crate::parser::{Node, Op};

/// Evaluate a tree.
pub fn eval(node: &Node) -> Result<i64, String> {
    match node {
        Node::Int(value) => Ok(*value),
        Node::Neg(inner) => {
            let value = eval(inner)?;
            value
                .checked_neg()
                .ok_or_else(|| "arithmetic overflow".to_string())
        }
        Node::Bin(op, left, right) => {
            let a = eval(left)?;
            let b = eval(right)?;
            match op {
                Op::Add => a.checked_add(b),
                Op::Sub => a.checked_sub(b),
                Op::Mul => a.checked_mul(b),
                Op::Div => {
                    if b == 0 {
                        return Err("division by zero".to_string());
                    }
                    a.checked_div(b)
                }
            }
            .ok_or_else(|| "arithmetic overflow".to_string())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::eval;
    use crate::parser::{Node, Op};

    fn int(value: i64) -> Box<Node> {
        Box::new(Node::Int(value))
    }

    #[test]
    fn adds() {
        assert_eq!(eval(&Node::Bin(Op::Add, int(2), int(3))), Ok(5));
    }

    #[test]
    fn subtracts() {
        assert_eq!(eval(&Node::Bin(Op::Sub, int(9), int(4))), Ok(5));
    }

    #[test]
    fn subtracts_left_to_right_when_the_tree_says_so() {
        let left = Node::Bin(Op::Sub, int(2), int(3));
        let whole = Node::Bin(Op::Sub, Box::new(left), int(4));
        assert_eq!(eval(&whole), Ok(-5));
    }

    #[test]
    fn divides_toward_zero() {
        assert_eq!(eval(&Node::Bin(Op::Div, int(7), int(2))), Ok(3));
        assert_eq!(eval(&Node::Bin(Op::Div, int(-7), int(2))), Ok(-3));
    }

    #[test]
    fn rejects_division_by_zero() {
        assert_eq!(
            eval(&Node::Bin(Op::Div, int(1), int(0))),
            Err("division by zero".to_string())
        );
    }

    #[test]
    fn rejects_overflow() {
        assert!(eval(&Node::Bin(Op::Mul, int(i64::MAX), int(2))).is_err());
    }
}

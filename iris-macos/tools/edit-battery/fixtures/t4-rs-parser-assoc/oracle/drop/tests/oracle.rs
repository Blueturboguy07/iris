//! Held-out oracle for t4-rs-parser-assoc.
//!
//! Dropped into a pristine copy at grade time as `tests/oracle.rs`; the agent
//! never sees it. Run with `cargo test --offline --test oracle`.
//!
//! `f2p_*` must go red -> green. `p2p_*` must stay green.

use calckit::eval::eval;
use calckit::parser::{parse, Node, Op};
use calckit::tokenizer::tokenize;
use calckit::evaluate;

fn tree(source: &str) -> Node {
    parse(&tokenize(source).unwrap()).unwrap()
}

// ---------------- F2P: left associativity ---------------------------------

#[test]
fn f2p_subtraction_chains_are_left_associative() {
    assert_eq!(evaluate("2 - 3 - 4"), Ok(-5));
    assert_eq!(evaluate("10 - 1 - 1 - 1"), Ok(7));
    assert_eq!(evaluate("100 - 50 - 25 - 10"), Ok(15));
    assert_eq!(evaluate("0 - 1 - 2 - 3 - 4"), Ok(-10));
}

#[test]
fn f2p_division_chains_are_left_associative() {
    assert_eq!(evaluate("100 / 5 / 2"), Ok(10));
    assert_eq!(evaluate("64 / 4 / 2 / 2"), Ok(4));
    assert_eq!(evaluate("7 / 2 / 2"), Ok(1));
}

#[test]
fn f2p_mixed_same_precedence_runs() {
    assert_eq!(evaluate("8 - 2 + 1"), Ok(7));
    assert_eq!(evaluate("1 - 2 + 3 - 4 + 5"), Ok(3));
    assert_eq!(evaluate("20 / 2 * 5"), Ok(50));
    assert_eq!(evaluate("2 * 6 / 4"), Ok(3));
    assert_eq!(evaluate("100 / 10 * 10 / 5"), Ok(20));
}

#[test]
fn f2p_associativity_interacts_correctly_with_precedence_and_parens() {
    assert_eq!(evaluate("2 - 3 * 4 - 5"), Ok(-15));
    assert_eq!(evaluate("(2 - 3) - 4"), Ok(-5));
    assert_eq!(evaluate("2 - (3 - 4)"), Ok(3));
    assert_eq!(evaluate("100 / (5 / 2)"), Ok(50));
    assert_eq!(evaluate("-2 - 3 - 4"), Ok(-9));
}

/// A left-leaning spine is documented as public API in `parser`'s module doc.
#[test]
fn f2p_the_tree_for_an_equal_precedence_run_leans_left() {
    let expected = Node::Bin(
        Op::Sub,
        Box::new(Node::Bin(
            Op::Sub,
            Box::new(Node::Int(2)),
            Box::new(Node::Int(3)),
        )),
        Box::new(Node::Int(4)),
    );
    assert_eq!(tree("2 - 3 - 4"), expected);

    let expected_div = Node::Bin(
        Op::Div,
        Box::new(Node::Bin(
            Op::Div,
            Box::new(Node::Int(8)),
            Box::new(Node::Int(4)),
        )),
        Box::new(Node::Int(2)),
    );
    assert_eq!(tree("8 / 4 / 2"), expected_div);
}

// A tiny deterministic PRNG, so the generated cases cannot be hardcoded.
struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

#[test]
fn f2p_generated_additive_chains_match_a_left_fold() {
    let mut rng = Lcg(20260826);
    for _ in 0..300 {
        let length = 2 + (rng.next() % 6) as usize;
        let mut source = String::new();
        let mut expected: i64 = 0;
        for position in 0..length {
            let operand = (rng.next() % 100) as i64;
            if position == 0 {
                expected = operand;
                source.push_str(&operand.to_string());
            } else if rng.next() % 2 == 0 {
                expected += operand;
                source.push_str(&format!(" + {}", operand));
            } else {
                expected -= operand;
                source.push_str(&format!(" - {}", operand));
            }
        }
        assert_eq!(evaluate(&source), Ok(expected), "source: {}", source);
    }
}

#[test]
fn f2p_generated_multiplicative_chains_match_a_left_fold() {
    let mut rng = Lcg(777777);
    for _ in 0..300 {
        let length = 2 + (rng.next() % 5) as usize;
        let mut source = String::new();
        let mut expected: i64 = 0;
        for position in 0..length {
            let operand = 1 + (rng.next() % 9) as i64;
            if position == 0 {
                expected = operand;
                source.push_str(&operand.to_string());
            } else if rng.next() % 2 == 0 {
                expected *= operand;
                source.push_str(&format!(" * {}", operand));
            } else {
                expected /= operand;
                source.push_str(&format!(" / {}", operand));
            }
        }
        assert_eq!(evaluate(&source), Ok(expected), "source: {}", source);
    }
}

// ---------------- P2P: everything that already worked ----------------------

#[test]
fn p2p_single_values_and_unary_minus() {
    assert_eq!(evaluate("42"), Ok(42));
    assert_eq!(evaluate("-42"), Ok(-42));
    assert_eq!(evaluate("--42"), Ok(42));
    assert_eq!(evaluate("  7  "), Ok(7));
}

#[test]
fn p2p_precedence_and_parentheses() {
    assert_eq!(evaluate("2 + 3 * 4"), Ok(14));
    assert_eq!(evaluate("(2 + 3) * 4"), Ok(20));
    assert_eq!(evaluate("1 + 2 + 3"), Ok(6));
    assert_eq!(evaluate("2 * 3 * 4"), Ok(24));
    assert_eq!(evaluate("1 - (2 - 3)"), Ok(2));
    assert_eq!(evaluate("((((5))))"), Ok(5));
}

#[test]
fn p2p_division_truncates_toward_zero() {
    assert_eq!(evaluate("7 / 2"), Ok(3));
    assert_eq!(evaluate("-7 / 2"), Ok(-3));
    assert_eq!(evaluate("7 / -2"), Ok(-3));
}

#[test]
fn p2p_errors_are_preserved() {
    assert_eq!(evaluate("1 / 0"), Err("division by zero".to_string()));
    assert!(evaluate("2 $ 3").is_err());
    assert!(evaluate("1 2").is_err());
    assert!(evaluate("(1 + 2").is_err());
    assert!(evaluate("").is_err());
    assert!(evaluate("1 +").is_err());
    assert!(evaluate("* 3").is_err());
}

#[test]
fn p2p_overflow_is_an_error_not_a_wrap() {
    let huge = format!("{} * 2", i64::MAX);
    assert!(evaluate(&huge).is_err());
    let too_big = "99999999999999999999";
    assert!(evaluate(too_big).is_err());
}

#[test]
fn p2p_tokenizer_is_unchanged() {
    use calckit::tokenizer::Token;
    assert_eq!(
        tokenize("12 + (3)"),
        Ok(vec![
            Token::Int(12),
            Token::Plus,
            Token::LParen,
            Token::Int(3),
            Token::RParen
        ])
    );
    assert!(tokenize("1 % 2").is_err());
}

#[test]
fn p2p_evaluator_is_unchanged() {
    let two = Box::new(Node::Int(2));
    let three = Box::new(Node::Int(3));
    assert_eq!(eval(&Node::Bin(Op::Add, two.clone(), three.clone())), Ok(5));
    assert_eq!(eval(&Node::Bin(Op::Sub, two.clone(), three.clone())), Ok(-1));
    assert_eq!(eval(&Node::Neg(two.clone())), Ok(-2));
    assert_eq!(
        eval(&Node::Bin(Op::Div, two, Box::new(Node::Int(0)))),
        Err("division by zero".to_string())
    );
}

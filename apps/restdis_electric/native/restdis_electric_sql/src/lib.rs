//! Parses a Postgres `where` clause into an Elixir-friendly parse tree.
//!
//! The heavy lifting is `datafusion-sqlparser-rs` with its `PostgreSqlDialect`.
//! This crate only translates the resulting `Expr` into tagged Elixir tuples.
//! It deliberately does *not* decide what is supported: anything it does not
//! recognise becomes `{:unsupported, description}` and `RestdisElectric.Eval`
//! rejects it. Keeping the accept/reject decision in Elixir means the parser
//! can never widen the supported subset by accident.

use rustler::types::tuple::make_tuple;
use rustler::{Encoder, Env, NifResult, Term};
use sqlparser::ast::{Expr, FunctionArg, FunctionArgExpr, FunctionArguments, Value};
use sqlparser::dialect::PostgreSqlDialect;
use sqlparser::parser::Parser;
use sqlparser::tokenizer::Token;

mod atoms {
    rustler::atoms! {
        ok,
        error,
        ident,
        lit,
        param,
        binop,
        unop,
        is,
        in_list,
        between,
        like,
        any,
        all,
        func,
        array,
        unsupported,
        number,
        string,
        bool_,
        null,
    }
}

/// Longest `where` clause we will hand to the parser. A client-supplied
/// expression runs on a dirty CPU scheduler, but an unbounded input would
/// still let one subscribe call occupy that scheduler for a long time.
const MAX_INPUT_BYTES: usize = 8 * 1024;

#[rustler::nif(name = "parse_nif", schedule = "DirtyCpu")]
fn parse_nif<'a>(env: Env<'a>, sql: String) -> NifResult<Term<'a>> {
    if sql.len() > MAX_INPUT_BYTES {
        return Ok(error(
            env,
            format!(
                "where clause is {} bytes, the limit is {}",
                sql.len(),
                MAX_INPUT_BYTES
            ),
        ));
    }

    let dialect = PostgreSqlDialect {};

    let mut parser = match Parser::new(&dialect).try_with_sql(&sql) {
        Ok(parser) => parser,
        Err(e) => return Ok(error(env, e.to_string())),
    };

    let expr = match parser.parse_expr() {
        Ok(expr) => expr,
        Err(e) => return Ok(error(env, e.to_string())),
    };

    if parser.peek_token().token != Token::EOF {
        return Ok(error(
            env,
            format!("unexpected trailing input at {}", parser.peek_token()),
        ));
    }

    let tree = encode_expr(env, &expr);
    Ok(make_tuple(env, &[atoms::ok().encode(env), tree]))
}

fn error<'a>(env: Env<'a>, message: String) -> Term<'a> {
    make_tuple(env, &[atoms::error().encode(env), message.encode(env)])
}

fn unsupported<'a>(env: Env<'a>, description: String) -> Term<'a> {
    make_tuple(
        env,
        &[atoms::unsupported().encode(env), description.encode(env)],
    )
}

fn encode_expr<'a>(env: Env<'a>, expr: &Expr) -> Term<'a> {
    match expr {
        Expr::Nested(inner) => encode_expr(env, inner),

        Expr::Identifier(ident) => make_tuple(
            env,
            &[atoms::ident().encode(env), ident.value.clone().encode(env)],
        ),

        Expr::CompoundIdentifier(parts) => {
            let joined = parts
                .iter()
                .map(|p| p.value.clone())
                .collect::<Vec<_>>()
                .join(".");
            make_tuple(env, &[atoms::ident().encode(env), joined.encode(env)])
        }

        Expr::Value(value) => encode_value(env, &value.value, expr),

        Expr::BinaryOp { left, op, right } => make_tuple(
            env,
            &[
                atoms::binop().encode(env),
                op.to_string().encode(env),
                encode_expr(env, left),
                encode_expr(env, right),
            ],
        ),

        Expr::UnaryOp { op, expr: inner } => make_tuple(
            env,
            &[
                atoms::unop().encode(env),
                op.to_string().encode(env),
                encode_expr(env, inner),
            ],
        ),

        Expr::IsNull(inner) => encode_is(env, "is_null", inner),
        Expr::IsNotNull(inner) => encode_is(env, "is_not_null", inner),
        Expr::IsTrue(inner) => encode_is(env, "is_true", inner),
        Expr::IsNotTrue(inner) => encode_is(env, "is_not_true", inner),
        Expr::IsFalse(inner) => encode_is(env, "is_false", inner),
        Expr::IsNotFalse(inner) => encode_is(env, "is_not_false", inner),
        Expr::IsUnknown(inner) => encode_is(env, "is_unknown", inner),
        Expr::IsNotUnknown(inner) => encode_is(env, "is_not_unknown", inner),

        Expr::InList {
            expr: inner,
            list,
            negated,
        } => {
            let items: Vec<Term> = list.iter().map(|e| encode_expr(env, e)).collect();
            make_tuple(
                env,
                &[
                    atoms::in_list().encode(env),
                    encode_expr(env, inner),
                    items.encode(env),
                    negated.encode(env),
                ],
            )
        }

        Expr::Between {
            expr: inner,
            negated,
            low,
            high,
        } => make_tuple(
            env,
            &[
                atoms::between().encode(env),
                encode_expr(env, inner),
                encode_expr(env, low),
                encode_expr(env, high),
                negated.encode(env),
            ],
        ),

        Expr::Like {
            negated,
            any,
            expr: inner,
            pattern,
            escape_char,
        } => encode_like(env, false, *negated, *any, inner, pattern, escape_char.is_some(), expr),

        Expr::ILike {
            negated,
            any,
            expr: inner,
            pattern,
            escape_char,
        } => encode_like(env, true, *negated, *any, inner, pattern, escape_char.is_some(), expr),

        Expr::AnyOp {
            left,
            compare_op,
            right,
            ..
        } => make_tuple(
            env,
            &[
                atoms::any().encode(env),
                compare_op.to_string().encode(env),
                encode_expr(env, left),
                encode_expr(env, right),
            ],
        ),

        Expr::AllOp {
            left,
            compare_op,
            right,
        } => make_tuple(
            env,
            &[
                atoms::all().encode(env),
                compare_op.to_string().encode(env),
                encode_expr(env, left),
                encode_expr(env, right),
            ],
        ),

        Expr::Array(array) => {
            let items: Vec<Term> = array.elem.iter().map(|e| encode_expr(env, e)).collect();
            make_tuple(env, &[atoms::array().encode(env), items.encode(env)])
        }

        Expr::Function(function) => encode_function(env, function, expr),

        other => unsupported(env, other.to_string()),
    }
}

#[allow(clippy::too_many_arguments)]
fn encode_like<'a>(
    env: Env<'a>,
    case_insensitive: bool,
    negated: bool,
    any: bool,
    inner: &Expr,
    pattern: &Expr,
    has_escape: bool,
    whole: &Expr,
) -> Term<'a> {
    if any || has_escape {
        return unsupported(env, whole.to_string());
    }

    make_tuple(
        env,
        &[
            atoms::like().encode(env),
            encode_expr(env, inner),
            encode_expr(env, pattern),
            negated.encode(env),
            case_insensitive.encode(env),
        ],
    )
}

fn encode_is<'a>(env: Env<'a>, tag: &str, inner: &Expr) -> Term<'a> {
    make_tuple(
        env,
        &[
            atoms::is().encode(env),
            tag.encode(env),
            encode_expr(env, inner),
        ],
    )
}

fn encode_function<'a>(
    env: Env<'a>,
    function: &sqlparser::ast::Function,
    whole: &Expr,
) -> Term<'a> {
    let name = function.name.to_string().to_lowercase();

    let args = match &function.args {
        FunctionArguments::List(list) if list.clauses.is_empty() && list.duplicate_treatment.is_none() => {
            &list.args
        }
        _ => return unsupported(env, whole.to_string()),
    };

    if function.over.is_some() || function.filter.is_some() || function.null_treatment.is_some() {
        return unsupported(env, whole.to_string());
    }

    let mut encoded: Vec<Term> = Vec::with_capacity(args.len());

    for arg in args {
        match arg {
            FunctionArg::Unnamed(FunctionArgExpr::Expr(e)) => encoded.push(encode_expr(env, e)),
            _ => return unsupported(env, whole.to_string()),
        }
    }

    make_tuple(
        env,
        &[
            atoms::func().encode(env),
            name.encode(env),
            encoded.encode(env),
        ],
    )
}

fn encode_value<'a>(env: Env<'a>, value: &Value, whole: &Expr) -> Term<'a> {
    let inner = match value {
        Value::Number(n, _) => make_tuple(
            env,
            &[atoms::number().encode(env), n.to_string().encode(env)],
        ),
        Value::SingleQuotedString(s) | Value::DollarQuotedString(sqlparser::ast::DollarQuotedString { value: s, .. }) => {
            make_tuple(env, &[atoms::string().encode(env), s.clone().encode(env)])
        }
        Value::Boolean(b) => make_tuple(env, &[atoms::bool_().encode(env), b.encode(env)]),
        Value::Null => atoms::null().encode(env),
        Value::Placeholder(p) => {
            return match p.strip_prefix('$').and_then(|d| d.parse::<u32>().ok()) {
                Some(index) => {
                    make_tuple(env, &[atoms::param().encode(env), index.encode(env)])
                }
                None => unsupported(env, whole.to_string()),
            }
        }
        _ => return unsupported(env, whole.to_string()),
    };

    make_tuple(env, &[atoms::lit().encode(env), inner])
}

rustler::init!("Elixir.RestdisElectric.SqlParser");

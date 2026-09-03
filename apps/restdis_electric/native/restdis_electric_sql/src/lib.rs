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
use sqlparser::ast::{
    Expr, FunctionArg, FunctionArgExpr, FunctionArguments, GroupByExpr, Query, Select, SelectItem,
    SetExpr, TableFactor, Value,
};
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
        in_subquery,
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
        none,
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

    let tree = encode_expr(env, &expr, true);
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

fn encode_expr<'a>(env: Env<'a>, expr: &Expr, allow_subquery: bool) -> Term<'a> {
    match expr {
        Expr::Nested(inner) => encode_expr(env, inner, allow_subquery),

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
                encode_expr(env, left, allow_subquery),
                encode_expr(env, right, allow_subquery),
            ],
        ),

        Expr::UnaryOp { op, expr: inner } => make_tuple(
            env,
            &[
                atoms::unop().encode(env),
                op.to_string().encode(env),
                encode_expr(env, inner, allow_subquery),
            ],
        ),

        Expr::IsNull(inner) => encode_is(env, "is_null", inner, allow_subquery),
        Expr::IsNotNull(inner) => encode_is(env, "is_not_null", inner, allow_subquery),
        Expr::IsTrue(inner) => encode_is(env, "is_true", inner, allow_subquery),
        Expr::IsNotTrue(inner) => encode_is(env, "is_not_true", inner, allow_subquery),
        Expr::IsFalse(inner) => encode_is(env, "is_false", inner, allow_subquery),
        Expr::IsNotFalse(inner) => encode_is(env, "is_not_false", inner, allow_subquery),
        Expr::IsUnknown(inner) => encode_is(env, "is_unknown", inner, allow_subquery),
        Expr::IsNotUnknown(inner) => encode_is(env, "is_not_unknown", inner, allow_subquery),

        Expr::InList {
            expr: inner,
            list,
            negated,
        } => {
            let items: Vec<Term> = list.iter().map(|e| encode_expr(env, e, allow_subquery)).collect();
            make_tuple(
                env,
                &[
                    atoms::in_list().encode(env),
                    encode_expr(env, inner, allow_subquery),
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
                encode_expr(env, inner, allow_subquery),
                encode_expr(env, low, allow_subquery),
                encode_expr(env, high, allow_subquery),
                negated.encode(env),
            ],
        ),

        Expr::Like {
            negated,
            any,
            expr: inner,
            pattern,
            escape_char,
        } => encode_like(env, false, *negated, *any, inner, pattern, escape_char.is_some(), expr, allow_subquery),

        Expr::ILike {
            negated,
            any,
            expr: inner,
            pattern,
            escape_char,
        } => encode_like(env, true, *negated, *any, inner, pattern, escape_char.is_some(), expr, allow_subquery),

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
                encode_expr(env, left, allow_subquery),
                encode_expr(env, right, allow_subquery),
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
                encode_expr(env, left, allow_subquery),
                encode_expr(env, right, allow_subquery),
            ],
        ),

        Expr::Array(array) => {
            let items: Vec<Term> = array.elem.iter().map(|e| encode_expr(env, e, allow_subquery)).collect();
            make_tuple(env, &[atoms::array().encode(env), items.encode(env)])
        }

        Expr::Function(function) => encode_function(env, function, expr, allow_subquery),

        Expr::InSubquery {
            expr: inner,
            subquery,
            negated,
        } => encode_in_subquery(env, inner, subquery, *negated, expr, allow_subquery),

        other => unsupported(env, other.to_string()),
    }
}

/// `field IN (SELECT column FROM table [WHERE ...])`.
///
/// Accepted only when the subquery is a plain, non-nested, single-table scan
/// with exactly one projected column: no `WITH`, no set operation, no join,
/// no `GROUP BY`/`HAVING`/`DISTINCT`/`ORDER BY`/`LIMIT`, and no subquery
/// nested inside its own `WHERE`. Whether the subquery is *correlated* to the
/// outer query cannot be decided here — this parser has no notion of the
/// outer table's schema — so that check happens in `RestdisElectric.Definition`.
fn encode_in_subquery<'a>(
    env: Env<'a>,
    inner: &Expr,
    subquery: &Query,
    negated: bool,
    whole: &Expr,
    allow_subquery: bool,
) -> Term<'a> {
    if !allow_subquery {
        return unsupported(env, format!("subquery nested inside a subquery: {}", whole));
    }

    match describe_subquery(subquery) {
        Ok((table, column, selection)) => {
            let selection_term = match selection {
                Some(selection) => encode_expr(env, selection, false),
                None => atoms::none().encode(env),
            };

            make_tuple(
                env,
                &[
                    atoms::in_subquery().encode(env),
                    encode_expr(env, inner, allow_subquery),
                    negated.encode(env),
                    table.encode(env),
                    column.encode(env),
                    selection_term,
                ],
            )
        }
        Err(reason) => unsupported(env, format!("{}: {}", reason, whole)),
    }
}

/// Structurally validates `subquery` and, if accepted, returns its table
/// name, its one projected column, and its optional `WHERE` clause.
fn describe_subquery(subquery: &Query) -> Result<(String, String, Option<&Expr>), String> {
    if subquery.with.is_some() {
        return Err("WITH inside a subquery is not supported".to_string());
    }

    if subquery.order_by.is_some() {
        return Err("ORDER BY inside a subquery is not supported".to_string());
    }

    if subquery.limit_clause.is_some() {
        return Err("LIMIT inside a subquery is not supported".to_string());
    }

    if subquery.fetch.is_some() {
        return Err("FETCH inside a subquery is not supported".to_string());
    }

    let select: &Select = match subquery.body.as_ref() {
        SetExpr::Select(select) => select,
        _ => return Err("set operations inside a subquery are not supported".to_string()),
    };

    if select.from.len() != 1 {
        return Err("a subquery must read exactly one table".to_string());
    }

    if !select.from[0].joins.is_empty() {
        return Err("joins inside a subquery are not supported".to_string());
    }

    let table = match &select.from[0].relation {
        TableFactor::Table {
            name, args: None, ..
        } => name.to_string(),
        _ => return Err("a subquery must read a plain table".to_string()),
    };

    if select.projection.len() != 1 {
        return Err("a subquery must project exactly one column".to_string());
    }

    let column = match &select.projection[0] {
        SelectItem::UnnamedExpr(Expr::Identifier(ident)) => ident.value.clone(),
        SelectItem::ExprWithAlias {
            expr: Expr::Identifier(ident),
            ..
        } => ident.value.clone(),
        _ => return Err("a subquery must project a single plain column".to_string()),
    };

    if select.distinct.is_some() {
        return Err("DISTINCT inside a subquery is not supported".to_string());
    }

    if select.having.is_some() {
        return Err("HAVING inside a subquery is not supported".to_string());
    }

    match &select.group_by {
        GroupByExpr::Expressions(exprs, _) if exprs.is_empty() => {}
        _ => return Err("GROUP BY inside a subquery is not supported".to_string()),
    }

    if !select.sort_by.is_empty() {
        return Err("SORT BY inside a subquery is not supported".to_string());
    }

    if select.qualify.is_some() {
        return Err("QUALIFY inside a subquery is not supported".to_string());
    }

    Ok((table, column, select.selection.as_ref()))
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
    allow_subquery: bool,
) -> Term<'a> {
    if any || has_escape {
        return unsupported(env, whole.to_string());
    }

    make_tuple(
        env,
        &[
            atoms::like().encode(env),
            encode_expr(env, inner, allow_subquery),
            encode_expr(env, pattern, allow_subquery),
            negated.encode(env),
            case_insensitive.encode(env),
        ],
    )
}

fn encode_is<'a>(env: Env<'a>, tag: &str, inner: &Expr, allow_subquery: bool) -> Term<'a> {
    make_tuple(
        env,
        &[
            atoms::is().encode(env),
            tag.encode(env),
            encode_expr(env, inner, allow_subquery),
        ],
    )
}

fn encode_function<'a>(
    env: Env<'a>,
    function: &sqlparser::ast::Function,
    whole: &Expr,
    allow_subquery: bool,
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
            FunctionArg::Unnamed(FunctionArgExpr::Expr(e)) => encoded.push(encode_expr(env, e, allow_subquery)),
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

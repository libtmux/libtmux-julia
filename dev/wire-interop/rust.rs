use libtmux::{Filterable, Pane};
use libtmux::query::FilterExpr;
use serde::Deserialize;
use serde_json::{Value, json};

// Public Pane handles have no inert-data constructor. Validate their actual
// schema, then evaluate identical scalar types through the library's derive.
#[derive(Deserialize, Filterable)]
#[filterable(target = "pane", crate = "libtmux")]
struct CapturedPane {
    pane_id: String,
    pane_active: bool,
    pane_dead: bool,
    pane_index: u32,
    pane_width: u32,
    pane_height: u32,
    pane_current_command: String,
    pane_current_path: String,
    pane_title: String,
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let path = std::env::args().nth(1).ok_or("expected corpus file")?;
    let corpus: Value = serde_json::from_slice(&std::fs::read(path)?)?;
    let panes: Vec<CapturedPane> = serde_json::from_value(corpus["panes"].clone())?;
    let mut valid = Vec::new();
    for fixture in corpus["valid"].as_array().ok_or("missing valid cases")? {
        let document = fixture["rust"].clone();
        let _: FilterExpr<Pane> = serde_json::from_value(document.clone())?;
        let expression: FilterExpr<CapturedPane> = serde_json::from_value(document)?;
        let selected: Vec<_> = panes.iter().filter(|pane| expression.matches(pane))
            .map(|pane| pane.pane_id.as_str()).collect();
        valid.push(json!({"id": fixture["id"], "selected": selected,
            "canonical": serde_json::to_value(&expression)?}));
    }
    let invalid: Vec<_> = corpus["invalid"].as_array().ok_or("missing invalid cases")?
        .iter().map(|fixture| json!({"id": fixture["id"], "rejected":
            serde_json::from_value::<FilterExpr<Pane>>(fixture["rust"].clone()).is_err()}))
        .collect();
    println!("{}", json!({"valid": valid, "invalid": invalid}));
    Ok(())
}

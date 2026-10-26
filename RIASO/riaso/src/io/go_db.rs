use std::collections::{HashMap, HashSet};

use anyhow::{Context, Result};
use rusqlite::Connection;

use crate::core::gene_set::{GeneSet, GeneSetDb};

pub fn read_go_db(org_path: &str, go_path: &str) -> Result<GeneSetDb> {
    let conn = Connection::open(org_path)
        .with_context(|| format!("failed to open the org annotation database: {org_path}"))?;
    let sql = "SELECT g.go_id, gi.symbol, e.ensembl_id FROM go g \
               JOIN gene_info gi ON gi._id = g._id \
               LEFT JOIN ensembl e ON e._id = g._id";
    let mut stmt = conn
        .prepare(sql)
        .with_context(|| format!("org database is missing the go/gene_info/ensembl tables (not an AnnotationDbi file?): {org_path}"))?;
    let mut genes_of: HashMap<String, HashSet<String>> = HashMap::new();
    let mut aliases: HashMap<String, String> = HashMap::new();
    {
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let go_id: String = row.get(0)?;
            let symbol: Option<String> = row.get(1)?;
            let ensembl: Option<String> = row.get(2)?;
            let sym = symbol.filter(|s| !s.is_empty());
            let ens = ensembl.filter(|s| !s.is_empty());

            let label = match sym.as_ref() {
                Some(s) => s.clone(),
                None => match ens.as_ref() {
                    Some(e) => e.clone(),
                    None => continue,
                },
            };
            genes_of.entry(go_id).or_default().insert(label.clone());
            if let Some(s) = sym {
                aliases.insert(s.to_ascii_lowercase(), label.clone());
            }
            if let Some(e) = ens {
                aliases.insert(e.to_ascii_lowercase(), label);
            }
        }
    }

    let conn = Connection::open(go_path)
        .with_context(|| format!("failed to open the GO annotation database: {go_path}"))?;
    let mut sets: HashMap<String, GeneSet> = HashMap::new();
    {
        let sql = "SELECT go_id, term, ontology FROM go_term";
        let mut stmt = conn.prepare(sql)?;
        let mut rows = stmt.query([])?;
        while let Some(row) = rows.next()? {
            let go_id: String = row.get(0)?;
            if let Some(genes) = genes_of.remove(&go_id) {
                let term: String = row.get(1)?;
                let ontology: String = row.get(2)?;
                sets.insert(
                    go_id.clone(),
                    GeneSet {
                        id: go_id,
                        name: term,
                        category: Some(ontology),
                        genes,
                    },
                );
            }
        }
    }

    Ok(GeneSetDb::new("go", sets, aliases))
}

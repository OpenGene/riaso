use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

use anyhow::{Context, Result};
use rusqlite::Connection;

use crate::core::gene_set::{GeneSet, GeneSetDb};

const NCBI_COL_GENE: usize = 0;
const NCBI_COL_PATHWAY: usize = 1;
const NCBI_COL_SPECIES: usize = 5;

const PW_COL_ID: usize = 0;
const PW_COL_NAME: usize = 1;
const PW_COL_SPECIES: usize = 2;

pub fn read_reactome_db(reactome_dir: &str, org_path: &str, species: &str) -> Result<GeneSetDb> {
    let conn = Connection::open(org_path)
        .with_context(|| format!("failed to open the org annotation database: {org_path}"))?;
    let uid_of = load_entrez_uid(&conn).with_context(|| {
        format!("org database is missing the genes table (not an AnnotationDbi file?): {org_path}")
    })?;
    let symbol_of = load_uid_map(&conn, "gene_info", "symbol").with_context(|| {
        format!(
            "org database is missing the gene_info table (not an AnnotationDbi file?): {org_path}"
        )
    })?;
    let ensembl_of = load_uid_map(&conn, "ensembl", "ensembl_id").with_context(|| {
        format!(
            "org database is missing the ensembl table (not an AnnotationDbi file?): {org_path}"
        )
    })?;
    drop(conn);

    let ncbi_path = Path::new(reactome_dir).join("NCBI2Reactome.txt");
    let file = File::open(&ncbi_path).with_context(|| {
        format!(
            "failed to open the Reactome gene-to-pathway file: {}",
            ncbi_path.display()
        )
    })?;
    let mut entrez_of: HashMap<String, HashSet<i64>> = HashMap::new();
    for line in BufReader::new(file).lines() {
        let line = line?;
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() <= NCBI_COL_SPECIES || f[NCBI_COL_SPECIES].trim() != species {
            continue;
        }
        let Ok(entrez) = f[NCBI_COL_GENE].trim().parse::<i64>() else {
            continue;
        };
        entrez_of
            .entry(f[NCBI_COL_PATHWAY].trim().to_string())
            .or_default()
            .insert(entrez);
    }

    let pw_path = Path::new(reactome_dir).join("ReactomePathways.txt");
    let file = File::open(&pw_path).with_context(|| {
        format!(
            "failed to open the Reactome pathway table: {}",
            pw_path.display()
        )
    })?;
    let mut name_of: HashMap<String, String> = HashMap::new();
    for line in BufReader::new(file).lines() {
        let line = line?;
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() <= PW_COL_SPECIES || f[PW_COL_SPECIES].trim() != species {
            continue;
        }
        name_of.insert(
            f[PW_COL_ID].trim().to_string(),
            f[PW_COL_NAME].trim().to_string(),
        );
    }

    let mut sets: HashMap<String, GeneSet> = HashMap::new();
    let mut aliases: HashMap<String, String> = HashMap::new();
    for (pid, entrez_ids) in entrez_of {
        let mut genes: HashSet<String> = HashSet::new();
        for e in entrez_ids {
            let Some(uid) = uid_of.get(&e) else { continue };
            let Some(sym) = symbol_of.get(uid) else {
                continue;
            };
            genes.insert(sym.clone());
            aliases.insert(sym.to_ascii_lowercase(), sym.clone());
            aliases.insert(e.to_string(), sym.clone());
            if let Some(ens) = ensembl_of.get(uid) {
                aliases.insert(ens.to_ascii_lowercase(), sym.clone());
            }
        }
        if genes.is_empty() {
            continue;
        }
        let name = name_of.get(&pid).cloned().unwrap_or_else(|| pid.clone());
        sets.insert(
            pid.clone(),
            GeneSet {
                id: pid,
                name,
                category: None,
                genes,
            },
        );
    }

    Ok(GeneSetDb::new("reactome", sets, aliases))
}

fn load_entrez_uid(conn: &Connection) -> Result<HashMap<i64, i64>> {
    let mut stmt = conn.prepare("SELECT _id, gene_id FROM genes")?;
    let mut rows = stmt.query([])?;
    let mut out: HashMap<i64, i64> = HashMap::new();
    while let Some(row) = rows.next()? {
        let uid: i64 = row.get(0)?;
        let gid: Option<String> = row.get(1)?;
        if let Some(e) = gid.and_then(|s| s.trim().parse::<i64>().ok()) {
            out.insert(e, uid);
        }
    }
    Ok(out)
}

fn load_uid_map(conn: &Connection, table: &str, col: &str) -> Result<HashMap<i64, String>> {
    let sql = format!("SELECT _id, {col} FROM {table}");
    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt.query([])?;
    let mut out: HashMap<i64, String> = HashMap::new();
    while let Some(row) = rows.next()? {
        let id: i64 = row.get(0)?;
        let val: Option<String> = row.get(1)?;
        if let Some(v) = val.filter(|s| !s.is_empty()) {
            out.insert(id, v);
        }
    }
    Ok(out)
}

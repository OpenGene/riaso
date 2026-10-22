use anyhow::{anyhow, Result};
use leiden_rs::{GraphDataBuilder, Leiden, LeidenConfig, QualityType};
use nalgebra_sparse::csr::CsrMatrix;
use ndarray::Array2;
use polars::prelude::*;

use crate::algorithm::qc::upsert_column;
use crate::core::SoData;

pub fn leiden(
    connectivities: &Array2<f64>,
    resolution: f64,
    random_state: u64,
) -> Result<Vec<i64>> {
    let (n, m) = connectivities.dim();
    if n != m {
        return Err(anyhow!(
            "leiden: connectivities must be square (N×N), got {n}×{m}"
        ));
    }

    let mut b = GraphDataBuilder::new(n);
    for i in 0..n {
        for j in (i + 1)..n {
            let w = connectivities[[i, j]];
            if w > 0.0 {
                b.add_edge(i, j, w)?;
            }
        }
    }
    run_leiden_graph(b, resolution, random_state)
}

pub fn leiden_from_csr(
    connectivities: &CsrMatrix<f64>,
    resolution: f64,
    random_state: u64,
) -> Result<Vec<i64>> {
    let (n, m) = (connectivities.nrows(), connectivities.ncols());
    if n != m {
        return Err(anyhow!(
            "leiden: connectivities must be square (N×N), got {n}×{m}"
        ));
    }

    let mut b = GraphDataBuilder::new(n);
    for i in 0..n {
        let row = connectivities.row(i);
        for (&j, &w) in row.col_indices().iter().zip(row.values().iter()) {
            if j > i && w > 0.0 {
                b.add_edge(i, j, w)?;
            }
        }
    }
    run_leiden_graph(b, resolution, random_state)
}

fn run_leiden_graph(b: GraphDataBuilder, resolution: f64, random_state: u64) -> Result<Vec<i64>> {
    let graph = b.build()?;

    let config = LeidenConfig::builder()
        .quality(QualityType::RBConfiguration)
        .resolution(resolution)
        .seed(random_state)
        .build();
    let out = Leiden::new(config)
        .run(&graph)
        .map_err(|e| anyhow!("leiden: leiden-rs failed: {e}"))?;

    Ok(out.partition.as_slice().iter().map(|&c| c as i64).collect())
}

pub fn run_leiden(data: &mut SoData, resolution: f64, random_state: u64) {
    let conn = match data.result.neighbors.as_ref() {
        Some(n) => &n.connectivities,

        None => return,
    };

    let labels = match leiden_from_csr(conn, resolution, random_state) {
        Ok(l) => l,
        Err(_) => return,
    };

    if let Some(obs) = data.obs.as_mut() {
        upsert_column(obs, Column::new("leiden".into(), labels));
    }
}

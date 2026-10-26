pub mod gsea;
pub mod ora;

pub use gsea::{run_gsea, GseaParams, RankBy};
pub use ora::{run_ora, OraParams};

pub(crate) fn bh_adjust(ps: &[f64]) -> Vec<f64> {
    let m = ps.len();
    if m == 0 {
        return Vec::new();
    }
    let mut order: Vec<usize> = (0..m).collect();
    order.sort_by(|&a, &b| {
        ps[a]
            .partial_cmp(&ps[b])
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut padj_sorted: Vec<f64> = order
        .iter()
        .enumerate()
        .map(|(rank, &j)| (ps[j] * (m as f64) / ((rank + 1) as f64)).min(1.0))
        .collect();

    for i in (1..m).rev() {
        if padj_sorted[i] < padj_sorted[i - 1] {
            padj_sorted[i - 1] = padj_sorted[i];
        }
    }
    let mut adj = vec![1.0f64; m];
    for (i, &j) in order.iter().enumerate() {
        adj[j] = padj_sorted[i];
    }
    adj
}
